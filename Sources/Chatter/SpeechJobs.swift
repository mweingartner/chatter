import Foundation
import ChatterCore

extension AppModel {
    func submit(_ input: SpeechRequest, requestID: String? = nil, respell: Bool = true, access: ClientAccess = ClientAccess()) throws -> SpeechJob {
        guard access.allows(.speak) else { throw ChatterError.invalid("This client cannot submit speech.") }
        var request = try input.validated()
        if let requestID {
            guard !requestID.isEmpty, requestID.utf8.count <= 128 else { throw ChatterError.invalid("requestID must be 1–128 UTF-8 bytes.") }
            if let existing = try history?.find(requestID: requestID, owner: access.ownerID) {
                guard existing.request.text == request.text, existing.request.pace == request.pace, existing.request.mode == request.mode,
                      existing.request.effectiveTone == request.effectiveTone,
                      existing.request.dialogue == request.dialogue, existing.request.language == request.language, existing.request.instruction == request.instruction,
                      (existing.request.dialogue != nil || existing.request.voice == request.voice || existing.voiceName.caseInsensitiveCompare(request.voice) == .orderedSame),
                      input.quality == nil || input.mode == "save" || input.quality == existing.request.quality,
                      input.sampleID == nil || input.sampleID == existing.request.sampleID else {
                    throw ChatterError.invalid("This requestID already belongs to different speech. Use a new ID.")
                }
                return existing
            }
        }
        guard activeJobs < settings.queueCapacity else { throw ChatterError.queueFull }
        if let owner = access.ownerID {
            guard jobs.count(where: { !$0.isTerminal && $0.clientID == owner }) < settings.clientQueueLimit,
                  submissionRate.allow(owner, limit: 60) else { throw ChatterError.queueFull }
        }
        try checkStorageBudget()
        let matches = voices.filter { $0.id == request.voice || $0.name.caseInsensitiveCompare(request.voice) == .orderedSame }
        guard matches.count == 1, let voice = matches.first else { throw ChatterError.invalid("Choose a saved voice by its unique ID or unambiguous name.") }
        guard access.allowsVoice(voice.id) else { throw ChatterError.invalid("This voice is not permitted for this client.") }
        let configuration = try voice.synthesisConfiguration.validated()
        if !configuration.kind.supportsInstructions, !(request.instruction ?? "").isEmpty {
            throw ChatterError.invalid(QwenCapabilities.cloneDeliveryNotice)
        }
        let references = try voice.references(overriding: request.sampleID)
        if configuration.kind == .cloned, request.sampleID == nil,
           voice.referenceSamples.reduce(0, { $0 + $1.metrics.duration }) > QwenCapabilities.maximumReferenceSeconds {
            throw ChatterError.invalid("Qwen voice sets support up to 180 seconds. Exclude some takes or use a single-take override; all originals remain saved.")
        }
        request.voice = voice.id
        request.tone = request.effectiveTone.rawValue
        request.quality = request.mode == "save" ? "studio" : (request.quality ?? settings.liveQuality)
        var job = SpeechJob(request: request, voiceName: voice.name)
        job.references = references
        job.voiceConfiguration = configuration
        job.engineName = QwenCapabilities.engine
        job.warnings = QwenCapabilities.warnings(configuration: configuration, request: request)
        if let dialogue=request.dialogue {
            job.voiceName = "Dialogue • " + dialogue.cast.keys.sorted().joined(separator:", ")
            job.dialogueTurns = try dialogue.turns.map { turn in
                let matches=voices.filter { $0.id == dialogue.cast[turn.actor] || $0.name.caseInsensitiveCompare(dialogue.cast[turn.actor]!) == .orderedSame }
                guard matches.count == 1, let actorVoice=matches.first else { throw ChatterError.invalid("Assign a unique saved voice to actor \(turn.actor).") }
                guard access.allowsVoice(actorVoice.id) else { throw ChatterError.invalid("A dialogue voice is not permitted for this client.") }
                let config=try actorVoice.synthesisConfiguration.validated()
                let line=try SpeechRequest(voice:actorVoice.id,text:turn.text,tone:turn.tone ?? request.tone,language:turn.language ?? request.language,instruction:turn.instruction).validated()
                if !config.kind.supportsInstructions, !(line.instruction ?? "").isEmpty { throw ChatterError.invalid("\(turn.actor): " + QwenCapabilities.cloneDeliveryNotice) }
                let refs=try actorVoice.references().map { EngineReference(reference:ChatterPaths.voices.appending(path:actorVoice.id).appending(path:$0.sampleID).appending(path:"reference.wav").path,transcript:$0.transcript) }
                job.warnings = Array(Set((job.warnings ?? []) + QwenCapabilities.warnings(configuration:config,request:line)))
                return EngineDialogueTurn(actor:turn.actor,voiceID:actorVoice.id,text:turn.text,configuration:config,references:refs,language:line.language ?? config.language,instruction:line.instruction,toneCue:line.effectiveTone.cue)
            }
        }
        job.toneCue = request.effectiveTone.cue
        job.sequence = nextSequence; job.requestID = requestID; job.clientID = access.ownerID
        if !respell { job.respell = false }
        job.expressive = false // Qwen receives delivery instructions directly; no external annotation pass.
        try history!.save(job)
        nextSequence += 1; jobs.insert(job, at: 0); drain(); return job
    }
    func cancelJob(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].isTerminal else { return }
        let wasActive = jobs[i].state != "queued"
        jobs[i].state = "cancelled"; jobs[i].message = "Cancelled"
        if wasActive { engine.cancel(id); playback.stop() }
        persistJob(id)
    }
    func cancelAll() { for id in jobs.filter({ !$0.isTerminal }).map(\.id) { cancelJob(id) } }
    func drain() {
        guard !processing, engine.ready else { return }
        processing = true
        Task {
            defer { processing = false }
            while engine.ready, let next = jobs.last(where: { $0.state == "queued" }) { await perform(next) }
        }
    }
    private func change(_ id: String, _ update: (inout SpeechJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }; update(&jobs[i])
    }
    private func perform(_ job: SpeechJob) async {
        let id = job.id
        // Playback chunks are read when they arrive; only the final WAV outlives the job.
        defer { removePlaybackChunks(id) }
        playback.stop()
        var output: URL?
        do {
            try checkStorageBudget()
            guard let voice = voices.first(where: { $0.id == job.request.voice }) else { throw ChatterError.invalid("The voice profile is unavailable.") }
            // Old receipts retain their explicit single-take behavior after migration.
            let configuration = try (job.voiceConfiguration ?? voice.synthesisConfiguration).validated()
            let references = try job.references ?? voice.references(overriding: job.request.sampleID)
            let payload = references.map { reference in
                ["reference":ChatterPaths.voices.appending(path: voice.id).appending(path: reference.sampleID).appending(path: "reference.wav").path,
                 "transcript":reference.transcript]
            }
            let directory = ChatterPaths.jobs.appending(path: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = job.request.mode == "save" ? URL(filePath: settings.outputDirectory).appending(path: "Chatter-\(id).wav") : directory.appending(path: "speech.wav")
            output = destination
            if job.request.mode == "play" { playback.prepare(pace: Float(job.request.pace)) }
            change(id) { $0.state = "generating"; $0.message = "Generating speech…"; $0.attempts += 1 }
            if let receipt = jobs.first(where: { $0.id == id }) { try history!.save(receipt) }
            let start = ContinuousClock.now
            // Preserve an already accepted legacy plan on restart, but never run Ollama for speech.
            let noted = job.expressionPlan?.annotate(job.request.text).text ?? job.request.text
            // Pronunciations apply as the job is spoken, so edits reach queued requests; the receipt keeps the original text.
            // Respelling runs off the main actor so a long text and list never stall the UI or the API, and never touches a
            // note, whether a review placed it or the writer typed it.
            let spokenText: String
            if job.respell == false { spokenText = job.request.text } else {
                let list = pronunciations
                spokenText = try await Task.detached(priority: .userInitiated) { try list.respell(noted, protecting: LeadingNote.ranges(in: noted)) }.value
            }
            var command: [String:Any] = ["id":id, "op":"synthesize", "text":spokenText,
                "references":payload, "voiceConfiguration":object(configuration),
                "language":job.request.language ?? configuration.language, "instruction":job.request.instruction ?? "",
                "toneCue":job.request.effectiveTone.cue,"mode":job.request.mode,"pace":job.request.pace,
                "quality":job.request.quality ?? "responsive","directory":directory.path,"output":directory.appending(path: "speech.wav").path,
                "maximumAudioSeconds":settings.maximumSpeechMinutes * 60, "maximumGenerationSeconds":settings.maximumGenerationMinutes * 60]
            if let turns=job.dialogueTurns {
                var prepared=turns
                for i in prepared.indices where job.respell != false { prepared[i].text = try pronunciations.respell(prepared[i].text,protecting:LeadingNote.ranges(in:prepared[i].text)) }
                command["dialogueTurns"]=object(prepared);command["gapSeconds"]=job.request.dialogue?.gapSeconds ?? 0.35
            }
            let result = try await engine.command(command, timeout: Double(settings.maximumGenerationMinutes * 60)) { [weak self] event in
                guard let self, self.jobs.first(where: { $0.id == id })?.state != "cancelled" else { return }
                if event["event"] as? String == "chunk", let path = event["path"] as? String {
                    self.playback.enqueue(URL(filePath: path), pace: Float(job.request.pace))
                    self.change(id) {
                        if $0.firstAudioSeconds == nil { let elapsed = start.duration(to: .now).components; $0.firstAudioSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 }
                        $0.state = "playing"; $0.message = "Speaking…"
                    }
                } else if let message = event["message"] as? String { self.change(id) { $0.message = message } }
            }
            guard jobs.first(where: { $0.id == id })?.state != "cancelled" else { return }
            let generated = directory.appending(path: "speech.wav")
            guard (result["path"] as? String) == generated.path else { throw ChatterError.unavailable("Engine returned an unexpected output path.") }
            if job.request.mode == "save" {
                // The restricted helper writes only inside Jobs. Publish through an owner-only temporary file.
                let partial = destination.appendingPathExtension("partial")
                do {
                    try FileManager.default.copyItem(at: generated, to: partial)
                    try PrivateStorage.protectFile(partial)
                    try FileManager.default.moveItem(at: partial, to: destination)
                    try FileManager.default.removeItem(at: generated)
                } catch { try? FileManager.default.removeItem(at: partial); throw error }
            }
            change(id) {
                $0.path = destination.path; $0.elapsedSeconds = result["elapsedSeconds"] as? Double
                $0.duration = result["duration"] as? Double; $0.profile = result["profile"] as? String
                $0.sampleRate = result["sampleRate"] as? Int; $0.modelID = result["modelID"] as? String
                $0.engineName = QwenCapabilities.engine
                if let timing=result["dialogueTiming"], let data=try? JSONSerialization.data(withJSONObject:timing) { $0.dialogueTiming=try? JSONDecoder().decode([DialogueTiming].self,from:data) }
            }
            if job.request.mode == "play" { try await playback.finish() }
            guard jobs.first(where: { $0.id == id })?.state != "cancelled" else { return }
            change(id) { $0.state = "completed"; $0.message = job.request.mode == "save" ? "Saved WAV • 24 kHz / 24-bit" : "Finished speaking" }
        } catch {
            if jobs.first(where: { $0.id == id })?.state != "cancelled" { change(id) { $0.state = "failed"; $0.message = error.localizedDescription }; playback.stop() }
            // An engine that died mid-write cannot remove its in-progress file; never leave one beside saved audio.
            if let output { try? FileManager.default.removeItem(atPath: output.path + ".partial") }
        }
        persistJob(id)
        trimHistory()
    }
    private func removePlaybackChunks(_ id: String) {
        let directory = ChatterPaths.jobs.appending(path: id)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasPrefix("turn-") || file.hasPrefix("part-") && file.hasSuffix(".wav") || file == "unpaced.wav" || file.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }
    func archiveFinishedJobs() {
        do {
            try history?.archiveFinished()
            jobs.removeAll { $0.isTerminal }
            notice = "Finished activity archived. Retention preferences still apply."
        } catch { self.error = error.localizedDescription }
    }
    func persistJob(_ id: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        do { try history!.save(job) } catch { self.error = "Queue persistence failed: \(error.localizedDescription)" }
    }
    func persistJobs() {
        do {
            for job in jobs { try history!.save(job) }
        } catch { self.error = "Queue persistence failed: \(error.localizedDescription)" }
    }
}

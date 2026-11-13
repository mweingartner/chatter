import ChatterAudioKit
import ChatterCore
import Qwen3Speech
import Foundation
@preconcurrency import MLX

/// Serial Qwen generation, typed delivery instructions, native-rate PCM and one final pace pass.
struct SynthesisJob {
    let engine: SpeechEngineCore
    let command: SynthesizeCommand
    /// Dialogue forwards unpaced chunks while retaining one ordered parent job.
    var onChunk: (([Float]) throws -> Void)? = nil
    func run() throws -> [String:Any] {
        if let turns=command.dialogueTurns { return try DialogueSynthesis(engine:engine,command:command,turns:turns).run() }
        let c=command
        guard let mode = SpeechMode(rawValue: c.mode) else { throw EngineFailure.invalid(SpeechMode.validationMessage) }
        // Play and render are live audio (short passages); only save is an export.
        let live = !mode.exportsWAV
        guard c.pace.isFinite, (0.5...2).contains(c.pace) else { throw EngineFailure.invalid("Pace must be between 0.5 and 2.0.") }
        guard ["responsive","balanced","studio"].contains(c.quality ?? "balanced") else { throw EngineFailure.invalid("Quality must be responsive, balanced or studio.") }
        let voice=try (c.voiceConfiguration ?? QwenVoiceConfiguration()).validated()
        let language=try QwenCapabilities.language(c.language ?? voice.language)
        if !voice.kind.supportsInstructions, let instruction=c.instruction, !instruction.isEmpty { throw EngineFailure.invalid(QwenCapabilities.cloneDeliveryNotice) }
        let quality = SpeechQuality(rawValue: c.quality ?? "balanced") ?? .balanced
        let profile = SpeechProfile(rawValue: quality.modelProfile(for: voice.kind, mode: c.mode, studioClones: engine.configuration.studioClones))!
        let (directory,output)=try paths()
        let start=ContinuousClock.now
        let deadline = start + .seconds(min(14400, max(1, c.maximumGenerationSeconds ?? 3600)))
        if profile == .quality, !engine.loadedProfiles.contains("quality") { engine.send(c.id,"progress",["message":"Loading the studio voice model…"]) }
        let model=try engine.model(profile)
        let conditioning=voice.kind == .cloned ? try engine.conditioning(c.references,profile:profile,language:language) : nil
        let instruction=[c.toneCue,c.instruction].compactMap { $0 }.joined(separator:" ")
        // A passage with nothing to say (only punctuation or symbols) is not sent to the model, which
        // would answer with silence it may never end.
        let passages=try DeliveryPassages.passages(QwenPromptSafety.spokenText(c.text),maxBytes:live ? 220 : 380,instruction:instruction,supportsInstructions:voice.kind.supportsInstructions).filter { Self.isSpeakable($0.text) }
        guard !passages.isEmpty else { throw EngineFailure.invalid("Enter text to speak.") }
        // A voice says a sentence the same way every time: each passage draws from a seed of its own.
        let seed=c.seed ?? PassageSeed.voice(voice,references:c.references,profile:profile.rawValue,language:language)
        let generation=QwenGeneration.settings(for:voice.kind)
        // Only speech played on this Mac is heard while it is made. A render is downloaded when it is
        // finished, so it is generated like a saved file: every passage is checked, and generated again
        // if need be, before any of it counts.
        let streams=mode.playsOnMac && quality.streamsChunks
        var options=QwenGenerationOptions()
        options.framesAfterEnd=generation.framesAfterEnd
        if streams { options.laterChunkSeconds=Self.laterChunkSeconds }
        let paced=abs(c.pace-1)>0.0001
        let unpaced=directory.appending(path:"unpaced.wav")
        let writer=try WAVStreamWriter(url:paced ? unpaced : output,sampleRate:24000,maximumSeconds: min(7200, max(1,c.maximumAudioSeconds ?? 1800)) * c.pace)
        var complete=false
        defer { if !complete { writer.cancel(); try? FileManager.default.removeItem(at:output) } }
        var firstAudio:Double?, chunks=0,frames=0,retries=0
        func deliver(_ samples:[Float]) throws {
            guard ContinuousClock.now < deadline else { throw EngineFailure.failed("Generation time limit reached.") }
            try checkCancelled()
            try writer.append(Self.validated(samples))
            if mode.playsOnMac {
                if let onChunk { try onChunk(samples); return }
                let part=directory.appending(path:"part-\(chunks).wav")
                try AudioIO.writePCM24(samples,sampleRate:24000,to:part)
                if firstAudio == nil { firstAudio=(ContinuousClock.now-start).seconds }
                engine.send(c.id,"chunk",["path":part.path,"index":chunks,"firstAudioSeconds":firstAudio!]);chunks+=1
            }
        }
        for (index,passage) in passages.enumerated() {
            try checkCancelled()
            let prompt:String? = switch voice.kind {
            case .cloned: nil
            case .preset: [voice.speaker!,passage.instruction].filter { !$0.isEmpty }.joined(separator:", ")
            case .designed: [voice.description!,passage.instruction].filter { !$0.isEmpty }.joined(separator:" ")
            }
            let tokens=model.textTokenCount(passage.text)
            var envelope=PassageEnvelope(trimsEdges:true,softensEnding:true)
            /// Whether any of this passage has been handed on to be heard: from then on it cannot be
            /// generated again without being said twice.
            var heard=false
            /// A whole attempt that ended but is not good, kept in case no attempt does better.
            var imperfect:(samples:[Float],fault:Double)?
            let audio=try PassageAttempts.run(passage:index+1,of:passages.count,retrying:{ fault in
                retries+=1
                engine.send(c.id,"progress",["message":"Passage \(index+1) of \(passages.count) \(Self.described(fault)); generating it again…"])
            },fallback:{ imperfect?.samples }) { attempt -> [Float] in
                MLXRandom.seed(PassageSeed.passage(base:seed,text:passage.text,prompt:prompt ?? "",attempt:attempt))
                envelope=PassageEnvelope(trimsEdges:true,softensEnding:true)
                var activity=SpeechActivity()
                var whole:[Float]=[]
                var verdict=PassageWatch.Verdict.carryOn
                do {
                    _ = try model.generateVoiceDesign(text:passage.text,instruct:prompt,language:language,conditioning:conditioning,refAudio:nil,refText:nil,temperature:Float(c.temperature ?? generation.temperature),topK:generation.topK,topP:Float(generation.topP),repetitionPenalty:1.05,minP:0,maxTokens:2048,streamingInterval:0.8,onToken:{ _ in frames+=1;engine.noteActivity() },onAudioChunk:{ chunk in
                        let samples=try Self.validated(chunk.asArray(Float.self))
                        activity.append(samples)
                        if verdict == .carryOn { verdict=PassageWatch.verdict(activity,tokens:tokens) }
                        // What has been heard cannot be taken back: such a passage is ended where it is.
                        if !heard {
                            if verdict == .neverSpoke { throw PassageAttempts.Fault.neverSpoke }
                            if verdict == .stalled { throw PassageAttempts.Fault.stalled }
                        } else if verdict == .neverSpoke { verdict = .carryOn }
                        if streams {
                            let ready=envelope.append(samples)
                            if !ready.isEmpty { try deliver(ready);heard=true }
                        } else { whole += samples }
                    },isCancelled:{ engine.isCancelled(c.id) || ContinuousClock.now >= deadline },wholeTextFirst:generation.wholeTextFirst,options:options,shouldEnd:{ verdict != .carryOn })
                } catch AudioGenerationError.frameBudgetReached where heard {
                    // Streamed speech has already played, so generating the passage again would say it
                    // twice. A run-on loops in silence after the words, so keep them and move on.
                    engine.send(c.id,"progress",["message":"Passage \(index+1) of \(passages.count) ran on after its words; continuing."])
                }
                if streams { return [] }
                // A whole passage is judged before any of it is used.
                let fault=(PassageWatch.saysEnough(activity,tokens:tokens) || !activity.hasSpoken ? 0 : 10)+max(0,activity.longestPause-PassageWatch.longestSilence)
                if fault > 0 {
                    if imperfect == nil || fault < imperfect!.fault { imperfect=(whole,fault) }
                    throw PassageAttempts.Fault.stalled
                }
                return whole
            }
            if streams {
                let tail = envelope.finish()
                if !tail.isEmpty { try deliver(tail) }
            } else {
                var shaped=PassageEnvelope(softensEnding:true)
                let body=shaped.append(shaped.trimmingEdgeSilence(try Self.validated(audio)))
                try deliver(body + shaped.finish())
            }
            // A short pause between sentences, preserved in the final WAV and live playback. Passages
            // keep 100 ms of silence after their last sound and 50 ms before their first, so
            // sentences measure about a quarter second apart (about 0.55 s with 300 ms here and
            // untrimmed edges, which Michael found far too long).
            if index<passages.count-1 { try deliver([Float](repeating:0,count:Self.sentenceGap)) }
            engine.send(c.id,"progress",["message":"Generated passage \(index+1) of \(passages.count)","segments":index+1])
        }
        try checkCancelled();try writer.finish()
        if paced { try PaceRenderer.render(input:unpaced,output:output,rate:Float(c.pace));try? FileManager.default.removeItem(at:unpaced) }
        try checkCancelled(removing:output);complete=true
        return ["path":output.path,"duration":try AudioIO.duration(of:output),"elapsedSeconds":(ContinuousClock.now-start).seconds,"firstAudioSeconds":firstAudio.map { $0 as Any } ?? NSNull(),"profile":profile.rawValue,"modelID":"Qwen3/\(profile.rawValue)","engineName":"Qwen3-TTS","sampleRate":24000,"bitsPerSample":24,"seed":seed,"frames":frames,"passages":passages.count,"retries":retries]
    }
    /// Streamed chunks after a passage's first hold 0.4 s, so a player is never more than a few
    /// tenths of a second from its next audio.
    static let laterChunkSeconds = 0.4

    /// Whether `text` holds a letter or digit in any script.
    static func isSpeakable(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    static func described(_ fault: PassageAttempts.Fault) -> String {
        switch fault {
        case .neverEnded: "did not finish"
        case .neverSpoke: "did not start"
        case .stalled: "went quiet partway"
        }
    }

    /// Silence between sentences: 180 ms at 24 kHz.
    static let sentenceGap = 4_320

    static func validated(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw EngineFailure.failed("Model produced invalid audio.") }
        return samples
    }

    private func checkCancelled(removing output: URL? = nil) throws {
        guard engine.isCancelled(command.id) else { return }
        if let output { try? FileManager.default.removeItem(at: output) }
        throw EngineFailure.cancelled
    }

    /// The job directory must be inside the engine's data root; outputs must be WAV files.
    private func paths() throws -> (URL, URL) {
        let jobs = engine.configuration.dataRoot.appending(path: "Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        guard try PathPolicy.isInside(command.directory, directory: jobs.path) else { throw EngineFailure.invalid("Invalid job directory.") }
        let directory = URL(filePath: try PathPolicy.canonical(command.directory))
        let output = URL(filePath: try PathPolicy.canonical(command.output))
        guard output.pathExtension.lowercased() == "wav" else { throw EngineFailure.invalid("Output must be an absolute WAV path.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (directory, output)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

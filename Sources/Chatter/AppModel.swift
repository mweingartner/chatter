import SwiftUI
import ServiceManagement
import Security
import ChatterCore

@MainActor @Observable
final class AppModel {
    var settings = Settings()
    var voices: [VoiceProfile] = []
    /// How product names and acronyms are said; applied to text as it is spoken.
    var pronunciations = PronunciationList() { didSet { sortedPronunciations = pronunciations.sorted } }
    /// `pronunciations` in display order, kept sorted so long lists redraw cheaply.
    private(set) var sortedPronunciations: [Pronunciation] = []
    var jobs: [SpeechJob] = []
    @ObservationIgnored var archivedJobs: [SpeechJob] = []
    /// Optional local models for on-demand pronunciation suggestions.
    var ollamaModels: [OllamaModel] = []
    var expressionStatus: ExpressionStatus = .checking
    var error: String?
    var notice: String?
    var preparing = false
    var preparationMessage = ""
    var installing = false
    var installLog = ""
    var serverStatus = "Starting"
    let engine = SpeechEngine()
    let playback = AudioPlayback()
    @ObservationIgnored let server = HTTPServer()
    @ObservationIgnored var processing = false
    @ObservationIgnored var nextSequence: UInt64 = 1
    @ObservationIgnored private var token = ""
    @ObservationIgnored var installTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored var selectedPage = "studio"
    var activeJobs: Int { jobs.count { !$0.isTerminal } }
    /// The studio model stays loaded when asked to, or when studio is the default live quality
    /// (so live studio speech never waits for a model load).
    var keepStudioResident: Bool { settings.keepStudioLoaded || settings.liveQuality == "studio" }
    var defaultVoice: VoiceProfile? { voices.first { $0.id == settings.defaultVoiceID } ?? voices.first }
    var loginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Awaiting approval in System Settings"
        case .notRegistered: "Not registered"
        case .notFound: "App registration unavailable"
        @unknown default: "Unknown"
        }
    }

    func start() {
        guard !started else { return }; started = true
        do {
            try ChatterPaths.makeDirectories()
            let settingsURL = ChatterPaths.root.appending(path: "settings.json")
            if FileManager.default.fileExists(atPath: settingsURL.path) { settings = try ChatterPaths.load(Settings.self, from: settingsURL) }
            let voicesURL = ChatterPaths.root.appending(path: "voices.json")
            voices = try DefaultVoices.loadOrCreate(at: voicesURL)
            loadPronunciations()
            jobs = try JobStore().load()
            archivedJobs = try JobStore(directory: ChatterPaths.root.appending(path: "ArchivedReceipts")).load()
            nextSequence = max(settings.nextJobSequence, ((jobs + archivedJobs).map(\.sequence).max() ?? 0) + 1)
            for i in jobs.indices where !jobs[i].isTerminal {
                jobs[i].state = "queued"; jobs[i].message = "Restored after app restart"
                try JobStore().save(jobs[i])
            }
            try loadToken()
            try FileManager.default.createDirectory(atPath: settings.outputDirectory, withIntermediateDirectories: true)
            server.route = { [weak self] request in await self?.route(request) ?? HTTPResponse(status: 503) }
            server.onError = { [weak self] message in self?.serverStatus = "Error: \(message)"; self?.error = message }
            playback.onError = { [weak self] message in self?.error = message }
            engine.onReady = { [weak self] in
                guard let self else { return }
                self.drain()
                Task { await self.warmVoices(); await self.importLucyIfNeeded() }
            }
            applyNetwork(); engine.keepStudioLoaded = keepStudioResident; engine.start()
            if Bundle.main.bundleURL.pathExtension == "app", settings.launchAtLogin {
                do { try SMAppService.mainApp.register() } catch { notice = "Login startup needs attention in General settings: \(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() { installTask?.cancel(); engine.stop(); playback.stop(); server.stop() }
    func saveSettings() {
        do {
            guard (1024...65535).contains(settings.port) else { throw ChatterError.invalid("Port must be between 1024 and 65535.") }
            guard (100...10000).contains(settings.queueCapacity) else { throw ChatterError.invalid("Queue capacity must be between 100 and 10,000.") }
            guard settings.outputDirectory.hasPrefix("/") else { throw ChatterError.invalid("Choose an absolute output folder.") }
            _ = try OllamaClient.validatedAddress(settings.ollamaAddress)
            try FileManager.default.createDirectory(atPath: settings.outputDirectory, withIntermediateDirectories: true)
            try ChatterPaths.save(settings, to: ChatterPaths.root.appending(path: "settings.json"))
            engine.configure(keepStudioLoaded: keepStudioResident)
        } catch { self.error = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = enabled; saveSettings()
        } catch { self.error = error.localizedDescription }
    }
    func applyNetwork() {
        do {
            try server.start(port: settings.port, allowLAN: settings.allowLAN)
            serverStatus = settings.allowLAN ? "Local and LAN • port \(settings.port)" : "This Mac • port \(settings.port)"
            saveSettings()
        } catch { self.error = error.localizedDescription; serverStatus = "Unavailable" }
    }
    private func loadToken() throws {
        let url = ChatterPaths.root.appending(path: "api-token")
        if FileManager.default.fileExists(atPath: url.path) { token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        if token.count < 32 { try rotateToken() }
    }
    func rotateToken() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatterError.unavailable("Cannot create a secure API token.") }
        token = Data(bytes).base64EncodedString()
        let url = ChatterPaths.root.appending(path: "api-token")
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func authorized(_ request: HTTPRequest) -> Bool {
        let expected = Array(("Bearer " + token).utf8), actual = Array((request.headers["authorization"] ?? "").utf8)
        guard !token.isEmpty, actual.count == expected.count else { return false }
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func copyToken() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string); notice = "Connection token copied." }
    func saveVoices() throws { try ChatterPaths.save(voices, to: ChatterPaths.root.appending(path: "voices.json")) }
    func createVoice(name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatterError.invalid("Name this voice first.") }
        let voice = VoiceProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines)); voices.append(voice)
        if settings.defaultVoiceID == nil { settings.defaultVoiceID = voice.id; saveSettings() }
        try saveVoices(); return voice.id
    }
    func removeVoice(_ id: String) {
        guard !jobs.contains(where: { !$0.isTerminal && ($0.request.voice == id || $0.dialogueTurns?.contains { $0.voiceID == id } == true) }) else { error = "Cancel this voice's active jobs before removing it."; return }
        voices.removeAll { $0.id == id }
        if settings.defaultVoiceID == id { settings.defaultVoiceID = voices.first?.id; saveSettings() }
        do { try saveVoices() } catch { self.error = error.localizedDescription }
        // Recordings remain on disk for recovery; removing a profile is reversible.
    }
    func selectSample(voiceID: String, sampleID: String) {
        guard let index = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[index].selectedSampleID = sampleID
        voices[index].useReferenceSet = false
        do { try saveVoices(); Task { await warmVoices() } } catch { self.error = error.localizedDescription }
    }
    func updateVoice(_ voice: VoiceProfile) {
        guard let index = voices.firstIndex(where: { $0.id == voice.id }) else { return }
        voices[index] = voice
        do { try saveVoices() } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func addSample(voiceID: String, source: URL, transcript: String, label: String, warm: Bool = true) async -> Bool {
        guard !preparing else { return false }
        error = nil
        preparing = true; preparationMessage = "Checking and preparing your recording…"
        defer { preparing = false }
        let id = UUID().uuidString
        let destination = ChatterPaths.voices.appending(path: voiceID).appending(path: id)
        do {
            let result = try await engine.command(["op":"prepare", "source":source.path, "destination":destination.path, "transcript":transcript]) { [weak self] event in
                if let message = event["message"] as? String { self?.preparationMessage = message }
            }
            guard let index = voices.firstIndex(where: { $0.id == voiceID }), let metrics = result["metrics"], let text = result["transcript"] as? String else { throw ChatterError.unavailable("Voice preparation returned incomplete data.") }
            var sample = VoiceSample(id: id, label: label, transcript: text, metrics: try JSONDecoder().decode(RecordingMetrics.self, from: JSONSerialization.data(withJSONObject: metrics)))
            sample.originalFileName = result["originalFileName"] as? String
            voices[index].samples.append(sample)
            if voices[index].selectedSampleID == nil { voices[index].selectedSampleID = id }
            try saveVoices(); if warm { await warmVoices() }
            notice = "Recording added to the voice library. Review its transcript and preview the voice set."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func warmVoices() async {
        guard engine.ready else { return }
        for voice in voices {
            guard voice.kind == .cloned, !voice.referenceSamples.isEmpty else { continue }
            let references = voice.referenceSamples.map { ["reference":voice.sampleDirectory($0).appending(path: "reference.wav").path,"transcript":$0.transcript] }
            do { _ = try await engine.command(["op":"precache", "references":references,"language":voice.synthesisConfiguration.language]) }
            catch { self.error = "Could not warm \(voice.name): \(error.localizedDescription)" }
        }
    }
    private func importLucyIfNeeded() async {
        let marker = ChatterPaths.root.appending(path: "lucy-import-checked")
        guard !FileManager.default.fileExists(atPath: marker.path), voices.isEmpty else { return }
        let refs = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lucy-fish-speech/fish-speech/references")
        if let directories = try? FileManager.default.contentsOfDirectory(at: refs, includingPropertiesForKeys: nil) {
            for directory in directories {
                let wav = directory.appending(path: "sample.wav"), lab = directory.appending(path: "sample.lab")
                guard FileManager.default.fileExists(atPath: wav.path), let text = try? String(contentsOf: lab, encoding: .utf8) else { continue }
                do {
                    let metadata = UserDefaults(suiteName: "com.lucy.app")?.data(forKey: "fishSpeechSavedVoices")
                    let records = metadata.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
                    let name = records.last { $0["id"] as? String == directory.lastPathComponent }?["name"] as? String ?? "Imported from Lucy"
                    let id = try createVoice(name: name)
                    await addSample(voiceID: id, source: wav, transcript: text, label: "Original Lucy reference")
                } catch { self.error = error.localizedDescription }
            }
        }
        try? Data().write(to: marker)
    }
}

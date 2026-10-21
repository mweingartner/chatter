import Foundation
import ChatterCore
import ChatterSystemSpeech

extension AppModel {
    /// Starts a recorded voice from an installed macOS voice that speaks with `accent`: the voice
    /// reads `VoiceAccents.referencePassage`, and that recording (with its exact transcript) is
    /// prepared like any imported take. Qwen voice design can't produce accents; cloning carries
    /// the macOS speaker's accent and timbre. Returns the new voice's ID, or nil after reporting why.
    func createVoice(name: String, from systemVoice: SystemVoiceOption, accent: VoiceAccent, language: String, description: String?) async -> String? {
        guard !preparing else { return nil }
        let text = VoiceAccents.referencePassage
        var created: String?
        // The app's own temporary folder, which the sandboxed engine cannot write (it can write
        // Jobs); addSample copies the recording into Jobs itself.
        let staging = FileManager.default.temporaryDirectory.appending(path: "chatter-accent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            // Busy while the macOS voice speaks, so no other import starts; addSample takes over after.
            preparing = true; preparationMessage = "\(systemVoice.name) is reading the reference passage…"
            defer { preparing = false }
            try PrivateStorage.directory(staging)
            let source = staging.appending(path: "macos-voice.aiff")
            try await SystemSpeech.render(text, voiceIdentifier: systemVoice.id, to: source)
            preparing = false
            let id = try createVoice(name: name)
            created = id
            guard var voice = voices.first(where: { $0.id == id }) else { return nil }
            voice.notes = "Started from the macOS voice \(systemVoice.name) (\(accent.name)) because Qwen voice design can't produce accents. It sounds like that macOS speaker. Apple's license limits macOS voices to personal, non-commercial use: don't publish or share audio made with this voice."
                + (description.map { " Requested: \($0)" } ?? "")
            voice.qwen = try QwenVoiceConfiguration(kind: .cloned, language: language).validated()
            updateVoice(voice)
            guard await addSample(voiceID: id, source: source, transcript: text, label: "macOS voice \(systemVoice.name) (\(accent.name))") else {
                removeVoice(id)
                if error == nil { error = "Couldn't prepare \(systemVoice.name)'s recording. Try again." }
                return nil
            }
            notice = "Created \(name) from the macOS voice \(systemVoice.name), with its \(accent.name) accent."
            return id
        } catch {
            if let created { removeVoice(created) }
            self.error = error.localizedDescription
            return nil
        }
    }
}

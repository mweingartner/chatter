import Foundation

/// Public starter library. Built-in speaker IDs require no recordings or private profiles.
public enum DefaultVoices {
    public static var profiles: [VoiceProfile] {
        [
            ("Aiden", "AA93FC30-E223-456E-A50A-214D78B1C916"),
            ("Ryan", "672989BA-4CE1-4CB6-A887-7EA8F1ADB82A"),
        ].map { name, id in
            var voice = VoiceProfile(name: name)
            voice.id = id
            voice.createdAt = Date(timeIntervalSince1970: 0)
            voice.notes = "Qwen built-in speaker. Supports tone and delivery instructions."
            voice.qwen = QwenVoiceConfiguration(kind: .preset, speaker: name, language: "English")
            return voice
        }
    }

    /// Seed only a new library. Preserve existing libraries, including intentionally empty ones.
    public static func loadOrCreate(at url: URL) throws -> [VoiceProfile] {
        if FileManager.default.fileExists(atPath: url.path) {
            return try ChatterPaths.load([VoiceProfile].self, from: url)
        }
        let voices = profiles
        try ChatterPaths.save(voices, to: url)
        return voices
    }
}

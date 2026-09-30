import Foundation

public enum VoiceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case cloned, preset, designed
    public var id: String { rawValue }
    public var title: String {
        switch self { case .cloned: "Recorded voice"; case .preset: "Built-in speaker"; case .designed: "Designed voice" }
    }
    public var supportsInstructions: Bool { self != .cloned }
}

/// Additive voice metadata. A missing value on a pre-3.0 profile means a recorded voice.
public struct QwenVoiceConfiguration: Codable, Sendable, Equatable {
    public var kind: VoiceKind
    public var speaker: String?
    public var description: String?
    public var language: String
    public init(kind: VoiceKind = .cloned, speaker: String? = nil, description: String? = nil, language: String = "Auto") {
        self.kind = kind; self.speaker = speaker; self.description = description; self.language = language
    }
    public func validated() throws -> Self {
        var copy = self
        copy.language = try QwenCapabilities.language(language)
        switch kind {
        case .cloned: break
        case .preset:
            guard let matched = QwenCapabilities.speakers.first(where: { $0.id.caseInsensitiveCompare(speaker ?? "") == .orderedSame }) else {
                throw ChatterError.invalid("Choose one of Qwen’s built-in speakers.")
            }
            copy.speaker = matched.id
        case .designed:
            let text = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 2_000 else { throw ChatterError.invalid("Describe the voice in 1–2,000 UTF-8 bytes.") }
            copy.description = text
        }
        return copy
    }
}

public struct QwenSpeaker: Codable, Sendable, Identifiable {
    public let id: String
    public let description: String
    public let language: String
}

public enum QwenCapabilities {
    public static let engine = "Qwen3-TTS"
    public static let sampleRate = 24_000
    public static let languages = ["Auto", "Chinese", "English", "Japanese", "Korean", "German", "French", "Russian", "Portuguese", "Spanish", "Italian"]
    public static let maximumReferenceSeconds = 180.0
    public static let speakers: [QwenSpeaker] = [
        .init(id: "Vivian", description: "Bright, expressive female voice", language: "Chinese"),
        .init(id: "Serena", description: "Warm, gentle female voice", language: "Chinese"),
        .init(id: "Uncle_Fu", description: "Mature male voice with a mellow timbre", language: "Chinese"),
        .init(id: "Dylan", description: "Youthful male voice; Beijing dialect", language: "Chinese"),
        .init(id: "Eric", description: "Lively male voice; Sichuan dialect", language: "Chinese"),
        .init(id: "Ryan", description: "Dynamic male voice with rhythmic delivery", language: "English"),
        .init(id: "Aiden", description: "Sunny American male voice", language: "English"),
        .init(id: "Ono_Anna", description: "Playful female voice", language: "Japanese"),
        .init(id: "Sohee", description: "Warm, expressive female voice", language: "Korean")
    ]
    public static func language(_ input: String) throws -> String {
        guard let value = languages.first(where: { $0.caseInsensitiveCompare(input) == .orderedSame }) else {
            throw ChatterError.invalid("Unsupported language. Choose: " + languages.joined(separator: ", "))
        }
        return value
    }
    public static let cloneDeliveryNotice = "Qwen cloned voices inherit delivery from their recordings. This Base model does not support tone or delivery instructions. Use a built-in or designed voice for instruction control."
    public static func warnings(configuration: QwenVoiceConfiguration, request: SpeechRequest) -> [String] {
        configuration.kind == .cloned && request.effectiveTone != .natural ? [cloneDeliveryNotice] : []
    }
}

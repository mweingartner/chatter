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
    /// Qwen voice design controls gender, age, pitch, pace, emotion and delivery, but not accent:
    /// accent requests come out as standard American English (measured 2026-10-17, and noted by
    /// the model's users). A recorded reference in the accent carries it through cloning.
    public static let designAccentNotice = "Qwen voice design can't produce accents or dialects; a requested accent comes out as standard American English. For an accent, start a recorded voice from a speaker who has it: a macOS voice in that accent, or your own recording."
    /// Whether a voice description asks for an accent: "accent", "accented", "dialect", or a
    /// named variety such as "Indian English".
    public static func describesAccent(_ description: String?) -> Bool {
        guard let description else { return false }
        if description.range(of: #"\b(accent(s|ed)?|dialects?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return VoiceAccents.namesVariety(description)
    }
    public static func warnings(configuration: QwenVoiceConfiguration, request: SpeechRequest) -> [String] {
        var warnings: [String] = []
        if configuration.kind == .cloned && request.effectiveTone != .natural { warnings.append(cloneDeliveryNotice) }
        if configuration.kind == .designed && describesAccent(configuration.description) { warnings.append(designAccentNotice) }
        return warnings
    }
}

/// How Qwen samples speech for a kind of voice.
///
/// Recorded and built-in voices use temperature 0.7, which keeps word errors low, with the
/// reference's top-k 50 and no top-p cut. A top-p cut (0.8 until 3.4) is what made the 0.6B model run
/// on: once the end-of-speech token falls outside the nucleus it can no longer be drawn, and the
/// model loops in room tone until the frame budget runs out. Measured 2026-11-12 on JARVIS, 96
/// passages each: 5 run-ons at top-p 0.8 (with or without upstream's end-of-speech exemption) and
/// none at 1.0, with the same word accuracy.
///
/// A designed voice is drawn afresh from its description for every passage, so it uses the
/// VoiceDesign model's published settings: the whole text in the prompt before the first frame and
/// temperature 0.9, which keep the description's voice consistent from sentence to sentence.
///
/// No voice generates frames after the model chooses to end. 3.4.0 generated two, to let a last
/// sound decay that the model had ended at full level; but the frames that follow the end are as
/// often a short burst of noise after silence, which was heard as a click at the end of Scar's
/// clips. The ending is shaped by `PassageEnvelope`'s fade instead.
public struct QwenGeneration: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    /// The reference's `non_streaming_mode`: the model reads the whole passage before speaking.
    public var wholeTextFirst: Bool
    /// Frames generated after the model chooses to end. Zero for every voice; kept for measurement.
    public var framesAfterEnd: Int

    public init(temperature: Double, topP: Double, topK: Int, wholeTextFirst: Bool, framesAfterEnd: Int = 0) {
        self.temperature = temperature; self.topP = topP; self.topK = topK; self.wholeTextFirst = wholeTextFirst
        self.framesAfterEnd = framesAfterEnd
    }

    public static func settings(for kind: VoiceKind) -> QwenGeneration {
        switch kind {
        case .designed: QwenGeneration(temperature: 0.9, topP: 1.0, topK: 50, wholeTextFirst: true)
        case .cloned, .preset: QwenGeneration(temperature: 0.7, topP: 1.0, topK: 50, wholeTextFirst: false)
        }
    }
}

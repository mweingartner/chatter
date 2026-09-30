import Foundation

/// Natural-language delivery presets for Qwen CustomVoice and VoiceDesign. Base cloning inherits its reference delivery.
public enum SpeechTone: String, CaseIterable, Codable, Identifiable, Sendable {
    case natural
    case cheerful, optimistic, excited, confident, grateful, proud
    case warm, friendly, calm, empathetic, reassuring, apologetic
    case stern, serious, determined, professional
    case curious, reflective, nostalgic, sad, bored
    case angry, frustrated, nervous, worried, scared, surprised, sarcastic
    case whisper, soft, urgent, shouting
    public var id: String { rawValue }
    public var title: String { self == .whisper ? "Whispering" : rawValue.capitalized }
    public static let categories = ["Natural", "Positive", "Supportive", "Firm & focused", "Reflective", "Intense", "Delivery"]
    public var category: String {
        switch self {
        case .natural: "Natural"
        case .cheerful, .optimistic, .excited, .confident, .grateful, .proud: "Positive"
        case .warm, .friendly, .calm, .empathetic, .reassuring, .apologetic: "Supportive"
        case .stern, .serious, .determined, .professional: "Firm & focused"
        case .curious, .reflective, .nostalgic, .sad, .bored: "Reflective"
        case .angry, .frustrated, .nervous, .worried, .scared, .surprised, .sarcastic: "Intense"
        case .whisper, .soft, .urgent, .shouting: "Delivery"
        }
    }
    public var detail: String {
        switch self {
        case .natural: "Use the voice’s natural delivery without an added tone cue."
        case .cheerful: "Bright, friendly and upbeat."
        case .optimistic: "Hopeful, encouraging and positive."
        case .excited: "Enthusiastic and animated."
        case .confident: "Self-assured and certain."
        case .grateful: "Express appreciation and thanks."
        case .proud: "A sense of achievement and satisfaction."
        case .warm: "Gentle, welcoming and caring."
        case .friendly: "Approachable, conversational delivery."
        case .calm: "Relaxed and composed."
        case .empathetic: "Acknowledge another person’s feelings with care."
        case .reassuring: "Steady, comforting encouragement."
        case .apologetic: "A sincere expression of regret."
        case .stern: "Firm and authoritative."
        case .serious: "Measured, focused and thoughtful."
        case .determined: "Resolved and committed."
        case .professional: "Clear, polished presentation."
        case .curious: "Engaged, questioning and interested."
        case .reflective: "Contemplative and considered."
        case .nostalgic: "A wistful recollection of the past."
        case .sad: "Subdued and sorrowful."
        case .bored: "Low interest and little enthusiasm."
        case .angry: "Forceful, with audible displeasure."
        case .frustrated: "Impatient or exasperated."
        case .nervous: "Uneasy or hesitant."
        case .worried: "Concerned about what may happen."
        case .scared: "Fearful and apprehensive."
        case .surprised: "An unexpected realization or reaction."
        case .sarcastic: "Dry irony; results depend strongly on the words."
        case .whisper: "A soft, whispered delivery."
        case .soft: "Quiet and gentle, with a normally voiced delivery."
        case .urgent: "A hurried sense of immediacy; pace remains separately adjustable."
        case .shouting: "Raised, forceful delivery."
        }
    }
    public var cue: String {
        self == .natural ? "" : "Speak with a \(rawValue) delivery. \(detail)"
    }
}

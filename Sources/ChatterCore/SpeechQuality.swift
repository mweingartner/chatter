import Foundation

/// One policy shared by the UI, HTTP capabilities and single-voice/dialogue synthesis.
public enum SpeechQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case responsive, balanced, studio
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var streamsChunks: Bool { self == .responsive }
    /// `studioClones`: recorded voices use the studio model at every quality (see
    /// `Settings.recordedVoiceModel`).
    public func modelProfile(for kind: VoiceKind, mode: String, studioClones: Bool = false) -> String {
        switch kind {
        case .cloned: mode == "save" || self == .studio || studioClones ? "quality" : "fast"
        case .preset: "custom"
        case .designed: "design"
        }
    }
    public var detail: String {
        switch self {
        case .responsive: "Streams short audio chunks as they are generated, for the fastest start."
        case .balanced: "Generates and checks a complete passage before playing it. Uses the same model as Responsive."
        case .studio: "Uses 1.7B Base (BF16) for recorded voices, and generates and checks each passage before playing it."
        }
    }
    public static let sharedNotice = "Built-in and designed voices use their 1.7B BF16 models at every level. Recorded voices use the model chosen in Engine settings at Responsive and Balanced. Responsive streams chunks; Balanced and Studio buffer passages. All output is native 24 kHz mono, 24-bit PCM."
    public static let saveNotice = "Save WAV always uses the matching 1.7B BF16 model, regardless of live quality. Native 24 kHz mono • 24-bit PCM."
}

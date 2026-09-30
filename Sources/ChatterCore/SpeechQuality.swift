import Foundation

/// One policy shared by the UI, HTTP capabilities and single-voice/dialogue synthesis.
public enum SpeechQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case responsive, balanced, studio
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var streamsChunks: Bool { self == .responsive }
    public func modelProfile(for kind: VoiceKind, mode: String) -> String {
        switch kind {
        case .cloned: mode == "save" || self == .studio ? "quality" : "fast"
        case .preset: "custom"
        case .designed: "design"
        }
    }
    public var detail: String {
        switch self {
        case .responsive: "Streams short audio chunks as they are generated. Recorded voices use 0.6B Base (8-bit)."
        case .balanced: "Buffers a complete passage before playing. Uses the same 0.6B Base (8-bit) model as Responsive for recorded voices."
        case .studio: "Uses 1.7B Base (BF16) for recorded voices and buffers each passage before playing."
        }
    }
    public static let sharedNotice = "Built-in and designed voices use their 1.7B BF16 models at every level. Responsive streams chunks; Balanced and Studio buffer passages. All output is native 24 kHz mono, 24-bit PCM."
    public static let saveNotice = "Save WAV always uses the matching 1.7B BF16 model, regardless of live quality. Native 24 kHz mono • 24-bit PCM."
}

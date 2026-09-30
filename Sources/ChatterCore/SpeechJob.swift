import Foundation

public struct SpeechJob: Codable, Identifiable, Sendable {
    public var id: String
    public var request: SpeechRequest
    public var voiceName: String
    public var references: [VoiceReference]?
    public var toneCue: String?
    public var dialogueTurns: [EngineDialogueTurn]?
    public var dialogueTiming: [DialogueTiming]?
    public var voiceConfiguration: QwenVoiceConfiguration?
    public var warnings: [String]?
    public var engineName: String?
    public var sampleRate: Int?
    public var modelID: String?
    /// False for pronunciation previews, which speak their text exactly; otherwise the user's
    /// pronunciations are applied when the job is spoken.
    public var respell: Bool?
    /// Whether this job gets an expression review, decided when it is accepted.
    public var expressive: Bool?
    /// The notes the review chose (kept so a restart speaks the same notes), the model that chose them, and
    /// why the review stopped early or did not run.
    public var expressionPlan: ExpressionPlan?
    public var expressionModel: String?
    public var expressionMessage: String?
    public var sequence: UInt64 = 0
    public var requestID: String?
    public var attempts = 0
    public var state: String
    public var createdAt: Date
    public var message: String
    public var path: String?
    public var firstAudioSeconds: Double?
    public var elapsedSeconds: Double?
    public var duration: Double?
    public var profile: String?
    public init(request: SpeechRequest, voiceName: String) {
        id = UUID().uuidString; self.request = request; self.voiceName = voiceName
        state = "queued"; createdAt = .now; message = "Waiting for the speech engine"
    }
    public var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(state) }
}

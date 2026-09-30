import Foundation

public enum ChatterError: LocalizedError, Sendable {
    case invalid(String)
    case unavailable(String)
    case cancelled
    case queueFull
    public var errorDescription: String? {
        switch self { case .invalid(let s), .unavailable(let s): s; case .cancelled: "Cancelled"; case .queueFull: "Speech queue is full. Retry with the same request ID after a request completes." }
    }
}

public struct SpeechRequest: Codable, Sendable {
    public var dialogue: DialogueScript?
    public var voice: String
    public var text: String
    public var pace: Double
    public var mode: String
    public var quality: String?
    public var sampleID: String?
    public var tone: String?
    public var language: String?
    public var instruction: String?
    /// Legacy receipt field. Qwen speech uses native instructions and never runs automatic annotation.
    public var expressive: Bool?
    public var effectiveTone: SpeechTone { tone.flatMap(SpeechTone.init(rawValue:)) ?? .natural }
    public init(voice: String, text: String, pace: Double = 1, mode: String = "play", quality: String? = nil, sampleID: String? = nil, tone: String? = nil, expressive: Bool? = nil, language: String? = nil, instruction: String? = nil) {
        self.voice = voice; self.text = text; self.pace = pace; self.mode = mode; self.quality = quality; self.sampleID = sampleID; self.tone = tone
        self.expressive = expressive; self.language = language; self.instruction = instruction
    }
    public func validated() throws -> Self {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatterError.invalid("Enter text to speak.") }
        guard text.utf8.count <= 100_000 else { throw ChatterError.invalid("Text exceeds 100,000 UTF-8 bytes. Split it into separate requests.") }
        guard pace.isFinite, (0.5...2).contains(pace) else { throw ChatterError.invalid("Pace must be between 0.5 and 2.0.") }
        guard ["play", "save"].contains(mode) else { throw ChatterError.invalid("Mode must be play or save.") }
        guard quality == nil || ["responsive", "balanced", "studio"].contains(quality) else { throw ChatterError.invalid("Quality must be responsive, balanced, or studio.") }
        if let tone, SpeechTone(rawValue: tone) == nil { throw ChatterError.invalid("Unknown tone. Choose one of: " + SpeechTone.allCases.map(\.rawValue).joined(separator: ", ")) }
        if let dialogue { _ = try dialogue.validated() }
        var result = self
        if let language { result.language = try QwenCapabilities.language(language) }
        if let instruction {
            guard instruction.utf8.count <= 2_000 else { throw ChatterError.invalid("Delivery instruction exceeds 2,000 UTF-8 bytes.") }
            result.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

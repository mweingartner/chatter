import Foundation

public struct DialogueLine: Codable, Sendable, Equatable {
    public var actor: String
    public var text: String
    public var tone: String?
    public var language: String?
    public var instruction: String?
    public init(actor: String, text: String, tone: String? = nil, language: String? = nil, instruction: String? = nil) {
        self.actor=actor;self.text=text;self.tone=tone;self.language=language;self.instruction=instruction
    }
}
public struct DialogueScript: Codable, Sendable, Equatable {
    public var cast: [String:String]
    public var turns: [DialogueLine]
    public var gapSeconds: Double?
    public init(cast: [String:String], turns: [DialogueLine], gapSeconds: Double = 0.35) { self.cast=cast;self.turns=turns;self.gapSeconds=gapSeconds }
    public func validated() throws -> Self {
        guard (1...20).contains(cast.count), (1...500).contains(turns.count) else { throw ChatterError.invalid("Dialogue requires 1–20 actors and 1–500 turns.") }
        guard cast.allSatisfy({ !$0.key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !$0.value.isEmpty }), turns.allSatisfy({ cast[$0.actor] != nil }) else { throw ChatterError.invalid("Every dialogue actor must have a saved voice assigned in the cast.") }
        let gap=gapSeconds ?? 0.35
        guard gap.isFinite, (0...10).contains(gap) else { throw ChatterError.invalid("Turn spacing must be 0–10 seconds.") }
        guard turns.reduce(0,{ $0+$1.text.utf8.count })<=100_000 else { throw ChatterError.invalid("Dialogue exceeds 100,000 UTF-8 bytes.") }
        for turn in turns { _ = try SpeechRequest(voice:cast[turn.actor]!,text:turn.text,tone:turn.tone,language:turn.language,instruction:turn.instruction).validated() }
        return self
    }
}
/// Immutable voice settings and transcripts accepted as part of one FIFO job.
public struct EngineDialogueTurn: Codable, Sendable {
    public var actor: String
    public var voiceID: String
    public var text: String
    public var configuration: QwenVoiceConfiguration
    public var references: [EngineReference]
    public var language: String
    public var instruction: String?
    public var toneCue: String
    public init(actor:String,voiceID:String,text:String,configuration:QwenVoiceConfiguration,references:[EngineReference],language:String,instruction:String?,toneCue:String) {
        self.actor=actor;self.voiceID=voiceID;self.text=text;self.configuration=configuration;self.references=references;self.language=language;self.instruction=instruction;self.toneCue=toneCue
    }
}
public struct DialogueTiming: Codable, Sendable {
    public var actor: String
    public var start: Double
    public var duration: Double
    public var modelID: String?
    public init(actor:String,start:Double,duration:Double,modelID:String? = nil) {
        self.actor=actor;self.start=start;self.duration=duration;self.modelID=modelID
    }
}

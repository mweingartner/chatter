import Foundation

/// The line-delimited JSON protocol between Chatter and its `chatter-engine` helper.
/// Commands arrive on the helper's stdin; events leave on its stdout (stdout carries nothing else).
/// Field names are unchanged from the retired Python worker, so the app's engine client is unchanged.
public enum EngineProtocol {
    /// Bumped when commands or events change incompatibly. Sent in the `hello` event.
    public static let version = 3
    public static let engineID = "engine"
}

public struct EngineReference: Codable, Sendable, Equatable {
    /// Absolute path to a prepared `reference.wav` inside the voice library.
    public var reference: String
    public var transcript: String
    public init(reference: String, transcript: String) { self.reference = reference; self.transcript = transcript }
}

public struct SynthesizeCommand: Codable, Sendable {
    public var dialogueTurns: [EngineDialogueTurn]?
    public var gapSeconds: Double?
    public var id: String
    public var text: String
    public var references: [EngineReference]
    public var toneCue: String?
    public var voiceConfiguration: QwenVoiceConfiguration?
    public var language: String?
    public var instruction: String?
    public var mode: String
    public var pace: Double
    public var quality: String?
    public var directory: String
    public var output: String
    public var seed: UInt64?
    public var temperature: Double?
}

public struct PrepareCommand: Codable, Sendable {
    public var id: String
    public var source: String
    public var destination: String
    public var transcript: String?
}

public struct PrecacheCommand: Codable, Sendable {
    public var language: String?
    public var id: String
    public var references: [EngineReference]
}

public struct AnalyzeCommand: Codable, Sendable {
    public var id: String
    public var source: String
}

/// Runtime preferences the app forwards to the engine.
public struct ConfigureCommand: Codable, Sendable {
    public var id: String
    /// Keep the studio (BF16) profile resident instead of loading it on demand.
    public var keepStudioLoaded: Bool?
    /// Seconds of studio inactivity before its weights are released.
    public var studioIdleSeconds: Double?
}

public enum EngineCommand: Sendable {
    case synthesize(SynthesizeCommand)
    case prepare(PrepareCommand)
    case precache(PrecacheCommand)
    case analyze(AnalyzeCommand)
    case configure(ConfigureCommand)
    case status(id: String)
    case cancel(target: String)

    public var id: String {
        switch self {
        case .synthesize(let c): c.id
        case .prepare(let c): c.id
        case .precache(let c): c.id
        case .analyze(let c): c.id
        case .configure(let c): c.id
        case .status(let id): id
        case .cancel(let target): target
        }
    }

    /// Decodes one protocol line. Unknown operations are rejected rather than ignored.
    public static func decode(_ line: Data) throws -> EngineCommand {
        struct Header: Decodable { let op: String; let id: String?; let target: String? }
        let header = try JSONDecoder().decode(Header.self, from: line)
        let decoder = JSONDecoder()
        switch header.op {
        case "synthesize": return .synthesize(try decoder.decode(SynthesizeCommand.self, from: line))
        case "prepare": return .prepare(try decoder.decode(PrepareCommand.self, from: line))
        case "precache": return .precache(try decoder.decode(PrecacheCommand.self, from: line))
        case "analyze": return .analyze(try decoder.decode(AnalyzeCommand.self, from: line))
        case "configure": return .configure(try decoder.decode(ConfigureCommand.self, from: line))
        case "status": return .status(id: header.id ?? UUID().uuidString)
        case "cancel":
            guard let target = header.target else { throw ChatterError.invalid("cancel requires a target") }
            return .cancel(target: target)
        default: throw ChatterError.invalid("Unknown worker operation \(header.op)")
        }
    }
}

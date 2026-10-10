import ChatterCore
import Foundation
import Testing
@testable import ChatterEngine

/// The engine side of `render`: accepted as live audio like `play` (same validation, model choice and
/// file confinement), and refused for dialogue. Everything here stops before MLX would run.
struct RenderModeTests {
    typealias Core = EngineCoreTests

    /// Render passes mode validation with every quality and reaches model loading, which fails visibly
    /// without models, after creating only its own job folder; it never writes the output.
    @Test(arguments: [nil, "responsive", "balanced", "studio"] as [String?])
    func renderReachesModelLoadingLikePlay(quality: String?) throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        for mode in ["play", "render"] {
            let engine = Core.engine(scratch)
            #expect(Core.failure { try SynthesisJob(engine: engine, command: Core.command(scratch, mode: mode, quality: quality)).run() }
                    == SpeechEngineCore.modelsMissing, "\(mode) \(quality ?? "nil")")
        }
        #expect(FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs/job"))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs/job/speech.wav"))
    }

    /// Render is validated exactly like play: bad pace, quality and paths are refused with the same messages.
    @Test func renderIsValidatedExactlyLikePlay() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Core.engine(scratch)
        func run(_ mode: String, pace: Double = 1, quality: String? = nil, directory: String? = nil, output: String? = nil) -> String {
            Core.failure { try SynthesisJob(engine: engine, command: Core.command(scratch, mode: mode, pace: pace, quality: quality, directory: directory, output: output)).run() }
        }
        let cases: [(Double, String?, String?, String?)] = [
            (2.5, nil, nil, nil), (0, nil, nil, nil), (1, "fast", nil, nil), (1, "Studio", nil, nil),
            (1, nil, scratch.url.path + "/Elsewhere/job", nil), (1, nil, nil, scratch.url.path + "/Jobs/job/speech.mp3"),
        ]
        for (pace, quality, directory, output) in cases {
            let play = run("play", pace: pace, quality: quality, directory: directory, output: output)
            #expect(!play.isEmpty)
            #expect(run("render", pace: pace, quality: quality, directory: directory, output: output) == play)
        }
    }

    /// Only Studio (or save) announces the studio model; render follows play, not save.
    @Test func renderAnnouncesTheStudioModelOnlyForStudioQuality() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        for (quality, announced) in [(nil, false), ("responsive", false), ("balanced", false), ("studio", true)] as [(String?, Bool)] {
            let events = Core.EventLog()
            let engine = Core.engine(scratch, events: events)
            _ = Core.failure { try SynthesisJob(engine: engine, command: Core.command(scratch, mode: "render", quality: quality)).run() }
            let messages = events.all.filter { $0.event == "progress" }.compactMap { $0.fields["message"] as? String }
            #expect(messages == (announced ? ["Loading the studio voice model…"] : []), "\(quality ?? "nil")")
        }
    }

    /// Dialogue refuses render before touching any file (the app also refuses it at submission).
    @Test(arguments: ["render", "Render", "stream"])
    func dialogueRefusesRenderAndUnknownModes(mode: String) throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Core.engine(scratch)
        let turn: [String: Any] = ["actor": "Host", "voiceID": "v", "text": "Hi",
                                   "configuration": ["kind": "preset", "speaker": "Aiden", "language": "English"],
                                   "references": [], "language": "English", "toneCue": ""]
        let object: [String: Any] = ["op": "synthesize", "id": "d", "text": "Host: Hi", "references": [], "mode": mode, "pace": 1,
                                     "directory": scratch.url.path + "/Jobs/d", "output": scratch.url.path + "/Jobs/d/speech.wav",
                                     "dialogueTurns": [turn]]
        guard case .synthesize(let command) = try EngineCommand.decode(JSONSerialization.data(withJSONObject: object)) else {
            Issue.record("not a synthesize command"); return
        }
        #expect(command.dialogueTurns?.count == 1)
        #expect(Core.failure { try SynthesisJob(engine: engine, command: command).run() } == "Invalid dialogue")
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs"))
    }
}

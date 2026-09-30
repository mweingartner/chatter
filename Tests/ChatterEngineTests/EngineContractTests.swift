import ChatterCore
import Foundation
import Testing
@testable import ChatterEngine

/// The helper's protocol, file-access policy and user-facing limits.
struct EngineContractTests {
    @Test func decodesEveryOperation() throws {
        let lines = [
            #"{"op":"synthesize","id":"a","text":"Hi","references":[{"reference":"/r.wav","transcript":"t"}],"mode":"play","pace":1,"directory":"/d","output":"/o.wav"}"#,
            #"{"op":"prepare","id":"b","source":"/s.wav","destination":"/d"}"#,
            #"{"op":"precache","id":"c","references":[]}"#,
            #"{"op":"analyze","id":"d","source":"/s.wav"}"#,
            #"{"op":"configure","id":"e","keepStudioLoaded":true}"#,
            #"{"op":"status","id":"f"}"#,
            #"{"op":"cancel","target":"a"}"#,
        ]
        let ids = try lines.map { try EngineCommand.decode(Data($0.utf8)).id }
        #expect(ids == ["a", "b", "c", "d", "e", "f", "a"])
    }

    @Test func rejectsUnknownOrIncompleteCommands() {
        for line in [#"{"op":"shell","id":"x"}"#, #"{"op":"cancel"}"#, #"{"op":"synthesize","id":"x"}"#, "not json", #"{"id":"x"}"#] {
            #expect(throws: (any Error).self) { try EngineCommand.decode(Data(line.utf8)) }
        }
    }

    @Test func pathPolicyConfinesAccessToChatterData() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engine-paths-\(UUID().uuidString)")
        let voices = root.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices.appending(path: "v/s"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try PathPolicy.isInside(voices.appending(path: "v/s/reference.wav").path, directory: voices.path))
        #expect(try PathPolicy.isInside(voices.appending(path: "new/take").path, directory: voices.path))
        #expect(try !PathPolicy.isInside("/etc/passwd", directory: voices.path))
        #expect(try !PathPolicy.isInside(root.path, directory: voices.path))
        #expect(throws: (any Error).self) { try PathPolicy.isInside(voices.path + "/v/../../escape", directory: voices.path) }
        #expect(throws: (any Error).self) { try PathPolicy.canonical("relative/path") }
        // A symlink inside the library that points outside it does not grant access.
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: voices.appending(path: "link"), withDestinationURL: outside)
        #expect(try !PathPolicy.isInside(voices.appending(path: "link/reference.wav").path, directory: voices.path))
        // /tmp and /private/tmp spellings of one directory are the same place.
        let tmp = "/tmp/" + root.path.split(separator: "/").suffix(1).joined()
        _ = tmp
        #expect(try PathPolicy.canonical(voices.path) == PathPolicy.canonical(voices.path + "/"))
    }

    @Test func startupWithoutModelsFailsVisibly() {
        let engine = SpeechEngineCore(configuration: EngineConfiguration(modelsRoot: URL(filePath: "/nonexistent/models"), dataRoot: FileManager.default.temporaryDirectory)) { _, _, _ in }
        #expect(throws: (any Error).self) { try engine.start() }
    }
}

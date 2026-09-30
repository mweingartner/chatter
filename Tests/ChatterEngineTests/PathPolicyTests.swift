import ChatterAudioKit
import ChatterCore
import Foundation
import Testing
@testable import ChatterEngine

/// File-access confinement for the engine: generated trees with symlinks, spelling variants and
/// hostile components. The oracle is the tree's own model of which links lead outside.
struct PathPolicyTests {
    @Test func spellingVariantsOfOnePlaceAgree() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let voices = scratch.url.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices.appending(path: "a/b"), withIntermediateDirectories: true)
        let canonical = try PathPolicy.canonical(voices.path)
        #expect(canonical == scratch.canonicalPath + "/Voices")
        #expect(try PathPolicy.canonical(voices.path + "/") == canonical)
        #expect(try PathPolicy.canonical(voices.path + "//a///b") == canonical + "/a/b")
        #expect(try PathPolicy.isInside(voices.path + "/a/b/reference.wav", directory: voices.path + "/"))
        // /tmp → /private/tmp style links above the root resolve on both sides.
        #expect(try PathPolicy.isInside(scratch.canonicalPath + "/Voices/a", directory: voices.path))
        #expect(try PathPolicy.isInside(voices.path + "/a", directory: scratch.canonicalPath + "/Voices"))
    }

    @Test func theRootItselfAndSiblingPrefixesAreOutside() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let voices = scratch.url.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.url.appending(path: "Voices2"), withIntermediateDirectories: true)
        #expect(try !PathPolicy.isInside(voices.path, directory: voices.path))
        #expect(try !PathPolicy.isInside(voices.path + "/", directory: voices.path))
        #expect(try !PathPolicy.isInside(scratch.url.path + "/Voices2/x", directory: voices.path))
        #expect(try !PathPolicy.isInside(scratch.url.path + "/VoicesX", directory: voices.path))
        #expect(try !PathPolicy.isInside("/", directory: voices.path))
    }

    @Test(arguments: ["relative", "", "./x", "~/x", "/a/./b", "/a/../b", "/a/b/..", "/a/b/.", "/..", "/./"])
    func relativeOrDotComponentsAreRejected(path: String) {
        let error = #expect(throws: EngineFailure.self) { try PathPolicy.canonical(path) }
        #expect(["Paths must be absolute.", "Paths may not contain relative components."].contains(error?.localizedDescription ?? ""))
    }

    @Test func dotsInsideNamesAreOrdinary() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        for name in ["...", "..x", "x..", ".hidden", "a.b.c"] {
            #expect(try PathPolicy.isInside(scratch.url.path + "/" + name + "/f", directory: scratch.url.path), "\(name)")
        }
    }

    /// Names that do not exist yet keep their spelling: percent signs, spaces, emoji. Unicode text is
    /// returned canonically equivalent (URL path components are decomposed, NFD), which names the
    /// same file on APFS.
    @Test(arguments: ["caf\u{E9}", "cafe\u{301}", "100% done", "a%2Fb", "%00", "日本語 ファイル", "👩‍👩‍👧", "line\u{2028}sep", "tab\there"])
    func pendingNamesArePreserved(name: String) throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let expected = scratch.canonicalPath + "/" + name + "/reference.wav"
        let canonical = try PathPolicy.canonical(scratch.url.path + "/" + name + "/reference.wav")
        #expect(canonical == expected, "\(canonical.debugDescription)")
        if name.unicodeScalars.allSatisfy(\.isASCII) { #expect(canonical.utf8.elementsEqual(expected.utf8)) }
        #expect(try PathPolicy.isInside(canonical, directory: scratch.url.path))
        try FileManager.default.createDirectory(atPath: (canonical as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: (expected as NSString).deletingLastPathComponent))
    }

    /// An embedded NUL cannot name a different file than the one that was checked: the canonical
    /// form either rejects it or spells it out.
    @Test func embeddedNULNeverShortensThePath() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        guard let canonical = try? PathPolicy.canonical(scratch.url.path + "/a\u{0}/../../etc/passwd") else { return }
        #expect(!canonical.contains("\u{0}") || canonical.hasPrefix(scratch.canonicalPath + "/"))
    }

    @Test func caseVariantsFollowTheFileSystem() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let voices = scratch.url.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        let variant = scratch.url.path + "/VOICES"
        // On a case-insensitive volume the variant is the same directory and resolves to its real name.
        let sameDirectory = FileManager.default.fileExists(atPath: variant)
        #expect(try PathPolicy.isInside(variant + "/x", directory: voices.path) == sameDirectory)
    }

    @Test func veryLongPendingPathsAreHandled() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let long = scratch.url.path + String(repeating: "/" + String(repeating: "n", count: 200), count: 40)   // ~8 KB, over PATH_MAX
        #expect(try PathPolicy.isInside(long, directory: scratch.url.path))
        #expect(try PathPolicy.canonical(long).hasSuffix(String(repeating: "n", count: 200)))
    }

    @Test func symlinkLoopsTerminate() throws {
        let scratch = try Scratch("paths"); defer { scratch.remove() }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: scratch.url.path + "/a", withDestinationPath: scratch.url.path + "/b")
        try fm.createSymbolicLink(atPath: scratch.url.path + "/b", withDestinationPath: scratch.url.path + "/a")
        // A loop never resolves: like any dangling link it is refused (promptly, without looping).
        #expect(throws: EngineFailure.self) { try PathPolicy.isInside(scratch.url.path + "/a/x", directory: scratch.url.path) }
        #expect(throws: EngineFailure.self) { try PathPolicy.canonical(scratch.url.path + "/a") }
    }

    /// Property: in a generated tree of directories, inside links and escaping links (absolute to a
    /// sibling directory, to `/`, and relative `../`), a path is inside exactly when it does not go
    /// through an escaping link.
    @Test func generatedTreesWithSymlinksAreConfined() throws {
        let fm = FileManager.default
        for seed in UInt64(1)...40 {
            var rng = SeededGenerator(seed: seed)
            let scratch = try Scratch("tree"); defer { scratch.remove() }
            let root = scratch.url.appending(path: "Voices"), outside = scratch.url.appending(path: "Outside")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside.appending(path: "d0"), withIntermediateDirectories: true)
            var real: [String: String] = ["": ""]   // spelled directory (relative to root) → real location
            var escaping: [String] = []
            for index in 0..<12 {
                let parent = real.keys.sorted().randomElement(using: &rng)!
                let name = "\(parent)/n\(index)"
                switch Int.random(in: 0..<5, using: &rng) {
                case 0, 1:
                    try fm.createDirectory(atPath: root.path + name, withIntermediateDirectories: false)
                    real[name] = real[parent]! + "/n\(index)"
                case 2:
                    let target = real.values.sorted().randomElement(using: &rng)!
                    try fm.createSymbolicLink(atPath: root.path + name, withDestinationPath: root.path + target)
                    real[name] = target
                default:
                    let depth = real[parent]!.split(separator: "/").count
                    let target = [outside.path + "/d0", "/", String(repeating: "../", count: depth + 1) + "Outside/d0"].randomElement(using: &rng)!
                    try fm.createSymbolicLink(atPath: root.path + name, withDestinationPath: target)
                    escaping.append(name)
                }
            }
            let bases = real.keys.sorted() + escaping + escaping.map { $0 + "/deeper" }
            for base in bases {
                let path = root.path + base + (Bool.random(using: &rng) ? "/reference.wav" : "/new/take")
                let leaves = escaping.contains { base == $0 || base.hasPrefix($0 + "/") }
                #expect(try PathPolicy.isInside(path, directory: root.path) == !leaves, "seed \(seed): \(base) escaping=\(escaping)")
                let canonical = try PathPolicy.canonical(path)
                #expect(try PathPolicy.canonical(canonical) == canonical, "idempotent, seed \(seed)")
            }
        }
    }

    /// A dangling link is refused outright: its destination could be created outside later.
    @Test func danglingLinksAreRejected() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let voices = scratch.url.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: voices.path + "/link", withDestinationPath: scratch.url.path + "/Outside/new")
        #expect(throws: EngineFailure.self) { try PathPolicy.canonical(voices.path + "/link") }
        #expect(throws: EngineFailure.self) { try PathPolicy.isInside(voices.path + "/link/reference.wav", directory: voices.path) }
        // An ordinary pending name beside it is still fine.
        #expect(try PathPolicy.isInside(voices.path + "/new-take/reference.wav", directory: voices.path))
    }

    /// Every shape of unresolvable link is refused wherever it sits in the path: relative and absolute
    /// targets, chains ending nowhere, self-loops, deep below the link, and as the confining directory.
    @Test func everyDanglingOrLoopingLinkShapeIsRefused() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let fm = FileManager.default
        let voices = scratch.url.path + "/Voices"
        try fm.createDirectory(atPath: voices + "/v", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: voices + "/relative", withDestinationPath: "missing-dir")
        try fm.createSymbolicLink(atPath: voices + "/chain", withDestinationPath: voices + "/relative")
        try fm.createSymbolicLink(atPath: voices + "/self", withDestinationPath: voices + "/self")
        try fm.createSymbolicLink(atPath: voices + "/v/up", withDestinationPath: "../../Outside/later")
        for link in ["relative", "chain", "self", "v/up"] {
            for suffix in ["", "/reference.wav", "/a/b/c/reference.wav"] {
                let path = voices + "/" + link + suffix
                #expect(throws: EngineFailure.self, "\(path)") { try PathPolicy.canonical(path) }
                #expect(throws: EngineFailure.self, "\(path)") { try PathPolicy.isInside(path, directory: voices) }
            }
            // A dangling link cannot be the confining directory either.
            #expect(throws: EngineFailure.self, "\(link)") { try PathPolicy.isInside(voices + "/v/x", directory: voices + "/" + link) }
        }
        #expect(!fm.fileExists(atPath: scratch.url.path + "/Outside"))
        // Once the chain's end exists, the same links resolve (inside the library) like any other.
        try fm.createDirectory(atPath: voices + "/missing-dir", withIntermediateDirectories: false)
        #expect(try PathPolicy.canonical(voices + "/chain/new/reference.wav") == scratch.canonicalPath + "/Voices/missing-dir/new/reference.wav")
        #expect(try PathPolicy.isInside(voices + "/chain/new/reference.wav", directory: voices))
    }

    /// Ordinary names that do not exist yet are still pending at any depth, and resolve below the
    /// deepest existing (canonical) ancestor, including below a live link.
    @Test func pendingNamesStillResolveBelowTheDeepestExistingAncestor() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let fm = FileManager.default
        let voices = scratch.url.path + "/Voices"
        try fm.createDirectory(atPath: voices + "/real", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: voices + "/alias", withDestinationPath: "real")
        let canonicalVoices = scratch.canonicalPath + "/Voices"
        for (path, expected) in [(voices + "/new", canonicalVoices + "/new"),
                                 (voices + "/new/deeper/reference.wav", canonicalVoices + "/new/deeper/reference.wav"),
                                 (voices + "/alias/take/reference.wav", canonicalVoices + "/real/take/reference.wav"),
                                 (voices + "/real/", canonicalVoices + "/real"),
                                 (voices + "//real//take", canonicalVoices + "/real/take")] {
            #expect(try PathPolicy.canonical(path) == expected, "\(path)")
            #expect(try PathPolicy.isInside(path, directory: voices), "\(path)")
        }
        // Resolution never creates anything.
        #expect(!fm.fileExists(atPath: voices + "/new") && !fm.fileExists(atPath: voices + "/real/take"))
    }

    /// Preparing through a dangling link fails and creates nothing outside the library.
    @Test func preparingThroughADanglingLinkWritesNothingOutside() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch.url.appending(path: "Voices/v"), withIntermediateDirectories: true)
        let target = scratch.url.appending(path: "Outside/new")
        try fm.createSymbolicLink(atPath: scratch.url.path + "/Voices/v/take", withDestinationPath: target.path)
        let source = scratch.url.appending(path: "import.wav")
        try AudioIO.writePCM24((0..<(44_100 * 4)).map { Float(0.2 * sin(Double($0) * 0.03)) }, to: source)
        let engine = EngineCoreTests.engine(scratch)
        _ = EngineCoreTests.failure { try engine.prepare(EngineCoreTests.prepareCommand(id: "p", source: source.path, destination: scratch.url.path + "/Voices/v/take", transcript: "Hi")) }
        #expect(!fm.fileExists(atPath: target.path))
        #expect(!fm.fileExists(atPath: scratch.url.path + "/Outside"))
    }
}

/// Engine behaviour that needs no GPU: request validation, file confinement and user-facing errors.
struct EngineCoreTests {
    static func engine(_ scratch: Scratch, events: EventLog? = nil) -> SpeechEngineCore {
        SpeechEngineCore(configuration: EngineConfiguration(modelsRoot: scratch.url.appending(path: "Models"), dataRoot: scratch.url)) { id, event, fields in
            events?.append(id, event, fields)
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, String, [String: Any])] = []
        func append(_ id: String, _ event: String, _ fields: [String: Any]) { lock.withLock { items.append((id, event, fields)) } }
        var all: [(id: String, event: String, fields: [String: Any])] { lock.withLock { items.map { ($0.0, $0.1, $0.2) } } }
    }

    static func command(_ scratch: Scratch, mode: String = "play", pace: Double = 1, quality: String? = nil,
                        directory: String? = nil, output: String? = nil) throws -> SynthesizeCommand {
        let object: [String: Any?] = ["op": "synthesize", "id": "job", "text": "Hello.", "references": [["reference": "/r.wav", "transcript": "t"]],
                                      "mode": mode, "pace": pace, "quality": quality,
                                      "directory": directory ?? scratch.url.path + "/Jobs/job", "output": output ?? scratch.url.path + "/Jobs/job/speech.wav"]
        guard case .synthesize(let c) = try EngineCommand.decode(JSONSerialization.data(withJSONObject: object.compactMapValues { $0 })) else {
            throw EngineFailure.invalid("not a synthesize command")
        }
        return c
    }

    static func decoded<T: Decodable>(_ object: [String: Any?]) -> T {
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object.compactMapValues { $0 }))
    }
    static func prepareCommand(id: String, source: String, destination: String, transcript: String?) -> PrepareCommand {
        decoded(["id": id, "source": source, "destination": destination, "transcript": transcript])
    }
    static func analyzeCommand(id: String, source: String) -> AnalyzeCommand { decoded(["id": id, "source": source]) }
    static func configureCommand(id: String, keepStudioLoaded: Bool?, studioIdleSeconds: Double?) -> ConfigureCommand {
        decoded(["id": id, "keepStudioLoaded": keepStudioLoaded, "studioIdleSeconds": studioIdleSeconds])
    }

    static func failure(_ body: () throws -> Any) -> String {
        do { _ = try body(); return "" } catch { return error.localizedDescription }
    }

    @Test(arguments: [("stream", 1.0, "Mode must be play or save."), ("PLAY", 1.0, "Mode must be play or save."),
                      ("play", 0.49, "Pace must be between 0.5 and 2.0."), ("save", 2.01, "Pace must be between 0.5 and 2.0."),
                      ("play", 0, "Pace must be between 0.5 and 2.0."), ("play", -1, "Pace must be between 0.5 and 2.0.")])
    func invalidRequestsAreRejectedBeforeAnyWork(mode: String, pace: Double, message: String) throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        #expect(Self.failure { try SynthesisJob(engine: engine, command: Self.command(scratch, mode: mode, pace: pace)).run() } == message)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs/job"))
    }

    /// Quality strings are exact: anything but the three names is refused before any file is touched,
    /// for saved requests too (which always use the studio profile).
    @Test(arguments: [("play", "unknown"), ("play", "Balanced"), ("play", "STUDIO"), ("play", ""), ("play", " responsive"),
                      ("play", "balanced\n"), ("save", "fast"), ("save", "quality")])
    func unknownQualitiesAreRejectedBeforeAnyWork(mode: String, quality: String) throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let events = EventLog()
        let engine = Self.engine(scratch, events: events)
        #expect(Self.failure { try SynthesisJob(engine: engine, command: Self.command(scratch, mode: mode, quality: quality)).run() }
                == "Quality must be responsive, balanced or studio.")
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs"))
        #expect(events.all.isEmpty)
    }

    /// The three known qualities, and an omitted one (balanced), pass validation and reach model loading.
    @Test(arguments: [nil, "responsive", "balanced", "studio"] as [String?])
    func knownQualitiesPassValidation(quality: String?) throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        #expect(Self.failure { try SynthesisJob(engine: engine, command: Self.command(scratch, quality: quality)).run() }
                == SpeechEngineCore.modelsMissing)
    }

    /// Keeping the studio profile loaded is only recorded once it has loaded: a profile that cannot
    /// load must not disable idle release and memory-pressure release. The idle time in the same
    /// command still applies, and a later `false` is always accepted.
    @Test func keepStudioLoadedStaysOffWhenTheStudioProfileCannotLoad() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let events = EventLog()
        let engine = Self.engine(scratch, events: events)
        for _ in 0..<2 {
            #expect(Self.failure { try engine.configure(Self.configureCommand(id: "c", keepStudioLoaded: true, studioIdleSeconds: 42)) }
                    == SpeechEngineCore.modelsMissing)
            #expect(!engine.configuration.keepStudioLoaded && engine.configuration.studioIdleSeconds == 42)
            #expect(engine.loadedProfiles.isEmpty)
        }
        // A studio directory without its config is still "not installed" (nothing is loaded from it).
        try FileManager.default.createDirectory(at: scratch.url.appending(path: "Models/quality"), withIntermediateDirectories: true)
        #expect(Self.failure { try engine.configure(Self.configureCommand(id: "c", keepStudioLoaded: true, studioIdleSeconds: nil)) }
                == SpeechEngineCore.modelsMissing)
        #expect(!engine.configuration.keepStudioLoaded)
        try engine.configure(Self.configureCommand(id: "c", keepStudioLoaded: false, studioIdleSeconds: nil))
        #expect(!engine.configuration.keepStudioLoaded && engine.configuration.studioIdleSeconds == 42)
        // No load was attempted, so nothing was announced. (Pressure relief calls into MLX, which cannot
        // run in a SwiftPM test bundle; idleTick with nothing loaded is a no-op.)
        engine.idleTick(now: .distantFuture)
        #expect(engine.loadedProfiles.isEmpty && events.all.isEmpty)
    }

    @Test func jobFilesAreConfinedAndOutputsMustBeWAV() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        func run(directory: String? = nil, output: String? = nil) -> String {
            Self.failure { try SynthesisJob(engine: engine, command: Self.command(scratch, directory: directory, output: output)).run() }
        }
        #expect(run(directory: scratch.url.path + "/Elsewhere/job") == "Invalid job directory.")
        #expect(run(directory: scratch.url.path + "/Jobs") == "Invalid job directory.")
        #expect(run(directory: scratch.url.path + "/Jobs/../Voices") == "Paths may not contain relative components.")
        #expect(run(output: scratch.url.path + "/Jobs/job/speech.mp3") == "Output must be an absolute WAV path.")
        #expect(run(output: scratch.url.path + "/Jobs/job/speech") == "Output must be an absolute WAV path.")
        #expect(run(output: "speech.wav") == "Paths must be absolute.")
        // Valid paths reach model loading, which fails visibly without models, after creating the job directory.
        #expect(run(output: scratch.url.path + "/Out/speech.WAV") == SpeechEngineCore.modelsMissing)
        #expect(FileManager.default.fileExists(atPath: scratch.url.path + "/Jobs/job"))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + "/Out/speech.WAV"))
    }

    @Test func studioRequestsAnnounceTheStudioModelBeforeLoadingIt() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        for (mode, quality, announced) in [("save", nil, true), ("play", "studio", true), ("play", "balanced", false), ("play", "unknown", false)] {
            let events = EventLog()
            let engine = Self.engine(scratch, events: events)
            _ = Self.failure { try SynthesisJob(engine: engine, command: Self.command(scratch, mode: mode, quality: quality)).run() }
            let messages = events.all.filter { $0.id == "job" && $0.event == "progress" }.compactMap { $0.fields["message"] as? String }
            #expect(messages == (announced ? ["Loading the studio voice model…"] : []), "\(mode) \(quality ?? "nil")")
        }
    }

    @Test func referencesMustBePreparedRecordingsInsideTheLibrary() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        let fm = FileManager.default
        let take = scratch.url.appending(path: "Voices/v/take")
        try fm.createDirectory(at: take, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: take.appending(path: "reference.wav"))
        try Data("RIFF".utf8).write(to: take.appending(path: "original.wav"))
        let outside = scratch.url.appending(path: "Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: outside.appending(path: "reference.wav"))
        try fm.createSymbolicLink(at: take.appending(path: "linked"), withDestinationURL: outside)
        try fm.createDirectory(at: take.appending(path: "escape"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: take.appending(path: "escape/reference.wav"), withDestinationURL: outside.appending(path: "reference.wav"))

        #expect(try engine.referenceURL(take.path + "/reference.wav").path == scratch.canonicalPath + "/Voices/v/take/reference.wav")
        let message = "A voice recording is missing from the library. Re-import it or disable that take."
        for path in [take.path + "/original.wav", take.path + "/missing/reference.wav", outside.path + "/reference.wav",
                     take.path + "/linked/reference.wav", take.path + "/escape/reference.wav", "reference.wav", take.path + "/../take/reference.wav"] {
            #expect(Self.failure { try engine.referenceURL(path) } == message, "\(path)")
        }
        #expect(Self.failure { try engine.conditioning([],profile:.fast,language:"Auto") } == "Enable at least one recording in this voice set.")
    }

    @Test func preparingOutsideTheVoiceLibraryIsRefused() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        for destination in [scratch.url.path + "/Jobs/x", scratch.url.path + "/Voices", "/tmp/elsewhere"] {
            let command = EngineCoreTests.prepareCommand(id: "p", source: "/nonexistent.wav", destination: destination, transcript: "Hi")
            #expect(Self.failure { try engine.prepare(command) } == "Recordings can only be prepared inside the voice library.", "\(destination)")
        }
    }

    /// End to end without the GPU: a recording is prepared into the library and analysed.
    @Test func preparesAndAnalyzesARecording() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let events = EventLog()
        let engine = Self.engine(scratch, events: events)
        let source = scratch.url.appending(path: "import.wav")
        let tone = (0..<(44_100 * 4)).map { Float(0.2 * sin(Double($0) * 2 * .pi * 220 / 44_100)) }
        try AudioIO.writePCM24(tone, to: source)
        let result = try engine.prepare(EngineCoreTests.prepareCommand(id: "p", source: source.path, destination: scratch.url.path + "/Voices/v/take", transcript: "  Hello there. "))
        #expect(result["transcript"] as? String == "Hello there.")
        #expect(result["originalFileName"] as? String == "original.wav")
        #expect(result["path"] as? String == scratch.canonicalPath + "/Voices/v/take/reference.wav")
        #expect(abs(((result["metrics"] as? [String: Any])?["duration"] as? Double ?? 0) - 4) < 0.01)
        #expect(FileManager.default.fileExists(atPath: scratch.url.path + "/Voices/v/take/reference.wav"))
        #expect(events.all.isEmpty)   // a supplied transcript needs no transcription progress

        let health = try engine.analyze(EngineCoreTests.analyzeCommand(id: "a", source: source.path))
        #expect(Set(health.keys).isSuperset(of: ["duration", "peak", "rms", "score", "warnings"]))
        #expect(Self.failure { try engine.analyze(EngineCoreTests.analyzeCommand(id: "a", source: scratch.url.path + "/missing.wav")) }
            .hasPrefix("Cannot decode this recording."))
        let tooShort = scratch.url.appending(path: "short.wav")
        try AudioIO.writePCM24(Array(tone.prefix(44_100)), to: tooShort)
        #expect(Self.failure { try engine.prepare(EngineCoreTests.prepareCommand(id: "p", source: tooShort.path, destination: scratch.url.path + "/Voices/v/t2", transcript: "Hi")) }
            == "Use an audio recording between 3 seconds and 3 minutes long.")
    }

    @Test func configureIgnoresInvalidIdleTimesAndReportsMissingStudioModels() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let engine = Self.engine(scratch)
        for invalid in [-1, -0.001, -1e300] {   // JSON cannot carry NaN or infinity
            try engine.configure(EngineCoreTests.configureCommand(id: "c", keepStudioLoaded: nil, studioIdleSeconds: invalid))
            #expect(engine.configuration.studioIdleSeconds == 600)
        }
        try engine.configure(EngineCoreTests.configureCommand(id: "c", keepStudioLoaded: false, studioIdleSeconds: 0))
        #expect(engine.configuration.studioIdleSeconds == 0 && !engine.configuration.keepStudioLoaded)
        #expect(Self.failure { try engine.configure(EngineCoreTests.configureCommand(id: "c", keepStudioLoaded: true, studioIdleSeconds: nil)) }
            == SpeechEngineCore.modelsMissing)
        engine.idleTick(now: .distantFuture)   // nothing loaded: no-op, no crash
        #expect(engine.loadedProfiles.isEmpty && !engine.busy)
    }

    @Test func cancellationIsTrackedPerJobAcrossThreads() async {
        let registry = CancellationRegistry()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<2000 { group.addTask { registry.cancel("job-\(n)"); if n % 2 == 0 { registry.clear("job-\(n)") } } }
        }
        #expect((0..<2000).allSatisfy { registry.isCancelled("job-\($0)") == ($0 % 2 == 1) })
        let scratch = try? Scratch(); defer { scratch?.remove() }
        let engine = Self.engine(scratch!)
        engine.requestCancel("a")
        #expect(engine.isCancelledExternally("a") && !engine.isCancelledExternally("b"))
        engine.clearCancellation("a")
        #expect(!engine.isCancelledExternally("a"))
    }

    @Test func runBlockingReturnsValuesAndRethrows() throws {
        #expect(try runBlocking { 41 + 1 } == 42)
        #expect(throws: EngineFailure.self) { try runBlocking { () async throws -> Int in throw EngineFailure.failed("x") } }
    }

    @Test func generatedAudioMustBeFiniteAndNonEmpty() throws {
        #expect(try SynthesisJob.validated([0, 0.5, -1]) == [0, 0.5, -1])
        for bad: [Float] in [[], [0, .nan], [.infinity], [-.infinity, 0]] {
            #expect(Self.failure { try SynthesisJob.validated(bad) } == "Model produced invalid audio.")
        }
    }

    @Test func failureMessagesAreTheUserFacingText() {
        #expect(EngineFailure.cancelled.localizedDescription == "Cancelled")
        #expect(EngineFailure.invalid("Bad input.").localizedDescription == "Bad input.")
        #expect(EngineFailure.failed("Broke.").localizedDescription == "Broke.")
        #expect(Duration.seconds(1.5).seconds == 1.5 && Duration.milliseconds(250).seconds == 0.25)
    }
}

import ChatterCore
import Darwin
import Foundation
import Testing

/// Deeper coverage of render mode, `?wait=`, query parsing and render expiry: every combination the
/// validator sees, the numeric edges of `wait`, seeded fuzz for the two parsers, and the file-system
/// shapes `removeExpiredRenders` can meet in the Jobs folder.
struct SpeechModeEdgeTests {
    static func message(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return error.localizedDescription }
    }

    // MARK: Modes × dialogue × quality

    /// Validation order is mode, then the dialogue/render rule, then quality: every combination gets
    /// exactly the first message that applies, and anything that passes keeps its mode and quality.
    @Test func everyModeDialogueAndQualityCombination() throws {
        let script = try DialogueScript(cast: ["Host": "Ryan"], turns: [DialogueLine(actor: "Host", text: "Hi.")]).validated()
        let qualityMessage = "Quality must be responsive, balanced, or studio."
        let renderDialogue = "Dialogue supports play or save; render is for single-voice speech."
        for mode in ["play", "save", "render", "Render", "PLAY", "", " render", "render ", "stream"] {
            for dialogue in [nil, script] {
                for quality in [nil, "responsive", "balanced", "studio", "fast", "Studio"] as [String?] {
                    var request = SpeechRequest(voice: "Ryan", text: "Host: Hi.", mode: mode, quality: quality)
                    request.dialogue = dialogue
                    let known = SpeechMode(rawValue: mode)
                    let expected: String? =
                        known == nil ? SpeechMode.validationMessage
                        : (known == .render && dialogue != nil) ? renderDialogue
                        : (quality != nil && SpeechQuality(rawValue: quality!) == nil) ? qualityMessage
                        : nil
                    let label = "mode=\(mode.debugDescription) dialogue=\(dialogue != nil) quality=\(quality ?? "nil")"
                    #expect(Self.message { try request.validated() } == expected, "\(label)")
                    if expected == nil {
                        let valid = try request.validated()
                        #expect(valid.mode == mode && valid.quality == quality, "\(label)")
                    }
                }
            }
        }
    }

    @Test func modeRulesAndMessages() {
        #expect(SpeechMode.allCases.map(\.rawValue) == ["play", "save", "render"])
        #expect(SpeechMode.validationMessage == "Mode must be play, save or render.")
        // The message names every mode, so a new mode cannot be added without updating it.
        for mode in SpeechMode.allCases { #expect(SpeechMode.validationMessage.contains(mode.rawValue)) }
        // Render is silent and private: no speakers, no export, but its quality is honoured.
        #expect(!SpeechMode.render.playsOnMac && !SpeechMode.render.exportsWAV && SpeechMode.render.honoursQuality)
        // The engine sees each mode by its own name (it treats every non-save mode as live audio).
        for mode in SpeechMode.allCases { #expect(SpeechMode(rawValue: mode.engineMode) == mode) }
        #expect(SpeechMode.renderRetention == 600)
        #expect(JobWait.maximum == 30 && JobWait.perCredential == 8)
    }

    /// The model each mode gets, for every voice kind and quality. Save always gets Studio for a clone;
    /// play and render pick by quality, so render is never silently upgraded or downgraded.
    @Test(arguments: SpeechMode.allCases)
    func modelProfileForEveryModeKindAndQuality(mode: SpeechMode) {
        for quality in SpeechQuality.allCases {
            for kind in VoiceKind.allCases {
                let expected: String = switch kind {
                case .preset: "custom"
                case .designed: "design"
                case .cloned: (mode == .save || quality == .studio) ? "quality" : "fast"
                }
                #expect(quality.modelProfile(for: kind, mode: mode.engineMode) == expected, "\(mode) \(quality) \(kind)")
                // Render and play are indistinguishable to model selection.
                if mode == .render { #expect(quality.modelProfile(for: kind, mode: "render") == quality.modelProfile(for: kind, mode: "play")) }
            }
        }
    }

    /// A render command reaches the engine protocol intact, alone or carrying dialogue turns (the engine
    /// refuses render dialogue itself; the protocol does not guess).
    @Test func engineCommandsDecodeRenderMode() throws {
        let single = #"{"op":"synthesize","id":"r","text":"Hi","references":[],"mode":"render","pace":1,"quality":"responsive","directory":"/d","output":"/d/speech.wav"}"#
        guard case .synthesize(let command) = try EngineCommand.decode(Data(single.utf8)) else { Issue.record("not synthesize"); return }
        #expect(command.mode == "render" && command.quality == "responsive" && command.dialogueTurns == nil)
        #expect(SpeechMode(rawValue: command.mode) == .render)
        let dialogue = #"{"op":"synthesize","id":"d","text":"Host: Hi","references":[],"mode":"render","pace":1,"directory":"/d","output":"/d/speech.wav","dialogueTurns":[{"actor":"Host","voiceID":"v","text":"Hi","configuration":{"kind":"preset","speaker":"Aiden","language":"English"},"references":[],"language":"English","toneCue":""}]}"#
        guard case .synthesize(let turns) = try EngineCommand.decode(Data(dialogue.utf8)) else { Issue.record("not synthesize"); return }
        #expect(turns.mode == "render" && turns.dialogueTurns?.count == 1)
    }

    // MARK: ?wait=

    @Test(arguments: [
        ("30", 30), ("30.0", 30), ("3e1", 30), ("+5", 5), (".5", 0.5), ("5.", 5), ("0.001", 0.001),
        ("1e-300", 1e-300), ("5e-324", 5e-324), ("29.999999", 29.999999), ("3E1", 30), ("3e+1", 30),
        ("300e-1", 30), ("+.5", 0.5), ("007", 7), ("00.5", 0.5),
        ("30.000000000000001", 30),   // rounds to exactly 30.0 as a Double
        ("tRuE", 30), ("True", 30),
    ] as [(String, Double)])
    func waitAcceptsEveryFormOfAnAllowedNumber(value: String, seconds: Double) throws {
        #expect(try JobWait.seconds(from: ["wait": value]) == seconds)
    }

    @Test(arguments: [
        "30.0001", "30.0000000000001", "31", "1e400", "Infinity", "-Infinity", "inF", "NaN", "nan(0x1)",
        "-0", "0.0", "0e5", "-5", "-0.001", "--5", "+-5",
        " 5", "5 ", "\t5", "5\n", " true", "true ", "1_0", "1,5", "e5", "1e", "0b11", "0o7",
        "５", "٥", "५", "²", "Ⅴ", "yes", "no", "on", "1s", "%35", "\0", "true\0",
        // Not decimal notation, whatever the toolchain's Double(_:) makes of it.
        "0x1A", "0X1A", "0x1E", "0X1E", "0x1p4", "0X1P4", "0x1.8p1", "0x", "0x0", "+0x5",
        "1e+", "1e-", "1e5e1", "1.2.3", "1..5", ".", "+", "-", "+.", ".e1", "5.e", "5\u{301}",
    ])
    func waitRejectsEverythingElse(value: String) {
        #expect(Self.message { try JobWait.seconds(from: ["wait": value]) } == "wait must be true, false or a number of seconds up to 30.")
    }

    @Test(arguments: ["false", "FALSE", "False", "0"])
    func waitFalseOrZeroMeansAnswerAtOnce(value: String) throws {
        #expect(try JobWait.seconds(from: ["wait": value]) == nil)
    }

    /// Only the `wait` key matters; other names (including near misses) never trigger a wait.
    @Test func onlyTheWaitKeyIsRead() throws {
        #expect(try JobWait.seconds(from: ["Wait": "abc", "WAIT": "5", "wait ": "5", "timeout": "5"]) == nil)
    }

    /// Seeded fuzz over the characters a number can be made of (plus noise): `seconds` either throws
    /// ChatterError.invalid, returns nil only for the two "do not wait" spellings, or returns a value in
    /// (0, 30] for "true", "" or ASCII decimal text only. It is deterministic. Metamorphic: any value in
    /// (0, 30] printed by Swift round-trips.
    @Test func waitFuzzNeverEscapesItsRange() throws {
        let decimalBytes = Set("0123456789+-.eE".utf8)
        let pieces = ["0", "1", "2", "3", "5", "9", ".", "e", "E", "+", "-", "x", "p", "a", "f", "n", "i", "t", "r", "u",
                      " ", "%", "_", "٣", "٫", "\u{0}", "true", "false", "30", "0.", "e-", "1e1", "inf", "nan"]
        for seed in UInt64(0)..<4000 {
            var rng = SeededGenerator(seed: seed)
            let value = rng.text(from: pieces, count: 0...7)
            let first = Result { try JobWait.seconds(from: ["wait": value]) }
            let second = Result { try JobWait.seconds(from: ["wait": value]) }
            switch (first, second) {
            case (.success(let a), .success(let b)):
                #expect(a == b, "seed \(seed) value \(value.debugDescription)")
                if let a {
                    #expect(a > 0 && a <= 30 && a.isFinite, "seed \(seed) value \(value.debugDescription) gave \(a)")
                    #expect(["true", ""].contains(value.lowercased()) || value.utf8.allSatisfy(decimalBytes.contains),
                            "seed \(seed) accepted non-decimal \(value.debugDescription)")
                }
                else { #expect(["false", "0"].contains(value.lowercased()), "seed \(seed) value \(value.debugDescription) gave nil") }
            case (.failure(let error), .failure):
                guard case ChatterError.invalid = error else { Issue.record("seed \(seed): unexpected \(error)"); continue }
            default: Issue.record("seed \(seed) value \(value.debugDescription) is not deterministic")
            }
        }
        var rng = SeededGenerator(seed: 0x3A17)
        for _ in 0..<2000 {
            let seconds = Double.random(in: Double.leastNonzeroMagnitude...30, using: &rng)
            #expect(try JobWait.seconds(from: ["wait": "\(seconds)"]) == seconds, "\(seconds)")
            let over = 30 + Double.random(in: 1e-9...1e6, using: &rng)
            #expect(throws: ChatterError.self, "\(over)") { try JobWait.seconds(from: ["wait": "\(over)"]) }
        }
    }

    // MARK: HTTPRequest.query

    @Test func queryEdgeShapes() {
        func q(_ path: String) -> [String: String] { HTTPRequest(method: "GET", path: path).query }
        // Undecodable names are dropped; undecodable values are kept exactly as written.
        #expect(q("/x?%FF=1&wait=%FF") == ["wait": "%FF"])
        #expect(q("/x?wait=%") == ["wait": "%"])
        #expect(q("/x?wait=%2") == ["wait": "%2"])
        #expect(q("/x?wait=5%") == ["wait": "5%"])
        // Escapes in names decode, so an encoded name is the same key, and the first occurrence wins.
        #expect(q("/x?w%61it=7&wait=9") == ["wait": "7"])
        #expect(q("/x?%77ait=%33%30") == ["wait": "30"])
        // An empty name, or one whose escapes do not decode, is skipped and shadows nothing.
        #expect(q("/x?=1&%=2&%FF=3&wait") == ["wait": ""])
        // `+` is not a space in this API, and `?` after the first one is ordinary data.
        #expect(q("/x?wait=+5") == ["wait": "+5"])
        #expect(q("/x?a=1?b=2") == ["a": "1?b=2"])
        #expect(q("/x??wait=1") == ["?wait": "1"])
        // Separators only: nothing.
        #expect(q("/x?&&&") == [:])
        #expect(q("?wait=true") == ["wait": "true"])
        // Unicode and NUL decode like any other escape.
        #expect(q("/x?n=%C3%A9&z=%00") == ["n": "é", "z": "\0"])
        // An earlier empty value still wins over a later real one.
        #expect(q("/x?wait=&wait=30") == ["wait": ""])
    }

    /// The query a real request line carries reaches `query` after `parse`, so `?wait=` survives the
    /// listener exactly as a client sent it.
    @Test func parsedRequestLinesKeepTheirQuery() throws {
        let raw = Data("POST /v1/speech?wait=12.5&x=%41 HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let request = try #require(try HTTPRequest.parse(raw)?.0)
        #expect(request.query == ["wait": "12.5", "x": "A"])
        #expect(try JobWait.seconds(from: request.query) == 12.5)
    }

    /// Seeded fuzz: arbitrary bytes and percent sequences never crash `query`. Properties: deterministic;
    /// no key is empty; a path without `?` has no query; every value either is the raw text after the
    /// first `=` or is its percent-decoding. Metamorphic: appending `&k=v` for a key already present changes
    /// nothing (the first occurrence wins), and prefixing `k=v&` with a plain key and value sets it.
    @Test func queryFuzzNeverCrashesAndTheFirstOccurrenceWins() {
        let pieces = ["a", "wait", "=", "&", "%", "%2", "%41", "%zz", "%FF", "%C3", "%A9", "%00", "%3D", "%26", "?", "#", "+",
                      " ", "é", "😀", "\u{0}", "\u{7F}", "30", "true"]
        for seed in UInt64(0)..<3000 {
            var rng = SeededGenerator(seed: seed)
            let bytes = (0..<Int.random(in: 0...24, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let noise = String(decoding: bytes, as: UTF8.self)
            let tail = rng.text(from: pieces, count: 0...14)
            let path = seed % 3 == 0 ? "/v1/speech" + noise + tail : "/v1/speech?" + tail + noise
            let query = HTTPRequest(method: "GET", path: path).query
            let label = "seed \(seed) path \(path.debugDescription)"
            #expect(query == HTTPRequest(method: "GET", path: path).query, "\(label)")
            #expect(!query.keys.contains(""), "\(label)")
            if !path.contains("?") { #expect(query.isEmpty, "\(label)") }
            if let mark = path.firstIndex(of: "?") {
                let pairs = path[path.index(after: mark)...].split(separator: "&")
                for (key, value) in query {
                    let raws = pairs.compactMap { pair -> String? in
                        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts[0].removingPercentEncoding == key else { return nil }
                        return parts.count > 1 ? String(parts[1]) : ""
                    }
                    let first = raws.first
                    #expect(first != nil, "\(label) key \(key.debugDescription) came from nowhere")
                    if let first { #expect(value == (first.removingPercentEncoding ?? first), "\(label) key \(key.debugDescription)") }
                }
                // First occurrence wins: repeating any present key at the end changes nothing.
                for key in query.keys where !key.contains("&") && !key.contains("=") && !key.contains("%") {
                    #expect(HTTPRequest(method: "GET", path: path + "&\(key)=override").query == query, "\(label) key \(key.debugDescription)")
                }
                // A plain pair placed first always wins over anything after it.
                let first = HTTPRequest(method: "GET", path: String(path[..<path.index(after: mark)]) + "wait=7&" + path[path.index(after: mark)...]).query
                #expect(first["wait"] == "7", "\(label)")
            }
        }
    }

    // MARK: Render expiry on disk

    /// A scratch tree: `root/Jobs` is the jobs folder; `root/Outside` holds things that must survive.
    struct Tree {
        let root: URL
        var jobs: URL { root.appending(path: "Jobs") }
        var outside: URL { root.appending(path: "Outside") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "render-edges-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appending(path: "Jobs"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "Outside"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: root.appending(path: "Outside/keep.wav"))
            try Data("keep".utf8).write(to: root.appending(path: "sibling.txt"))
        }
        func remove() {
            chmod(jobs.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        /// Everything outside the jobs folder that the tree started with is still there, untouched.
        func outsideIntact(_ comment: Comment? = nil) {
            #expect(FileManager.default.contents(atPath: outside.appending(path: "keep.wav").path) == Data("keep".utf8), comment)
            #expect(FileManager.default.contents(atPath: root.appending(path: "sibling.txt").path) == Data("keep".utf8), comment)
        }
        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
    }

    static func renderJob(id: String = UUID().uuidString, mode: String = "render", state: String = "completed", path: String? = "set") -> SpeechJob {
        var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: "Hi.", mode: mode), voiceName: "Scar")
        job.id = id; job.state = state; job.path = path
        return job
    }

    /// Writes `speech.wav` for a job, sets its modification time and returns the time actually stored
    /// (file systems round), so boundary tests compare against what the code will read.
    @discardableResult
    static func writeAudio(_ tree: Tree, id: String, modified: Date) throws -> Date {
        let directory = tree.jobs.appending(path: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appending(path: "speech.wav")
        try Data([1, 2, 3]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: audio.path)
        return try #require(try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date)
    }

    /// Exactly `renderRetention` after the audio was written it expires; a moment before, it is kept.
    /// Audio dated in the future (clock moved back) is kept, never deleted early.
    @Test func expiryBoundaryAndFutureTimestamps() throws {
        let tree = try Tree(); defer { tree.remove() }
        let now = Date()
        let atBoundary = UUID().uuidString, justBefore = UUID().uuidString, future = UUID().uuidString
        let written = try Self.writeAudio(tree, id: atBoundary, modified: now.addingTimeInterval(-SpeechMode.renderRetention))
        let writtenBefore = try Self.writeAudio(tree, id: justBefore, modified: now.addingTimeInterval(-SpeechMode.renderRetention + 5))
        try Self.writeAudio(tree, id: future, modified: now.addingTimeInterval(3600))
        let jobs = [Self.renderJob(id: atBoundary), Self.renderJob(id: justBefore), Self.renderJob(id: future)]
        // Judge each at its own exact boundary using the stored times.
        #expect(try AudioStorage.removeExpiredRenders([jobs[1]], jobs: tree.jobs, now: writtenBefore.addingTimeInterval(SpeechMode.renderRetention - 0.001)) == [])
        #expect(try AudioStorage.removeExpiredRenders(jobs, jobs: tree.jobs, now: written.addingTimeInterval(SpeechMode.renderRetention)) == [atBoundary])
        #expect(!tree.exists(tree.jobs.appending(path: atBoundary)))
        #expect(tree.exists(tree.jobs.appending(path: justBefore)) && tree.exists(tree.jobs.appending(path: future)))
        tree.outsideIntact()
    }

    /// The job folder is a symlink to a folder outside Jobs (with old audio inside): the link is
    /// removed, never what it points to.
    @Test func aSymlinkedJobFolderIsUnlinkedNotFollowed() throws {
        let tree = try Tree(); defer { tree.remove() }
        let victim = tree.outside.appending(path: "victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: victim.appending(path: "speech.wav"))
        try Data("precious".utf8).write(to: victim.appending(path: "other.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: victim.appending(path: "speech.wav").path)
        let id = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: tree.jobs.appending(path: id), withDestinationURL: victim)
        // A link to Jobs' own parent, too: unlinking it must not touch the tree.
        let parentLink = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: tree.jobs.appending(path: parentLink), withDestinationURL: tree.root)

        let expired = try AudioStorage.removeExpiredRenders([Self.renderJob(id: id), Self.renderJob(id: parentLink)], jobs: tree.jobs)
        #expect(Set(expired) == [id, parentLink])
        #expect(!tree.exists(tree.jobs.appending(path: id)) && !tree.exists(tree.jobs.appending(path: parentLink)))
        #expect(FileManager.default.contents(atPath: victim.appending(path: "speech.wav").path) == Data("precious".utf8))
        #expect(FileManager.default.contents(atPath: victim.appending(path: "other.txt").path) == Data("precious".utf8))
        #expect(tree.exists(tree.jobs))
        tree.outsideIntact()
    }

    /// `speech.wav` is a symlink to a file outside Jobs: only the job folder (with the link) goes.
    @Test func aSymlinkedAudioFileNeverDeletesItsTarget() throws {
        let tree = try Tree(); defer { tree.remove() }
        let target = tree.outside.appending(path: "keep.wav")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: target.path)
        let id = UUID().uuidString
        let directory = tree.jobs.appending(path: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appending(path: "speech.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // Age the link itself (setAttributes would follow it to the target).
        var times = [timeval(tv_sec: time(nil) - 86_400, tv_usec: 0), timeval(tv_sec: time(nil) - 86_400, tv_usec: 0)]
        #expect(lutimes(link.path, &times) == 0)

        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: id)], jobs: tree.jobs) == [id])
        #expect(!tree.exists(directory))
        tree.outsideIntact()
    }

    /// `speech.wav` is a directory: its own modification time decides, and an expired one goes with
    /// the job folder; a fresh one is kept.
    @Test func anAudioPathThatIsADirectoryFollowsTheSameClock() throws {
        let tree = try Tree(); defer { tree.remove() }
        let old = UUID().uuidString, fresh = UUID().uuidString
        for id in [old, fresh] {
            let audio = tree.jobs.appending(path: "\(id)/speech.wav")
            try FileManager.default.createDirectory(at: audio.appending(path: "nested"), withIntermediateDirectories: true)
            try Data([0]).write(to: audio.appending(path: "nested/part.wav"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: id == old ? -86_400 : -1)], ofItemAtPath: audio.path)
        }
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: old), Self.renderJob(id: fresh)], jobs: tree.jobs) == [old])
        #expect(!tree.exists(tree.jobs.appending(path: old)))
        #expect(tree.exists(tree.jobs.appending(path: "\(fresh)/speech.wav/nested/part.wav")))
        tree.outsideIntact()
    }

    /// Receipt IDs that are not UUIDs (traversal, separators, empty, braces) are never turned into
    /// paths, even when the folder they name exists and the receipt's path points at real audio.
    @Test func nonUUIDIdentifiersAndReceiptPathsAreNeverFollowed() throws {
        let tree = try Tree(); defer { tree.remove() }
        let outsideAudio = tree.outside.appending(path: "keep.wav").path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: outsideAudio)
        let uuid = UUID().uuidString
        let ids = ["..", ".", "", "/", "../Outside", "../../", "\(uuid)/..", "{\(uuid)}", "\(uuid) ", " \(uuid)", "\(uuid)/x", "*", "~"]
        let expired = try AudioStorage.removeExpiredRenders(ids.map { Self.renderJob(id: $0, path: outsideAudio) }, jobs: tree.jobs)
        #expect(expired.isEmpty)
        #expect(tree.exists(tree.jobs))
        tree.outsideIntact()
        // A real render whose receipt path points outside: only its own job folder is judged and removed.
        let real = UUID().uuidString
        try Self.writeAudio(tree, id: real, modified: Date(timeIntervalSinceNow: -86_400))
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: real, path: outsideAudio)], jobs: tree.jobs) == [real])
        tree.outsideIntact()
        // Lowercase UUIDs are UUIDs too.
        let lower = UUID().uuidString.lowercased()
        try Self.writeAudio(tree, id: lower, modified: Date(timeIntervalSinceNow: -86_400))
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: lower)], jobs: tree.jobs) == [lower])
    }

    /// Every terminal state expires; queued and generating renders are never touched, however old.
    @Test(arguments: [("completed", true), ("failed", true), ("cancelled", true), ("queued", false), ("generating", false), ("preparing", false)])
    func onlyTerminalRendersExpire(state: String, expires: Bool) throws {
        let tree = try Tree(); defer { tree.remove() }
        let id = UUID().uuidString
        try Self.writeAudio(tree, id: id, modified: Date(timeIntervalSinceNow: -86_400))
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: id, state: state)], jobs: tree.jobs) == (expires ? [id] : []))
        #expect(tree.exists(tree.jobs.appending(path: id)) == !expires)
    }

    /// No Jobs folder at all: renders with receipts are reported (so receipts stop offering audio) and
    /// nothing is created.
    @Test func aMissingJobsFolderReportsWithoutCreatingAnything() throws {
        let tree = try Tree(); defer { tree.remove() }
        let missing = tree.root.appending(path: "NoJobs")
        let id = UUID().uuidString
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: id)], jobs: missing) == [id])
        #expect(!tree.exists(missing))
    }

    /// A folder that cannot be removed is an error, not a silent skip: the receipt is not reported, so
    /// it is retried on the next pass. (FileManager empties the folder before failing on the folder
    /// itself, so the audio may already be gone; the receipt then reports it as missing next time.)
    @Test func aFolderThatCannotBeRemovedThrows() throws {
        let tree = try Tree(); defer { tree.remove() }
        let id = UUID().uuidString
        try Self.writeAudio(tree, id: id, modified: Date(timeIntervalSinceNow: -86_400))
        #expect(chmod(tree.jobs.path, 0o555) == 0)
        #expect(throws: (any Error).self) { try AudioStorage.removeExpiredRenders([Self.renderJob(id: id)], jobs: tree.jobs) }
        #expect(tree.exists(tree.jobs.appending(path: id)))
        // Once the folder can be removed, the same receipt expires normally.
        #expect(chmod(tree.jobs.path, 0o755) == 0)
        #expect(try AudioStorage.removeExpiredRenders([Self.renderJob(id: id)], jobs: tree.jobs) == [id])
        #expect(!tree.exists(tree.jobs.appending(path: id)))
    }

    /// Seeded property test against an oracle. Random receipts (mode, state, path, ID shape, audio age or
    /// absence) over a real Jobs folder: the IDs reported are exactly the terminal render receipts with a
    /// path, a UUID ID and audio at least `renderRetention` old or missing; exactly those folders are
    /// gone; every other folder and everything outside Jobs remains. Running again is idempotent.
    @Test func expiryMatchesItsOracleForRandomReceipts() throws {
        let modes = ["play", "save", "render", "Render", ""]
        let states = ["completed", "failed", "cancelled", "queued", "generating"]
        for seed in UInt64(0)..<40 {
            var rng = SeededGenerator(seed: seed)
            let tree = try Tree(); defer { tree.remove() }
            let now = Date()
            var receipts: [SpeechJob] = [], expected: Set<String> = []
            for index in 0..<Int.random(in: 1...12, using: &rng) {
                let uuid = Bool.random(using: &rng) || index == 0
                let id = uuid ? UUID().uuidString : "job-\(index)"
                let mode = modes.randomElement(using: &rng)!
                let state = states.randomElement(using: &rng)!
                let hasPath = Int.random(in: 0..<5, using: &rng) > 0
                // Age: nil = no audio file; otherwise seconds before now (negative = future).
                let age: Double? = Int.random(in: 0..<6, using: &rng) == 0 ? nil
                    : [-60, 0, 1, 599, 600, 601, 86_400].randomElement(using: &rng)!
                try FileManager.default.createDirectory(at: tree.jobs.appending(path: id), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: tree.jobs.appending(path: "\(id)/other.bin"))
                var stored: Date?
                if let age { stored = try Self.writeAudio(tree, id: id, modified: now.addingTimeInterval(-age)) }
                receipts.append(Self.renderJob(id: id, mode: mode, state: state, path: hasPath ? "/anything" : nil))
                let terminal = ["completed", "failed", "cancelled"].contains(state)
                if mode == "render", terminal, hasPath, uuid, stored.map({ now.timeIntervalSince($0) >= SpeechMode.renderRetention }) ?? true {
                    expected.insert(id)
                }
            }
            let label = "seed \(seed)"
            let expired = try AudioStorage.removeExpiredRenders(receipts, jobs: tree.jobs, now: now)
            #expect(Set(expired) == expected, "\(label)")
            #expect(expired.count == Set(expired).count, "\(label): an ID was reported twice")
            for receipt in receipts {
                #expect(tree.exists(tree.jobs.appending(path: receipt.id)) == !expected.contains(receipt.id), "\(label) \(receipt.id)")
            }
            tree.outsideIntact(Comment(rawValue: label))
            // Idempotent: the same pass again deletes nothing more and reports the same receipts (their
            // audio is now missing), which the app clears by dropping the receipt's path.
            let again = try AudioStorage.removeExpiredRenders(receipts, jobs: tree.jobs, now: now)
            #expect(Set(again) == expected, "\(label)")
            for receipt in receipts where !expected.contains(receipt.id) {
                #expect(tree.exists(tree.jobs.appending(path: "\(receipt.id)/other.bin")), "\(label) \(receipt.id)")
            }
        }
    }
}

private extension RandomNumberGenerator {
    /// Concatenates a random number of pieces.
    mutating func text(from pieces: [String], count: ClosedRange<Int>) -> String {
        (0..<Int.random(in: count, using: &self)).map { _ in pieces.randomElement(using: &self)! }.joined()
    }
}

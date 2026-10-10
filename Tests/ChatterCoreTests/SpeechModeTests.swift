import ChatterCore
import Foundation
import Testing

struct SpeechModeTests {
    @Test func onlyPlayUsesTheMacsSpeakersAndOnlySaveExports() {
        #expect(SpeechMode.allCases.filter(\.playsOnMac) == [.play])
        #expect(SpeechMode.allCases.filter(\.exportsWAV) == [.save])
        #expect(SpeechMode.allCases.filter(\.honoursQuality) == [.play, .render])
        #expect(SpeechMode.allCases.map(\.engineMode) == ["play", "save", "render"])
    }

    @Test func renderIsAValidModeForSingleVoiceSpeech() throws {
        for mode in ["play", "save", "render"] {
            #expect(try SpeechRequest(voice: "Scar", text: "Hello.", mode: mode, quality: "responsive").validated().mode == mode)
        }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice: "Scar", text: "Hello.", mode: "stream").validated() }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice: "Scar", text: "Hello.", mode: "Render").validated() }
    }

    @Test func dialogueCannotBeRendered() throws {
        let script = try DialogueScript(cast: ["Host": "Ryan"], turns: [DialogueLine(actor: "Host", text: "Hi.")]).validated()
        var request = SpeechRequest(voice: "Ryan", text: "Host: Hi.", mode: "render")
        request.dialogue = script
        #expect(throws: ChatterError.self) { try request.validated() }
        request.mode = "play"
        #expect(try request.validated().mode == "play")
    }

    @Test func renderedClonesUseTheRequestedModel() {
        #expect(SpeechQuality.responsive.modelProfile(for: .cloned, mode: "render") == "fast")
        #expect(SpeechQuality.balanced.modelProfile(for: .cloned, mode: "render") == "fast")
        #expect(SpeechQuality.studio.modelProfile(for: .cloned, mode: "render") == "quality")
        #expect(SpeechQuality.responsive.modelProfile(for: .cloned, mode: "save") == "quality")
    }

    // MARK: ?wait=

    @Test(arguments: [(nil, nil), ("true", 30), ("TRUE", 30), ("", 30), ("false", nil), ("0", nil), ("5", 5), ("0.25", 0.25), ("30", 30)] as [(String?, Double?)])
    func waitAcceptsTrueFalseOrSeconds(value: String?, seconds: Double?) throws {
        let query = value.map { ["wait": $0] } ?? [:]
        #expect(try JobWait.seconds(from: query) == seconds)
    }

    @Test(arguments: ["31", "-1", "abc", "nan", "inf", "1e9", "%zz", "5s"])
    func waitRejectsAnythingElse(value: String) {
        #expect(throws: ChatterError.self) { try JobWait.seconds(from: ["wait": value]) }
    }

    @Test func queryParametersAreDecodedAndTheFirstWins() {
        #expect(HTTPRequest(method: "GET", path: "/v1/jobs/x").query.isEmpty)
        #expect(HTTPRequest(method: "GET", path: "/v1/jobs/x?").query.isEmpty)
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait=true&x=1").query == ["wait": "true", "x": "1"])
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait=%31%30").query == ["wait": "10"])
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait=1&wait=30").query == ["wait": "1"])
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait").query == ["wait": ""])
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?=5&&wait=2").query == ["wait": "2"])
        // An escape that does not decode stays as written, so validation refuses it.
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait=%zz").query == ["wait": "%zz"])
        #expect(HTTPRequest(method: "POST", path: "/v1/speech?wait=a=b").query == ["wait": "a=b"])
    }

    // MARK: Ephemeral render audio

    @Test func renderAudioExpiresAfterItsWindowAndOtherModesAreKept() throws {
        let jobs = FileManager.default.temporaryDirectory.appending(path: "render-expiry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: jobs) }
        let now = Date()
        func job(_ mode: String, state: String = "completed", writtenAgo: TimeInterval?, id: String = UUID().uuidString) throws -> SpeechJob {
            var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: "Hi.", mode: mode), voiceName: "Scar")
            job.id = id; job.state = state
            let directory = jobs.appending(path: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let writtenAgo {
                let audio = directory.appending(path: "speech.wav")
                try Data([1, 2, 3]).write(to: audio)
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-writtenAgo)], ofItemAtPath: audio.path)
                job.path = audio.path
            } else { job.path = directory.appending(path: "speech.wav").path }
            return job
        }
        let old = try job("render", writtenAgo: SpeechMode.renderRetention + 1)
        let fresh = try job("render", writtenAgo: SpeechMode.renderRetention - 5)
        let missing = try job("render", writtenAgo: nil)
        let running = try job("render", state: "generating", writtenAgo: SpeechMode.renderRetention + 60)
        let oldPlay = try job("play", writtenAgo: SpeechMode.renderRetention * 10)
        let oldSave = try job("save", writtenAgo: SpeechMode.renderRetention * 10)
        var noPath = try job("render", writtenAgo: SpeechMode.renderRetention + 60)
        noPath.path = nil
        let notUUID = try job("render", writtenAgo: SpeechMode.renderRetention + 60, id: "not-a-uuid")

        let expired = try AudioStorage.removeExpiredRenders([old, fresh, missing, running, oldPlay, oldSave, noPath, notUUID], jobs: jobs, now: now)
        #expect(Set(expired) == [old.id, missing.id])
        for gone in [old, missing] { #expect(!FileManager.default.fileExists(atPath: jobs.appending(path: gone.id).path)) }
        for kept in [fresh, running, oldPlay, oldSave, noPath, notUUID] { #expect(FileManager.default.fileExists(atPath: jobs.appending(path: kept.id).path)) }
    }

    // MARK: Archived renders and the read-time backstop

    /// The render sweep reads the database, so archiving finished activity cannot keep a render's
    /// audio past its window, and clearing the path keeps an archived receipt archived.
    @Test func archivedRendersAreSweptAndStayArchived() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "render-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try JobDatabase(root: root)
        let jobsFolder = root.appending(path: "Jobs")
        var sequence: UInt64 = 0
        func receipt(_ mode: String, text: String = "Hi.", writtenAgo: TimeInterval?, state: String = "completed") throws -> SpeechJob {
            var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: text, mode: mode), voiceName: "Scar")
            sequence += 1; job.sequence = sequence; job.state = state
            if let writtenAgo {
                let directory = jobsFolder.appending(path: job.id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let audio = directory.appending(path: "speech.wav")
                try Data([0]).write(to: audio)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-writtenAgo)], ofItemAtPath: audio.path)
                job.path = audio.path
            }
            try database.save(job)
            return job
        }
        let archivedOld = try receipt("render", writtenAgo: SpeechMode.renderRetention + 30)
        let archivedFresh = try receipt("render", writtenAgo: 5)
        let play = try receipt("play", text: #"Say "mode":"render" and "path": aloud."#, writtenAgo: SpeechMode.renderRetention * 3)
        let noAudio = try receipt("render", writtenAgo: nil)
        try database.archiveFinished()
        let running = try receipt("render", writtenAgo: SpeechMode.renderRetention + 30, state: "generating")

        let candidates = try database.renderedAudio()
        #expect(Set(candidates.map(\.id)) == [archivedOld.id, archivedFresh.id])
        #expect(!candidates.contains { $0.id == play.id || $0.id == noAudio.id || $0.id == running.id })

        let expired = try AudioStorage.removeExpiredRenders(candidates, jobs: jobsFolder)
        #expect(expired == [archivedOld.id])
        var cleared = try #require(candidates.first { $0.id == archivedOld.id })
        cleared.path = nil
        try database.save(cleared)
        #expect(try database.find(id: archivedOld.id)?.path == nil)
        #expect(try database.recent().allSatisfy { $0.id != archivedOld.id })  // still archived
        #expect(try database.renderedAudio().map(\.id) == [archivedFresh.id])
        #expect(FileManager.default.fileExists(atPath: jobsFolder.appending(path: play.id).path))
    }

    @Test func renderAudioIsOfferedOnlyInsideItsWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "render-offer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func job(_ mode: String, writtenAgo: TimeInterval?, state: String = "completed", path: Bool = true) throws -> SpeechJob {
            var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: "Hi.", mode: mode), voiceName: "Scar")
            job.state = state
            let audio = folder.appending(path: "\(job.id).wav")
            if let writtenAgo {
                try Data([0]).write(to: audio)
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-writtenAgo)], ofItemAtPath: audio.path)
            }
            if path { job.path = audio.path }
            return job
        }
        #expect(AudioStorage.offersAudio(try job("render", writtenAgo: 5), now: now))
        #expect(!AudioStorage.offersAudio(try job("render", writtenAgo: SpeechMode.renderRetention), now: now))
        #expect(!AudioStorage.offersAudio(try job("render", writtenAgo: nil), now: now))
        #expect(!AudioStorage.offersAudio(try job("render", writtenAgo: 5, state: "generating"), now: now))
        #expect(!AudioStorage.offersAudio(try job("render", writtenAgo: 5, path: false), now: now))
        #expect(AudioStorage.offersAudio(try job("play", writtenAgo: SpeechMode.renderRetention * 100), now: now))
        #expect(AudioStorage.offersAudio(try job("save", writtenAgo: nil), now: now))
        #expect(!AudioStorage.offersAudio(try job("save", writtenAgo: nil, path: false), now: now))
    }
}

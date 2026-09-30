import Foundation
import Testing
@testable import ChatterCore

/// Since Chatter 2.2.1 the user's Expression settings decide whether a job gets expression notes; HTTP and MCP
/// requests can no longer say. What ChatterCore must still guarantee: receipts written by 2.2.0, when a request
/// could decide, load unchanged and keep the decision made when they were accepted; a request that did not
/// decide (every HTTP and MCP request now) leaves no `expressive` in its receipt's request; Studio's switch
/// survives validation; and "Add notes to HTTP and MCP requests" defaults on and survives older or repaired
/// preferences files.
struct ExpressionSettingAuthorityTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    static func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    static func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    /// A queue receipt exactly as Chatter 2.2.0 wrote it for an HTTP request that passed `expressive`.
    static func receipt22(id: String, requestExpressive: String, jobExpressive: String, state: String = "queued", sequence: Int) -> String {
        """
        {
          "attempts" : 0,
          "createdAt" : 780000000.5,
          "expressive" : \(jobExpressive),
          "id" : "\(id)",
          "message" : "Waiting for the speech engine",
          "request" : {
            "expressive" : \(requestExpressive),
            "mode" : "play",
            "pace" : 1,
            "quality" : "responsive",
            "text" : "I am so happy to be here!",
            "tone" : "natural",
            "voice" : "4B1A2C3D-0000-0000-0000-000000000001"
          },
          "requestID" : "retry-\(id)",
          "sequence" : \(sequence),
          "state" : "\(state)",
          "toneCue" : "",
          "voiceName" : "Loki"
        }
        """
    }

    // MARK: Receipts from 2.2.0

    /// A job queued by 2.2.0 with `expressive:false` (or true) was decided when it was accepted; after the
    /// upgrade it must load with that decision, not flip to the current setting, and saving it again must not
    /// drop or alter either field.
    @Test func receiptsWrittenWhenRequestsCouldDecideKeepTheirDecision() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(id: String, request: String, job: String, expectRequest: Bool?, expectJob: Bool?)] = [
            ("off", "false", "false", false, false),
            ("on", "true", "true", true, true),
            // A preview-like job: the request asked, but respell was off, so the job was not expressive.
            ("asked-not-run", "true", "false", true, false),
            // Explicit nulls, as a hand-edited or older receipt might have.
            ("null", "null", "null", nil, nil),
        ]
        for (n, item) in cases.enumerated() {
            let json = Self.receipt22(id: item.id, requestExpressive: item.request, jobExpressive: item.job, sequence: n + 1)
            try Data(json.utf8).write(to: directory.appending(path: item.id + ".json"))
        }
        let store = JobStore(directory: directory)
        let loaded = try store.load()
        #expect(loaded.map(\.id) == ["null", "asked-not-run", "on", "off"])
        for item in cases {
            let job = try #require(loaded.first { $0.id == item.id })
            #expect(job.request.expressive == item.expectRequest, "\(item.id)")
            #expect(job.expressive == item.expectJob, "\(item.id)")
            #expect(job.requestID == "retry-\(item.id)" && job.voiceName == "Loki" && job.request.text == "I am so happy to be here!")
        }
        // A restart re-saves unfinished receipts; the decision must survive that, byte for byte on the second pass.
        for job in loaded { try store.save(job) }
        let firstPass = try loaded.map { try Data(contentsOf: directory.appending(path: $0.id + ".json")) }
        let reloaded = try store.load()
        for job in reloaded { try store.save(job) }
        let secondPass = try reloaded.map { try Data(contentsOf: directory.appending(path: $0.id + ".json")) }
        #expect(firstPass == secondPass)
        #expect(reloaded.map(\.expressive) == loaded.map(\.expressive))
        #expect(reloaded.map(\.request.expressive) == loaded.map(\.request.expressive))
    }

    /// A receipt whose request carries a non-Boolean `expressive` cannot have been written by any Chatter
    /// (2.2.0 rejected such requests); it is corruption and must be visible, not read as "the setting".
    @Test func aReceiptWithAMalformedRequestDecisionIsNotSilentlyReadAsTheSetting() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.receipt22(id: "bad", requestExpressive: #""false""#, jobExpressive: "false", sequence: 1).utf8)
            .write(to: directory.appending(path: "bad.json"))
        #expect(throws: DecodingError.self) { try JobStore(directory: directory).load() }
    }

    // MARK: Requests that don't decide

    /// Every HTTP and MCP request now builds a `SpeechRequest` without `expressive`; its receipt's request must
    /// not claim a decision, while the job-level `expressive` (what the API documents) reports the setting's.
    @Test func requestsThatDontDecideLeaveNoExpressiveInTheirReceipt() throws {
        let request = try SpeechRequest(voice: "v", text: "Hi.", tone: "cheerful").validated()
        #expect(request.expressive == nil)
        let requestObject = try Self.object(request)
        #expect(requestObject["expressive"] == nil)
        #expect(Set(requestObject.keys) == ["voice", "text", "pace", "mode", "tone"])

        for setting in [true, false] {
            var job = SpeechJob(request: request, voiceName: "V")
            job.expressive = setting
            let receipt = try Self.object(job)
            #expect(receipt["expressive"] as? Bool == setting)
            let receiptRequest = try #require(receipt["request"] as? [String: Any])
            #expect(receiptRequest["expressive"] == nil)
        }
        // Studio still passes its switch through the request, and it is recorded as given.
        for studio in [true, false] {
            let object = try Self.object(SpeechRequest(voice: "v", text: "Hi.", expressive: studio))
            #expect(object["expressive"] as? Bool == studio)
        }
    }

    /// `submit` validates before it reads `expressive`; validation must never invent, drop or flip the
    /// Studio switch, whatever the other fields.
    @Test(arguments: [nil, true, false] as [Bool?])
    func validationKeepsTheStudioSwitch(expressive: Bool?) throws {
        for tone in [nil] + SpeechTone.allCases.map(\.rawValue) as [String?] {
            for mode in ["play", "save"] {
                for quality in [nil, "responsive", "balanced", "studio"] as [String?] {
                    let request = SpeechRequest(voice: "v", text: "(whispering) Hi.", pace: 1.25, mode: mode, quality: quality, tone: tone, expressive: expressive)
                    #expect(try request.validated().expressive == expressive, "\(String(describing: tone)) \(mode) \(String(describing: quality))")
                }
            }
        }
        // Invalid requests still fail for their own reason; the switch neither rescues nor breaks them.
        #expect(throws: ChatterError.self) { try SpeechRequest(voice: "v", text: " ", expressive: expressive).validated() }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice: "v", text: "Hi.", tone: "not-a-tone", expressive: expressive).validated() }
    }

    // MARK: The setting for requests

    @Test func theSettingForRequestsIsOnByDefaultAndSurvivesOlderAndRepairedPreferences() throws {
        func decode(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        #expect(Settings().expressionNotesForRequests)
        // Preferences from before expression notes existed gain the default (on).
        #expect(try decode(#"{"port":19423,"allowLAN":false,"studioTone":"cheerful","liveQuality":"balanced"}"#).expressionNotesForRequests)
        // The two switches are independent.
        let studioOff = try decode(#"{"expressionNotesInStudio":false}"#)
        #expect(!studioOff.expressionNotesInStudio && studioOff.expressionNotesForRequests)
        let requestsOff = try decode(#"{"expressionNotesForRequests":false}"#)
        #expect(requestsOff.expressionNotesInStudio && !requestsOff.expressionNotesForRequests)
        // Repairing other fields (an unknown tone, an address off this Mac) must not reset the user's choice.
        let repaired = try decode(#"{"expressionNotesForRequests":false,"studioTone":"nope","ollamaAddress":"http://10.0.0.5:11434"}"#)
        #expect(repaired.studioTone == "natural" && repaired.ollamaAddress == OllamaClient.defaultAddress)
        #expect(!repaired.expressionNotesForRequests)
        // A hand-edited string is corruption, not "off" or "on".
        #expect(throws: DecodingError.self) { try decode(#"{"expressionNotesForRequests":"false"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"expressionNotesForRequests":0}"#) }
        // An explicit null falls back to the default rather than failing.
        #expect(try decode(#"{"expressionNotesForRequests":null}"#).expressionNotesForRequests)
    }

    @Test func theSettingForRequestsSurvivesASaveToDisk() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "settings.json")
        for value in [false, true, false] {
            var settings = Settings(); settings.expressionNotesForRequests = value
            try ChatterPaths.save(settings, to: url)
            #expect(try ChatterPaths.load(Settings.self, from: url).expressionNotesForRequests == value)
            let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(raw["expressionNotesForRequests"] as? Bool == value)
        }
    }

    // MARK: Property: receipts keep every expression field

    /// Seeded property: whatever mix of request fields, Studio switch and job decision a receipt holds, a save
    /// and load through the queue store reproduces it exactly, and saving twice gives the same bytes.
    @Test(arguments: [201, 202, 203, 204] as [UInt64])
    func receiptsRoundTripEveryExpressionDecision(seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobStore(directory: directory)
        let decisions: [Bool?] = [nil, true, false]
        var expected: [String: SpeechJob] = [:]
        for n in 1...60 {
            let request = SpeechRequest(
                voice: "voice-\(Int.random(in: 0..<4, using: &rng))", text: "Line \(n). (excited) Next!",
                pace: [0.5, 1, 1.5, 2].randomElement(using: &rng)!, mode: ["play", "save"].randomElement(using: &rng)!,
                quality: [nil, "responsive", "balanced", "studio"].randomElement(using: &rng)!,
                sampleID: Bool.random(using: &rng) ? nil : "sample-\(n)",
                tone: ([nil] + SpeechTone.allCases.map(\.rawValue)).randomElement(using: &rng)!,
                expressive: decisions.randomElement(using: &rng)!)
            var job = SpeechJob(request: request, voiceName: "V")
            job.sequence = UInt64(n)
            job.respell = [nil, false].randomElement(using: &rng)!
            job.expressive = decisions.randomElement(using: &rng)!
            if Bool.random(using: &rng) {
                job.expressionPlan = ExpressionPlan(notes: [.init(sentence: 0, note: .excited)])
                job.expressionModel = "qwen3.8:27b-mlx"
            }
            if Bool.random(using: &rng) { job.expressionMessage = "Ollama isn't running." }
            try store.save(job)
            expected[job.id] = job
        }
        let loaded = try store.load()
        #expect(loaded.count == expected.count, "seed \(seed)")
        for job in loaded {
            let original = try #require(expected[job.id], "seed \(seed)")
            #expect(job.request.expressive == original.request.expressive, "seed \(seed) \(job.id)")
            #expect(job.expressive == original.expressive, "seed \(seed) \(job.id)")
            #expect(job.respell == original.respell && job.expressionPlan == original.expressionPlan, "seed \(seed) \(job.id)")
            #expect(job.expressionModel == original.expressionModel && job.expressionMessage == original.expressionMessage, "seed \(seed) \(job.id)")
            #expect(job.request.tone == original.request.tone && job.request.quality == original.request.quality, "seed \(seed) \(job.id)")
            #expect(job.request.sampleID == original.request.sampleID && job.request.pace == original.request.pace, "seed \(seed) \(job.id)")
            // Deterministic: re-encoding the loaded job gives the same bytes as the original.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(job) == encoder.encode(original), "seed \(seed) \(job.id)")
        }
    }
}

/// The rule that decides whether a job gets a review.
struct ExpressionReviewWantedTests {
    @Test(arguments: [true, false])
    func requestsFollowTheSetting(forRequests: Bool) {
        #expect(ExpressionReview.isWanted(respell: true, studioChoice: nil, forRequests: forRequests) == forRequests)
    }

    @Test(arguments: [true, false])
    func studioFollowsItsOwnSwitch(forRequests: Bool) {
        #expect(ExpressionReview.isWanted(respell: true, studioChoice: true, forRequests: forRequests))
        #expect(!ExpressionReview.isWanted(respell: true, studioChoice: false, forRequests: forRequests))
    }

    @Test func previewsAreAlwaysSpokenExactly() {
        for choice in [nil, true, false] as [Bool?] {
            for forRequests in [true, false] { #expect(!ExpressionReview.isWanted(respell: false, studioChoice: choice, forRequests: forRequests)) }
        }
    }
}

// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import os
import Testing

/// In-memory receipts and WAVs, standing in for `read_job` / `download_audio` as the Python tests patched them.
final class FakeJobSource: ChatterJobSource {
    let jobs: OSAllocatedUnfairLock<[String: JSONObject]>
    let audio: [String: URL]
    private let downloadCount = OSAllocatedUnfairLock(initialState: 0)
    private let readCount = OSAllocatedUnfairLock(initialState: 0)

    init(jobs: [String: JSONObject], audio: [String: URL]) {
        self.jobs = OSAllocatedUnfairLock(initialState: jobs)
        self.audio = audio
    }

    var downloads: Int { downloadCount.withLock { $0 } }
    var reads: Int { readCount.withLock { $0 } }

    func update(_ id: String, _ change: @Sendable (inout JSONObject) -> Void) {
        jobs.withLock { if var job = $0[id] { change(&job); $0[id] = job } }
    }

    func job(id: String) async throws -> JSONObject {
        readCount.withLock { $0 += 1 }
        guard let job = jobs.withLock({ $0[id] }) else { throw RemotionHandoffError.jobUnreadable(jobID: id) }
        return job
    }

    func downloadAudio(for job: JSONObject, to destination: URL) async throws {
        downloadCount.withLock { $0 += 1 }
        guard let id = job["id"]?.stringValue, let source = audio[id] else { throw RemotionHandoffError.audioDownloadFailed }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// The Python test fixture: a Remotion project and two completed save jobs (44101 and 22050 frames).
struct HandoffFixture {
    let directory: TemporaryDirectory
    let project: URL
    var plan: JSONValue
    let jobIDs: [String]
    let source: FakeJobSource

    init(frames: [Int] = [44101, 22050]) throws {
        directory = try TemporaryDirectory()
        project = directory.url
        try Data("{}".utf8).write(to: project.appending(path: "package.json"))
        var scenes: [JSONValue] = []
        var jobs: [String: JSONObject] = [:]
        var audio: [String: URL] = [:]
        var ids: [String] = []
        for (index, count) in frames.enumerated() {
            let id = UUID().uuidString.uppercased()
            ids.append(id)
            scenes.append(["id": .string("scene-\(index)"), "title": .string("Scene \(index)"), "jobID": .string(id)])
            jobs[id] = [
                "id": .string(id), "state": "completed", "audioURL": .string("/v1/jobs/\(id)/audio"),
                "path": "/remote-host-only/voice.wav", "duration": 12345,
                "request": ["text": "Requested narration.", "voice": "voice-id", "tone": "optimistic", "pace": 1.25, "mode": "save"],
            ]
            let wav = project.appending(path: "fixture-\(index).wav")
            try WAVFixture.write(to: wav, frames: count)
            audio[id] = wav
        }
        plan = ["fps": 30, "scenes": .array(scenes)]
        jobIDs = ids
        source = FakeJobSource(jobs: jobs, audio: audio)
    }

    var stager: RemotionStager { RemotionStager(source: source, pause: { _ in }) }
    var manifestURL: URL { project.appending(path: RemotionStager.manifestFileName) }

    func prepare(_ plan: JSONValue? = nil, waitSeconds: Double = 0) async throws -> JSONValue {
        try await stager.prepare(plan: plan ?? self.plan, project: project.path, waitSeconds: waitSeconds)
    }

    func stagingLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: project.path).filter { $0.hasPrefix(".chatter-stage-") }
    }
}

@Suite("Remotion handoff (prepare_remotion.py port)")
struct RemotionStagerTests {
    // MARK: The four integration tests from scripts/tests/test_remotion_handoff.py

    @Test("Samples determine timing and retries preserve assets")
    func samplesDetermineTimingAndRetriesPreserveAssets() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.directory.remove() }
        let result = try await fixture.prepare()
        let scenes = try #require(result["scenes"]?.arrayValue)
        #expect(scenes.map { $0["audioFrames"] } == [31, 15])
        #expect(scenes.map { $0["from"] } == [0, 37])
        #expect(result["durationInFrames"] == 58)
        for scene in scenes {
            #expect(scene["tone"] == "optimistic")
            #expect(scene["pace"] == 1.25)
            #expect(scene["bitsPerSample"] == 24)
            #expect(!scene.encoded().contains("/remote-host-only"))
            #expect(scene["audioURL"] == nil)
            let src = try #require(scene["src"]?.stringValue)
            let jobID = try #require(scene["jobID"]?.stringValue)
            let staged = try Data(contentsOf: fixture.project.appending(path: "public").appending(path: src))
            #expect(staged == (try Data(contentsOf: #require(fixture.source.audio[jobID]))))
        }
        let second = try await fixture.prepare()
        #expect(result == second)
        let assets = try FileManager.default.contentsOfDirectory(atPath: fixture.project.appending(path: "public/chatter").path)
        #expect(assets.filter { $0.hasSuffix(".wav") }.count == 2)
    }

    @Test("Pending, failed and play jobs preserve the existing manifest")
    func pendingFailedAndPlayJobsPreserveExistingManifest() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.directory.remove() }
        try Data("previous usable manifest".utf8).write(to: fixture.manifestURL)
        let id = fixture.jobIDs[0]
        for state in ["queued", "running", "failed", "cancelled"] {
            fixture.source.update(id) { $0["state"] = .string(state) }
            await #expect {
                try await fixture.prepare()
            } throws: { error in
                switch error as? RemotionHandoffError {
                case .jobStillPending(let scene, let reported), .jobUnusable(let scene, let reported):
                    scene == "scene-0" && reported == state
                default: false
                }
            }
            #expect(try String(contentsOf: fixture.manifestURL, encoding: .utf8) == "previous usable manifest")
        }
        fixture.source.update(id) {
            $0["state"] = "completed"
            if case .object(var request)? = $0["request"] { request["mode"] = "play"; $0["request"] = .object(request) }
        }
        await #expect(throws: RemotionHandoffError.notSaveJob(scene: "scene-0")) { try await fixture.prepare() }
        #expect(fixture.source.downloads == 0)
        #expect(RemotionHandoffError.jobStillPending(scene: "s", state: "queued").description
            == "Scene s: narration is still queued. Poll the existing job or rerun with --wait-seconds; do not submit a duplicate.")
    }

    @Test("Truncated audio never replaces the manifest and leaves no staging directory")
    func truncatedAudioNeverReplacesManifest() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.directory.remove() }
        try Data("previous usable manifest".utf8).write(to: fixture.manifestURL)
        let wav = try #require(fixture.source.audio[fixture.jobIDs[0]])
        try Data(try Data(contentsOf: wav).dropLast(3)).write(to: wav)
        await #expect(throws: RemotionHandoffError.truncatedAudio) { try await fixture.prepare() }
        #expect(RemotionHandoffError.truncatedAudio.description.contains("truncated"))
        #expect(try String(contentsOf: fixture.manifestURL, encoding: .utf8) == "previous usable manifest")
        #expect(try fixture.stagingLeftovers().isEmpty)
    }

    @Test("An invalid route or plan fails before fetching")
    func invalidRouteAndPlanFailBeforeFetching() async throws {
        var fixture = try HandoffFixture()
        defer { fixture.directory.remove() }
        fixture.source.update(fixture.jobIDs[0]) { $0["audioURL"] = "https://unrelated.invalid/audio" }
        await #expect {
            try await fixture.prepare()
        } throws: { error in
            (error as? RemotionHandoffError) == .unexpectedAudioRoute && "\(error)".contains("route")
        }
        #expect(fixture.source.downloads == 0)
        guard case .object(var plan) = fixture.plan, case .array(var scenes)? = plan["scenes"] else { return }
        scenes.append(scenes[0])
        plan["scenes"] = .array(scenes)
        fixture.plan = .object(plan)
        #expect(throws: RemotionHandoffError.invalidPlan("Scene IDs must be nonempty, unique strings of at most 128 characters.")) {
            try RemotionHandoffPlan(validating: fixture.plan)
        }
        for fps: JSONValue in [true, 0, 29.97, 121] {
            plan["fps"] = fps
            #expect(throws: RemotionHandoffError.invalidPlan("fps must be an integer from 1 to 120.")) {
                try RemotionHandoffPlan(validating: .object(plan))
            }
        }
    }

    // MARK: Additional coverage

    @Test("Manifest structure, key order, formatting and content-addressed names")
    func manifestShape() async throws {
        let fixture = try HandoffFixture(frames: [44100])
        defer { fixture.directory.remove() }
        fixture.source.update(fixture.jobIDs[0]) {
            $0["request"] = ["text": "Café — “quoted”", "voice": "v", "pace": 1, "mode": "save"]
        }
        let manifest = try await fixture.prepare()
        #expect(manifest.objectValue?.keys == ["schemaVersion", "fps", "durationInFrames", "scenes"])
        let scene = try #require(manifest["scenes"]?[0])
        #expect(scene.objectValue?.keys == [
            "id", "title", "jobID", "text", "voice", "tone", "pace", "src", "sha256", "from", "durationInFrames", "tailFrames",
            "durationSeconds", "audioFrames", "sampleRate", "channels", "bitsPerSample",
        ])
        #expect(scene["tone"] == "natural")
        #expect(scene["pace"] == .int(1))
        #expect(scene["durationSeconds"] == .double(1.0) && scene["tailFrames"] == 6 && scene["durationInFrames"] == 36)
        let digest = try #require(scene["sha256"]?.stringValue)
        #expect(scene["src"] == .string("chatter/\(fixture.jobIDs[0].lowercased())-\(digest.prefix(16)).wav"))
        let text = try String(contentsOf: fixture.manifestURL, encoding: .utf8)
        #expect(text == manifest.encoded(.indented, asciiOnly: false) + "\n")
        #expect(text.contains("Café — “quoted”") && text.hasPrefix("{\n  \"schemaVersion\": 1,\n  \"fps\": 30,"))
    }

    @Test("A corrupted asset with the expected name is replaced; a matching one is reused")
    func corruptedAssetReplaced() async throws {
        let fixture = try HandoffFixture(frames: [4410])
        defer { fixture.directory.remove() }
        let first = try await fixture.prepare()
        let asset = fixture.project.appending(path: "public").appending(path: try #require(first["scenes"]?[0]?["src"]?.stringValue))
        try Data("corrupt".utf8).write(to: asset)
        _ = try await fixture.prepare()
        #expect(try SHA256Digest.file(at: asset) == first["scenes"]?[0]?["sha256"]?.stringValue)
    }

    @Test("--wait-seconds polls a queued job until it completes")
    func waitsForQueuedJob() async throws {
        let fixture = try HandoffFixture(frames: [4410])
        defer { fixture.directory.remove() }
        let id = fixture.jobIDs[0]
        fixture.source.update(id) { $0["state"] = "queued" }
        let pauses = OSAllocatedUnfairLock(initialState: [Double]())
        let source = fixture.source
        let stager = RemotionStager(source: source, pause: { seconds in
            pauses.withLock { $0.append(seconds) }
            source.update(id) { $0["state"] = "completed" }
        })
        let manifest = try await stager.prepare(plan: fixture.plan, project: fixture.project.path, waitSeconds: 30)
        #expect(manifest["scenes"]?.arrayValue?.count == 1)
        #expect(pauses.withLock { $0 }.count == 1 && (pauses.withLock { $0 }.first ?? 0) <= RemotionStager.maximumPollInterval)
    }

    @Test("Project and wait-seconds validation")
    func projectAndWaitValidation() async throws {
        let fixture = try HandoffFixture(frames: [4410])
        defer { fixture.directory.remove() }
        await #expect(throws: RemotionHandoffError.projectMissing) {
            try await fixture.stager.prepare(plan: fixture.plan, project: fixture.project.appending(path: "public").path)
        }
        for wait in [-1, Double.nan, .infinity] {
            await #expect(throws: RemotionHandoffError.invalidWaitSeconds) { try await fixture.prepare(waitSeconds: wait) }
        }
        #expect(fixture.source.reads == 0)
    }

    @Test(
        "Plan validation messages",
        arguments: [
            ("[]", "The handoff must be a JSON object."),
            (#"{"scenes":[]}"#, "At least one scene is required."),
            (#"{"scenes":{}}"#, "At least one scene is required."),
            (#"{"tailSeconds":5.5,"scenes":[1]}"#, "tailSeconds must be between 0 and 5."),
            (#"{"tailSeconds":true,"scenes":[1]}"#, "tailSeconds must be between 0 and 5."),
            (#"{"fps":null,"scenes":[1]}"#, "fps must be an integer from 1 to 120."),
            (#"{"scenes":[1]}"#, "Each scene must be an object."),
            (#"{"scenes":[{"id":"  "}]}"#, "Scene IDs must be nonempty, unique strings of at most 128 characters."),
            (#"{"scenes":[{"id":7}]}"#, "Scene IDs must be nonempty, unique strings of at most 128 characters."),
            (#"{"scenes":[{"id":"a","title":3}]}"#, "Scene titles must be strings."),
            (#"{"scenes":[{"id":"a"}]}"#, "Scene a needs a Chatter jobID."),
            (#"{"scenes":[{"id":"a","jobID":"not-a-uuid"}]}"#, "Scene a needs a Chatter jobID."),
            (#"{"scenes":[{"id":"a","jobID":12}]}"#, "Scene a needs a Chatter jobID."),
        ])
    func planValidation(plan: String, message: String) throws {
        #expect(throws: RemotionHandoffError.invalidPlan(message)) { try RemotionHandoffPlan(validating: JSONValue.parse(plan)) }
    }

    @Test("Scene IDs up to 128 characters, tail frames round up, and Python UUID spellings are accepted")
    func planAcceptance() throws {
        let long = String(repeating: "é", count: 128)
        let plan = try RemotionHandoffPlan(validating: [
            "fps": 30, "tailSeconds": 0.21,
            "scenes": [
                ["id": .string(long), "jobID": "{12345678-1234-5678-1234-567812345678}"],
                ["id": "b", "title": "B", "jobID": "urn:uuid:12345678123456781234567812345678"],
            ],
        ])
        #expect(plan.tailFrames == 7 && plan.fps == 30)
        #expect(plan.scenes.map(\.title) == [long, "B"])
        #expect(CanonicalUUID("URN:UUID:12345678123456781234567812345678") == nil)
        #expect(CanonicalUUID("ABCDEF00-1234-5678-1234-567812345678")?.description == "abcdef00-1234-5678-1234-567812345678")
        #expect(throws: RemotionHandoffError.self) {
            try RemotionHandoffPlan(validating: ["scenes": [["id": .string(long + "x"), "jobID": "12345678123456781234567812345678"]]])
        }
        #expect(try RemotionHandoffPlan(validating: ["tailSeconds": 0, "scenes": [["id": "a", "jobID": "12345678123456781234567812345678"]]])
            .tailFrames == 0)
    }

    @Test("A job whose ID differs from its receipt is rejected")
    func mismatchedJobID() async throws {
        let fixture = try HandoffFixture(frames: [4410])
        defer { fixture.directory.remove() }
        fixture.source.update(fixture.jobIDs[0]) { $0["id"] = .string(UUID().uuidString) }
        await #expect(throws: RemotionHandoffError.notSaveJob(scene: "scene-0")) { try await fixture.prepare() }
    }

    // MARK: Against a live (mock) Chatter over HTTP

    @Test("chatter-tools remotion stages real downloads from a Chatter instance")
    func endToEndThroughCLI() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let project = try TemporaryDirectory()
        defer { project.remove() }
        try Data("{}".utf8).write(to: project.file("package.json"))
        let api = try chatter.settings.makeClient()
        var scenes: [JSONValue] = []
        for index in 0..<2 {
            let job = try await api.json("/v1/speech", body: [
                "voice": "voice-Ryan", "text": .string("Scene \(index)."), "mode": "save", "tone": "optimistic",
                "requestID": .string("remotion-\(index)"),
            ])
            _ = try await api.waitForJob(try #require(job["id"]?.stringValue))
            scenes.append(["id": .string("s\(index)"), "jobID": job["id"] ?? .null])
        }
        let handoff = project.file("chatter-handoff.json")
        try Data(JSONValue.object(["fps": 24, "tailSeconds": 0, "scenes": .array(scenes)]).encoded().utf8).write(to: handoff)
        let output = CapturedOutput(), errors = CapturedOutput()
        let status = await ChatterToolsCommand.run(
            ["remotion", handoff.path, "--proj", project.url.path, "--wait-seconds=5"],
            environment: chatter.bridgeEnvironment, output: output, errors: errors)
        #expect(status == 0, "\(errors.text)")
        let summary = try JSONValue.parse(output.text)
        #expect(summary["scenes"] == 2 && summary["fps"] == 24 && summary["durationInFrames"] == 24)
        #expect(summary["manifest"] == .string(RemotionStager.manifestURL(project: project.url.path).path))
        let manifest = try JSONValue.parse(Data(contentsOf: project.file(RemotionStager.manifestFileName)))
        #expect(manifest["scenes"]?[0]?["tone"] == "optimistic" && manifest["scenes"]?[0]?["channels"] == 1)
        #expect(!output.text.contains(chatter.token) && !errors.text.contains(chatter.token))
        let audioRequests = chatter.server.requests.filter { $0.path.hasSuffix("/audio") }
        #expect(audioRequests.count == 2 && audioRequests.allSatisfy { $0.headers["authorization"] == "Bearer " + chatter.token })
    }

    @Test("Download failures and missing receipts report the helper's messages over HTTP")
    func liveFailures() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let fixture = try HandoffFixture(frames: [4410])
        defer { fixture.directory.remove() }
        let source = ChatterServiceJobSource(environment: chatter.bridgeEnvironment, home: chatter.support.url)
        let unknown = UUID().uuidString
        await #expect(throws: RemotionHandoffError.jobUnreadable(jobID: unknown)) { try await source.job(id: unknown) }
        let destination = fixture.directory.file("download.wav")
        await #expect(throws: RemotionHandoffError.audioDownloadFailed) {
            try await source.downloadAudio(for: ["audioURL": .string("/v1/jobs/\(unknown)/audio")], to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let stager = RemotionStager(source: source)
        await #expect(throws: RemotionHandoffError.jobUnreadable(jobID: fixture.jobIDs[0])) {
            try await stager.prepare(plan: fixture.plan, project: fixture.project.path)
        }
    }
}

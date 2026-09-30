// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// `verify api` (formerly `verify-api.py`): exercises the installed app's authentication, origin and
/// protocol checks, input validation, FIFO order, idempotency, cancellation, WAV retrieval, MCP,
/// and the portable stdio bridge. Never prints the bearer token.
public struct APIVerification: Sendable {
    public static let defaultReport = ".runtime/api-validation.json"
    static let jobSummaryKeys = ["id", "state", "sequence", "firstAudioSeconds", "elapsedSeconds", "duration", "message", "path"]

    public let settings: VerificationSettings
    public let report: URL

    public init(settings: VerificationSettings, report: URL = URL(filePath: defaultReport)) {
        self.settings = settings
        self.report = report
    }

    public func run(output: any TextOutput) async throws {
        let api = try settings.makeClient()
        let unauthorized = try await api.call("/v1/health", headers: ["Authorization": "Bearer wrong"]).status
        try verify(unauthorized == 401, "GET /v1/health with a wrong token returned HTTP \(unauthorized), expected 401.")
        let foreign = try await api.call("/v1/health", headers: ["Origin": "https://example.com"]).status
        try verify(foreign == 403, "GET /v1/health from a foreign Origin returned HTTP \(foreign), expected 403.")
        let badProtocol = try await api.call("/mcp", body: [:], method: "POST", headers: ["MCP-Protocol-Version": "bad"]).status
        try verify(badProtocol == 400, "POST /mcp with a bad MCP-Protocol-Version returned HTTP \(badProtocol), expected 400.")
        let health = try await api.json("/v1/health")
        try output.line("health " + health.pythonRepr)
        let voice = try await firstVoiceID(api)
        for pace: JSONValue in [true, 0] {
            let status = try await api.call("/v1/speech", body: ["voice": voice, "text": "test", "pace": pace]).status
            try verify(status == 400, "Speech with pace \(pace.encoded()) returned HTTP \(status), expected 400.")
        }
        let prefix = "validation-\(wallClockNanoseconds())"
        let requests: [JSONValue] = [
            ["voice": voice, "text": "This is a studio quality recording created locally by Chatter.", "pace": 1.25,
             "mode": "save", "requestID": .string(prefix + "-save")],
            ["voice": voice, "text": "The next request follows the first, in order.", "pace": 1, "mode": "play",
             "quality": "responsive", "requestID": .string(prefix + "-play")],
            ["voice": voice, "text": "This cancelled request should never speak.", "mode": "play",
             "requestID": .string(prefix + "-cancel")],
        ]
        var accepted: [JSONValue] = []
        for request in requests { accepted.append(try await api.json("/v1/speech", body: request)) }
        let sequences = try accepted.map { try $0.required("sequence", "receipt").numberValue ?? .nan }
        try verify(sequences == sequences.sorted(), "Receipts are not in FIFO sequence order: \(sequences).")
        let ids = try accepted.map { try $0.requiredString("id", "receipt") }
        let again = try await api.json("/v1/speech", body: requests[0])
        try verify(again["id"] == .string(ids[0]), "Retrying a requestID did not return the original job.")
        let cancelled = try await api.json("/v1/jobs/" + ids[2], method: "DELETE")
        try verify(cancelled["state"] == "cancelled", "DELETE did not cancel the job: \(cancelled.encoded()).")
        var jobs: [JSONValue] = []
        for id in ids { jobs.append(try await api.waitForJob(id)) }
        for job in jobs { try output.line("job " + job.selecting(Self.jobSummaryKeys).encoded()) }
        let states = jobs.map { $0["state"]?.stringValue ?? "" }
        try verify(states == ["completed", "completed", "cancelled"], "Unexpected final job states \(states).")

        let audio = try await api.call(try jobs[0].requiredString("audioURL", "job"))
        try verify(audio.status == 200 && audio.json == nil && audio.data.prefix(4) == Data("RIFF".utf8),
            "The saved job's audio route did not return a WAV (HTTP \(audio.status)).")
        let path = try jobs[0].requiredString("path", "job")
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        try verify(audio.data.count == size, "Downloaded WAV is \(audio.data.count) bytes; \(path) is \(size ?? -1).")

        let initialize = try await api.json("/mcp", body: VerificationSettings.rpc("initialize", [
            "protocolVersion": .string(ChatterMCPForwarder.protocolVersion), "capabilities": [:],
            "clientInfo": ["name": "validation", "version": "1"],
        ]))
        try verify(initialize["result"]?["protocolVersion"] == .string(ChatterMCPForwarder.protocolVersion),
            "MCP initialize negotiated \(initialize.encoded()).")
        let tools = try await api.json("/mcp", body: VerificationSettings.rpc("tools/list"))
        try verify(tools["result"]?["tools"]?.arrayValue?.count == 8, "MCP tools/list did not list eight tools.")

        try verifyBridge()
        try writeReport(JSONValue.array(jobs).encoded(.indented), to: report)
        try output.line(
            "PASS authentication, origin, protocol, input validation, FIFO, idempotency, cancellation, WAV retrieval, MCP, portable stdio bridge")
    }

    /// Runs one `chatter_status` call through the `chatter-mcp` binary against the same instance.
    private func verifyBridge() throws {
        let call = VerificationSettings.rpc("tools/call", ["name": "chatter_status", "arguments": [:]])
        let result = try ChildProcess.run(
            settings.bridgeExecutable, input: Data((call.encoded() + "\n").utf8), environment: settings.bridgeEnvironment)
        try verify(result.status == 0, "chatter-mcp exited with status \(result.status).")
        let reply = try? JSONValue.parse(result.standardOutput)
        try verify(reply?["result"]?["isError"] == .bool(false), "chatter-mcp did not relay a successful chatter_status.")
    }

    private func firstVoiceID(_ api: ChatterAPIClient) async throws -> JSONValue {
        guard let voice = try await api.json("/v1/voices")["voices"]?[0]?["id"] else {
            throw VerificationFailure("Chatter has no saved voices.")
        }
        return voice
    }
}

/// `verify tones` (formerly `verify-tones.py`): tone catalog, MCP schema/discovery, validation,
/// idempotency, multi-reference voices and three saved multi-passage WAVs.
public struct ToneVerification: Sendable {
    public static let defaultReport = ".runtime/tone-api-results.json"
    /// The 33 tone IDs, in catalog order.
    public static let expectedTones = """
        natural cheerful optimistic excited confident grateful proud warm friendly calm empathetic reassuring \
        apologetic stern serious determined professional curious reflective nostalgic sad bored angry frustrated \
        nervous worried scared surprised sarcastic whisper soft urgent shouting
        """.split(separator: " ").map(String.init)
    static let baseText = "We have a clear plan for tomorrow. Take your time, check the details, and meet me at the garden gate."
    static let longText = baseText
        + " Bring a notebook and a bottle of water. We will walk along the river, stop at the old bridge, and talk about the projects we want to finish this week. When we reach the lake, we can find a quiet place to sit. There is plenty of time to think carefully and decide what comes next. Before heading home, we will check the map together and choose a different path through the trees."

    public let settings: VerificationSettings
    public let report: URL

    public init(settings: VerificationSettings, report: URL = URL(filePath: defaultReport)) {
        self.settings = settings
        self.report = report
    }

    public func run(output: any TextOutput) async throws {
        let api = try settings.makeClient()
        let expected = JSONValue.array(Self.expectedTones.map(JSONValue.string))
        let catalog = try await api.json("/v1/tones").required("tones")
        try verify(JSONValue.array(catalog.arrayValue?.map { $0["id"] ?? .null } ?? []) == expected,
            "GET /v1/tones does not list the expected 33 tones in order.")
        let voices = try await api.json("/v1/voices").requiredArray("voices")
        let wanted = settings.environment["CHATTER_TEST_VOICE"] ?? "Ryan"
        guard let voice = voices.first(where: { $0["name"] == .string(wanted) })
            ?? voices.first(where: { $0["isDefault"]?.isTruthy ?? false })
        else { throw VerificationFailure("No voice named \(wanted) and no default voice.") }
        let voiceID = try voice.required("id", "voice")
        for invalid: JSONValue in ["unknown", "", true, 42, [:], .null] {
            let status = try await api.call("/v1/speech", body: ["voice": voiceID, "text": "Validation", "tone": invalid]).status
            try verify(status == 400, "Speech with tone \(invalid.encoded()) returned HTTP \(status), expected 400.")
        }
        let tools = try await api.json("/mcp", body: VerificationSettings.rpc("tools/list"))["result"]?["tools"]?.arrayValue ?? []
        let speech = tools.first { $0["name"] == "chatter_speak" }
        try verify(speech?["inputSchema"]?["properties"]?["tone"]?["enum"] == expected,
            "chatter_speak's tone enum does not match the catalog.")
        let discovered = try await api.json("/mcp", body: VerificationSettings.rpc(
            "tools/call", ["name": "chatter_tones", "arguments": [:]]))
        try verify(discovered["result"]?["structuredContent"]?["tones"] == catalog,
            "chatter_tones does not match GET /v1/tones.")

        var jobs: [JSONValue] = []
        let references = voice["referenceSampleIDs"]?.arrayValue?.count
        for tone in ["cheerful", "optimistic", "stern"] {
            let text = tone == "optimistic" ? Self.longText : Self.baseText
            var request: JSONObject = [
                "voice": voiceID, "text": .string(text), "mode": "save", "pace": 1, "tone": .string(tone),
                "requestID": .string("tone-verification-\(tone)-\(wallClockNanoseconds())"),
            ]
            let reply = try await api.call("/v1/speech", body: .object(request))
            let job = reply.json ?? .null
            try verify(reply.status == 202 && job["request"]?["tone"] == .string(tone) && job["request"]?["text"] == .string(text),
                "Speech for tone \(tone) was not accepted as requested: \(job.encoded()).")
            try verify(job["referenceSampleIDs"]?.arrayValue?.count == references,
                "Job for tone \(tone) does not use every reference sample of the voice.")
            let retry = try await api.json("/v1/speech", body: .object(request))
            try verify(retry["id"] == job["id"], "Retrying the \(tone) request did not return the original job.")
            request["tone"] = "calm"
            let mismatch = try await api.call("/v1/speech", body: .object(request)).status
            try verify(mismatch == 400, "Reusing a requestID with a different tone returned HTTP \(mismatch), expected 400.")
            try verify(job["toneCue"] == nil, "Job for tone \(tone) exposes a toneCue.")
            jobs.append(job)
        }
        var results: [JSONValue] = []
        for job in jobs {
            let result = try await api.waitForJob(try job.requiredString("id", "job"))
            try verify(result["state"] == "completed", "Tone job did not complete: \(result.encoded()).")
            results.append(result)
            guard case .object(var summary) = result.selecting(["id", "sequence", "state", "duration", "elapsedSeconds", "path"])
            else { continue }
            summary["tone"] = try result.required("request", "job").required("tone", "request")
            try output.line(JSONValue.object(summary).encoded())
        }
        try writeReport(JSONValue.array(results).encoded(.indented), to: report)
        try output.line("PASS tone catalog, MCP schema/discovery, validation, idempotency, multi-reference voice, multi-passage WAV generation")
    }
}

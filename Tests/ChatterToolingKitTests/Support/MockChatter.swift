// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import os

/// A stateful stand-in for the Chatter app: REST routes, `/mcp`, durable `Queue/` receipts and saved WAVs.
/// Jobs complete when polled unless the engine is suspended.
final class MockChatter: Sendable {
    struct Behavior: Sendable {
        var enforceAuthentication = true
        var queueCapacity = 1000
        var initialQueueDepth = 0
        /// Accept fewer jobs than the advertised capacity (to fail the stress test part-way).
        var acceptanceLimit: Int?
        /// Frames in every saved WAV (mono 44.1 kHz 24-bit).
        var savedFrames = 22050
        var stalePluginSchema = false
    }

    private struct State {
        var jobs: [String: JSONObject] = [:]
        var byRequestID: [String: (id: String, request: JSONValue)] = [:]
        var sequence = 41
        var engineSuspended = false
    }

    static let voices: JSONValue = [
        ["id": "voice-Ryan", "name": "Ryan", "isDefault": true, "supportsInstructions": false, "referenceSampleIDs": ["s1", "s2", "s3"]],
        ["id": "voice-ada", "name": "Ada", "isDefault": false, "supportsInstructions": true, "referenceSampleIDs": ["a1"]],
    ]
    static let tones = JSONValue.array(ToneVerification.expectedTones.map { ["id": .string($0), "name": .string($0.capitalized)] })

    let token = "secret-token-\(UUID().uuidString)"
    let support: TemporaryDirectory
    let behavior: Behavior
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let serverBox = OSAllocatedUnfairLock<MockHTTPServer?>(initialState: nil)

    var server: MockHTTPServer { serverBox.withLock { $0! } }
    var baseURL: String { server.baseURL }
    var tokenFile: URL { support.file("api-token") }
    var queueDirectory: URL { support.file("Queue") }

    static func start(_ behavior: Behavior = Behavior()) async throws -> MockChatter {
        let chatter = try MockChatter(behavior: behavior)
        let server = try await MockHTTPServer.start { [chatter] request in chatter.respond(to: request) }
        chatter.serverBox.withLock { $0 = server }
        return chatter
    }

    private init(behavior: Behavior) throws {
        self.behavior = behavior
        support = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: support.file("Queue"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.file("Output"), withIntermediateDirectories: true)
        try Data((token + "\n").utf8).write(to: support.file("api-token"))
    }

    func stop() {
        server.stop()
        support.remove()
    }

    /// Environment that points `chatter-mcp` / the stager at this mock (and nowhere else).
    var bridgeEnvironment: [String: String] {
        ["CHATTER_URL": baseURL, "CHATTER_TOKEN_FILE": tokenFile.path, "HOME": support.url.path, "PATH": "/usr/bin:/bin"]
    }

    var settings: VerificationSettings {
        var settings = VerificationSettings(
            baseURL: baseURL, supportDirectory: support.url, bridgeExecutable: BuiltProducts.bridge, environment: bridgeEnvironment)
        settings.pollInterval = 0.01
        return settings
    }

    var engineSuspended: Bool {
        get { state.withLock { $0.engineSuspended } }
        set { state.withLock { $0.engineSuspended = newValue } }
    }

    func job(_ id: String) -> JSONObject? { state.withLock { $0.jobs[id] } }

    var jobs: [JSONObject] { state.withLock { Array($0.jobs.values) } }

    /// Replaces fields of a job (e.g. to force a state for the stager tests).
    func update(_ id: String, _ change: @Sendable (inout JSONObject) -> Void) {
        state.withLock { if var job = $0.jobs[id] { change(&job); $0.jobs[id] = job } }
    }

    // MARK: Routing

    private func respond(to request: MockRequest) -> MockResponse {
        if behavior.enforceAuthentication, request.headers["authorization"] != "Bearer " + token {
            return .json(["error": "unauthorized"], status: 401)
        }
        if request.headers["origin"] != nil { return .json(["error": "forbidden origin"], status: 403) }
        let path = request.path
        switch (request.method, path) {
        case ("POST", "/mcp"): return mcp(request)
        case ("GET", "/v1/health"):
            return .json([
                "status": "ok", "engine": "ready", "queueDepth": .int(queueDepth()), "queueCapacity": .int(behavior.queueCapacity),
            ])
        case ("GET", "/v1/voices"): return .json(["voices": Self.voices])
        case ("GET", "/v1/tones"): return .json(["tones": Self.tones])
        case ("POST", "/v1/speech"):
            let (status, body) = speak(request.json ?? .null)
            return .json(body, status: status)
        default: break
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "jobs" else { return .json(["error": "not found"], status: 404) }
        let id = parts[2]
        if parts.count == 4, parts[3] == "audio", request.method == "GET" {
            guard let job = poll(id), job["state"] == "completed", let path = job["path"]?.stringValue,
                let data = FileManager.default.contents(atPath: path)
            else { return .json(["error": "no audio"], status: 404) }
            return MockResponse(status: 200, headers: ["Content-Type": "audio/wav"], body: data)
        }
        switch request.method {
        case "GET": return poll(id).map { .json(.object($0)) } ?? .json(["error": "unknown job"], status: 404)
        case "DELETE": return cancel(id).map { .json(.object($0)) } ?? .json(["error": "unknown job"], status: 404)
        default: return .json(["error": "method"], status: 405)
        }
    }

    private func queueDepth() -> Int {
        behavior.initialQueueDepth + state.withLock { $0.jobs.values.filter { $0["state"] == "queued" }.count }
    }

    // MARK: Speech

    private func speak(_ body: JSONValue) -> (Int, JSONValue) {
        guard case .object(let object) = body else { return (400, ["error": "body must be an object"]) }
        guard let voice = Self.voices.arrayValue?.first(where: { $0["id"] == object["voice"] }) else {
            return (400, ["error": "unknown voice"])
        }
        guard let text = object["text"]?.stringValue, !text.isEmpty else { return (400, ["error": "text"]) }
        let pace = object["pace"] ?? 1
        guard case let value? = pace.numberValue, pace.boolValue == nil, value > 0 else { return (400, ["error": "pace"]) }
        if let tone = object["tone"] {
            guard let name = tone.stringValue, ToneVerification.expectedTones.contains(name) else { return (400, ["error": "tone"]) }
        }
        let mode = object["mode"] ?? "play"
        guard mode == "play" || mode == "save" else { return (400, ["error": "mode"]) }
        return state.withLock { state -> (Int, JSONValue) in
            let requestID = object["requestID"]?.stringValue
            if let requestID, let existing = state.byRequestID[requestID] {
                guard existing.request == body, let job = state.jobs[existing.id] else { return (400, ["error": "requestID reused"]) }
                return (202, .object(job))
            }
            let queued = state.jobs.values.filter { $0["state"] == "queued" }.count + behavior.initialQueueDepth
            guard queued < behavior.acceptanceLimit ?? behavior.queueCapacity else { return (429, ["error": "queue full"]) }
            state.sequence += 1
            let id = UUID().uuidString
            var request: JSONObject = ["text": .string(text), "voice": object["voice"] ?? .null, "pace": pace, "mode": mode]
            if let tone = object["tone"] { request["tone"] = tone }
            if let quality = object["quality"] { request["quality"] = quality }
            for key in ["language", "instruction"] { if let value = object[key] { request[key] = value } }
            let job: JSONObject = [
                "id": .string(id), "sequence": .int(state.sequence), "state": "queued", "request": .object(request),
                "requestID": requestID.map(JSONValue.string) ?? .null,
                "referenceSampleIDs": voice["referenceSampleIDs"] ?? [], "audioURL": .string("/v1/jobs/\(id)/audio"),
            ]
            state.jobs[id] = job
            if let requestID { state.byRequestID[requestID] = (id, body) }
            let receipt: JSONValue = ["id": .string(id), "sequence": .int(state.sequence), "requestID": job["requestID"] ?? .null]
            try? Data(receipt.encoded().utf8).write(to: queueDirectory.appending(path: id + ".json"))
            return (202, .object(job))
        }
    }

    /// Returns the job, completing it first when the engine is running.
    private func poll(_ id: String) -> JSONObject? {
        let output = support.file("Output/\(id).wav")
        let frames = Int(Double(behavior.savedFrames) * 24000 / 44100)
        return state.withLock { state -> JSONObject? in
            guard var job = state.jobs[id] else { return nil }
            if job["state"] == "queued", !state.engineSuspended {
                if job["request"]?["mode"] == "save" {
                    try? WAVFixture.write(to: output, frames: frames, sampleRate: 24000)
                    job["path"] = .string(output.path)
                }
                job["state"] = "completed"
                job["duration"] = .double(Double(frames) / 24000)
                job["elapsedSeconds"] = 0.25
                job["firstAudioSeconds"] = 0.1
                state.jobs[id] = job
            }
            return job
        }
    }

    private func cancel(_ id: String) -> JSONObject? {
        state.withLock { state -> JSONObject? in
            guard var job = state.jobs[id] else { return nil }
            if job["state"] == "queued" { job["state"] = "cancelled" }
            state.jobs[id] = job
            return job
        }
    }

    // MARK: MCP

    private func mcp(_ request: MockRequest) -> MockResponse {
        if let version = request.headers["mcp-protocol-version"], version != ChatterMCPForwarder.protocolVersion {
            return .json(["error": "unsupported protocol version"], status: 400)
        }
        guard let message = request.json, case .object(let object) = message else { return .json(["error": "parse"], status: 400) }
        guard let id = object["id"] else { return .empty(202) }
        let params = object["params"] ?? [:]
        let result: JSONValue
        switch object["method"]?.stringValue ?? "" {
        case "initialize":
            result = [
                "protocolVersion": .string(ChatterMCPForwarder.protocolVersion), "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Chatter", "version": "test"],
            ]
        case "tools/list":
            result = ["tools": .array(PluginVerification.toolNames.sorted().map { name in
                var properties: JSONObject = [:]
                if name == "chatter_speak" {
                    properties["tone"] = ["type": "string", "enum": .array(ToneVerification.expectedTones.map(JSONValue.string))]
                    if !behavior.stalePluginSchema {
                        for key in ["language", "instruction", "quality", "sampleID"] { properties[key] = ["type": "string"] }
                    }
                } else if name == "chatter_dialogue" {
                    for key in ["cast", "turns", "mode", "quality", "pace", "gapSeconds"] { properties[key] = [:] }
                }
                return ["name": .string(name), "inputSchema": ["type": "object", "properties": .object(properties)]]
            })]
        case "tools/call":
            result = tool(params["name"]?.stringValue ?? "", params["arguments"] ?? [:])
        default:
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return .json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func tool(_ name: String, _ arguments: JSONValue) -> JSONValue {
        func success(_ content: JSONValue) -> JSONValue {
            ["content": [["type": "text", "text": .string(content.encoded())]], "structuredContent": content, "isError": false]
        }
        let failure: JSONValue = ["content": [["type": "text", "text": "failed"]], "isError": true]
        switch name {
        case "chatter_status": return success(["engine": "ready", "queueDepth": .int(queueDepth())])
        case "chatter_voices": return success(["voices": Self.voices])
        case "chatter_capabilities": return success(["engine": "Qwen3-TTS", "sampleRate": 24000, "wavBits": 24])
        case "chatter_tones": return success(["tones": Self.tones])
        case "chatter_speak":
            let (status, body) = speak(arguments)
            return status == 202 ? success(body) : failure
        case "chatter_job", "chatter_cancel":
            let id = arguments["id"]?.stringValue ?? ""
            let job = name == "chatter_job" ? poll(id) : cancel(id)
            return job.map { success(.object($0)) } ?? failure
        default: return failure
        }
    }
}

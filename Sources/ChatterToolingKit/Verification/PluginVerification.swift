// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// `verify plugin` (formerly `verify-plugin.py`): drives the MCP stdio transport (`chatter-mcp`, or
/// whatever a Codex CLI resolves for `chatter`), checks all eight tools and 33 tones, and saves an
/// capability-appropriate narration WAV for an editor handoff. Never prints credentials.
public struct PluginVerification: Sendable {
    public static let defaultReport = ".runtime/video-narration-check.json"
    public static let defaultVoice = "Ryan"
    static let toolNames: Set<String> = [
        "chatter_capabilities", "chatter_dialogue", "chatter_status", "chatter_voices", "chatter_tones", "chatter_speak", "chatter_job", "chatter_cancel",
    ]
    static let narration = "Every good story begins with an idea. Let us bring this one to life, one scene at a time."

    /// How the MCP transport is launched.
    public enum Transport: Sendable {
        /// Run this executable (normally `chatter-mcp`) with the inherited environment.
        case executable(String)
        /// Ask a Codex CLI (`<cli> mcp get chatter --json`) for the installed transport.
        case codexCLI(String)
    }

    public let settings: VerificationSettings
    public let transport: Transport
    public let voice: String
    public let report: URL
    public var responseTimeout: TimeInterval = 30
    public var jobDeadline: Double = 180
    public var pollInterval: Double = 1

    public init(settings: VerificationSettings, transport: Transport, voice: String = defaultVoice, report: URL = URL(filePath: defaultReport)) {
        self.settings = settings
        self.transport = transport
        self.voice = voice
        self.report = report
    }

    public func run(output: any TextOutput) async throws {
        let session = try launch()
        defer { session.close() }
        var serial = 0
        func send(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            serial += 1
            try session.send(JSONValue.object(["jsonrpc": "2.0", "id": .int(serial), "method": .string(method), "params": params]).encoded())
            guard let line = await session.nextLineAsync(timeout: responseTimeout) else {
                throw VerificationFailure("Installed Chatter MCP transport did not respond")
            }
            let response = try JSONValue.parse(line)
            try verify(response["id"] == .int(serial) && response["error"] == nil, response.encoded())
            return try response.required("result")
        }
        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
            let result = try await send("tools/call", ["name": .string(name), "arguments": arguments])
            try verify(!(result["isError"]?.isTruthy ?? false), result.encoded())
            return try result.required("structuredContent", name)
        }

        let initialized = try await send("initialize", [
            "protocolVersion": .string(ChatterMCPForwarder.protocolVersion), "capabilities": [:],
            "clientInfo": ["name": "chatter-plugin-verifier", "version": "1"],
        ])
        try session.send(JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).encoded())
        let toolset = try await send("tools/list", [:]).requiredArray("tools")
        try verify(Set(toolset.compactMap { $0["name"]?.stringValue }) == Self.toolNames && toolset.count == Self.toolNames.count,
            "The transport does not list exactly the eight Chatter tools.")
        try verify(try await call("chatter_status")["engine"] == "ready", "The Chatter engine is not ready.")
        let capabilities = try await call("chatter_capabilities")
        try verify(capabilities["engine"] == "Qwen3-TTS" && capabilities["sampleRate"] == 24000 && capabilities["wavBits"] == 24,
            "Expected the Qwen3-TTS capability catalog and native 24 kHz/24-bit output.")
        let speechProperties = toolset.first { $0["name"] == "chatter_speak" }?["inputSchema"]?["properties"]?.objectValue
        let dialogueProperties = toolset.first { $0["name"] == "chatter_dialogue" }?["inputSchema"]?["properties"]?.objectValue
        try verify(["language", "instruction", "quality", "sampleID"].allSatisfy { speechProperties?[$0] != nil }
            && ["cast", "turns", "mode", "quality", "pace", "gapSeconds"].allSatisfy { dialogueProperties?[$0] != nil },
            "The transport has stale speech or dialogue schemas; refresh the plugin in a new chat.")
        let tones = try await call("chatter_tones").requiredArray("tones")
        let toneIDs = tones.map { $0["id"]?.stringValue ?? "" }
        let speechTool = toolset.first { $0["name"] == "chatter_speak" }
        try verify(speechTool?["inputSchema"]?["properties"]?["tone"]?["enum"] == .array(toneIDs.map(JSONValue.string)),
            "chatter_speak's tone enum does not match chatter_tones.")
        try verify(toneIDs.count == 33 && Set(["cheerful", "optimistic", "stern"]).isSubset(of: toneIDs), "Expected 33 tones.")
        let voices = try await call("chatter_voices").requiredArray("voices")
        // The historical default test voice may have been removed; then use the library's default voice.
        let named = voices.first(where: { $0["name"]?.stringValue?.lowercased() == voice.lowercased() })
        let fallback = voice == Self.defaultVoice ? voices.first(where: { $0["isDefault"] == true }) : nil
        guard let selected = named ?? fallback else {
            throw VerificationFailure("No saved voice named \(voice).")
        }
        let supportsInstructions = selected["supportsInstructions"] == true
        var fields: JSONObject = [
            "voice": try selected.required("id", "voice"), "tone": supportsInstructions ? "optimistic" : "natural", "pace": 1, "mode": "save",
            "language": "English",
            "text": .string(Self.narration), "requestID": .string("plugin-narration-check-" + UUID().uuidString.lowercased()),
        ]
        if supportsInstructions { fields["instruction"] = "Speak warmly and clearly, with an optimistic delivery." }
        let request = JSONValue.object(fields)
        var job = try await call("chatter_speak", request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(jobDeadline))
        while !["completed", "failed", "cancelled"].contains(job["state"]?.stringValue ?? "") {
            let id = job["id"]?.pythonDescription ?? "unknown"
            guard ContinuousClock.now < deadline else { throw VerificationFailure("Narration still queued or running: \(id)") }
            try await Task.sleep(for: .seconds(pollInterval))
            job = try await call("chatter_job", ["id": try job.required("id", "job")])
        }
        try verify(job["state"] == "completed", job.encoded())
        try verify(job["request"]?["tone"] == request["tone"], "The job did not keep the requested tone.")
        try verify(job["request"]?["language"] == request["language"] && job["request"]?["instruction"] == request["instruction"],
            "The job did not preserve language and delivery instructions.")
        try verify(job["referenceSampleIDs"] == selected["referenceSampleIDs"], "The job did not use every reference sample of the voice.")
        let path = try job.requiredString("path", "job")
        let wav = try WAVFormat.read(from: URL(filePath: path))
        try verify(wav.channels == 1 && wav.sampleRate == 24000 && wav.sampleWidth == 3,
            "Expected mono 24 kHz 24-bit PCM; got \(wav.channels) ch, \(wav.sampleRate) Hz, \(wav.bitsPerSample)-bit.")
        let duration = try job.required("duration", "job").numberValue ?? .nan
        try verify(abs(wav.durationSeconds - duration) < 0.001, "WAV lasts \(wav.durationSeconds) s; the job reports \(duration) s.")
        let summary: JSONValue = [
            "server": try initialized.required("serverInfo", "initialize result"),
            "tools": .array(toolset.map { $0["name"] ?? .null }), "toneCount": .int(tones.count),
            "voices": .array(voices.map { $0["name"] ?? .null }), "capabilities": capabilities,
            "supportsInstructions": .bool(supportsInstructions), "job": job,
        ]
        try writeReport(summary.encoded(.indented) + "\n", to: report)
        try output.line(JSONValue.object([
            "installedPlugin": "passed", "toneCount": .int(tones.count), "job": job["id"] ?? .null, "path": .string(path),
            "duration": job["duration"] ?? .null,
        ]).encoded())
    }

    private func launch() throws -> MCPStdioSession {
        switch transport {
        case .executable(let path):
            return try MCPStdioSession(executable: path, environment: settings.environment)
        case .codexCLI(let cli):
            let result = try ChildProcess.run(cli, ["mcp", "get", "chatter", "--json"], environment: settings.environment)
            try verify(result.status == 0, "\(cli) mcp get chatter exited with status \(result.status).")
            let transport = try JSONValue.parse(result.standardOutput).required("transport", "Codex MCP config")
            var environment = settings.environment
            for (key, value) in transport["env"]?.objectValue ?? JSONObject() { environment[key] = value.pythonDescription }
            return try MCPStdioSession(
                executable: try transport.requiredString("command", "transport"),
                arguments: transport["args"]?.arrayValue?.map(\.pythonDescription) ?? [],
                environment: environment,
                currentDirectory: transport["cwd"]?.stringValue.map { URL(filePath: $0, directoryHint: .isDirectory) })
        }
    }
}

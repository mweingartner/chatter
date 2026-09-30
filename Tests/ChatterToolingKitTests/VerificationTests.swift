// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import os
import Testing

/// Records suspend/resume instead of signalling a real process.
final class FakeEngine: EngineSuspension {
    private let events = OSAllocatedUnfairLock(initialState: [String]())
    let chatter: MockChatter

    init(_ chatter: MockChatter) { self.chatter = chatter }

    var log: [String] { events.withLock { $0 } }

    func suspend() throws -> EngineResumption {
        events.withLock { $0.append("suspend") }
        chatter.engineSuspended = true
        return EngineResumption { [events, chatter] in
            events.withLock { $0.append("resume") }
            chatter.engineSuspended = false
        }
    }
}

@Suite("verify api|queue|tones|plugin against a mock Chatter")
struct VerificationTests {
    @Test("verify api passes against a conforming app, prints the Python output and writes the report")
    func api() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let report = chatter.support.file("runtime/api-validation.json")
        let output = CapturedOutput()
        try await APIVerification(settings: chatter.settings, report: report).run(output: output)
        let lines = output.lines
        #expect(lines.count == 5)
        #expect(lines.first == "health {'status': 'ok', 'engine': 'ready', 'queueDepth': 0, 'queueCapacity': 1000}")
        #expect(lines[1].hasPrefix(#"job {"id": ""#) && lines[1].contains(#""state": "completed""#))
        #expect(lines[3].contains(#""state": "cancelled""#) && lines[3].contains(#""path": null"#))
        #expect(lines.last == "PASS authentication, origin, protocol, input validation, FIFO, idempotency, cancellation, WAV retrieval, MCP, portable stdio bridge")
        #expect(try JSONValue.parse(Data(contentsOf: report)).arrayValue?.count == 3)
        #expect(!output.text.contains(chatter.token))
        // The bridge subprocess reached this instance with the token file, not the real app.
        #expect(chatter.server.requests.contains { $0.path == "/mcp" && $0.json?["params"]?["name"] == "chatter_status" })
    }

    @Test("verify api fails when authentication is not enforced")
    func apiDetectsMissingAuthentication() async throws {
        var behavior = MockChatter.Behavior()
        behavior.enforceAuthentication = false
        let chatter = try await MockChatter.start(behavior)
        defer { chatter.stop() }
        await #expect(throws: VerificationFailure("GET /v1/health with a wrong token returned HTTP 200, expected 401.")) {
            try await APIVerification(settings: chatter.settings, report: chatter.support.file("r.json")).run(output: CapturedOutput())
        }
    }

    @Test("verify tones passes, prints one line per tone and writes the report")
    func tones() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let report = chatter.support.file("tone-api-results.json")
        let output = CapturedOutput()
        try await ToneVerification(settings: chatter.settings, report: report).run(output: output)
        #expect(output.lines.count == 4)
        #expect(output.lines[0].hasSuffix(#", "tone": "cheerful"}"#) && output.lines[1].hasSuffix(#""tone": "optimistic"}"#))
        #expect(output.lines[3] == "PASS tone catalog, MCP schema/discovery, validation, idempotency, multi-reference voice, multi-passage WAV generation")
        #expect(try JSONValue.parse(Data(contentsOf: report)).arrayValue?.count == 3)
        let saved = chatter.jobs.filter { $0["requestID"]?.stringValue?.hasPrefix("tone-verification-") == true }
        #expect(saved.count == 3 && saved.allSatisfy { $0["referenceSampleIDs"]?.arrayValue?.count == 3 })
    }

    @Test("verify tones honours CHATTER_TEST_VOICE and falls back to the default voice")
    func toneVoiceSelection() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        var settings = chatter.settings
        settings.environment["CHATTER_TEST_VOICE"] = "Ada"
        try await ToneVerification(settings: settings, report: chatter.support.file("t.json")).run(output: CapturedOutput())
        #expect(chatter.jobs.allSatisfy { $0["request"]?["voice"] == "voice-ada" })
        settings.environment["CHATTER_TEST_VOICE"] = "nobody"
        try await ToneVerification(settings: settings, report: chatter.support.file("t.json")).run(output: CapturedOutput())
        #expect(chatter.jobs.contains { $0["request"]?["voice"] == "voice-Ryan" })
    }

    @Test("verify queue fills 1,000 slots from 12 clients, checks 429 and retry, then cancels and resumes")
    func queue() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let engine = FakeEngine(chatter)
        let output = CapturedOutput()
        try await QueueVerification(settings: chatter.settings, engine: engine).run(output: output)
        #expect(engine.log == ["suspend", "resume"])
        #expect(output.lines.count == 2)
        let summary = try JSONValue.parse(output.lines[0])
        #expect(summary.objectValue?.keys == [
            "accepted", "concurrentClients", "seconds", "contiguousFIFOSequence", "durableReceipts", "overflowStatus", "retryDeduplicated",
        ])
        #expect(summary["accepted"] == 1000 && summary["overflowStatus"] == 429 && summary["retryDeduplicated"] == true)
        #expect(output.lines[1] == "All queue stress jobs cancelled; worker resumed.")
        #expect(chatter.jobs.count == 1000 && chatter.jobs.allSatisfy { $0["state"] == "cancelled" })
    }

    @Test("verify queue refuses to start while speech is queued and never suspends the engine")
    func queueBusy() async throws {
        var behavior = MockChatter.Behavior()
        behavior.initialQueueDepth = 1
        let chatter = try await MockChatter.start(behavior)
        defer { chatter.stop() }
        let engine = FakeEngine(chatter)
        await #expect(throws: VerificationFailure("Wait for user speech before this test.")) {
            try await QueueVerification(settings: chatter.settings, engine: engine).run(output: CapturedOutput())
        }
        #expect(engine.log.isEmpty)
    }

    @Test("A failure mid-stress still cancels the submitted jobs and resumes the engine")
    func queueFailureCleansUp() async throws {
        var behavior = MockChatter.Behavior()
        behavior.acceptanceLimit = 300
        let chatter = try await MockChatter.start(behavior)
        defer { chatter.stop() }
        let engine = FakeEngine(chatter)
        let output = CapturedOutput()
        await #expect {
            try await QueueVerification(settings: chatter.settings, engine: engine).run(output: output)
        } throws: { error in
            (error as? VerificationFailure)?.description.hasPrefix("(429, ") == true
        }
        #expect(engine.log == ["suspend", "resume"] && !chatter.engineSuspended)
        #expect(output.text.isEmpty)
        #expect(chatter.jobs.count >= 300 && chatter.jobs.allSatisfy { $0["state"] == "cancelled" })
    }

    @Test("verify plugin uses supported delivery controls and writes the narration report", arguments: ["RYAN", "Ada"])
    func plugin(voice: String) async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let report = chatter.support.file("video-narration-check.json")
        var verification = PluginVerification(
            settings: chatter.settings, transport: .executable(BuiltProducts.bridge), voice: voice, report: report)
        verification.pollInterval = 0.01
        let output = CapturedOutput()
        try await verification.run(output: output)
        let line = try JSONValue.parse(output.text)
        #expect(line.objectValue?.keys == ["installedPlugin", "toneCount", "job", "path", "duration"])
        #expect(line["installedPlugin"] == "passed" && line["toneCount"] == 33 && line["duration"] == 0.5)
        let saved = try JSONValue.parse(Data(contentsOf: report))
        #expect(saved["server"]?["name"] == "Chatter" && saved["voices"] == ["Ryan", "Ada"] && saved["job"]?["state"] == "completed")
        #expect(!output.text.contains(chatter.token))
        #expect(saved["job"]?["request"]?["tone"] == (voice == "Ada" ? "optimistic" : "natural"))
        #expect((saved["job"]?["request"]?["instruction"] != nil) == (voice == "Ada"))
        #expect(saved["job"]?["request"]?["language"] == "English")
    }

    @Test("verify plugin rejects stale schemas before queuing audio")
    func stalePluginSchema() async throws {
        var behavior = MockChatter.Behavior(); behavior.stalePluginSchema = true
        let chatter = try await MockChatter.start(behavior)
        defer { chatter.stop() }
        let verification = PluginVerification(settings: chatter.settings, transport: .executable(BuiltProducts.bridge))
        await #expect(throws: VerificationFailure.self) { try await verification.run(output: CapturedOutput()) }
        #expect(chatter.jobs.isEmpty)
    }

    @Test("verify plugin can resolve the transport through a Codex CLI")
    func pluginThroughCodexCLI() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let cli = chatter.support.file("codex")
        let transport: JSONValue = ["transport": [
            "command": .string(BuiltProducts.bridge), "args": [],
            "env": ["CHATTER_URL": .string(chatter.baseURL), "CHATTER_TOKEN_FILE": .string(chatter.tokenFile.path)],
        ]]
        try Data("#!/bin/sh\n[ \"$*\" = 'mcp get chatter --json' ] || exit 3\ncat <<'EOF'\n\(transport.encoded())\nEOF\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        var settings = chatter.settings
        settings.environment = ["PATH": "/usr/bin:/bin", "HOME": chatter.support.url.path]
        var verification = PluginVerification(settings: settings, transport: .codexCLI(cli.path), report: chatter.support.file("r.json"))
        verification.pollInterval = 0.01
        let output = CapturedOutput()
        try await verification.run(output: output)
        #expect(output.text.contains(#""installedPlugin": "passed""#))
    }

    @Test("verify plugin reports an unresponsive transport instead of hanging")
    func pluginTimeout() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        var verification = PluginVerification(settings: chatter.settings, transport: .executable("/bin/cat"), report: chatter.support.file("r.json"))
        verification.responseTimeout = 0.3
        // `cat` echoes the request back: wrong shape, so the first assertion fails fast.
        await #expect(throws: VerificationFailure.self) { try await verification.run(output: CapturedOutput()) }
        var silent = PluginVerification(settings: chatter.settings, transport: .executable("/usr/bin/true"), report: chatter.support.file("r.json"))
        silent.responseTimeout = 0.3
        await #expect(throws: VerificationFailure.self) { try await silent.run(output: CapturedOutput()) }
    }

    @Test("verify commands through the CLI: missing token file fails with exit 1 and no token output")
    func cliMissingToken() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let output = CapturedOutput(), errors = CapturedOutput()
        let status = await ChatterToolsCommand.run(
            ["verify", "api", "--support-dir", directory.url.path, "--base-url", "http://127.0.0.1:1"],
            environment: [:], output: output, errors: errors)
        #expect(status == 1)
        #expect(errors.text == "verify api FAILED: Chatter API token not found at \(directory.file("api-token").path).\n")
    }

    @Test("verify tones through the CLI against the mock")
    func cliTones() async throws {
        let chatter = try await MockChatter.start()
        defer { chatter.stop() }
        let output = CapturedOutput(), errors = CapturedOutput()
        let status = await ChatterToolsCommand.run(
            ["verify", "tones", "--base-url", chatter.baseURL, "--support-dir", chatter.support.url.path,
             "--output", chatter.support.file("out/tones.json").path],
            environment: chatter.bridgeEnvironment, output: output, errors: errors)
        #expect(status == 0, "\(errors.text)")
        #expect(output.lines.last?.hasPrefix("PASS tone catalog") == true)
    }

    @Test("The engine locator finds a direct child process by exact name")
    func childProcessLookup() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let children = try ChatterEngineProcess.childProcessIDs(of: getpid(), named: "sleep")
        #expect(children.contains(process.processIdentifier))
        #expect(try ChatterEngineProcess.childProcessIDs(of: getpid(), named: "chatter-engine-\(UUID().uuidString.prefix(4))").isEmpty)
        #expect(throws: VerificationFailure.self) {
            try ChatterEngineProcess(appName: "no-such-app-\(UUID().uuidString.prefix(6))").suspend()
        }
    }
}

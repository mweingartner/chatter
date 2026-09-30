// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import os
import Testing

@Suite("chatter-mcp bridge")
struct MCPBridgeTests {
    static let token = "bridge-secret-\(UUID().uuidString)"

    /// A token file plus a bridge pointed at `baseURL` with no access to the real home directory.
    private func bridge(_ baseURL: String, directory: TemporaryDirectory) throws -> MCPBridge {
        try Data((Self.token + "\n").utf8).write(to: directory.file("token"))
        let environment = ["CHATTER_URL": baseURL, "CHATTER_TOKEN_FILE": directory.file("token").path]
        return MCPBridge(forwarder: ChatterMCPForwarder(environment: environment, home: directory.url))
    }

    @Test("Requests are POSTed to /mcp with the bridge headers; replies come back as one compact line")
    func forwardsRequests() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { request in
            .json(["jsonrpc": "2.0", "id": request.json?["id"] ?? .null, "result": ["echo": request.json?["method"] ?? .null, "é": 1.5]])
        }
        defer { server.stop() }
        let outcome = try await bridge(server.baseURL, directory: directory).handle(line: #"{"jsonrpc":"2.0","id":"a-1","method":"tools/list"}"#)
        #expect(outcome == .reply(#"{"jsonrpc": "2.0", "id": "a-1", "result": {"echo": "tools/list", "\u00e9": 1.5}}"#))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/mcp")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["accept"] == "application/json, text/event-stream")
        #expect(request.headers["authorization"] == "Bearer " + Self.token)
        #expect(request.headers["mcp-protocol-version"] == "2025-11-25")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"jsonrpc": "2.0", "id": "a-1", "method": "tools/list"}"#)
    }

    @Test("Notifications (empty 202) and JSON null replies print nothing")
    func silentReplies() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { request in
            request.json?["id"] == nil ? .empty(202) : MockResponse(status: 200, body: Data("null".utf8))
        }
        defer { server.stop() }
        let bridge = try bridge(server.baseURL, directory: directory)
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .silent)
        let nullReply = await bridge.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"x"}"#)
        #expect(nullReply == .silent)
    }

    @Test("HTTP errors map to the bridge message: JSON-RPC error with an id, stderr without")
    func httpErrors() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { _ in .json(["error": "unauthorized"], status: 401) }
        defer { server.stop() }
        let bridge = try bridge(server.baseURL, directory: directory)
        let message = "Chatter returned HTTP 401. Check the host, token, and connection settings."
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"x"}"#)
            == .reply(#"{"jsonrpc": "2.0", "id": 9, "error": {"code": -32000, "message": "\#(message)"}}"#))
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","id":null,"method":"x"}"#)
            == .reply(#"{"jsonrpc": "2.0", "id": null, "error": {"code": -32000, "message": "\#(message)"}}"#))
        #expect(await bridge.handle(line: #"{"jsonrpc":"2.0","method":"x"}"#) == .diagnostic(message))
        #expect(await bridge.handle(line: "[1]") == .diagnostic(message))
    }

    @Test("Redirects are refused, so the token never reaches the Location target")
    func refusesRedirects() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = try await MockHTTPServer.start { _ in .json(["jsonrpc": "2.0", "id": 1, "result": [:]]) }
        defer { target.stop() }
        let redirector = try await MockHTTPServer.start { _ in
            MockResponse(status: 307, headers: ["Location": target.baseURL + "/mcp"])
        }
        defer { redirector.stop() }
        let outcome = try await bridge(redirector.baseURL, directory: directory).handle(line: #"{"jsonrpc":"2.0","id":1,"method":"x"}"#)
        #expect(outcome == .reply(
            #"{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "Chatter returned HTTP 307. Check the host, token, and connection settings."}}"#))
        #expect(target.requests.isEmpty)
    }

    @Test("An unreachable host maps to the unreachable message")
    func unreachable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { _ in .empty(500) }
        let closed = server.baseURL
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        let outcome = try await bridge(closed, directory: directory).handle(line: #"{"id":3}"#)
        #expect(outcome == .reply(
            #"{"jsonrpc": "2.0", "id": 3, "error": {"code": -32000, "message": "Chatter is unreachable. Start the app and check its Connections settings."}}"#))
    }

    @Test("Invalid input lines and non-JSON replies are reported, never silently dropped")
    func malformed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: Data("event: x\n".utf8)) }
        defer { server.stop() }
        let bridge = try bridge(server.baseURL, directory: directory)
        #expect(await bridge.handle(line: "") == .diagnostic("Expecting value: line 1 column 1 (char 0)"))
        #expect(await bridge.handle(line: "{oops") == .diagnostic("Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"))
        guard case .reply(let text) = await bridge.handle(line: #"{"id":4}"#) else {
            Issue.record("expected a JSON-RPC error")
            return
        }
        #expect(text.contains("-32000") && text.contains("not JSON"))
    }

    @Test("The connection is re-resolved per line, so a rotated token is picked up")
    func tokenRotation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { _ in .empty(202) }
        defer { server.stop() }
        let bridge = try bridge(server.baseURL, directory: directory)
        _ = await bridge.handle(line: #"{"method":"a"}"#)
        try Data("rotated".utf8).write(to: directory.file("token"))
        _ = await bridge.handle(line: #"{"method":"b"}"#)
        #expect(server.requests.map { $0.headers["authorization"] } == ["Bearer " + Self.token, "Bearer rotated"])
    }

    @Test("run() processes lines in order until EOF")
    func runLoop() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { request in
            guard let id = request.json?["id"] else { return .empty(202) }
            return .json(["jsonrpc": "2.0", "id": id, "result": [:]])
        }
        defer { server.stop() }
        let lines = OSAllocatedUnfairLock(initialState: [#"{"id":1}"#, #"{"method":"n"}"#, "bad", #"{"id":2}"#])
        let output = CapturedOutput(), diagnostics = CapturedOutput()
        try await bridge(server.baseURL, directory: directory).run(
            nextLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } }, output: output, diagnostics: diagnostics)
        #expect(output.lines == [#"{"jsonrpc": "2.0", "id": 1, "result": {}}"#, #"{"jsonrpc": "2.0", "id": 2, "result": {}}"#])
        #expect(diagnostics.lines == ["Expecting value: line 1 column 1 (char 0)"])
    }

    // MARK: The built executable

    @Test("chatter-mcp end to end: one line out per request, nothing for notifications, exit 0 at EOF, token never echoed")
    func executable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let server = try await MockHTTPServer.start { request in
            guard let id = request.json?["id"] else { return .empty(202) }
            if id == 2 { return .json(["error": "no"], status: 401) }
            return .json(["jsonrpc": "2.0", "id": id, "result": ["isError": false]])
        }
        defer { server.stop() }
        try Data(Self.token.utf8).write(to: directory.file("token"))
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, "garbage", #"{"jsonrpc":"2.0","method":"late"}"#,
        ].joined(separator: "\n")
        let result = try ChildProcess.run(
            BuiltProducts.bridge, input: Data(input.utf8),
            environment: ["CHATTER_URL": server.baseURL, "CHATTER_TOKEN_FILE": directory.file("token").path, "HOME": directory.url.path])
        let stdout = String(decoding: result.standardOutput, as: UTF8.self)
        let stderr = String(decoding: result.standardError, as: UTF8.self)
        #expect(result.status == 0)
        #expect(stdout == """
            {"jsonrpc": "2.0", "id": 1, "result": {"isError": false}}
            {"jsonrpc": "2.0", "id": 2, "error": {"code": -32000, "message": "Chatter returned HTTP 401. Check the host, token, and connection settings."}}

            """)
        #expect(stderr == "Expecting value: line 1 column 1 (char 0)\n")
        #expect(!stdout.contains(Self.token) && !stderr.contains(Self.token))
        #expect(server.requests.count == 4)
    }

    @Test("chatter-mcp without a token explains how to connect and still exits 0")
    func executableWithoutToken() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let result = try ChildProcess.run(
            BuiltProducts.bridge, input: Data(#"{"id":1}"#.utf8) + Data("\n".utf8),
            environment: ["HOME": directory.url.path, "CHATTER_TOKEN_FILE": directory.file("missing").path])
        #expect(result.status == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self).contains("Chatter connection token not found."))
    }

    @Test("chatter-mcp exits 0 immediately on empty stdin")
    func executableEOF() throws {
        let result = try ChildProcess.run(BuiltProducts.bridge, environment: ["HOME": "/nonexistent"])
        #expect(result.status == 0 && result.standardOutput.isEmpty && result.standardError.isEmpty)
    }
}

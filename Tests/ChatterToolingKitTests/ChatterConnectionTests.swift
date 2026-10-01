// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import Testing

@Suite("Connection resolution matches mcp_bridge.connection()")
struct ChatterConnectionTests {
    /// A fake home with `Library/Application Support/Chatter` (optionally with settings and token).
    private func home(settings: String? = nil, token: String? = nil) throws -> TemporaryDirectory {
        let home = try TemporaryDirectory()
        let support = ChatterConnection.supportDirectory(home: home.url)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let settings { try Data(settings.utf8).write(to: support.appending(path: "settings.json")) }
        if let token { try Data(token.utf8).write(to: support.appending(path: "api-token")) }
        return home
    }

    @Test("Defaults: settings.json port and the support-directory token file (trimmed)")
    func defaults() throws {
        let home = try home(settings: #"{"port": 19000}"#, token: "  abc123\n")
        defer { home.remove() }
        let connection = try ChatterConnection.resolve(environment: [:], home: home.url)
        #expect(connection == ChatterConnection(baseURL: "http://127.0.0.1:19000", token: "abc123"))
    }

    @Test("Missing or unusable settings fall back to port 18423", arguments: [nil, "not json", "[1]", #"{"port": true}"#])
    func defaultPort(settings: String?) throws {
        let home = try home(settings: settings, token: "t")
        defer { home.remove() }
        #expect(try ChatterConnection.resolve(environment: [:], home: home.url).baseURL == "http://127.0.0.1:18423")
    }

    @Test("A string port is used verbatim")
    func stringPort() throws {
        let home = try home(settings: #"{"port": "18500"}"#, token: "t")
        defer { home.remove() }
        #expect(try ChatterConnection.resolve(environment: [:], home: home.url).baseURL == "http://127.0.0.1:18500")
    }

    @Test("CHATTER_URL (trailing slashes stripped), CHATTER_TOKEN and CHATTER_TOKEN_FILE override defaults")
    func environmentOverrides() throws {
        let home = try home(token: "file-token")
        defer { home.remove() }
        let lan = try ChatterConnection.resolve(
            environment: ["CHATTER_URL": "https://mac.local:18424//", "CHATTER_TOKEN": "env-token"], home: home.url)
        #expect(lan == ChatterConnection(baseURL: "https://mac.local:18424", token: "env-token"))
        try Data("custom\n".utf8).write(to: home.file("lan-token"))
        let custom = try ChatterConnection.resolve(environment: ["CHATTER_TOKEN": "", "CHATTER_TOKEN_FILE": "~/lan-token"], home: home.url)
        #expect(custom.token == "custom")
    }

    @Test("Missing, empty and header-unsafe tokens fail with the bridge's messages")
    func tokenFailures() throws {
        let home = try home()
        defer { home.remove() }
        #expect(throws: ChatterConnectionError.tokenNotFound) { try ChatterConnection.resolve(environment: [:], home: home.url) }
        #expect(ChatterConnectionError.tokenNotFound.description
            == "Chatter connection token not found. Start Chatter locally, or set CHATTER_URL and CHATTER_TOKEN_FILE for your LAN host.")
        try Data(" \n".utf8).write(to: home.file("blank"))
        #expect(throws: ChatterConnectionError.tokenEmpty) {
            try ChatterConnection.resolve(environment: ["CHATTER_TOKEN_FILE": home.file("blank").path], home: home.url)
        }
        #expect(throws: ChatterConnectionError.tokenHasInvalidCharacters) {
            try ChatterConnection.resolve(environment: ["CHATTER_TOKEN": "a\r\nX-Evil: 1"], home: home.url)
        }
    }

    @Test("Descriptions never include the token; invalid URLs are rejected without echoing them")
    func noTokenLeak() throws {
        let connection = ChatterConnection(baseURL: "http://127.0.0.1:1", token: "super-secret")
        #expect(!"\(connection)".contains("super-secret"))
        #expect(throws: ChatterConnectionError.invalidURL) { try ChatterConnection(baseURL: "", token: "t").url(for: "/mcp") }
        #expect(throws: ChatterConnectionError.invalidURL) { try ChatterConnection(baseURL: "file:///etc", token: "t").url(for: "/mcp") }
        #expect(try connection.url(for: "/mcp").absoluteString == "http://127.0.0.1:1/mcp")
    }
}

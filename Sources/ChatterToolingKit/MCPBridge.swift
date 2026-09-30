// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// Posts one JSON-RPC message to Chatter's `/mcp` endpoint and returns the decoded reply.
public protocol MCPForwarding: Sendable {
    /// Returns `nil` when Chatter answers with an empty body (or JSON `null`), e.g. for notifications.
    func forward(_ message: JSONValue) async throws -> JSONValue?
}

/// Forwards to a live Chatter, re-resolving the connection for every message (token rotation safe).
public struct ChatterMCPForwarder: MCPForwarding {
    /// Protocol revision announced in the `MCP-Protocol-Version` header.
    public static let protocolVersion = "2025-11-25"
    public static let timeout: TimeInterval = 20

    private let environment: [String: String]
    private let home: URL
    private let http: ChatterHTTPSession

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.home = home
        http = ChatterHTTPSession(timeout: Self.timeout)
    }

    public func forward(_ message: JSONValue) async throws -> JSONValue? {
        let connection = try ChatterConnection.resolve(environment: environment, home: home)
        var request = URLRequest(url: try connection.url(for: "/mcp"), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpBody = Data(message.encoded().utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            throw ChatterConnectionError.unreachable
        }
        guard (200..<300).contains(response.statusCode) else { throw ChatterConnectionError.httpStatus(response.statusCode) }
        guard !data.isEmpty else { return nil }
        do {
            let reply = try JSONValue.parse(data)
            return reply == .null ? nil : reply
        } catch {
            throw ChatterConnectionError.invalidResponse(error.description)
        }
    }
}

/// The stdio ↔ HTTP bridge behind `chatter-mcp`: one JSON-RPC line in, at most one line out.
public struct MCPBridge: Sendable {
    /// JSON-RPC error code used for every bridge-side failure.
    public static let failureCode = -32000

    private let forwarder: any MCPForwarding

    public init(forwarder: any MCPForwarding = ChatterMCPForwarder()) { self.forwarder = forwarder }

    /// What one input line produced.
    public enum Outcome: Sendable, Equatable {
        /// Nothing to print (notification or empty reply).
        case silent
        /// A JSON-RPC line for stdout.
        case reply(String)
        /// A diagnostic for stderr (the input had no `id` to answer).
        case diagnostic(String)
    }

    /// Handles one input line. Failures become a JSON-RPC error when the input object had an `id`
    /// member (even `null`), otherwise a stderr diagnostic.
    public func handle(line: String) async -> Outcome {
        var message: JSONValue?
        do {
            let value = try JSONValue.parse(line)
            message = value
            guard let reply = try await forwarder.forward(value) else { return .silent }
            return .reply(reply.encoded())
        } catch {
            let text = errorMessage(error)
            if case .object(let object)? = message, let id = object["id"] {
                let failure: JSONValue = [
                    "jsonrpc": "2.0", "id": id, "error": ["code": .int(Self.failureCode), "message": .string(text)],
                ]
                return .reply(failure.encoded())
            }
            return .diagnostic(text)
        }
    }

    /// Processes lines sequentially until `nextLine` returns `nil` (EOF).
    /// Returns early only if stdout/stderr can no longer be written.
    public func run(
        nextLine: () -> String? = { readLine(strippingNewline: true) },
        output: any TextOutput = FileHandleOutput.standardOutput,
        diagnostics: any TextOutput = FileHandleOutput.standardError
    ) async throws {
        while let line = nextLine() {
            switch await handle(line: line) {
            case .silent: break
            case .reply(let text): try output.line(text)
            case .diagnostic(let text): try diagnostics.line(text)
            }
        }
    }
}

/// An error of this package whose `description` is the complete user-facing message.
public protocol ChatterToolingFailure: Error, CustomStringConvertible {}

/// The user-facing message for any error: this package's own wording, else the system description.
public func errorMessage(_ error: any Error) -> String {
    if let failure = error as? any ChatterToolingFailure { return failure.description }
    return error.localizedDescription
}

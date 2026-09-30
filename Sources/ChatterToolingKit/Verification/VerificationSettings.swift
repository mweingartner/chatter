// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// Where the `verify` commands find the installed app. Defaults match the Python scripts:
/// `http://127.0.0.1:18423`, the token in `~/Library/Application Support/Chatter/api-token`,
/// and reports under `.runtime/` in the current directory.
public struct VerificationSettings: Sendable {
    public var baseURL: String
    public var tokenFile: URL
    /// `~/Library/Application Support/Chatter` (its `Queue/` holds durable receipts).
    public var supportDirectory: URL
    /// The `chatter-mcp` executable the api/plugin checks launch.
    public var bridgeExecutable: String
    /// Environment inherited by child processes (and consulted for `CHATTER_TEST_VOICE`).
    public var environment: [String: String]
    /// Job polling for `/v1/jobs/<id>` (deadline and interval in seconds).
    public var jobDeadline: Double = 180
    public var pollInterval: Double = 0.25

    public init(
        baseURL: String = ChatterAPIClient.defaultBaseURL,
        supportDirectory: URL = ChatterConnection.supportDirectory(),
        tokenFile: URL? = nil,
        bridgeExecutable: String = VerificationSettings.siblingExecutable(named: "chatter-mcp"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.baseURL = baseURL
        self.supportDirectory = supportDirectory
        self.tokenFile = tokenFile ?? supportDirectory.appending(path: "api-token")
        self.bridgeExecutable = bridgeExecutable
        self.environment = environment
    }

    /// A client for the configured instance (reads the token file).
    public func makeClient() throws -> ChatterAPIClient {
        ChatterAPIClient(
            baseURL: baseURL, token: try ChatterAPIClient.loadToken(from: tokenFile), jobDeadline: jobDeadline,
            pollInterval: pollInterval)
    }

    /// Environment for a bridge child aimed at the same instance these checks target.
    public var bridgeEnvironment: [String: String] {
        var environment = environment
        environment["CHATTER_URL"] = baseURL
        environment["CHATTER_TOKEN_FILE"] = tokenFile.path
        environment["CHATTER_TOKEN"] = nil
        return environment
    }

    /// `<directory of this executable>/<name>`, e.g. `chatter-mcp` beside `chatter-tools`.
    public static func siblingExecutable(named name: String) -> String {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: name).path
    }

    /// JSON-RPC request with `id` 1, as the Python `rpc` lambda built it.
    static func rpc(_ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    }
}

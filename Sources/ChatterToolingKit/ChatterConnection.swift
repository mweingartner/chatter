// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// Where a Chatter instance listens and the bearer token that authorizes it.
///
/// `description` deliberately omits the token so the value can be logged safely.
public struct ChatterConnection: Sendable, Equatable, CustomStringConvertible {
    /// Base URL without trailing slashes, e.g. `http://127.0.0.1:18423`.
    public let baseURL: String
    public let token: String

    /// Chatter's default loopback port when `settings.json` does not name one.
    public static let defaultPort = 18423

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public var description: String { "ChatterConnection(\(baseURL))" }

    /// `~/Library/Application Support/Chatter` for the given home directory.
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Chatter", directoryHint: .isDirectory)
    }

    /// Resolves the connection the way the MCP bridge always has:
    /// `CHATTER_URL`, else `http://127.0.0.1:<settings.json port>`; `CHATTER_TOKEN`, else the token file
    /// named by `CHATTER_TOKEN_FILE`, else `<support>/api-token`.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(ChatterConnectionError) -> ChatterConnection {
        let support = supportDirectory(home: home)
        var url = environment["CHATTER_URL"] ?? "http://127.0.0.1:\(settingsPort(support: support))"
        while url.hasSuffix("/") { url.removeLast() }
        var token = environment["CHATTER_TOKEN"] ?? ""
        if token.isEmpty {
            let path = environment["CHATTER_TOKEN_FILE"].map { expandTilde($0, home: home) }
                ?? support.appending(path: "api-token").path
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8)
            else { throw .tokenNotFound }
            token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token.isEmpty else { throw .tokenEmpty }
        guard token.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
            throw .tokenHasInvalidCharacters
        }
        return ChatterConnection(baseURL: url, token: token)
    }

    /// Absolute URL for a server-relative route such as `/mcp`.
    public func url(for route: String) throws(ChatterConnectionError) -> URL {
        guard let url = URL(string: baseURL + route), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host() != nil
        else { throw .invalidURL }
        return url
    }

    /// The `port` from `settings.json`, or the default when the file or key is unusable.
    static func settingsPort(support: URL) -> String {
        guard let data = FileManager.default.contents(atPath: support.appending(path: "settings.json").path),
            let settings = try? JSONValue.parse(data)
        else { return String(defaultPort) }
        switch settings["port"] {
        case .int(let port): return String(port)
        case .string(let port): return port
        default: return String(defaultPort)
        }
    }

    /// Python `Path.expanduser` for `~` and `~/…`.
    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))).path }
        return (path as NSString).expandingTildeInPath
    }
}

/// Connection and transport failures, worded exactly as the Python bridge reported them.
public enum ChatterConnectionError: ChatterToolingFailure, Sendable, Equatable {
    case tokenNotFound
    case tokenEmpty
    case tokenHasInvalidCharacters
    case invalidURL
    case httpStatus(Int)
    case unreachable
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .tokenNotFound:
            "Chatter connection token not found. Start Chatter locally, or set CHATTER_URL and CHATTER_TOKEN_FILE for your LAN host."
        case .tokenEmpty: "Chatter token is empty."
        case .tokenHasInvalidCharacters: "Chatter token contains characters that cannot be sent in an HTTP header."
        case .invalidURL: "CHATTER_URL is not a valid http(s) URL."
        case .httpStatus(let code): "Chatter returned HTTP \(code). Check the host, token, and connection settings."
        case .unreachable: "Chatter is unreachable. Start the app and check its Connections settings."
        case .invalidResponse(let reason): "Chatter returned a response that is not JSON (\(reason))."
        }
    }
}

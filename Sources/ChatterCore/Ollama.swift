import Foundation

/// A model the local Ollama server can run on this Mac.
public struct OllamaModel: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    public var capabilities: [String]
    public var parameterSize: String?
    public var id: String { name }
    public var canThink: Bool { capabilities.contains("thinking") }
    public init(name: String, sizeBytes: Int64 = 0, capabilities: [String] = [], parameterSize: String? = nil) {
        self.name = name; self.sizeBytes = sizeBytes; self.capabilities = capabilities; self.parameterSize = parameterSize
    }
}

public enum OllamaError: LocalizedError, Equatable, Sendable {
    case notRunning(String)
    case modelMissing(String)
    case timedOut
    case server(String)
    case unreadable
    case invalidAddress

    public var errorDescription: String? {
        switch self {
        case .notRunning(let address): "Ollama isn’t running at \(address). Open Ollama and try again."
        case .modelMissing(let model): "Ollama doesn’t have “\(model)”. Choose another model in Expression settings, or run “ollama pull \(model)”."
        case .timedOut: "The language model took too long to answer."
        case .server(let message): "Ollama: \(message)"
        case .unreadable: "Ollama sent a reply Chatter couldn’t read."
        case .invalidAddress: "Use the address of Ollama on this Mac, such as http://127.0.0.1:11434."
        }
    }
}

/// Talks to the Ollama server on this Mac. Only loopback addresses are accepted, requests go direct (no
/// proxy) and never follow a redirect, so text sent for review never leaves the computer; models that
/// Ollama runs in its cloud are never offered.
public struct OllamaClient: Sendable {
    public static let defaultAddress = "http://127.0.0.1:11434"
    public let baseURL: URL
    let session: URLSession

    /// A session that ignores system proxies, keeps nothing on disk, and is used only for Ollama.
    public static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    public init(address: String = OllamaClient.defaultAddress, session: URLSession = OllamaClient.directSession) throws {
        baseURL = try Self.validatedAddress(address)
        self.session = session
    }

    /// An http(s) URL whose host is 127.0.0.1, ::1 or localhost, with no path, query or credentials.
    public static func validatedAddress(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["127.0.0.1", "::1", "localhost"].contains(host),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else { throw OllamaError.invalidAddress }
        return url
    }

    var address: String { baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString }

    public func version() async throws -> String {
        let root = try await get("api/version", timeout: .seconds(5))
        guard let version = root["version"] as? String else { throw OllamaError.unreadable }
        return version
    }

    /// Models stored on this Mac that can generate text, by name. Cloud models (which Ollama lists with a
    /// remote host) and embedding-only models are left out.
    public func localModels() async throws -> [OllamaModel] {
        let root = try await get("api/tags", timeout: .seconds(10))
        guard let models = root["models"] as? [[String: Any]] else { throw OllamaError.unreadable }
        return models.compactMap { item -> OllamaModel? in
            guard let name = item["name"] as? String ?? item["model"] as? String, item["remote_host"] == nil, item["remote_model"] == nil else { return nil }
            let capabilities = item["capabilities"] as? [String]
            if let capabilities, !capabilities.contains("completion") { return nil }
            let details = item["details"] as? [String: Any]
            let parameters = (details?["parameter_size"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return OllamaModel(name: name, sizeBytes: (item["size"] as? NSNumber)?.int64Value ?? 0,
                               capabilities: capabilities ?? [], parameterSize: parameters)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One chat turn whose reply must match `schema` (a JSON schema). Returns the reply's content.
    /// `think` turns a reasoning model's thinking on or off; nil leaves the model's default.
    public func chat(model: String, instructions: String, prompt: String, schema: Data, think: Bool?, timeout: Duration) async throws -> Data {
        let format = try JSONSerialization.jsonObject(with: schema)
        var body: [String: Any] = ["model": model, "stream": false, "format": format, "options": ["temperature": 0],
                                   "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]]]
        if let think { body["think"] = think }
        let root = try await post("api/chat", body: body, model: model, timeout: timeout)
        guard let message = root["message"] as? [String: Any], let content = message["content"] as? String else { throw OllamaError.unreadable }
        return Data(content.utf8)
    }

    /// Loads a model into memory ahead of use, so the first review doesn't wait for it.
    public func load(model: String) async throws {
        _ = try await post("api/generate", body: ["model": model], model: model, timeout: .seconds(120))
    }

    // MARK: Transport

    private func get(_ path: String, timeout: Duration) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = Self.seconds(timeout)
        return try await send(request, model: nil, timeout: timeout)
    }

    private func post(_ path: String, body: [String: Any], model: String, timeout: Duration) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.seconds(timeout)
        return try await send(request, model: model, timeout: timeout)
    }

    /// Sends a request that must finish within `timeout` in total (a request's own timeout only limits
    /// the silence between bytes) and must not be redirected.
    private func send(_ request: URLRequest, model: String?, timeout: Duration) async throws -> [String: Any] {
        let session = session, address = address
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                do { return try await session.data(for: request, delegate: RedirectRefusal()) } catch let error as URLError {
                    switch error.code {
                    case .cancelled: throw CancellationError()
                    case .timedOut: throw OllamaError.timedOut
                    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                        throw OllamaError.notRunning(address)
                    default: throw OllamaError.server(error.localizedDescription)
                    }
                }
            }
            group.addTask { try await Task.sleep(for: max(timeout, .milliseconds(500))); throw OllamaError.timedOut }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OllamaError.unreadable }
            return first
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = root?["error"] as? String ?? "HTTP \(status)"
            // Ollama answers 404 "model … not found" for a model it doesn't have.
            if let model, status == 404 || (message.localizedCaseInsensitiveContains("model") && message.localizedCaseInsensitiveContains("not found")) {
                throw OllamaError.modelMissing(model)
            }
            throw OllamaError.server(message)
        }
        guard let root else { throw OllamaError.unreadable }
        return root
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        max(0.5, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

/// Refuses every redirect, so a request can only reach the address it was made for; the redirect
/// response itself comes back as an error status.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

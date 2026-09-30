// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// Authenticated calls against a running Chatter's REST and MCP routes, as `verify-api.py`'s `call` made them.
/// The token is only ever placed in the `Authorization` header.
public struct ChatterAPIClient: Sendable {
    /// Where `verify-*.py` always pointed: the local app on its default port.
    public static let defaultBaseURL = "http://127.0.0.1:18423"
    public static let timeout: TimeInterval = 20

    public let baseURL: String
    private let token: String
    private let http: ChatterHTTPSession
    /// How long `waitForJob` polls before giving up, and how often.
    let jobDeadline: Double
    let pollInterval: Double

    public init(baseURL: String = defaultBaseURL, token: String, jobDeadline: Double = 180, pollInterval: Double = 0.25) {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.token = token
        self.jobDeadline = jobDeadline
        self.pollInterval = pollInterval
        http = ChatterHTTPSession(timeout: Self.timeout, maximumConnectionsPerHost: QueueVerification.concurrentClients)
    }

    /// Reads and trims the token file (the token itself is never printed).
    public static func loadToken(from file: URL) throws -> String {
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else {
            throw VerificationFailure("Chatter API token not found at \(file.path).")
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ChatterConnectionError.tokenEmpty }
        return token
    }

    /// A decoded response: JSON when Chatter labels it `application/json` (and for every error), raw bytes otherwise.
    public struct Reply: Sendable {
        public let status: Int
        public let json: JSONValue?
        public let data: Data
    }

    /// Sends `body` as JSON (POST unless `method` says otherwise; GET without a body).
    /// `headers` override the defaults, e.g. a wrong `Authorization` for the 401 check.
    public func call(
        _ path: String, body: JSONValue? = nil, method: String? = nil, headers: [String: String] = [:]
    ) async throws -> Reply {
        guard let url = URL(string: baseURL + path) else { throw VerificationFailure("Invalid Chatter route \(path).") }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.httpBody = body.map { Data($0.encoded().utf8) }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            throw ChatterConnectionError.unreachable
        }
        let success = (200..<300).contains(response.statusCode)
        let mediaType = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !success || mediaType == "application/json" else {
            return Reply(status: response.statusCode, json: nil, data: data)
        }
        do {
            return Reply(status: response.statusCode, json: try JSONValue.parse(data), data: data)
        } catch {
            throw VerificationFailure("\(request.httpMethod ?? "GET") \(path) returned HTTP \(response.statusCode) with a non-JSON body.")
        }
    }

    /// The JSON body of a call, failing when the reply is not JSON.
    public func json(_ path: String, body: JSONValue? = nil, method: String? = nil) async throws -> JSONValue {
        let reply = try await call(path, body: body, method: method)
        guard let json = reply.json else { throw VerificationFailure("\(path) did not return JSON.") }
        return json
    }

    /// Polls `/v1/jobs/<id>` until the job is completed, failed or cancelled.
    public func waitForJob(_ id: String) async throws -> JSONValue {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(jobDeadline))
        while clock.now < deadline {
            let job = try await json("/v1/jobs/" + id)
            if let state = job["state"]?.stringValue, ["completed", "failed", "cancelled"].contains(state) { return job }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw VerificationFailure("Timed out waiting for job \(id).")
    }
}

/// A failed verification check (Python's `AssertionError`/`TimeoutError`). Never contains the token.
public struct VerificationFailure: ChatterToolingFailure, Sendable, Equatable {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// Asserts a verification condition, like Python's `assert condition, message`.
func verify(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw VerificationFailure(message()) }
}

extension JSONValue {
    /// A member that must exist (Python `value[key]`), else a verification failure naming `context`.
    func required(_ key: String, _ context: String = "response") throws -> JSONValue {
        guard let value = self[key] else { throw VerificationFailure("\(context) has no '\(key)': \(encoded())") }
        return value
    }

    func requiredString(_ key: String, _ context: String = "response") throws -> String {
        guard let value = try required(key, context).stringValue else {
            throw VerificationFailure("\(context) '\(key)' is not a string.")
        }
        return value
    }

    func requiredArray(_ key: String, _ context: String = "response") throws -> [JSONValue] {
        guard let value = try required(key, context).arrayValue else {
            throw VerificationFailure("\(context) '\(key)' is not an array.")
        }
        return value
    }

    /// `{k: value.get(k) for k in keys}`: the listed members in order, `null` where missing.
    func selecting(_ keys: [String]) -> JSONValue {
        .object(JSONObject(keys.map { ($0, self[$0] ?? .null) }))
    }
}

/// Nanoseconds since the Unix epoch, like Python's `time.time_ns()`, for unique request-ID prefixes.
func wallClockNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }

/// Writes a verification report, creating its directory.
func writeReport(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

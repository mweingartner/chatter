// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// An ephemeral URLSession that never follows redirects, so a bearer token is only ever sent
/// to the host the caller named. No cookies, cache or credential storage.
public final class ChatterHTTPSession: Sendable {
    private let session: URLSession

    /// - Parameters:
    ///   - timeout: Idle timeout per request, matching Python's socket timeout.
    ///   - maximumConnectionsPerHost: Parallel connections (the queue stress test uses 12).
    public init(timeout: TimeInterval, maximumConnectionsPerHost: Int = 6) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Sends a request and returns the body with the final (never redirected) response.
    /// Throws the underlying transport error when no HTTP response arrives.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Downloads a response body straight to `destination` (which must not exist yet).
    /// A non-2xx response leaves nothing at `destination`.
    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (location, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (200..<300).contains(http.statusCode) {
            try FileManager.default.moveItem(at: location, to: destination)
        }
        return http
    }
}

/// Answers every redirect with `nil`, delivering the 3xx response itself.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

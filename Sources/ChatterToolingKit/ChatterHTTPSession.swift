// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation
import Security
import CryptoKit

/// An ephemeral URLSession that never follows redirects, so a bearer token is only ever sent
/// to the host the caller named. No cookies, cache or credential storage.
public final class ChatterHTTPSession: Sendable {
    private let session: URLSession

    /// - Parameters:
    ///   - timeout: Idle timeout per request, matching Python's socket timeout.
    ///   - maximumConnectionsPerHost: Parallel connections (the queue stress test uses 12).
    public init(timeout: TimeInterval, maximumConnectionsPerHost: Int = 6, tlsFingerprint: String? = ProcessInfo.processInfo.environment["CHATTER_TLS_SHA256"]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        session = URLSession(configuration: configuration, delegate: RedirectRefusal(fingerprint: tlsFingerprint), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }
    private func validate(_ request: URLRequest) throws {
        guard let url = request.url else { throw ChatterConnectionError.invalidURL }
        _ = try ChatterConnection(baseURL: url.absoluteString, token: "").url(for: "")
    }

    /// Sends a request and returns the body with the final (never redirected) response.
    /// Throws the underlying transport error when no HTTP response arrives.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try validate(request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Downloads a response body straight to `destination` (which must not exist yet).
    /// A non-2xx response leaves nothing at `destination`.
    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        try validate(request)
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
    let fingerprint: String?
    init(fingerprint: String?) { self.fingerprint = fingerprint?.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let fingerprint else { return (.performDefaultHandling, nil) }
        guard ChatterConnection.validFingerprint(fingerprint), let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first else { return (.cancelAuthenticationChallenge, nil) }
        let observed = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard observed == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        // Explicit pin replaces DNS identity, not certificate validity or proof of the private key.
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

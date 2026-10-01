import Foundation
import Security
import Testing
@testable import ChatterCore

@Suite("Security transport") struct SecurityTransportTests {
    @Test func identityRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LocalTLSIdentity.load(directory: root)
        let second = try LocalTLSIdentity.load(directory: root)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint.count == 64)
        let cert = try #require(SecCertificateCreateWithData(nil, first.certificate as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "localhost" as CFString), &trust) == errSecSuccess)
        let verified = try #require(trust)
        SecTrustSetAnchorCertificates(verified, [cert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(verified, true)
        #expect(SecTrustEvaluateWithError(verified, nil))
        let mode = try FileManager.default.attributesOfItem(atPath: root.appending(path: "identity-key.bin").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
    @Test func headersAuthenticateBeforeBody() throws {
        let data = Data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer test\r\nContent-Length: 2000000\r\n\r\n".utf8)
        #expect(try HTTPRequest.parse(data) == nil)
        #expect(try HTTPRequest.parse(data, headersOnly: true)?.0.headers["authorization"] == "Bearer test")
        #expect(throws: (any Error).self) { try HTTPRequest.parse(Data("GET / HTTP/1.1\r\nAuthorization : bad\r\n\r\n".utf8)) }
    }
}

import Foundation
import Network
import Testing
import ChatterCore
@testable import ChatterToolingKit

@Suite("Verified LAN transport", .serialized) @MainActor struct TLSTransportTests {
    @Test func pinnedTLSAndNegativeControls() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try LocalTLSIdentity.load(directory: root)
        let server = HTTPServer(); defer { server.stop() }
        server.authorizeHeaders = { request in request.headers["authorization"] == "Bearer fixture" ? nil : HTTPResponse(status: 401) }
        server.route = { _ in HTTPResponse(body: Data("verified".utf8)) }
        let port = Int.random(in: 30000...45000)
        try server.start(port: port, allowLAN: true, identity: identity.identity)
        try await Task.sleep(for: .milliseconds(100))
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/status")!)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let good = ChatterHTTPSession(timeout: 5, tlsFingerprint: identity.fingerprint)
        let (body, response) = try await good.send(request)
        #expect(response.statusCode == 200); #expect(body == Data("verified".utf8))
        let wrong = ChatterHTTPSession(timeout: 5, tlsFingerprint: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { try await wrong.send(request) }
        let untrusted = ChatterHTTPSession(timeout: 5, tlsFingerprint: nil)
        await #expect(throws: (any Error).self) { try await untrusted.send(request) }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        #expect(try await good.send(request).1.statusCode == 401)
    }
    @Test func unauthenticatedConnectionsDoNotStarveAuthorizedWork() async throws {
        let server = HTTPServer(); defer { server.stop() }
        server.authorizeHeaders = { $0.headers["authorization"] == "Bearer fixture" ? nil : HTTPResponse(status: 401) }
        server.route = { _ in HTTPResponse(body: Data("available".utf8)) }
        let port = UInt16.random(in: 30000...45000)
        try server.start(port: Int(port), allowLAN: false)
        try await Task.sleep(for: .milliseconds(100))
        var held: [NWConnection] = []
        defer { for socket in held { socket.cancel() } }
        let queue = DispatchQueue(label: "security-slow-connections")
        for _ in 0..<128 {
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            socket.start(queue: queue)
            socket.send(content: Data("GET / HTTP/1.1\r\nHost: localhost\r\n".utf8), completion: .contentProcessed { _ in })
            held.append(socket)
        }
        try await Task.sleep(for: .milliseconds(200))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let response = try await ChatterHTTPSession(timeout: 5).send(request)
        #expect(response.1.statusCode == 200)
    }
    @Test func remotePlaintextAndInvalidPinsAreRejected() throws {
        #expect(throws: ChatterConnectionError.insecureRemoteURL) {
            try ChatterConnection.resolve(environment: ["CHATTER_URL":"http://192.0.2.1:18423", "CHATTER_TOKEN":"fixture"])
        }
        #expect(throws: ChatterConnectionError.invalidTLSFingerprint) {
            try ChatterConnection.resolve(environment: ["CHATTER_TLS_SHA256":"ignore", "CHATTER_TOKEN":"fixture"])
        }
        #expect(throws: ChatterConnectionError.invalidURL) {
            try ChatterConnection(baseURL: "https://user:password@host.invalid", token: "fixture").url(for: "/mcp")
        }
    }
}

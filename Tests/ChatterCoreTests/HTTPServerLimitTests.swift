import ChatterCore
import Darwin
import Foundation
import Testing

/// The listener's connection limits, driven with a raw loopback socket so the exact bytes and the
/// exact silence are under the test's control (no client-side timeouts, retries or buffering).
///
/// Limits (HTTPServer.accept): 3 s to authenticate, 10 s idle, 120 s absolute. A connection whose
/// complete request is being answered is exempt from the idle limit only. The tests run in parallel,
/// so the suite's wall time is that of the slowest (about 12 s), and every bound is checked against
/// the watchdog's 1 s tick: a limit of N seconds closes the connection between N and about N + 1.5.
@MainActor struct HTTPServerLimitTests {
    static let token = "Bearer limits"

    /// A plain BSD socket on 127.0.0.1. Blocking calls run off the main actor (the server needs it).
    struct RawClient: Sendable {
        let fd: Int32

        static func connect(port: UInt16, receiveBuffer: Int32? = nil) async throws -> RawClient {
            for _ in 0..<20 {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EMFILE) }
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                if var size = receiveBuffer { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if result == 0 { return RawClient(fd: fd) }
                Darwin.close(fd)
                try await Task.sleep(for: .milliseconds(50))
            }
            throw POSIXError(.ECONNREFUSED)
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        }

        /// Reads until the server closes the connection or `limit` passes. Returns when it closed
        /// (seconds after `since`, nil if still open at the limit) and the bytes received.
        func waitForClose(since start: ContinuousClock.Instant, limit: Duration) async -> (closedAfter: Double?, bytes: Int) {
            let fd = fd
            return await Task.detached {
                var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                var total = 0
                while ContinuousClock.now - start < limit {
                    let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                    if count > 0 { total += count; continue }
                    if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        let elapsed = (ContinuousClock.now - start).components
                        return (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, total)
                    }
                }
                return (nil, total)
            }.value
        }

        func close() { Darwin.close(fd) }
    }

    /// Counts route invocations so a test can prove an incomplete request never reached the router.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func hit() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// Starts a server on a free loopback port (below the ephemeral range, so the test's own client
    /// sockets never hold it) and connects a raw client, moving to another port if one is taken.
    static func serve(receiveBuffer: Int32? = nil, route: @escaping (HTTPRequest) async -> HTTPResponse) async throws -> (HTTPServer, RawClient) {
        var lastError: any Error = POSIXError(.EADDRINUSE)
        for _ in 0..<8 {
            let server = HTTPServer()
            server.authorizeHeaders = { $0.headers["authorization"] == token ? nil : HTTPResponse(status: 401) }
            server.route = route
            let port = UInt16.random(in: 20000...29999)
            do {
                try server.start(port: Int(port), allowLAN: false)
                return (server, try await RawClient.connect(port: port, receiveBuffer: receiveBuffer))
            } catch { lastError = error; server.stop() }
        }
        throw lastError
    }

    /// A client that never finishes its headers is unauthenticated and is closed after 3 s, even if it
    /// keeps the connection busy by trickling bytes (activity does not buy an unauthenticated client time).
    @Test(arguments: [false, true])
    func anUnauthenticatedClientIsClosedAfterThreeSeconds(trickle: Bool) async throws {
        let calls = Calls()
        let (server, client) = try await Self.serve { _ in calls.hit(); return HTTPResponse() }
        defer { server.stop() }
        defer { client.close() }
        let start = ContinuousClock.now
        // A valid credential that is never followed by the blank line does not authenticate.
        client.send("POST /v1/speech?wait=true HTTP/1.1\r\nAuthorization: \(Self.token)\r\n")
        let trickler = Task.detached {
            while trickle, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { client.send("X") } }
        }
        let result = await client.waitForClose(since: start, limit: .seconds(8))
        trickler.cancel(); await trickler.value   // never write to the descriptor after it is closed
        let closed = try #require(result.closedAfter, "an unauthenticated connection outlived 8 s")
        #expect(closed >= 2.9 && closed < 5.5, "closed after \(closed) s")
        #expect(result.bytes == 0)
        #expect(calls.count == 0)
    }

    /// Authenticated headers with a body that never finishes: the request is not complete, so it is not
    /// being answered, and the 10 s idle limit still applies. (`?wait=` must not exempt a half-sent request.)
    @Test func aHalfSentAuthenticatedRequestIsClosedAfterTheIdleLimit() async throws {
        let calls = Calls()
        let (server, client) = try await Self.serve { _ in calls.hit(); return HTTPResponse() }
        defer { server.stop() }
        defer { client.close() }
        let start = ContinuousClock.now
        client.send("POST /v1/speech?wait=30 HTTP/1.1\r\nAuthorization: \(Self.token)\r\nContent-Length: 100\r\n\r\n{\"voice\":")
        let result = await client.waitForClose(since: start, limit: .seconds(16))
        let closed = try #require(result.closedAfter, "a half-sent request outlived 16 s")
        #expect(closed >= 9.9 && closed < 12.5, "closed after \(closed) s")
        #expect(result.bytes == 0)
        #expect(calls.count == 0)
    }

    /// A complete, authorized request whose answer takes longer than the idle limit is answered.
    /// (The same property is pinned over HTTP by TLSTransportTests; this uses the raw socket and a
    /// slower route so the reply lands well past the 10 s idle mark.)
    @Test func aCompleteRequestIsAnsweredPastTheIdleLimit() async throws {
        let (server, client) = try await Self.serve { request in
            try? await Task.sleep(for: .seconds(11))
            return HTTPResponse(body: Data("done \(request.query["wait"] ?? "-")".utf8))
        }
        defer { server.stop() }
        defer { client.close() }
        let start = ContinuousClock.now
        client.send("GET /v1/jobs/x?wait=true HTTP/1.1\r\nAuthorization: \(Self.token)\r\n\r\n")
        let result = await client.waitForClose(since: start, limit: .seconds(16))
        let closed = try #require(result.closedAfter)
        #expect(closed >= 10.9, "closed after \(closed) s")
        #expect(result.bytes > 0)
    }

    /// The idle exemption covers Chatter preparing a reply, not a client that stops reading one. A
    /// download whose client never reads stalls the server's writes; that connection must still be
    /// closed by the idle limit rather than holding one of the 128 authenticated slots for 120 s.
    ///
    /// Oracle: after the stall the client drains its socket. A connection the server gave up on ends
    /// after the few hundred KB already in flight; one it kept open delivers the whole file. TCP
    /// zero-window probes (about 5 s, then backing off) can let one more chunk through and restart the
    /// idle clock, so the stall is long enough to cover a second probe (closure by about 26 s).
    /// Regression: setting `answering` for the whole response kept this connection open (whole file).
    @Test func aClientThatStopsReadingADownloadIsClosedAfterTheIdleLimit() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stalled-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = scratch.appending(path: "speech.wav")
        let size = 64 << 20
        FileManager.default.createFile(atPath: audio.path, contents: nil)
        let handle = try FileHandle(forWritingTo: audio)
        try handle.truncate(atOffset: UInt64(size)); try handle.close()   // sparse: no real disk use
        let (server, client) = try await Self.serve(receiveBuffer: 4096) { _ in
            var response = HTTPResponse(contentType: "audio/wav")
            response.fileURL = audio
            return response
        }
        defer { server.stop() }
        defer { client.close() }
        let start = ContinuousClock.now
        client.send("GET /v1/jobs/x/audio HTTP/1.1\r\nAuthorization: \(Self.token)\r\n\r\n")
        try await Task.sleep(for: .seconds(28))   // never read: the server's writes stall
        let result = await client.waitForClose(since: start, limit: .seconds(40))
        #expect(result.closedAfter != nil)
        #expect(result.bytes > 0 && result.bytes < size / 8, "the stalled download was kept open (\(result.bytes) of \(size) bytes delivered)")
    }
}

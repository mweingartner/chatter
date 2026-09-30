import Foundation
import Network
import os
import Testing
@testable import ChatterCore

/// The Ollama client's total deadline, cancellation and redirect refusal, against a stub that never
/// answers and against real loopback servers (one that trickles its reply so the connection is never
/// idle, and one that redirects). In the serialized `OllamaClientTests` suite with the other client tests.
extension OllamaClientTests {
    /// A URL protocol that never answers, and counts how often a request was started and stopped.
    final class Hanging: URLProtocol {
        static let counts = OSAllocatedUnfairLock(initialState: (started: 0, stopped: 0))
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.counts.withLock { $0.started += 1 } }
        override func stopLoading() { Self.counts.withLock { $0.stopped += 1 } }
    }

    static func hangingClient() throws -> OllamaClient {
        Hanging.counts.withLock { $0 = (0, 0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Hanging.self]
        return try OllamaClient(session: URLSession(configuration: configuration))
    }

    /// Waits up to `limit` for `condition`, polling.
    static func eventually(within limit: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: The deadline

    /// A fast reply wins the race, and the client does not wait out the timeout it was given.
    @Test func aFastReplyWinsAndReturnsAtOnce() async throws {
        let client = try Self.client { _ in (200, Data(#"{"message":{"content":"{\"notes\":[]}"}}"#.utf8)) }
        let start = ContinuousClock.now
        let reply = try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(60))
        #expect(String(decoding: reply, as: UTF8.self) == #"{"notes":[]}"#)
        #expect(ContinuousClock.now - start < .seconds(2))
        // A zero or negative timeout still leaves half a second, so a fast server is heard.
        #expect(try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .zero).count == 12)
        #expect(try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(-3)).count == 12)
        #expect(Stub.requests.last?.timeoutInterval == 0.5)
    }

    /// A server that never answers is abandoned at the timeout (at least half a second), never later,
    /// and the abandoned request is stopped rather than left running.
    @Test(arguments: [(Duration.milliseconds(1), Duration.milliseconds(450)), (.milliseconds(800), .milliseconds(750))])
    func aSilentServerIsAbandonedAtTheTimeout(timeout: Duration, atLeast: Duration) async throws {
        let client = try Self.hangingClient()
        let start = ContinuousClock.now
        await #expect(throws: OllamaError.timedOut) {
            try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: false, timeout: timeout)
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= atLeast && elapsed < .seconds(2), "\(elapsed)")
        #expect(await Self.eventually { Hanging.counts.withLock { $0.stopped } == 1 })
        #expect(Hanging.counts.withLock { $0.started } == 1)
    }

    /// Cancelling the caller cancels the request: the call ends promptly as a cancellation (not a
    /// timeout or a failure) and the request is stopped.
    @Test func cancellingTheCallerCancelsTheRequest() async throws {
        let client = try Self.hangingClient()
        let start = ContinuousClock.now
        let call = Task { try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: false, timeout: .seconds(30)) }
        #expect(await Self.eventually { Hanging.counts.withLock { $0.started } == 1 })
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await Self.eventually { Hanging.counts.withLock { $0.stopped } == 1 })
    }

    /// A review whose model never answers ends out of time within its budget, through the real client.
    @Test func aReviewAgainstASilentServerEndsOutOfTime() async throws {
        let client = try Self.hangingClient()
        let start = ContinuousClock.now
        let outcome = await ExpressionReview.run("Hello there. How are you?", budget: .seconds(1)) { sentences, left in
            let reply = try await client.chat(model: "m", instructions: "", prompt: ExpressionReview.prompt(sentences),
                                              schema: ExpressionReview.schema, think: false, timeout: left)
            return ExpressionReview.notes(in: reply, count: sentences.count)
        }
        #expect(outcome.stop == .outOfTime && outcome.plan.isEmpty && outcome.reviewed == 0 && outcome.total == 2)
        #expect(outcome.editorMessage == "No notes were added: the model did not finish in time.")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// A real server that keeps sending a byte at a time is never idle, so a request's own timeout never
    /// fires; the total deadline still ends the call on time.
    @Test func aTricklingServerCannotHoldTheCallPastItsTimeout() async throws {
        let server = try await TricklingServer.start(every: .milliseconds(100))
        defer { server.stop() }
        let client = try OllamaClient(address: server.baseURL)
        let start = ContinuousClock.now
        let call = Task { try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: false, timeout: .seconds(1)) }
        // A watchdog, so a client without a total deadline fails this test (as a cancellation) instead of hanging it.
        let watchdog = Task { try await Task.sleep(for: .seconds(5)); call.cancel() }
        defer { watchdog.cancel() }
        let result = await call.result
        #expect(throws: OllamaError.timedOut) { try result.get() }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(900) && elapsed < .seconds(3), "\(elapsed)")
        // The server was still sending when the client gave up, then saw the connection closed.
        #expect(server.sent >= 3)
        #expect(await Self.eventually { server.closed })
    }

    // MARK: Redirects

    /// A redirect is never followed: the target receives nothing and the redirect reads as a server error.
    @Test(arguments: [301, 302, 303, 307, 308])
    func redirectsAreNeverFollowed(status: Int) async throws {
        let target = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: Data(#"{"version":"9.9.9","models":[]}"#.utf8)) }
        defer { target.stop() }
        let redirector = try await MockHTTPServer.start { request in
            MockResponse(status: status, headers: ["Location": target.baseURL + request.path])
        }
        defer { redirector.stop() }
        let client = try OllamaClient(address: redirector.baseURL)
        await #expect(throws: OllamaError.server("HTTP \(status)")) { try await client.version() }
        await #expect(throws: OllamaError.server("HTTP \(status)")) { try await client.localModels() }
        // A chat is not a missing model just because it was redirected.
        await #expect(throws: OllamaError.server("HTTP \(status)")) {
            try await client.chat(model: "m", instructions: "", prompt: "Secret text.", schema: ExpressionReview.schema, think: nil, timeout: .seconds(5))
        }
        #expect(target.requests.isEmpty)
        #expect(redirector.requests.map(\.path) == ["/api/version", "/api/tags", "/api/chat"])
    }

    /// The same holds for a client given its own session: every request carries the refusal.
    @Test func redirectsAreRefusedWhateverTheSession() async throws {
        let target = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: Data(#"{"version":"1"}"#.utf8)) }
        defer { target.stop() }
        let redirector = try await MockHTTPServer.start { _ in MockResponse(status: 307, headers: ["Location": target.baseURL + "/api/version"]) }
        defer { redirector.stop() }
        let client = try OllamaClient(address: redirector.baseURL, session: URLSession(configuration: .ephemeral))
        await #expect(throws: OllamaError.server("HTTP 307")) { try await client.version() }
        #expect(target.requests.isEmpty)
        // The same server answering directly is read normally.
        #expect(try await OllamaClient(address: target.baseURL).version() == "1")
    }

    @Test func theDefaultSessionIgnoresProxiesAndIsOnlyForOllama() throws {
        let configuration = OllamaClient.directSession.configuration
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCache == nil || configuration.urlCache?.diskCapacity == 0)
        #expect(try OllamaClient().session === OllamaClient.directSession)
        #expect(OllamaClient.directSession !== URLSession.shared)
    }

    // MARK: Missing models

    /// Only a chat can report a missing model; a 404 elsewhere is a server error.
    @Test func a404WithoutAModelIsAServerError() async throws {
        let client = try Self.client { _ in (404, Data()) }
        await #expect(throws: OllamaError.server("HTTP 404")) { try await client.version() }
        await #expect(throws: OllamaError.server("HTTP 404")) { try await client.localModels() }
        await #expect(throws: OllamaError.modelMissing("m")) {
            try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(2))
        }
        await #expect(throws: OllamaError.modelMissing("m")) { try await client.load(model: "m") }
    }

    @Test func missingModelWordsAreMatchedInAnyCaseAndOrder() async throws {
        for (message, expected) in [("Model 'x' NOT FOUND", OllamaError.modelMissing("x")), ("not found: model x", .modelMissing("x")),
                                    ("model is loading", .server("model is loading")), ("not found", .server("not found")),
                                    ("route not found", .server("route not found"))] {
            let client = try Self.client { _ in (500, Self.json(["error": message])) }
            await #expect(throws: expected) {
                try await client.chat(model: "x", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(2))
            }
        }
    }
}

/// A loopback HTTP server that answers every request with headers at once and then one byte of body at a
/// time, forever, so the connection is never idle. Records how many bytes it sent and whether the client
/// closed the connection.
final class TricklingServer: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let state: OSAllocatedUnfairLock<(sent: Int, closed: Bool)>

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var sent: Int { state.withLock { $0.sent } }
    var closed: Bool { state.withLock { $0.closed } }

    private init(listener: NWListener, port: UInt16, state: OSAllocatedUnfairLock<(sent: Int, closed: Bool)>) {
        self.listener = listener; self.port = port; self.state = state
    }

    static func start(every interval: Duration) async throws -> TricklingServer {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "TricklingServer")
        let state = OSAllocatedUnfairLock(initialState: (sent: 0, closed: false))
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { update in
                switch update { case .failed, .cancelled: state.withLock { $0.closed = true }; default: break }
            }
            connection.start(queue: queue)
            @Sendable func trickle() {
                connection.send(content: Data(" ".utf8), completion: .contentProcessed { error in
                    if error != nil { state.withLock { $0.closed = true }; connection.cancel(); return }
                    state.withLock { $0.sent += 1 }
                    queue.asyncAfter(deadline: .now() + seconds) { trickle() }
                })
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, _ in
                // Whatever the request, a JSON reply of a million bytes starts at once and never finishes in time.
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n"
                if data == nil, isComplete { connection.cancel(); return }
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in trickle() })
                // Read (and ignore) the rest of the request, noticing when the client closes its side.
                @Sendable func drain() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, isComplete, error in
                        if isComplete || error != nil { state.withLock { $0.closed = true }; connection.cancel() } else { drain() }
                    }
                }
                drain()
            }
        }
        let pending = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            pending.withLock { $0 = continuation }
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready: pending.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): pending.withLock { $0.take() }?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return TricklingServer(listener: listener, port: port, state: state)
    }

    func stop() { listener.cancel() }
}

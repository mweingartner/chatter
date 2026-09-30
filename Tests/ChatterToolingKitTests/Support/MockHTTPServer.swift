// Chatter integration tooling (Swift replacement for the former Python helpers).
import ChatterToolingKit
import Foundation
import Network
import os

/// One HTTP request as the mock server received it (header names lowercased).
struct MockRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var json: JSONValue? { try? JSONValue.parse(body) }
}

/// A canned HTTP response.
struct MockResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ value: JSONValue, status: Int = 200) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(value.encoded().utf8))
    }

    static func empty(_ status: Int) -> MockResponse { MockResponse(status: status) }
}

/// A loopback HTTP/1.1 server on an ephemeral port (Network framework). Every response closes its connection.
final class MockHTTPServer: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let log: OSAllocatedUnfairLock<[MockRequest]>

    var baseURL: String { "http://127.0.0.1:\(port)" }
    /// Every request received so far, in arrival order.
    var requests: [MockRequest] { log.withLock { $0 } }

    private init(listener: NWListener, port: UInt16, log: OSAllocatedUnfairLock<[MockRequest]>) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    static func start(_ handler: @escaping @Sendable (MockRequest) async -> MockResponse) async throws -> MockHTTPServer {
        let parameters = NWParameters.tcp
        // Ephemeral port, reachable only over the loopback interface.
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "MockHTTPServer")
        let log = OSAllocatedUnfairLock(initialState: [MockRequest]())
        // NWListener refuses to start (EINVAL) without a connection handler, so install it first.
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receive(connection, Data()) { request in
                log.withLock { $0.append(request) }
                return await handler(request)
            }
        }
        let pending = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            pending.withLock { $0 = continuation }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): pending.withLock { $0.take() }?.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return MockHTTPServer(listener: listener, port: port, log: log)
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private static func receive(
        _ connection: NWConnection, _ buffer: Data, handler: @escaping @Sendable (MockRequest) async -> MockResponse
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let request = parse(buffer) {
                Task {
                    let response = await handler(request)
                    connection.send(content: serialize(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(connection, buffer, handler: handler)
            }
        }
    }

    private static func parse(_ buffer: Data) -> MockRequest? {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = head[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return MockRequest(
            method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private static func serialize(_ response: MockResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + response.body
    }
}

import Foundation
import Network
import ChatterCore

@MainActor
final class HTTPServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    var onError: ((String) -> Void)?
    var route: ((HTTPRequest) async -> HTTPResponse)?
    private let queue = DispatchQueue(label: "com.chatter.network") // Network.framework requires a callback queue; state stays on MainActor.

    func start(port: Int, allowLAN: Bool) throws {
        stop()
        guard (1024...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ChatterError.invalid("Choose a port from 1024 to 65535.") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !allowLAN { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort) }
        // A fixed requiredLocalEndpoint already supplies the port. Supplying it again
        // to NWListener is rejected with EINVAL on current macOS releases.
        let listener = try allowLAN ? NWListener(using: parameters, on: nwPort) : NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.onError?(error.localizedDescription) } }
        }
        listener.start(queue: queue); self.listener = listener
    }
    func stop() { listener?.cancel(); listener = nil; for c in connections.values { c.cancel() }; connections.removeAll() }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 128 else {
            connection.start(queue: queue)
            let response = HTTPResponse(status: 503, body: Data("{\"error\":\"Connection capacity reached; retry with the same requestID\"}".utf8), headers: ["Retry-After":"1"])
            connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if let stale = self?.connections.removeValue(forKey: id) { stale.cancel() }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var next = buffer; if let data { next.append(data) }
                do {
                    if let (request, _) = try HTTPRequest.parse(next) {
                        let response = await self.route?(request) ?? HTTPResponse(status: 503)
                        self.send(response, to: connection, id: id)
                    } else if complete || error != nil { self.close(id) }
                    else { self.receive(connection, id: id, buffer: next) }
                } catch {
                    self.send(HTTPResponse(status: 400, body: Data("{\"error\":\"Invalid HTTP request\"}".utf8)), to: connection, id: id)
                }
            }
        }
    }
    private func send(_ response: HTTPResponse, to connection: NWConnection, id: UUID) {
        connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

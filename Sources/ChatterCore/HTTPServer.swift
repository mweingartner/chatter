import Foundation
import Network
import Security

/// Local HTTP and optional LAN HTTPS use independent admission pools. Unauthenticated
/// connections are evicted oldest-first, so a slow sender cannot permanently reserve a slot.
@MainActor
public final class HTTPServer {
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    public var onError: ((String) -> Void)?
    public var route: ((HTTPRequest) async -> HTTPResponse)?
    public var authorizeHeaders: ((HTTPRequest) -> HTTPResponse?)?
    private let queue = DispatchQueue(label: "com.chatter.network")
    private var local = true
    private struct Connection {
        let socket: NWConnection
        let peer: String
        let accepted: ContinuousClock.Instant
        var authenticated = false
        var activity = ContinuousClock.now
    }
    public init() {}

    public func start(port: Int, allowLAN: Bool, identity: SecIdentity? = nil) throws {
        stop()
        guard (1024...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ChatterError.invalid("Choose a port from 1024 to 65535.") }
        local = !allowLAN
        let parameters: NWParameters
        if allowLAN {
            guard let identity, let native = sec_identity_create(identity) else { throw ChatterError.invalid("LAN access requires a TLS identity.") }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, native)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else { parameters = .tcp }
        parameters.allowLocalEndpointReuse = true
        if !allowLAN { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort) }
        let listener = try allowLAN ? NWListener(using: parameters, on: nwPort) : NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.onError?(error.localizedDescription) } }
        }
        listener.start(queue: queue); self.listener = listener
    }
    public func stop() {
        listener?.cancel(); listener = nil
        for entry in connections.values { entry.socket.cancel() }
        connections.removeAll()
    }
    private func accept(_ socket: NWConnection) {
        let peer: String
        if case .hostPort(let host, _) = socket.endpoint { peer = "\(host)" } else { socket.cancel(); return }
        let waiting = connections.filter { !$0.value.authenticated }
        let samePeer = waiting.filter { $0.value.peer == peer }
        if samePeer.count >= 4, let oldest = samePeer.min(by: { $0.value.accepted < $1.value.accepted }) { close(oldest.key) }
        else if waiting.count >= 32, let oldest = waiting.min(by: { $0.value.accepted < $1.value.accepted }) { close(oldest.key) }
        guard connections.count < 160 else { socket.cancel(); return }
        let id = UUID()
        connections[id] = Connection(socket: socket, peer: peer, accepted: .now)
        socket.start(queue: queue)
        receive(socket, id: id, buffer: Data())
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let entry = self.connections[id] else { return }
                let age = ContinuousClock.now - entry.accepted
                if (!entry.authenticated && age > .seconds(3)) || age > .seconds(120) || ContinuousClock.now - entry.activity > .seconds(10) {
                    self.close(id); return
                }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var next = buffer; if let data { next.append(data) }
                self.connections[id]?.activity = .now
                do {
                    if self.connections[id]?.authenticated == false,
                       var header = try HTTPRequest.parse(next, headersOnly: true)?.0 {
                        header.isLocal = self.local
                        guard let authorize = self.authorizeHeaders else { self.send(HTTPResponse(status: 503), to: connection, id: id); return }
                        if let rejection = authorize(header) { self.send(rejection, to: connection, id: id); return }
                        guard self.connections.values.filter(\.authenticated).count < 128 else {
                            self.send(HTTPResponse(status: 503, headers: ["Retry-After":"1"]), to: connection, id: id); return
                        }
                        self.connections[id]?.authenticated = true
                    }
                    if var request = try HTTPRequest.parse(next)?.0 {
                        request.isLocal = self.local
                        let response = await self.route?(request) ?? HTTPResponse(status: 503)
                        self.send(response, to: connection, id: id)
                    } else if complete || error != nil { self.close(id) }
                    else { self.receive(connection, id: id, buffer: next) }
                } catch { self.send(HTTPResponse(status: 400), to: connection, id: id) }
            }
        }
    }
    private func send(_ response: HTTPResponse, to connection: NWConnection, id: UUID) {
        guard let url = response.fileURL else {
            connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
            return
        }
        Task { [weak self] in
            defer { self?.close(id) }
            do {
                // Open and validate once. A path substitution cannot redirect subsequent chunks.
                let file = try await Task.detached { try DownloadFile(url: url) }.value
                defer { try? file.handle.close() }
                try await Self.write(response.head(contentLength: file.size), on: connection)
                var remaining = file.size
                while remaining > 0, self?.connections[id] != nil {
                    let count = min(65_536, remaining)
                    let chunk = try await Task.detached { try file.handle.read(upToCount: count) ?? Data() }.value
                    guard !chunk.isEmpty else { return }
                    try await Self.write(chunk, on: connection)
                    remaining -= chunk.count; self?.connections[id]?.activity = .now
                }
            } catch { connection.cancel() }
        }
    }
    private static func write(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.socket.cancel() }
}

private struct DownloadFile: Sendable {
    let handle: FileHandle
    let size: Int
    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChatterError.invalid("Audio is unavailable.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1_000_000_000 else {
            close(fd); throw ChatterError.invalid("Invalid audio file.")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); size = Int(info.st_size)
    }
}

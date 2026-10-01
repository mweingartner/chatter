import Foundation
import AppKit
import ChatterCore

extension AppModel {
    func access(for request: HTTPRequest) -> ClientAccess? {
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer ") else { return nil }
        if request.isLocal, authorized(request) { return ClientAccess() }
        let token = String(authorization.dropFirst(7))
        guard token.utf8.count <= 256, let client = clients.first(where: { $0.matches(token) }) else { return nil }
        return ClientAccess(client: client)
    }
    func rejectHeaders(_ request: HTTPRequest) -> HTTPResponse? {
        if request.headers["origin"] != nil { return json(["error":"Browser origins are not enabled."], status: 403) }
        guard access(for: request) != nil else { return HTTPResponse(status: 401, headers: ["WWW-Authenticate":"Bearer"]) }
        return nil
    }
    func createClient(name: String, scopes: Set<ClientScope>, voiceIDs: Set<String>, days: Int) throws -> String {
        guard clients.filter({ !$0.revoked && $0.expiresAt > .now }).count < 100 else { throw ChatterError.invalid("Remove an unused client before creating another.") }
        let (client, secret) = try ClientCredential.create(name: name, scopes: scopes, voiceIDs: voiceIDs, days: days)
        var updated = clients.filter { !$0.revoked && $0.expiresAt > .now }; updated.append(client)
        try ChatterPaths.save(updated, to: ChatterPaths.root.appending(path: "clients.json")); clients = updated
        return secret
    }
    func revokeClient(_ id: String) {
        do {
            var updated = clients
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].revoked = true }
            try ChatterPaths.save(updated, to: ChatterPaths.root.appending(path: "clients.json")); clients = updated
            for job in jobs where job.clientID == id && !job.isTerminal { cancelJob(job.id) }
        } catch { self.error = error.localizedDescription }
    }
    func job(id: String, access: ClientAccess) throws -> SpeechJob? {
        let result = try jobs.first(where: { $0.id == id }) ?? history?.find(id: id)
        return result.flatMap { access.canRead($0) ? $0 : nil }
    }
    func copyFingerprint() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tlsFingerprint, forType: .string)
        notice = "Certificate fingerprint copied. Verify it on each LAN client."
    }
    func replaceLANIdentity() {
        do {
            lanServer.stop()
            let directory = ChatterPaths.root.appending(path: "TLS")
            // The directory contains only Chatter's generated identity pair.
            for name in ["identity-key.bin", "identity.der"] {
                let file = directory.appending(path: name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            applyNetwork()
            notice = "LAN identity replaced. Update the fingerprint on connected clients."
        } catch { self.error = error.localizedDescription }
    }
}

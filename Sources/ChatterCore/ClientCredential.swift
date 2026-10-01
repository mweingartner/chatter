import Foundation
import CryptoKit
import Security

public enum ClientScope: String, Codable, CaseIterable, Sendable { case read, speak, cancel }

public struct ClientCredential: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let digest: String
    public let scopes: Set<ClientScope>
    /// Empty means all saved voices. Explicit IDs remain fixed when voices are added.
    public let voiceIDs: Set<String>
    public let expiresAt: Date
    public var revoked = false

    public static func create(name: String, scopes: Set<ClientScope>, voiceIDs: Set<String> = [], days: Int = 90, now: Date = .now) throws -> (ClientCredential, String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 100, !scopes.isEmpty, (1...365).contains(days) else {
            throw ChatterError.invalid("Name the client, choose permissions and an expiry between 1 and 365 days.")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatterError.unavailable("Cannot generate client token.") }
        let token = Data(bytes).base64EncodedString()
        return (ClientCredential(id: UUID().uuidString, name: label, digest: hash(token), scopes: scopes, voiceIDs: voiceIDs, expiresAt: now.addingTimeInterval(Double(days) * 86400)), token)
    }
    public func matches(_ token: String, now: Date = .now) -> Bool {
        guard !revoked, now < expiresAt else { return false }
        let a = Array(digest.utf8), b = Array(Self.hash(token).utf8)
        return a.count == b.count && zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public struct ClientAccess: Sendable {
    public let client: ClientCredential?
    public init(client: ClientCredential? = nil) { self.client = client }
    public var ownerID: String? { client?.id }
    public func allows(_ scope: ClientScope) -> Bool { client == nil || client!.scopes.contains(scope) }
    public func canRead(_ job: SpeechJob) -> Bool { client == nil || job.clientID == client?.id }
    public func allowsVoice(_ id: String) -> Bool { client == nil || client!.voiceIDs.isEmpty || client!.voiceIDs.contains(id) }
}

/// Fixed-window admission counters bounded by the number of configured credentials.
public struct ClientRateLimiter {
    private var windows: [String: (start: Date, count: Int)] = [:]
    public init() {}
    public mutating func allow(_ id: String, limit: Int, now: Date = .now) -> Bool {
        windows = windows.filter { now.timeIntervalSince($0.value.start) < 60 }
        var value = windows[id] ?? (now, 0)
        guard value.count < limit else { return false }
        value.count += 1; windows[id] = value; return true
    }
}

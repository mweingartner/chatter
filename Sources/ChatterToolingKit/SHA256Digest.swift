// Chatter integration tooling (Swift replacement for the former Python helpers).
import CryptoKit
import Foundation

/// Streaming SHA-256 used for content-addressed Remotion asset names.
public enum SHA256Digest {
    /// Lowercase hex digest of the file at `url`, read in 1 MiB blocks.
    public static func file(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

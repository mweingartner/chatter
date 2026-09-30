import Foundation

/// Where the engine may read and write. The app is the only client, but paths are still checked
/// so a compromised or buggy client cannot make the engine touch files outside Chatter's data.
enum PathPolicy {
    /// Canonical absolute path: symlinks resolved on the deepest existing ancestor; `..`, `.` and
    /// dangling links rejected.
    static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw EngineFailure.invalid("Paths must be absolute.") }
        let components = URL(filePath: path).pathComponents
        guard !components.contains(".."), !components.contains(".") else { throw EngineFailure.invalid("Paths may not contain relative components.") }
        var existing = URL(filePath: path)
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            // A dangling symbolic link is not a pending name: where it leads is decided elsewhere.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: existing.path)) != nil {
                throw EngineFailure.invalid("Cannot resolve \(existing.path).")
            }
            remainder.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { throw EngineFailure.invalid("Cannot resolve \(existing.path).") }
        defer { free(resolved) }
        return ([String(cString: resolved)] + remainder).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    static func isInside(_ path: String, directory: String) throws -> Bool {
        let root = try canonical(directory)
        return try canonical(path).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

import Foundation

/// A process-level defense-in-depth policy, separate from Apple's App Sandbox entitlement.
/// The helper has no reason to access credentials, connect to a network, or write outside
/// its media/cache directories. The parent stages imports and publishes completed exports.
public enum EngineSandbox {
    public static func profile(root: URL, bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, temporary: URL? = nil) -> String {
        let temporary = temporary ?? root.appending(path: "EngineCache/Temporary")
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        func subpath(_ url: URL) -> String { "(subpath " + quoted(canonicalPath(url)) + ")" }
        let read = [bundle, root.appending(path: "Models"), root.appending(path: "Voices"), root.appending(path: "Jobs"), root.appending(path: "EngineCache"), home.appending(path: "Library/Caches"), temporary]
        let write = [root.appending(path: "Voices"), root.appending(path: "Jobs"), root.appending(path: "Logs"), root.appending(path: "EngineCache"), home.appending(path: "Library/Caches"), temporary]
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read-data \(subpath(home)))
        (deny file-read-data \(subpath(root)))
        (allow file-read-data \(read.map(subpath).joined(separator: " ")))
        (deny file-write*)
        (allow file-write* \(write.map(subpath).joined(separator: " ")) (literal "/dev/null"))
        """
    }

    /// Seatbelt matches kernel paths. Foundation can normalize /private/var back to /var,
    /// even after resolving symlinks, which would silently miss both allow and deny rules.
    /// Resolve the nearest existing ancestor with realpath, retaining not-yet-created leaves.
    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var leaves: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + leaves.reversed()).joined(separator: "/")
            }
            guard ancestor.path != "/" else { return url.path }
            leaves.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}

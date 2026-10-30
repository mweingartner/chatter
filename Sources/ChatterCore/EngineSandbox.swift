import Foundation

/// A process-level defense-in-depth policy, separate from Apple's App Sandbox entitlement.
/// The helper has no reason to access credentials, connect to a network, or write outside
/// its media/cache directories. The parent stages imports and publishes completed exports.
///
/// It also may not start other programs. A child it executes would inherit this policy, but
/// Launch Services and launchd start processes as children of launchd, outside it, so asking
/// either one to run something would sidestep every rule here. `executable` is the one binary
/// sandbox-exec may run; nothing else can be forked, executed, opened, submitted or scripted.
///
/// Nor may it leave anything an unsandboxed program will later trust. cfprefsd writes preferences
/// on the caller's behalf, beyond the file rules. Shared caches under ~/Library/Caches hold build
/// output and updates that other tools run. The parent opens the engine log and passes it in as
/// stderr, so the engine needs no access to Logs, where a planted link would redirect the parent.
public enum EngineSandbox {
    public static func profile(root: URL, bundle: URL, executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, temporary: URL? = nil) -> String {
        let temporary = temporary ?? root.appending(path: "EngineCache/Temporary")
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        func subpath(_ url: URL) -> String { "(subpath " + quoted(canonicalPath(url)) + ")" }
        let read = [bundle, root.appending(path: "Models"), root.appending(path: "Voices"), root.appending(path: "Jobs"), root.appending(path: "EngineCache"), temporary]
        let write = [root.appending(path: "Voices"), root.appending(path: "Jobs"), root.appending(path: "EngineCache"), temporary]
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-fork)
        (deny process-exec*)
        (allow process-exec (literal \(quoted(canonicalPath(executable)))))
        (deny lsopen)
        (deny job-creation)
        (deny appleevent-send)
        (deny user-preference-write)
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

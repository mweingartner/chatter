import Foundation

/// Prevent two current app processes from migrating or draining the same data directory.
public final class InstanceLock {
    private let descriptor: Int32
    public init(root: URL) throws {
        let fd = open(root.appending(path: ".instance-lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatterError.unavailable("Cannot lock Chatter's data directory.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ChatterError.unavailable("Chatter is already running with this data directory.") }
        descriptor = fd
    }
    deinit { close(descriptor) }
}

import Foundation

/// Owner-only files from creation, including temporary files. Never follows a destination symlink.
public enum PrivateStorage {
    public static func directory(_ url: URL, repair: Bool = true) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChatterError.invalid("Private storage must be a real directory.") }
        defer { close(descriptor) }
        if repair, fchmod(descriptor, 0o700) != 0 { throw ChatterError.unavailable("Cannot protect private storage.") }
    }

    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".private-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatterError.unavailable("Cannot create private file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw ChatterError.unavailable("Cannot save private file.") }
    }

    /// Opens `url` for appending, never through a link. Anything else at that name (a symlink, a file
    /// with other hard links, a FIFO) is removed, never what it points to, and a fresh file started:
    /// what is written there would otherwise land in a file the writer was never meant to reach.
    public static func appendHandle(_ url: URL) throws -> FileHandle {
        for _ in 0..<2 {
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            if fd >= 0 {
                var info = stat()
                if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, fchmod(fd, 0o600) == 0, fcntl(fd, F_SETFL, O_APPEND) == 0 {
                    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                }
                close(fd)
            }
            guard unlink(url.path) == 0 else { break }
        }
        throw ChatterError.unavailable("Cannot open a private log file.")
    }

    /// Up to the last `limit` bytes of a regular file, never read through a link.
    public static func tail(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChatterError.unavailable("Cannot read private file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ChatterError.invalid("Private storage requires a regular file.") }
        try handle.seek(toOffset: UInt64(max(0, Int64(info.st_size) - Int64(limit))))
        return try handle.readToEnd() ?? Data()
    }

    public static func protectFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChatterError.invalid("Cannot protect file.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
            throw ChatterError.invalid("Private storage requires a regular file.")
        }
    }
}

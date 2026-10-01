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

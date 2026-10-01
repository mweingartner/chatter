import Foundation

extension ModelInstaller {
    /// Rehash only files whose inode/size/mtime/ctime changed. The cache is private and never
    /// substitutes for the pinned manifest when a model is downloaded or changes on disk.
    public func verifyInstalled(integrityCacheURL: URL? = nil) async throws {
        struct Stamp: Codable, Equatable {
            let device: Int32
            let inode: UInt64
            let size: Int64
            let modified: Int64
            let modifiedNanos: Int64
            let changed: Int64
            let changedNanos: Int64
            let expected: String
        }
        func stamp(_ file: ModelFile) throws -> Stamp {
            var value = stat()
            guard stat(url(file).path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size == file.size else { throw ModelInstallerError.integrity(file.destination) }
            return Stamp(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                         modified: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                         changed: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec), expected: file.sha256)
        }
        let cacheURL = integrityCacheURL ?? modelsRoot.appending(path: ".verified-models.json")
        let cached = (try? ChatterPaths.load([String: Stamp].self, from: cacheURL)) ?? [:]
        var checked: [String: Stamp] = [:]
        for file in files {
            try Task.checkCancellation()
            let before = try stamp(file)
            if cached[file.destination] != before {
                guard try await hash(of: url(file)) == file.sha256, try stamp(file) == before else { throw ModelInstallerError.integrity(file.destination) }
            }
            checked[file.destination] = before
        }
        try ChatterPaths.save(checked, to: cacheURL)
    }
}

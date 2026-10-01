import Foundation

public enum AudioStorage {
    public static func managedBytes(output: URL, jobs: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var total: Int64 = 0
        var count = 0
        for directory in Set([output.standardizedFileURL, jobs.standardizedFileURL]) {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                let info = try url.resourceValues(forKeys: keys)
                if directory == output.standardizedFileURL { files.skipDescendants() }
                guard info.isSymbolicLink != true, info.isRegularFile == true else { continue }
                if directory == output.standardizedFileURL, !isExport(url) { continue }
                count += 1
                guard count <= 10000 else { throw ChatterError.unavailable("Chatter contains 10,000 generated files. Remove unneeded audio before submitting more jobs.") }
                total += Int64(info.fileSize ?? 0)
            }
        }
        return total
    }
    public static func removeAudio(for job: SpeechJob, output: URL, jobs: URL, deleteExports: Bool = false) throws {
        guard job.isTerminal, UUID(uuidString: job.id) != nil else { return }
        if deleteExports, let path = job.path {
            let url = URL(filePath: path)
            // Never delete an arbitrary path from a receipt, a renamed export, or a user's copy.
            if url.lastPathComponent == "Chatter-\(job.id).wav",
               url.deletingLastPathComponent().resolvingSymlinksInPath() == output.resolvingSymlinksInPath() {
                try removeIfPresent(url)
            }
        }
        try removeIfPresent(jobs.appending(path: job.id))
    }
    public static func isExport(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == "wav" && name.hasPrefix("Chatter-") && UUID(uuidString: String(name.dropFirst(8))) != nil
    }
    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { }
    }
}

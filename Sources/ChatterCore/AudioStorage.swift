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
    /// Removes the working folder of each finished `render` job whose audio was written more than
    /// `SpeechMode.renderRetention` ago, and returns their IDs so receipts stop offering the audio.
    /// A render whose audio is already gone is reported too. Other modes are never touched.
    public static func removeExpiredRenders(_ candidates: [SpeechJob], jobs: URL, now: Date = .now) throws -> [String] {
        var expired: [String] = []
        for job in candidates where job.request.mode == SpeechMode.render.rawValue && job.isTerminal && job.path != nil {
            guard UUID(uuidString: job.id) != nil else { continue }
            let directory = jobs.appending(path: job.id)
            let audio = directory.appending(path: "speech.wav")
            let written = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate]) as? Date
            if let written, now.timeIntervalSince(written) < SpeechMode.renderRetention { continue }
            try removeIfPresent(directory)
            expired.append(job.id)
        }
        return expired
    }
    /// Whether a finished job's audio may still be offered. Render audio is offered only
    /// while its file exists and is younger than `SpeechMode.renderRetention`, even if a
    /// sweep has not removed it yet; other modes keep their audio for normal retention.
    public static func offersAudio(_ job: SpeechJob, now: Date = .now) -> Bool {
        guard job.state == "completed", let path = job.path else { return false }
        guard job.request.mode == SpeechMode.render.rawValue else { return true }
        guard let written = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return false }
        return now.timeIntervalSince(written) < SpeechMode.renderRetention
    }
    public static func isExport(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == "wav" && name.hasPrefix("Chatter-") && UUID(uuidString: String(name.dropFirst(8))) != nil
    }
    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { }
    }
}

import Foundation

/// One atomically replaced, fsynced receipt per job. A failed write never acknowledges submission.
public struct JobStore: Sendable {
    public let directory: URL
    public init(directory: URL = ChatterPaths.root.appending(path: "Queue")) { self.directory = directory }
    public func save(_ job: SpeechJob) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: job.id + ".json")
        try ChatterPaths.save(job, to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    public func load() throws -> [SpeechJob] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        // Corruption must be visible, never treated as an empty queue.
        return try paths.map { try ChatterPaths.load(SpeechJob.self, from: $0) }.sorted { $0.sequence > $1.sequence }
    }
}

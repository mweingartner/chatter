import Foundation
import ChatterCore

extension AppModel {
    func prepareOutputDirectory() throws {
        let url = URL(filePath: settings.outputDirectory)
        let defaultURL = URL(filePath: Settings().outputDirectory)
        if url.standardizedFileURL == defaultURL.standardizedFileURL {
            try PrivateStorage.directory(defaultURL.deletingLastPathComponent())
            try PrivateStorage.directory(defaultURL)
        } else if !FileManager.default.fileExists(atPath: url.path) { try PrivateStorage.directory(url) }
    }
    func checkStorageBudget() throws {
        let output = URL(filePath: settings.outputDirectory)
        let values = try output.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let workingBytes = Int64(settings.maximumSpeechMinutes) * 60 * 24000 * 3 * 8
        guard (values.volumeAvailableCapacityForImportantUsage ?? 0) > workingBytes + 1_000_000_000 else {
            throw ChatterError.unavailable("Not enough free space for this job. Free disk space or lower the speech-duration limit.")
        }
        var used = try AudioStorage.managedBytes(output: output, jobs: ChatterPaths.jobs)
        for name in ["jobs.sqlite3", "jobs.sqlite3-wal"] {
            used += ((try? FileManager.default.attributesOfItem(atPath: ChatterPaths.root.appending(path: name).path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        guard used + workingBytes <= Int64(settings.storageLimitGB) * 1_000_000_000 else {
            throw ChatterError.unavailable("Chatter's audio storage limit is reached. Clean up finished jobs or increase the storage limit.")
        }
    }
    func trimHistory() {
        do {
            guard let history else { return }
            for job in try history.expired(days: settings.retentionDays, keep: settings.retainedJobLimit) {
                try AudioStorage.removeAudio(for: job, output: URL(filePath: settings.outputDirectory), jobs: ChatterPaths.jobs, deleteExports: settings.deleteExpiredAudio)
                try history.remove(id: job.id)
            }
            try history.checkpoint()
            let active = Dictionary(uniqueKeysWithValues: jobs.filter { !$0.isTerminal }.map { ($0.id, $0) })
            jobs = try history.recent(limit: settings.retainedJobLimit).map { active[$0.id] ?? $0 }
        } catch { self.error = "History cleanup: " + error.localizedDescription }
    }
    func startMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.trimHistory()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

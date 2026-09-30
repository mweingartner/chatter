// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// `verify queue` (formerly `verify-queue.py`): fills the installed app's 1,000-job queue from 12
/// concurrent clients while only Chatter's own engine is suspended, checks FIFO sequencing,
/// durable receipts, overflow (429) and retry de-duplication, then cancels every test job.
public struct QueueVerification: Sendable {
    public static let queueCapacity = 1000
    public static let concurrentClients = 12

    public let settings: VerificationSettings
    public let engine: any EngineSuspension

    public init(settings: VerificationSettings, engine: any EngineSuspension = ChatterEngineProcess()) {
        self.settings = settings
        self.engine = engine
    }

    public func run(output: any TextOutput) async throws {
        let api = try settings.makeClient()
        let health = try await api.json("/v1/health")
        try verify(health["queueDepth"] == 0, "Wait for user speech before this test.")
        try verify(health["queueCapacity"] == .int(Self.queueCapacity), "Expected a queue capacity of \(Self.queueCapacity).")
        guard let voice = try await api.json("/v1/voices")["voices"]?[0]?["id"] else {
            throw VerificationFailure("Chatter has no saved voices.")
        }
        let prefix = "queue-stress-\(wallClockNanoseconds())"
        let resumption = try engine.suspend()
        var failure: (any Error)?
        do {
            try await stress(api, voice: voice, prefix: prefix, output: output)
        } catch {
            failure = error
        }
        // Cancel every test job even if submission failed part-way, and always resume the engine.
        do {
            try await cancelTestJobs(api, prefix: prefix)
        } catch {
            failure = failure ?? error
        }
        do {
            try resumption.resume()
        } catch {
            failure = failure ?? error
        }
        if let failure { throw failure }
        try output.line("All queue stress jobs cancelled; worker resumed.")
    }

    private func stress(_ api: ChatterAPIClient, voice: JSONValue, prefix: String, output: any TextOutput) async throws {
        let start = ContinuousClock.now
        let receipts = try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            var receipts = [JSONValue](repeating: .null, count: Self.queueCapacity)
            var next = 0
            func submit(_ index: Int) {
                group.addTask {
                    let reply = try await api.call("/v1/speech", body: [
                        "voice": voice, "text": .string("Queue validation request \(index)."), "mode": "play",
                        "requestID": .string("\(prefix)-\(index)"),
                    ])
                    let body = reply.json ?? .null
                    try verify(reply.status == 202, "(\(reply.status), \(body.encoded()))")
                    return (index, body)
                }
            }
            while next < min(Self.concurrentClients, Self.queueCapacity) {
                submit(next)
                next += 1
            }
            while let (index, receipt) = try await group.next() {
                receipts[index] = receipt
                if next < Self.queueCapacity {
                    submit(next)
                    next += 1
                }
            }
            return receipts
        }
        let ids = receipts.map { $0["id"]?.stringValue ?? "" }
        try verify(Set(ids).count == Self.queueCapacity && !ids.contains(""), "Receipt IDs are not \(Self.queueCapacity) distinct jobs.")
        // IDs name files under Queue/; refuse anything that could leave that directory.
        try verify(ids.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") }, "A receipt ID is not a plain file name.")
        let sequences = receipts.compactMap { $0["sequence"]?.intValue }.sorted()
        try verify(sequences.count == Self.queueCapacity && sequences == Array(sequences[0]..<sequences[0] + Self.queueCapacity),
            "Receipt sequences are not contiguous FIFO order.")
        let overflow = try await api.call("/v1/speech", body: [
            "voice": voice, "text": "Overflow request.", "requestID": .string(prefix + "-overflow"),
        ])
        try verify(overflow.status == 429, "(\(overflow.status), \((overflow.json ?? .null).encoded()))")
        let again = try await api.call("/v1/speech", body: [
            "voice": voice, "text": "Queue validation request 0.", "mode": "play", "requestID": .string(prefix + "-0"),
        ])
        try verify(again.status == 202 && again.json?["id"] == .string(ids[0]), "A retried requestID was not de-duplicated.")
        let queue = settings.supportDirectory.appending(path: "Queue", directoryHint: .isDirectory)
        for (id, receipt) in zip(ids, receipts) {
            let file = queue.appending(path: id + ".json")
            let persisted = try JSONValue.parse(try Data(contentsOf: file))
            try verify(persisted["sequence"] == receipt["sequence"], "Durable receipt \(file.lastPathComponent) has a different sequence.")
        }
        let seconds = start.duration(to: .now)
        let elapsed = Double(seconds.components.seconds) + Double(seconds.components.attoseconds) / 1e18
        let summary: JSONValue = [
            "accepted": .int(receipts.count), "concurrentClients": .int(Self.concurrentClients), "seconds": .double(elapsed),
            "contiguousFIFOSequence": true, "durableReceipts": .int(Self.queueCapacity), "overflowStatus": .int(overflow.status),
            "retryDeduplicated": true,
        ]
        try output.line(summary.encoded())
    }

    /// Cancels every persisted job whose requestID carries this run's prefix.
    private func cancelTestJobs(_ api: ChatterAPIClient, prefix: String) async throws {
        let queue = settings.supportDirectory.appending(path: "Queue", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for file in files {
            let job = try JSONValue.parse(try Data(contentsOf: file))
            guard job["requestID"]?.stringValue?.hasPrefix(prefix) == true else { continue }
            _ = try await api.call("/v1/jobs/" + (try job.requiredString("id", "queued job")), method: "DELETE")
        }
    }
}

import Foundation
import CryptoKit
import Testing
@testable import ChatterCore

@Suite("Security state") struct SecurityStateTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try PrivateStorage.directory(root); return root
    }
    @Test func duplicateProcessesCannotShareTheQueue() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var lock: InstanceLock? = try InstanceLock(root: root)
        #expect(lock != nil)
        #expect(throws: (any Error).self) { try InstanceLock(root: root) }
        lock = nil
        let next = try InstanceLock(root: root)
        withExtendedLifetime(next) { }
    }
    @Test func legacyLANNeedsOptIn() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"allowLAN":true,"port":18423}"#.utf8))
        #expect(!old.allowLAN)
        var fresh = Settings(); #expect(!fresh.allowLAN); fresh.allowLAN = true
        let roundtrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(fresh))
        #expect(roundtrip.allowLAN)
        #expect(!fresh.deleteExpiredAudio)
    }
    @Test func credentialsExpireAndCannotReadAnotherClientsJobs() throws {
        let now = Date()
        var (client, token) = try ClientCredential.create(name: "Editor", scopes: [.read,.speak], voiceIDs: ["Ryan"], days: 1, now: now)
        #expect(client.matches(token, now: now))
        #expect(!client.matches("wrong", now: now))
        #expect(!client.matches(token, now: now.addingTimeInterval(86401)))
        let encoded = try JSONEncoder().encode(client)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(token))
        let access = ClientAccess(client: client)
        #expect(access.allows(.speak)); #expect(!access.allows(.cancel))
        #expect(access.allowsVoice("Ryan")); #expect(!access.allowsVoice("Private voice"))
        var job = SpeechJob(request: SpeechRequest(voice: "Ryan", text: "Test"), voiceName: "Ryan")
        #expect(!access.canRead(job)); job.clientID = client.id; #expect(access.canRead(job))
        client.revoked = true; #expect(!client.matches(token, now: now))
    }
    @Test func rateLimitHasAnIndependentBoundedWindow() {
        var limit = ClientRateLimiter(); let now = Date()
        let first = limit.allow("one", limit: 1, now: now)
        let repeated = limit.allow("one", limit: 1, now: now)
        let other = limit.allow("two", limit: 1, now: now)
        let renewed = limit.allow("one", limit: 1, now: now.addingTimeInterval(60))
        #expect(first); #expect(!repeated); #expect(other); #expect(renewed)
    }
    @Test func migrationPagingAndOwnerScopedRetries() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var original = SpeechJob(request: SpeechRequest(voice: "Ryan", text: "Original"), voiceName: "Ryan")
        original.sequence = 7; original.requestID = "shared-key"
        try JobStore(directory: root.appending(path: "Queue")).save(original)
        let db = try JobDatabase(root: root)
        #expect(try db.find(id: original.id)?.request.text == "Original")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Queue/\(original.id).json").path))
        for i in 8...27 {
            var job = SpeechJob(request: original.request, voiceName: "Ryan")
            job.sequence = UInt64(i); job.state = "completed"; job.clientID = "client"; job.requestID = "key-\(i)"
            try db.save(job)
        }
        var other = SpeechJob(request: original.request, voiceName: "Ryan")
        other.clientID = "other"; other.requestID = "shared-key"; other.sequence = 28
        try db.save(other)
        #expect(try db.find(requestID: "shared-key", owner: nil)?.id == original.id)
        #expect(try db.find(requestID: "shared-key", owner: "other")?.id == other.id)
        #expect(try db.find(requestID: "shared-key", owner: "client") == nil)
        #expect(try db.recent(limit: 3).count == 5) // three terminal + both active
        let expired = try db.expired(days: 30, keep: 5)
        #expect(expired.count == 15); #expect(expired.allSatisfy { $0.isTerminal })
        try db.archiveFinished(); #expect(try db.recent(limit: 3).count == 2)
        #expect(try db.find(requestID: "key-27", owner: "client") != nil)
        #expect(try db.maximumSequence() == 28)
        try db.remove(id: original.id); #expect(try db.find(id: original.id) != nil)
    }
    @Test func pendingPayloadBudgetRejectsNewWorkButAllowsCompletion() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var first = SpeechJob(request: SpeechRequest(voice: "Ryan", text: String(repeating: "a", count: 500)), voiceName: "Ryan")
        let next = SpeechJob(request: first.request, voiceName: "Ryan")
        // Date encoding can differ by a byte across receipts. Permit either alone,
        // but leave substantially less room than their combined encoded size.
        let budget = max(try JSONEncoder().encode(first).count, try JSONEncoder().encode(next).count) + 1
        let db = try JobDatabase(root: root, maximumPendingBytes: Int64(budget))
        try db.save(first)
        #expect(throws: (any Error).self) { try db.save(next) }
        first.state = "completed"; try db.save(first)
        try db.save(next)
        #expect(try db.activeCount() == 1)
    }
    @Test func retentionPreservesExportsUnlessExplicitlyEnabled() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let jobs = root.appending(path: "Jobs"), output = root.appending(path: "Audio")
        try PrivateStorage.directory(jobs); try PrivateStorage.directory(output)
        var job = SpeechJob(request: SpeechRequest(voice: "Ryan", text: "Test"), voiceName: "Ryan")
        job.state = "completed"; let file = output.appending(path: "Chatter-\(job.id).wav"); job.path = file.path
        try Data([1]).write(to: file)
        try AudioStorage.removeAudio(for: job, output: output, jobs: jobs)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try AudioStorage.removeAudio(for: job, output: output, jobs: jobs, deleteExports: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let unrelated = output.appending(path: "keep.wav"); try Data([2]).write(to: unrelated); job.path = unrelated.path
        try AudioStorage.removeAudio(for: job, output: output, jobs: jobs, deleteExports: true)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
    @Test func changedModelsCannotUseTheIntegrityCache() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let good = Data("original".utf8), url = root.appending(path: "weights")
        try good.write(to: url)
        let digest = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
        let model = ModelFile(repository: "test", revision: "test", path: "weights", destination: "weights", size: Int64(good.count), sha256: digest)
        let installer = ModelInstaller(modelsRoot: root, files: [model])
        try await installer.verifyInstalled(); try await installer.verifyInstalled()
        let modification = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data("modified".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: url.path)
        await #expect(throws: (any Error).self) { try await installer.verifyInstalled() }
    }
}

import CryptoKit
import Foundation
import os
import Testing
@testable import ChatterCore

/// Installer failure modes: every interruption must leave a state that the next "Retry" repairs,
/// and nothing unverified may ever become an installed model file.
struct ModelInstallerEdgeTests {
    typealias T = ModelInstallerTests
    static var content: Data { T.content }

    /// Serves `content` like a real CDN: honors `Range`, and answers 416 for a range at or past the end.
    static func strictServer(_ body: Data = T.content, delay: Duration? = nil) async throws -> MockHTTPServer {
        try await MockHTTPServer.start { request in
            if let delay { try? await Task.sleep(for: delay) }
            if let range = request.headers["range"], range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()) {
                guard start < body.count else { return MockResponse(status: 416) }
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body: body.subdata(in: start..<body.count))
            }
            return MockResponse(status: 200, body: body)
        }
    }

    static func installer(_ server: MockHTTPServer, root: URL, files: [ModelFile] = [T.file()]) -> ModelInstaller {
        ModelInstaller(modelsRoot: root, files: files, baseURL: URL(string: server.baseURL)!)
    }

    static func prepare(_ root: URL, partial: Data) throws {
        try FileManager.default.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        try partial.write(to: root.appending(path: "p/model.bin.partial"))
    }

    static func leftovers(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".partial") || $0.contains(".link-") }
    }

    /// A resumed response that starts somewhere other than the end of the partial file is refused
    /// before anything is appended, and the next attempt downloads from the start.
    @Test func aMisalignedResumeIsRefusedAndTheRetryStartsOver() async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { request in
            if let range = request.headers["range"], range.hasPrefix("bytes=") {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes 0-\(body.count - 1)/\(body.count)"], body: body)
            }
            return MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: body.prefix(100))
        let installer = Self.installer(server, root: root)
        await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
        #expect((try? Data(contentsOf: root.appending(path: "p/model.bin.partial")))?.isEmpty ?? true)
        try await installer.install { _ in }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
        #expect(Self.leftovers(root).isEmpty)
    }

    /// Every resumed response whose Content-Range does not start exactly at the partial's end (100,000
    /// bytes here) is refused with a message naming the problem, the partial is emptied, and the retry
    /// asks for the whole file. `10-` and `1000-` guard against a prefix comparison on the digits.
    @Test(arguments: ["bytes 0-299999/300000", "bytes 10-299999/300000", "bytes 1000-299999/300000", "bytes 100001-299999/300000",
                      "bytes 99999-299999/300000", "bytes */300000", "items 100000-299999/300000"])
    func everyMisalignedContentRangeIsRefused(contentRange: String) async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { request in
            if request.headers["range"] != nil {
                return MockResponse(status: 206, headers: ["Content-Range": contentRange], body: body.subdata(in: 100_000..<body.count))
            }
            return MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: body.prefix(100_000))
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted \(contentRange)") } catch {
            #expect(error.localizedDescription == "Model download was interrupted: the server resumed at the wrong position (\(contentRange)); "
                    + "retry to download from the start. Retry; downloads resume.")
        }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin.partial")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin").path))
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=100000-", nil])
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
        #expect(Self.leftovers(root).isEmpty)
    }

    /// A resumed response that names the right start is appended (one request, no restart).
    @Test func anAlignedContentRangeResumesInOneRequest() async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { request in
            guard let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) else {
                return MockResponse(status: 200, body: body)
            }
            return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                                body: body.subdata(in: start..<body.count))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: body.prefix(100_000))
        try await Self.installer(server, root: root).install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=100000-"])
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
        #expect(Self.leftovers(root).isEmpty)
    }

    /// A fresh download (no Range sent) answered with 206 and a full-file Content-Range is accepted.
    @Test func aFullRangeAnswerToAFreshRequestIsAccepted() async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { _ in
            MockResponse(status: 206, headers: ["Content-Range": "bytes 0-\(body.count - 1)/\(body.count)"], body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await Self.installer(server, root: root).install { _ in }
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == nil)
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
    }

    /// A 206 without Content-Range is refused like a misaligned one: nothing is appended.
    @Test func aResumeWithoutContentRangeIsRefused() async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { request in
            request.headers["range"] != nil ? MockResponse(status: 206, body: body.subdata(in: 100..<body.count)) : MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: body.prefix(100))
        let installer = Self.installer(server, root: root)
        await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
        #expect((try? Data(contentsOf: root.appending(path: "p/model.bin.partial")))?.isEmpty ?? true)
        try await installer.install { _ in }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
    }

    /// A server that sends more than the pinned size is cut off before the excess reaches the disk.
    @Test func anOversizedBodyIsCutOffAtThePinnedSize() async throws {
        let oversized = T.content + Data(repeating: 7, count: 2_000_000)
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: oversized) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("expected an integrity failure") } catch {
            #expect(error.localizedDescription.contains("integrity"))
        }
        let partial = root.appending(path: "p/model.bin.partial")
        #expect(((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? 0) <= T.content.count)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin").path))
    }

    /// A clean but short transfer keeps what arrived: the next attempt resumes instead of starting over.
    @Test func aShortTransferKeepsItsProgressForTheNextResume() async throws {
        let body = T.content
        let server = try await MockHTTPServer.start { request in
            if let range = request.headers["range"], range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()) {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body: body.subdata(in: start..<body.count))
            }
            return MockResponse(status: 200, body: body.prefix(120_000))   // ends early, cleanly
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted a short body") } catch {
            #expect(error.localizedDescription.contains("ended the transfer early"))
        }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin.partial")) == body.prefix(120_000))
        try await installer.install { _ in }
        #expect(server.requests.last?.headers["range"] == "bytes=120000-")
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
    }

    /// A 416 means nothing exists past the kept bytes: the partial is discarded so the next attempt
    /// downloads from the start instead of asking for the same impossible range forever.
    @Test func anUnsatisfiableResumeDiscardsThePartial() async throws {
        let body = T.content
        let honest = OSAllocatedUnfairLock(initialState: false)
        let server = try await MockHTTPServer.start { request in
            if request.headers["range"] != nil, !honest.withLock({ $0 }) { return MockResponse(status: 416) }
            return MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: body.prefix(100))
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted an unsatisfiable resume") } catch {
            #expect(error.localizedDescription == "p/model.bin failed its integrity check and was removed. Retry to download it again.")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin.partial").path))
        honest.withLock { $0 = true }
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=100-", nil])
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == body)
    }

    /// Regression: a partial that is already complete (the app quit while verifying it) used to be
    /// re-requested with `Range: bytes=<size>-`, which a CDN answers 416 on every retry, forever.
    @Test func aCompletePartialIsVerifiedWithoutARequest() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: Self.content)
        try await Self.installer(server, root: root).install { _ in }
        #expect(server.requests.isEmpty)
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
        #expect(Self.leftovers(root).isEmpty)
    }

    @Test func aCompleteButCorruptPartialIsDiscardedAndTheRetryDownloadsAfresh() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var corrupt = Self.content; corrupt[299_999] ^= 0x55
        try Self.prepare(root, partial: corrupt)
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("expected an integrity failure") } catch {
            #expect(error.localizedDescription == "p/model.bin failed its integrity check and was removed. Retry to download it again.")
        }
        #expect(Self.leftovers(root).isEmpty)
        try await installer.install { _ in }
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == nil)
        #expect(installer.isInstalled)
    }

    @Test func anOversizedPartialIsDiscardedAndDownloadedWithoutARange() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: Self.content + Data(repeating: 1, count: 10))
        try await Self.installer(server, root: root).install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == [nil])
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
    }

    @Test func serverErrorsKeepThePartialSoTheRetryResumes() async throws {
        let failing = OSAllocatedUnfairLock(initialState: true)
        let body = Self.content
        let server = try await MockHTTPServer.start { request in
            if failing.withLock({ $0 }) { return MockResponse(status: 503) }
            let start = Int(request.headers["range"]?.dropFirst(6).dropLast() ?? "0") ?? 0
            return start > 0
                ? MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body: body.subdata(in: start..<body.count))
                : MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: Self.content.prefix(100_000))
        let installer = Self.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("expected HTTP failure") } catch {
            #expect(error.localizedDescription == "Model download failed with HTTP 503 for p/model.bin. Retry; downloads resume.")
        }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin.partial")) == Self.content.prefix(100_000))
        failing.withLock { $0 = false }
        try await installer.install { _ in }
        #expect(server.requests.last?.headers["range"] == "bytes=100000-")
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
    }

    @Test func aShortBodyFailsVerificationAndInstallsNothing() async throws {
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: T.content.prefix(150_000)) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(server, root: root)
        await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin").path))
        #expect(!installer.isInstalled && installer.missingBytes == Int64(Self.content.count))
    }

    /// Regression: cancelling before the request started raised an uncaught NSGenericException
    /// ("Task created in a session that has been invalidated") and terminated the app.
    @Test func cancellationBeforeTheRequestStartsFailsCleanly() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for _ in 0..<20 {
            let stream = DownloadStream(url: URL(string: server.baseURL + "/x")!, offset: 0, partial: root.appending(path: "x.partial"),
                                        expected: Int64(Self.content.count)) { _ in }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await stream.run()
            }
            await #expect(throws: ModelInstallerError.self) { try await task.value }
        }
    }

    @Test func cancellingAnInstallStopsPromptlyAndInstallsNothing() async throws {
        let server = try await Self.strictServer(delay: .seconds(20))
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(server, root: root)
        let task = Task { try await installer.install { _ in } }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let clock = ContinuousClock(), start = clock.now
        task.cancel()
        do { try await task.value; Issue.record("expected cancellation") } catch {
            #expect(error.localizedDescription.hasPrefix("Model download was interrupted: "))
        }
        #expect(clock.now - start < .seconds(5))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin").path))
    }

    @Test func anAlreadyCancelledInstallDoesNothing() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Self.installer(server, root: root).install { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    /// Two installers racing on one models directory (a double click, or the app and chatter-tools)
    /// may fail, but must not crash, and a later install always ends verified with no temporary files.
    @Test func concurrentInstallsNeverLeaveAnUnverifiedModel() async throws {
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 97 &+ 3) })
        let file = T.file(content: big)
        let server = try await Self.strictServer(big)
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try? await Self.installer(server, root: root, files: [file]).install { _ in } } }
        }
        let installer = Self.installer(server, root: root, files: [file])
        try await installer.install { _ in }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == big)
        #expect(try await installer.hash(of: root.appending(path: "p/model.bin")) == file.sha256)
        #expect(Self.leftovers(root).isEmpty)
    }

    @Test func progressIsReportedInOrderAndEndsWithCompletion() async throws {
        let server = try await Self.strictServer()
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.prepare(root, partial: Self.content.prefix(30_000))
        let log = OSAllocatedUnfairLock(initialState: [String]())
        let installer = Self.installer(server, root: root)
        try await installer.install { message in log.withLock { $0.append(message) } }
        let messages = log.withLock { $0 }
        #expect(messages.first?.hasPrefix("Downloading p/model.bin (") == true && messages.first?.contains(", resuming") == true)
        #expect(messages.last == "SETUP_COMPLETE\n")
        let percents = messages.compactMap { line -> Double? in
            guard line.hasPrefix("  p/model.bin ") else { return nil }
            return Double(line.dropFirst("  p/model.bin ".count).dropLast(2))
        }
        #expect(!percents.isEmpty && percents == percents.sorted() && percents.allSatisfy { $0 > 10 && $0 <= 100 })
        log.withLock { $0 = [] }
        try await installer.install { message in log.withLock { $0.append(message) } }
        #expect(log.withLock { $0 } == ["Verified p/model.bin\n", "SETUP_COMPLETE\n"])
    }

    @Test func emptyManifestIsTriviallyInstalled() async throws {
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(modelsRoot: root, files: [])
        #expect(installer.isInstalled && installer.missingBytes == 0)
        let messages = OSAllocatedUnfairLock(initialState: [String]())
        try await installer.install { message in messages.withLock { $0.append(message) } }
        #expect(messages.withLock { $0 } == ["SETUP_COMPLETE\n"])
    }

    @Test func missingBytesCountsOnlyAbsentOrWrongSizedFiles() throws {
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = T.file("a.bin", content: Data(repeating: 1, count: 10)), b = T.file("b/b.bin", content: Data(repeating: 2, count: 20))
        let installer = ModelInstaller(modelsRoot: root, files: [a, b])
        #expect(installer.missingBytes == 30 && !installer.isInstalled)
        try FileManager.default.createDirectory(at: root.appending(path: "b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: root.appending(path: "a.bin"))
        try Data(repeating: 2, count: 19).write(to: root.appending(path: "b/b.bin"))
        #expect(installer.missingBytes == 20 && !installer.isInstalled)
        try Data(repeating: 2, count: 20).write(to: root.appending(path: "b/b.bin"))
        #expect(installer.missingBytes == 0 && installer.isInstalled)
    }

    @Test func hashMatchesKnownVectors() async throws {
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = ModelInstaller(modelsRoot: root, files: [])
        let empty = root.appending(path: "empty"), abc = root.appending(path: "abc"), large = root.appending(path: "large")
        try Data().write(to: empty); try Data("abc".utf8).write(to: abc)
        let big = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })   // spans two read chunks
        try big.write(to: large)
        #expect(try await installer.hash(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try await installer.hash(of: abc) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try await installer.hash(of: large) == T.sha(big))
        await #expect(throws: (any Error).self) { try await installer.hash(of: root.appending(path: "missing")) }
    }

    @Test func remoteURLsFollowTheHuggingFaceResolveLayout() {
        let file = ModelFile(repository: "mlx-community/x", revision: "0123", path: "sub/model.safetensors", destination: "d", size: 1, sha256: "")
        #expect(file.remoteURL(base: URL(string: "https://huggingface.co")!).absoluteString
                == "https://huggingface.co/mlx-community/x/resolve/0123/sub/model.safetensors")
        #expect(ModelManifest.totalBytes == ModelManifest.files.reduce(0) { $0 + $1.size })
        #expect(ModelManifest.files.allSatisfy { !$0.destination.hasPrefix("/") && !$0.destination.contains("..") })
    }

    @Test func errorMessagesTellTheUserWhatToDo() {
        #expect(ModelInstallerError.http(404, "x.bin").localizedDescription == "Model download failed with HTTP 404 for x.bin. Retry; downloads resume.")
        #expect(ModelInstallerError.integrity("fast/x").localizedDescription == "fast/x failed its integrity check and was removed. Retry to download it again.")
        #expect(ModelInstallerError.interrupted("offline").localizedDescription == "Model download was interrupted: offline. Retry; downloads resume.")
    }
}

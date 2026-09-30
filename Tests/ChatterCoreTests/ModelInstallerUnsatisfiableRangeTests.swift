import Foundation
import os
import Testing
@testable import ChatterCore

/// HTTP 416 (Range Not Satisfiable) means nothing exists past the bytes that were asked for, so the
/// kept partial can never be completed: the stream empties it and fails as an integrity problem, the
/// installer removes it, and the next "Retry" downloads from the start. A 416 is never allowed to
/// become a loop (the same impossible range asked for on every retry), never writes its body, and a
/// real CDN (which answers 416 at or past the end) is never asked for a range that would earn one.
struct ModelInstallerUnsatisfiableRangeTests {
    typealias T = ModelInstallerTests
    typealias E = ModelInstallerEdgeTests
    typealias R = ModelInstallerResumeTests

    static let integrity = "p/model.bin failed its integrity check and was removed. Retry to download it again."
    static func partialURL(_ root: URL) -> URL { root.appending(path: "p/model.bin.partial") }
    static func installedURL(_ root: URL) -> URL { root.appending(path: "p/model.bin") }
    static func downloading(_ size: Int, resuming: Bool) -> String {
        "Downloading p/model.bin (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))\(resuming ? ", resuming" : "")…\n"
    }

    // MARK: Through the installer

    /// A 416 to a fresh request (no Range sent, nothing kept) is still refused as an integrity problem,
    /// installs nothing, leaves no partial, and costs exactly one request per attempt: a server that
    /// keeps answering 416 is asked once per Retry, never in a loop, and never for a range again once
    /// the partial is gone. When it recovers, the next Retry installs.
    @Test func aPersistent416CostsOneRequestPerRetryAndNeverRepeatsTheRange() async throws {
        let body = T.content
        let broken = OSAllocatedUnfairLock(initialState: true)
        let server = try await MockHTTPServer.start { _ in
            broken.withLock { $0 } ? MockResponse(status: 416, headers: ["Content-Range": "bytes */\(body.count)"]) : MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: body.prefix(100))
        let installer = E.installer(server, root: root)
        for attempt in 1...3 {
            do { try await installer.install { _ in }; Issue.record("attempt \(attempt): accepted a 416") } catch {
                #expect(error.localizedDescription == Self.integrity, "attempt \(attempt)")
            }
            #expect(server.requests.count == attempt, "attempt \(attempt): one request per attempt")
            #expect(!FileManager.default.fileExists(atPath: Self.partialURL(root).path), "attempt \(attempt)")
            #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path), "attempt \(attempt)")
        }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=100-", nil, nil])
        broken.withLock { $0 = false }
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=100-", nil, nil, nil])
        #expect(try Data(contentsOf: Self.installedURL(root)) == body)
        #expect(E.leftovers(root).isEmpty)
    }

    /// A 416 that carries a body (an HTML error page, or a whole file a confused proxy attached) writes
    /// none of it, for a resume and for a fresh request, and the honest retry installs the real file.
    @Test(arguments: [(100_000, 512), (100_000, 5_000_000), (0, 512), (0, 5_000_000)])
    func a416WithABodyInstallsNothingAndTheRetryDownloadsAfresh(kept: Int, bodyLength: Int) async throws {
        let content = T.content
        let junk = Data((0..<bodyLength).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 1) })
        let honest = OSAllocatedUnfairLock(initialState: false)
        let server = try await MockHTTPServer.start { _ in
            honest.withLock { $0 } ? MockResponse(status: 200, body: content)
                : MockResponse(status: 416, headers: ["Content-Type": "text/html"], body: junk)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        if kept > 0 { try E.prepare(root, partial: content.prefix(kept)) }
        let installer = E.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted a 416 with a body") } catch {
            #expect(error.localizedDescription == Self.integrity)
        }
        #expect(!FileManager.default.fileExists(atPath: Self.partialURL(root).path))
        #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path))
        honest.withLock { $0 = true }
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == [kept > 0 ? "bytes=\(kept)-" : nil, nil])
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
        #expect(E.leftovers(root).isEmpty)
    }

    /// What the user reads around a 416: the attempt announces a resume, reports no progress (nothing
    /// was received), and never claims completion; the retry announces a fresh download (no
    /// "resuming", because the partial is gone), reports progress, and completes.
    @Test func theLogAroundA416AnnouncesAResumeThenAFreshDownload() async throws {
        let body = T.content
        let honest = OSAllocatedUnfairLock(initialState: false)
        let server = try await MockHTTPServer.start { request in
            request.headers["range"] != nil && !honest.withLock({ $0 }) ? MockResponse(status: 416) : MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: body.prefix(60_000))
        let installer = E.installer(server, root: root)
        let log = OSAllocatedUnfairLock(initialState: [String]())
        do { try await installer.install { line in log.withLock { $0.append(line) } }; Issue.record("accepted a 416") } catch {
            #expect(error.localizedDescription == Self.integrity)
        }
        #expect(log.withLock { $0 } == [Self.downloading(body.count, resuming: true)])
        log.withLock { $0 = [] }
        honest.withLock { $0 = true }
        try await installer.install { line in log.withLock { $0.append(line) } }
        let lines = log.withLock { $0 }
        #expect(lines.first == Self.downloading(body.count, resuming: false))
        #expect(lines.last == "SETUP_COMPLETE\n")
        let percents = lines.compactMap { line -> Double? in
            guard line.hasPrefix("  p/model.bin ") else { return nil }
            return Double(line.dropFirst("  p/model.bin ".count).dropLast(2))
        }
        #expect(!percents.isEmpty && percents == percents.sorted() && percents.allSatisfy { $0 > 0 && $0 <= 100 }, "\(percents)")
    }

    /// A 416 on the second of three files names that file, keeps the first installed, and stops before
    /// the third. The retry verifies the first without a request, downloads the second from the start,
    /// then the third.
    @Test func a416MidInstallNamesTheFileAndTheRetryFinishesTheRest() async throws {
        let contents = (0..<3).map { index in Data((0..<(40_000 + index * 1_000)).map { UInt8(truncatingIfNeeded: $0 &* (7 + index) &+ index) }) }
        let files = contents.enumerated().map { index, content in
            ModelFile(repository: "org/repo", revision: "abc123", path: "f\(index).bin", destination: "d\(index)/f\(index).bin",
                      size: Int64(content.count), sha256: T.sha(content))
        }
        let honest = OSAllocatedUnfairLock(initialState: false)
        let server = try await MockHTTPServer.start { request in
            guard let index = (0..<3).first(where: { request.path.hasSuffix("/f\($0).bin") }) else { return MockResponse(status: 404) }
            if index == 1, request.headers["range"] != nil, !honest.withLock({ $0 }) { return MockResponse(status: 416) }
            return MockResponse(status: 200, body: contents[index])
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "d1"), withIntermediateDirectories: true)
        try contents[1].prefix(500).write(to: root.appending(path: "d1/f1.bin.partial"))
        let installer = ModelInstaller(modelsRoot: root, files: files, baseURL: URL(string: server.baseURL)!)
        do { try await installer.install { _ in }; Issue.record("accepted a 416") } catch {
            #expect(error.localizedDescription == "d1/f1.bin failed its integrity check and was removed. Retry to download it again.")
        }
        #expect(try Data(contentsOf: root.appending(path: "d0/f0.bin")) == contents[0])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "d1/f1.bin.partial").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "d2/f2.bin").path))
        #expect(server.requests.map(\.path).map { String($0.split(separator: "/").last!) } == ["f0.bin", "f1.bin"])
        honest.withLock { $0 = true }
        try await installer.install { _ in }
        let retried = server.requests.dropFirst(2)
        #expect(retried.map { String($0.path.split(separator: "/").last!) } == ["f1.bin", "f2.bin"])
        #expect(retried.allSatisfy { $0.headers["range"] == nil })
        for index in 0..<3 {
            #expect(try Data(contentsOf: root.appending(path: "d\(index)/f\(index).bin")) == contents[index], "file \(index)")
        }
        #expect(installer.isInstalled && E.leftovers(root).isEmpty)
    }

    // MARK: A strict CDN is never asked for an unsatisfiable range

    /// Seeded property over every kept length, weighted to the boundaries (0, 1, size − 1, size,
    /// size + 1, far past size): a CDN that answers 416 at or past the end is never asked for such a
    /// range, so a correct partial of any length installs in one attempt. Exactly one request is made
    /// unless the partial is already complete (none); a Range is sent only for 0 < kept < size, and it
    /// starts at `kept`. Metamorphic: the installed bytes are the same whatever was kept.
    @Test func aStrictCDNNeverAnswers416ToAnyKeptLength() async throws {
        let content = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 53 &+ 11) })
        let size = content.count
        let file = T.file(content: content)
        let server = try await E.strictServer(content)
        var lengths = [0, 1, size - 1, size, size + 1, size + 4_096]
        var rng = SeededGenerator(seed: 0x416)
        for _ in 0..<24 { lengths.append(Int(rng.next() % UInt64(size + 2))) }
        for kept in lengths {
            let label = "kept \(kept) of \(size)"
            let before = server.requests.count
            let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            if kept > 0 {
                try E.prepare(root, partial: kept <= size ? content.prefix(kept) : content + Data(repeating: 0xAA, count: kept - size))
            }
            try await E.installer(server, root: root, files: [file]).install { _ in }
            let sent = server.requests.dropFirst(before).map { $0.headers["range"] }
            #expect(sent == (kept == size ? [] : [kept > 0 && kept < size ? "bytes=\(kept)-" : nil]), "\(label): \(sent)")
            #expect(try Data(contentsOf: Self.installedURL(root)) == content, "\(label)")
            #expect(E.leftovers(root).isEmpty, "\(label)")
        }
        // No request anywhere in the run asked for a start at or past the end.
        let starts = server.requests.compactMap { $0.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } }
        #expect(starts.allSatisfy { $0 > 0 && $0 < size }, "\(starts)")
    }

    // MARK: DownloadStream on its own

    /// The stream itself (without the installer's clean-up) empties the kept bytes on a 416 and writes
    /// none of the 416's body, however large. Repeated to expose a delivery race.
    @Test func theStreamEmptiesThePartialAndWritesNoneOfA416Body() async throws {
        let content = T.content
        let junk = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        let server = try await MockHTTPServer.start { _ in
            MockResponse(status: 416, headers: ["Content-Range": "bytes */\(content.count)"], body: junk)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appending(path: "x.bin.partial")
        for attempt in 0..<10 {
            try content.prefix(100_000).write(to: partial)
            let stream = DownloadStream(url: URL(string: server.baseURL + "/r/x.bin")!, offset: 100_000, partial: partial,
                                        expected: Int64(content.count), name: "p/model.bin") { _ in
                Issue.record("attempt \(attempt): progress reported for a 416")
            }
            do { try await stream.run(); Issue.record("attempt \(attempt): accepted a 416") } catch {
                #expect(error.localizedDescription == Self.integrity, "attempt \(attempt)")
            }
            let kept = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int
            #expect(kept == 0, "attempt \(attempt): \(kept.map(String.init) ?? "no file") bytes kept after a 416")
        }
        #expect(server.requests.count == 10 && server.requests.allSatisfy { $0.headers["range"] == "bytes=100000-" })
    }

    /// Driven directly: a 416 cancels the transfer (rather than letting its body stream in), a chunk
    /// that still arrives is not written, counted or reported, and the integrity refusal (not the
    /// cancellation it caused) is the outcome — for a resume and for a fresh request.
    @Test(arguments: [Int64(0), 50])
    func aChunkAfterA416IsIgnored(offset: Int64) async throws {
        let h = try R.Harness(offset: offset, expected: 100)
        #expect(await h.respond(416, contentRange: "bytes */100") == .cancel)
        h.receive(Int(100 - offset))   // would exactly complete the file if it were written
        h.finish(URLError(.cancelled))
        #expect(h.reported.isEmpty)
        #expect(await h.outcome() == "p/x.bin failed its integrity check and was removed. Retry to download it again.")
    }

    /// Only 416 is treated as "this partial can never be completed": its neighbours are ordinary HTTP
    /// failures that keep the partial for the next resume.
    @Test(arguments: [415, 417, 400, 404, 500])
    func neighbouringStatusesKeepThePartial(status: Int) async throws {
        let server = try await MockHTTPServer.start { _ in MockResponse(status: status) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: T.content.prefix(100))
        do { try await E.installer(server, root: root).install { _ in }; Issue.record("accepted HTTP \(status)") } catch {
            #expect(error.localizedDescription == "Model download failed with HTTP \(status) for p/model.bin. Retry; downloads resume.")
        }
        #expect(try Data(contentsOf: Self.partialURL(root)) == T.content.prefix(100))
    }
}

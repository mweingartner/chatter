import Foundation
import os
import Testing
@testable import ChatterCore

/// A clean but short transfer is an interruption whose bytes are kept, so every "Retry" makes progress;
/// bytes that were short and corrupt are only discarded once a later attempt completes and hashes them.
/// An over-size refusal leaves nothing behind, and a server-supplied Content-Range shown to the user is
/// capped. Every sequence ends with the verified file installed and no temporary files.
struct ModelInstallerResumeTests {
    typealias T = ModelInstallerTests
    typealias E = ModelInstallerEdgeTests
    typealias S = ModelInstallerSizeLimitTests

    static let endedEarly = "Model download was interrupted: the server ended the transfer early. Retry; downloads resume."
    static let integrity = "p/model.bin failed its integrity check and was removed. Retry to download it again."

    /// Serves at most `cap` bytes per request, honestly: a fresh request gets 200 with the first `cap`
    /// bytes, a resume gets 206 with a Content-Range naming exactly the bytes sent. The body of the
    /// first response may carry one flipped byte at `corruptFirstAt` (an index into that response).
    static func cappingServer(_ body: Data, cap: Int, corruptFirstAt: Int? = nil) async throws -> MockHTTPServer {
        let served = OSAllocatedUnfairLock(initialState: 0)
        return try await MockHTTPServer.start { request in
            let index = served.withLock { count -> Int in defer { count += 1 }; return count }
            let range = request.headers["range"]
            let start = range.flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            let end = min(start + cap, body.count)
            var chunk = body.subdata(in: start..<end)
            if index == 0, let at = corruptFirstAt, at < chunk.count { chunk[at] ^= 0x40 }
            guard range != nil else { return MockResponse(status: 200, body: chunk) }
            return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(end - 1)/\(body.count)"], body: chunk)
        }
    }

    /// The Range headers a capping server sees while a download of `size` bytes fills in `cap`-byte steps.
    static func resumeRanges(size: Int, cap: Int) -> [String?] {
        stride(from: 0, to: size, by: cap).map { $0 == 0 ? nil : "bytes=\($0)-" }
    }

    // MARK: Successive resumes

    /// A server that caps every response (a proxy with a transfer limit, or a flaky CDN edge) still
    /// installs the file: each Retry resumes exactly where the last one ended, the partial grows by
    /// exactly one cap per attempt, and the user is told each time that the transfer ended early.
    @Test(arguments: [30_000, 64_000, 99_999, 150_000, 299_999, 300_000])
    func aRangeCappingServerCompletesThroughSuccessiveResumes(cap: Int) async throws {
        let content = T.content
        let server = try await Self.cappingServer(content, cap: cap)
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = E.installer(server, root: root)
        let needed = (content.count + cap - 1) / cap
        let log = OSAllocatedUnfairLock(initialState: [String]())
        for attempt in 1...needed {
            log.withLock { $0 = [] }
            do {
                try await installer.install { message in log.withLock { $0.append(message) } }
                #expect(attempt == needed, "installed after \(attempt) of \(needed) attempts")
            } catch {
                #expect(attempt < needed, "attempt \(attempt) failed: \(error.localizedDescription)")
                #expect(error.localizedDescription == Self.endedEarly)
                #expect(S.partialSize(root) == attempt * cap, "attempt \(attempt): the transfer's progress was not kept exactly")
                #expect(!FileManager.default.fileExists(atPath: S.installedURL(root).path))
            }
            let first = log.withLock { $0.first } ?? ""
            #expect(first.hasPrefix("Downloading p/model.bin (") && first.contains(", resuming") == (attempt > 1), "attempt \(attempt): \(first)")
        }
        #expect(server.requests.map { $0.headers["range"] } == Self.resumeRanges(size: content.count, cap: cap))
        #expect(try Data(contentsOf: S.installedURL(root)) == content)
        #expect(installer.isInstalled && E.leftovers(root).isEmpty)
    }

    /// A short transfer that was also corrupt is kept (a short transfer cannot be hashed), resumed to
    /// full size by the next Retry, rejected there by the hash check and removed; the Retry after that
    /// downloads from byte 0 and installs.
    @Test func aShortAndCorruptTransferIsDiscardedByTheNextHashCheckAndTheOneAfterInstalls() async throws {
        let content = T.content
        let server = try await S.server(content, misbehaving: 1) { _ in
            var short = content.prefix(120_000); short[50_000] ^= 0x01
            return MockResponse(status: 200, body: short)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = E.installer(server, root: root)

        do { try await installer.install { _ in }; Issue.record("accepted a short body") } catch {
            #expect(error.localizedDescription == Self.endedEarly)
        }
        var kept = content.prefix(120_000); kept[50_000] ^= 0x01
        #expect(try Data(contentsOf: S.partialURL(root)) == kept)

        do { try await installer.install { _ in }; Issue.record("installed corrupt bytes") } catch {
            #expect(error.localizedDescription == Self.integrity)
        }
        #expect(!FileManager.default.fileExists(atPath: S.partialURL(root).path))
        #expect(!FileManager.default.fileExists(atPath: S.installedURL(root).path))

        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == [nil, "bytes=120000-", nil])
        #expect(try Data(contentsOf: S.installedURL(root)) == content)
        #expect(E.leftovers(root).isEmpty)
    }

    /// Seeded property over file length, per-response cap and an optional corrupt byte in the first
    /// response. The exact sequence of outcomes and Range headers is predicted: `k = ceil(size / cap)`
    /// attempts install a clean file (k - 1 "ended early", then success); a corrupt first response
    /// costs one full pass that ends in an integrity failure, then k more attempts from byte 0.
    @Test func everyCappedSequenceEndsInstalledAfterExactlyThePredictedRetries() async throws {
        for seed in UInt64(1)...30 {
            var rng = SeededGenerator(seed: seed)
            let size = Int.random(in: 1...20_000, using: &rng)
            let content = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let cap = Int.random(in: max(1, (size + 7) / 8)...size, using: &rng)
            let corruptAt: Int? = Int.random(in: 0..<3, using: &rng) == 0 ? Int.random(in: 0..<min(cap, size), using: &rng) : nil
            let label = "seed \(seed): size \(size) cap \(cap) corrupt \(corruptAt.map(String.init) ?? "none")"

            let server = try await Self.cappingServer(content, cap: cap, corruptFirstAt: corruptAt)
            let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let installer = E.installer(server, root: root, files: [T.file(content: content)])
            let k = (size + cap - 1) / cap
            let pass = Array(repeating: "ended early", count: k - 1)
            let predicted = corruptAt == nil ? pass + ["installed"] : pass + ["integrity"] + pass + ["installed"]

            var outcomes: [String] = []
            while outcomes.last != "installed", outcomes.count <= predicted.count {
                do { try await installer.install { _ in }; outcomes.append("installed") } catch {
                    switch error.localizedDescription {
                    case Self.endedEarly: outcomes.append("ended early")
                    case Self.integrity: outcomes.append("integrity")
                    default: outcomes.append("unexpected: \(error.localizedDescription)")
                    }
                    #expect(!FileManager.default.fileExists(atPath: S.installedURL(root).path), "\(label)")
                    #expect((S.partialSize(root) ?? 0) <= size, "\(label)")
                }
            }
            #expect(outcomes == predicted, "\(label)")
            let ranges = Self.resumeRanges(size: size, cap: cap)
            #expect(server.requests.map { $0.headers["range"] } == (corruptAt == nil ? ranges : ranges + ranges), "\(label)")
            #expect((try? Data(contentsOf: S.installedURL(root))) == content, "\(label)")
            #expect(E.leftovers(root).isEmpty, "\(label)")
        }
    }

    // MARK: The Content-Range shown to the user

    /// The misaligned Content-Range quoted in the message is capped at 64 characters: 63 and 64 are
    /// shown whole, 65 and longer are cut to their first 64 — a server cannot flood the message.
    @Test(arguments: [63, 64, 65, 500, 4_000])
    func theQuotedContentRangeIsCappedAt64Characters(length: Int) async throws {
        let content = T.content
        let contentRange = "bytes 1-" + String(repeating: "9", count: length - "bytes 1-".count)
        #expect(contentRange.count == length)
        let server = try await MockHTTPServer.start { _ in
            MockResponse(status: 206, headers: ["Content-Range": contentRange], body: content.subdata(in: S.resumeOffset..<content.count))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: content.prefix(S.resumeOffset))
        do { try await E.installer(server, root: root).install { _ in }; Issue.record("accepted a misaligned resume") } catch {
            let shown = String(contentRange.prefix(64))
            #expect(error.localizedDescription == "Model download was interrupted: the server resumed at the wrong position (\(shown)); "
                    + "retry to download from the start. Retry; downloads resume.")
            #expect(!error.localizedDescription.contains(String(repeating: "9", count: 57)))
        }
        #expect(try Data(contentsOf: S.partialURL(root)).isEmpty)
    }

    // MARK: Over-size refusals leave nothing behind

    /// After an over-size refusal the partial file is gone — not merely empty — whether the oversized
    /// body answered a fresh request or a resume, and whether it arrived in one chunk or many.
    @Test(arguments: [(false, 1), (false, 5_000_000), (true, 1), (true, 5_000_000)])
    func anOversizeRefusalRemovesThePartial(resume: Bool, excess: Int) async throws {
        let content = T.content
        let server = try await MockHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(content.count + excess - 1)/\(content.count + excess)"],
                                    body: content.subdata(in: start..<content.count) + Data(repeating: 0xA5, count: excess))
            }
            return MockResponse(status: 200, body: content + Data(repeating: 0xA5, count: excess))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        if resume { try E.prepare(root, partial: content.prefix(S.resumeOffset)) }
        do { try await E.installer(server, root: root).install { _ in }; Issue.record("accepted an oversized body") } catch {
            #expect(error.localizedDescription == Self.integrity)
        }
        #expect(!FileManager.default.fileExists(atPath: S.partialURL(root).path))
        #expect(!FileManager.default.fileExists(atPath: S.installedURL(root).path))
        #expect(E.leftovers(root).isEmpty)
        #expect(server.requests.map { $0.headers["range"] } == [resume ? "bytes=\(S.resumeOffset)-" : nil])
    }

    // MARK: DownloadStream on its own

    /// The stream (without the installer's clean-up) leaves an empty partial after refusing an
    /// oversized body: a chunk still queued after the refusal is never written. Repeated to expose a
    /// delivery race. The error names the file by the URL's last component when no name is given.
    @Test func theStreamWritesNothingAfterAnOversizeRefusal() async throws {
        let content = T.content
        let server = try await MockHTTPServer.start { _ in
            MockResponse(status: 200, body: content + Data((0..<6_000_000).map { UInt8(truncatingIfNeeded: $0 &* 11) }))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for attempt in 0..<20 {
            let partial = root.appending(path: "x.bin.partial")
            try? FileManager.default.removeItem(at: partial)
            let stream = DownloadStream(url: URL(string: server.baseURL + "/r/x.bin")!, offset: 0, partial: partial,
                                        expected: Int64(content.count)) { _ in }
            do { try await stream.run(); Issue.record("attempt \(attempt): accepted an oversized body") } catch {
                #expect(error.localizedDescription == "x.bin failed its integrity check and was removed. Retry to download it again.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int
            #expect(size == 0, "attempt \(attempt): \(size.map(String.init) ?? "no file") bytes kept after the refusal")
        }
    }

    /// A clean short transfer through the stream alone is an interruption and keeps exactly the bytes
    /// that arrived, appended after the resume offset.
    @Test func theStreamKeepsAShortResumeAppendedAtItsOffset() async throws {
        let content = T.content
        let server = try await Self.cappingServer(content, cap: 70_000)
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appending(path: "x.partial")
        try content.prefix(10_000).write(to: partial)
        let stream = DownloadStream(url: URL(string: server.baseURL + "/x")!, offset: 10_000, partial: partial,
                                    expected: Int64(content.count), name: "fast/x") { _ in }
        do { try await stream.run(); Issue.record("accepted a short transfer") } catch {
            #expect(error.localizedDescription == Self.endedEarly)
        }
        #expect(try Data(contentsOf: partial) == content.prefix(80_000))
    }

    // MARK: DownloadStream's delegate, driven directly

    /// Drives the stream's delegate callbacks by hand (deterministic chunk boundaries and ordering,
    /// including a chunk arriving after a refusal, which loopback transfers never reproduce), then reads
    /// the recorded outcome through `run()`, which returns it without starting its request.
    final class Harness: @unchecked Sendable {
        let stream: DownloadStream
        let root = T.temporaryRoot()
        private let lock = NSLock()
        private var reportedOffsets: [Int64] = []
        let session = URLSession(configuration: .ephemeral)
        let task: URLSessionDataTask

        init(offset: Int64 = 0, expected: Int64 = 100) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = URL(string: "http://127.0.0.1:9/r/x.bin")!
            task = session.dataTask(with: url)   // never resumed
            var sink: ((Int64) -> Void)!
            stream = DownloadStream(url: url, offset: offset, partial: root.appending(path: "x.partial"), expected: expected,
                                    name: "p/x.bin") { sink($0) }
            sink = { [unowned self] value in lock.withLock { reportedOffsets.append(value) } }
        }
        deinit { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }

        var reported: [Int64] { lock.withLock { reportedOffsets } }
        func respond(_ status: Int, contentRange: String? = nil) async -> URLSession.ResponseDisposition {
            let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: contentRange.map { ["Content-Range": $0] } ?? [:])!
            return await stream.urlSession(session, dataTask: task, didReceive: response)
        }
        func receive(_ count: Int) { stream.urlSession(session, dataTask: task, didReceive: Data(repeating: 1, count: count)) }
        func finish(_ error: Error? = nil) { stream.urlSession(session, task: task, didCompleteWithError: error) }
        /// The outcome as `run()` reports it: "ok" or the error's text.
        func outcome() async -> String {
            do { try await stream.run(); return "ok" } catch { return error.localizedDescription }
        }
    }

    /// A chunk delivered after an over-size refusal is ignored: it is not written, not counted, not
    /// reported as progress, and the refusal stands as the outcome.
    @Test func aChunkAfterAnOversizeRefusalIsIgnored() async throws {
        let h = try Harness(expected: 100)
        #expect(await h.respond(200) == .allow)
        h.receive(40)
        h.receive(61)   // 101 > 100: refused
        h.receive(100)  // queued before the cancellation took effect
        h.receive(1)
        h.finish(URLError(.cancelled))
        #expect(h.reported == [40])
        #expect(await h.outcome() == "p/x.bin failed its integrity check and was removed. Retry to download it again.")
    }

    /// A chunk delivered after a misaligned resume was refused is ignored, and the refusal (not the
    /// cancellation it caused) is what the user is told.
    @Test func aChunkAfterAMisalignedResumeIsIgnored() async throws {
        let h = try Harness(offset: 50, expected: 100)
        #expect(await h.respond(206, contentRange: "bytes 0-99/100") == .cancel)
        h.receive(50)
        h.finish(URLError(.cancelled))
        #expect(h.reported.isEmpty)
        #expect(await h.outcome() == "Model download was interrupted: the server resumed at the wrong position (bytes 0-99/100); "
                + "retry to download from the start. Retry; downloads resume.")
    }

    /// The completion rule, at and around the pinned size: fewer bytes than pinned is "ended early"
    /// (kept for resume), exactly pinned is success, and a transport error is reported as itself.
    @Test(arguments: [(0, false, endedEarly), (99, false, endedEarly), (100, false, "ok"), (60, true, nil)] as [(Int, Bool, String?)])
    func completionIsJudgedByTheBytesThatArrived(bytes: Int, transportError: Bool, expected: String?) async throws {
        let h = try Harness(expected: 100)
        #expect(await h.respond(200) == .allow)
        if bytes > 0 { h.receive(bytes) }
        h.finish(transportError ? URLError(.notConnectedToInternet) : nil)
        let outcome = await h.outcome()
        if let expected {
            #expect(outcome == expected)
        } else {
            // The transport wording belongs to Foundation; only the framing is Chatter's.
            let transport = URLError(.notConnectedToInternet).localizedDescription
            #expect(outcome == "Model download was interrupted: \(transport). Retry; downloads resume.", "\(outcome)")
        }
    }

    /// A resumed stream counts the bytes it already had: 50 kept + 50 received completes, 50 + 49 is
    /// short, 50 + 51 is refused. A 200 answer to the resume starts the count from zero again.
    @Test(arguments: [(206, 50, "ok"), (206, 49, endedEarly), (206, 51, "integrity"), (200, 100, "ok"), (200, 50, endedEarly)])
    func aResumeCountsTheBytesAlreadyKept(status: Int, received: Int, expected: String) async throws {
        let h = try Harness(offset: 50, expected: 100)
        #expect(await h.respond(status, contentRange: status == 206 ? "bytes 50-99/100" : nil) == .allow)
        h.receive(received)
        h.finish()
        let outcome = await h.outcome()
        #expect(expected == "integrity" ? outcome.hasPrefix("p/x.bin failed its integrity check") : outcome == expected, "\(outcome)")
    }

    /// HTTP failures name the file by its installed path when given one, else by the URL's last component.
    @Test(arguments: [("fast/tokenizer.json", "fast/tokenizer.json"), (nil, "tokenizer.json")] as [(String?, String)])
    func httpFailuresNameTheFile(name: String?, shown: String) async throws {
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 404) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stream = DownloadStream(url: URL(string: server.baseURL + "/org/repo/resolve/abc/tokenizer.json")!, offset: 0,
                                    partial: root.appending(path: "t.partial"), expected: 10, name: name) { _ in }
        do { try await stream.run(); Issue.record("accepted a 404") } catch {
            #expect(error.localizedDescription == "Model download failed with HTTP 404 for \(shown). Retry; downloads resume.")
        }
    }
}

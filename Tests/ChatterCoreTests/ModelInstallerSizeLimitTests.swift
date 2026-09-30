import Foundation
import os
import Testing
@testable import ChatterCore

/// The pinned size is a hard ceiling on what a download may write, and a resumed (206) response is
/// appended only when its Content-Range starts exactly where the partial file ends. Every refusal
/// must leave a state the next "Retry" repairs, and nothing unverified may be installed.
struct ModelInstallerSizeLimitTests {
    typealias T = ModelInstallerTests
    typealias E = ModelInstallerEdgeTests

    static let resumeOffset = 100_000

    static func partialURL(_ root: URL) -> URL { root.appending(path: "p/model.bin.partial") }
    static func installedURL(_ root: URL) -> URL { root.appending(path: "p/model.bin") }
    static func partialSize(_ root: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: partialURL(root).path))?[.size] as? Int
    }

    /// A server that answers the first `misbehaving` requests with `bad`, then behaves like a CDN.
    static func server(_ body: Data, misbehaving: Int, bad: @escaping @Sendable (MockRequest) -> MockResponse) async throws -> MockHTTPServer {
        let served = OSAllocatedUnfairLock(initialState: 0)
        return try await MockHTTPServer.start { request in
            let index = served.withLock { count -> Int in defer { count += 1 }; return count }
            if index < misbehaving { return bad(request) }
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                                    body: body.subdata(in: start..<body.count))
            }
            return MockResponse(status: 200, body: body)
        }
    }

    // MARK: The pinned size as a boundary

    /// One byte short, exact, one byte over — for a fresh download (200) and a resume (206). Only the
    /// exact size installs; the short body fails verification, the long one is cut off by the stream.
    /// Guards against `<` for `<=` (or the reverse) in the size ceiling.
    @Test(arguments: [(-1, false), (0, false), (1, false), (-1, true), (0, true), (1, true)])
    func thePinnedSizeIsAnExactBoundary(delta: Int, resume: Bool) async throws {
        let content = T.content
        let body = delta < 0 ? content.prefix(content.count + delta) : content + Data(repeating: 0x5A, count: delta)
        let server = try await MockHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"],
                                    body: body.subdata(in: start..<body.count))
            }
            return MockResponse(status: 200, body: body)
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        if resume { try E.prepare(root, partial: content.prefix(Self.resumeOffset)) }
        let installer = E.installer(server, root: root)
        if delta == 0 {
            try await installer.install { _ in }
            #expect(try Data(contentsOf: Self.installedURL(root)) == content)
            #expect(E.leftovers(root).isEmpty && installer.isInstalled)
        } else {
            do { try await installer.install { _ in }; Issue.record("accepted a body \(delta) byte(s) off the pinned size") } catch {
                if delta > 0 {
                    guard case ModelInstallerError.integrity = error else { Issue.record("expected an integrity failure, got \(error)"); return }
                } else {
                    // A clean but short transfer is an interruption: what arrived is kept for the next resume.
                    guard case ModelInstallerError.interrupted = error else { Issue.record("expected an interruption, got \(error)"); return }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path))
            if delta > 0 {
                #expect((Self.partialSize(root) ?? 0) == 0, "bytes past the pinned size were kept")
            } else {
                #expect(Self.partialSize(root) == content.count + delta, "the short transfer's progress was lost")
            }
            #expect(!installer.isInstalled)
        }
        #expect(server.requests.map { $0.headers["range"] } == [resume ? "bytes=\(Self.resumeOffset)-" : nil])
    }

    // MARK: Oversized bodies

    /// A tiny file whose whole (oversized) body arrives in one chunk: the chunk is refused before any
    /// byte of it is written, with the integrity message the user sees.
    @Test func anOversizedBodyArrivingInOneChunkWritesNothing() async throws {
        let small = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 1) })
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: small + Data([0])) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = E.installer(server, root: root, files: [T.file(content: small)])
        do { try await installer.install { _ in }; Issue.record("accepted an oversized body") } catch {
            #expect(error.localizedDescription == "p/model.bin failed its integrity check and was removed. Retry to download it again.")
        }
        #expect((Self.partialSize(root) ?? 0) == 0)   // removed after the refusal
        #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path))
    }

    /// A body many times the pinned size arrives in many chunks. After the refusal the partial is
    /// empty — not merely "no larger than the pinned size" — so no stray chunk can be written after
    /// the cut-off (which would misalign the next resume). Repeated to expose a delivery race.
    @Test func anOversizedBodyArrivingInManyChunksLeavesAnEmptyPartial() async throws {
        let oversized = T.content + Data((0..<8_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: oversized) }
        for attempt in 0..<20 {
            let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let installer = E.installer(server, root: root)
            await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
            #expect((Self.partialSize(root) ?? 0) == 0, "attempt \(attempt)")
            #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path))
        }
    }

    /// Progress never reports more than 100%, even while a server is sending far more than the pinned
    /// size (without the ceiling, it would climb past 700% here before verification failed).
    @Test func progressNeverExceedsTheWholeFile() async throws {
        let oversized = T.content + Data(repeating: 3, count: 2_000_000)
        let server = try await MockHTTPServer.start { _ in MockResponse(status: 200, body: oversized) }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let log = OSAllocatedUnfairLock(initialState: [String]())
        await #expect(throws: ModelInstallerError.self) {
            try await E.installer(server, root: root).install { message in log.withLock { $0.append(message) } }
        }
        let percents = log.withLock { $0 }.compactMap { line -> Double? in
            guard line.hasPrefix("  p/model.bin ") else { return nil }
            return Double(line.dropFirst("  p/model.bin ".count).dropLast(2))
        }
        #expect(percents.allSatisfy { $0 <= 100 }, "\(percents)")
    }

    /// After an oversize refusal the partial is empty, so the retry asks for the whole file (no
    /// Range) and installs the verified bytes.
    @Test func theRetryAfterAnOversizeRefusalDownloadsAfresh() async throws {
        let content = T.content
        let server = try await Self.server(content, misbehaving: 1) { _ in
            MockResponse(status: 200, body: content + Data(repeating: 1, count: 500_000))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = E.installer(server, root: root)
        await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == [nil, nil])
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
        #expect(E.leftovers(root).isEmpty)
    }

    /// A resume whose Content-Range starts at the right byte but claims a larger file is accepted at
    /// first (only the start is checked), then cut off at the pinned size: the partial — including
    /// the bytes kept from earlier attempts — is emptied, and the retry starts from byte 0.
    @Test func anAlignedResumeThatOverstatesTheSizeIsCutOffAndTheRetryStartsOver() async throws {
        let content = T.content, offset = Self.resumeOffset
        let server = try await Self.server(content, misbehaving: 1) { _ in
            MockResponse(status: 206, headers: ["Content-Range": "bytes \(offset)-2299999/2300000"],
                         body: content.subdata(in: offset..<content.count) + Data(repeating: 2, count: 2_000_000))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: content.prefix(offset))
        let installer = E.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted an oversized resume") } catch {
            guard case ModelInstallerError.integrity = error else { Issue.record("expected an integrity failure, got \(error)"); return }
        }
        #expect((Self.partialSize(root) ?? 0) == 0)   // removed after the refusal
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=\(offset)-", nil])
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
        #expect(E.leftovers(root).isEmpty)
    }

    /// The total in Content-Range is not trusted either way: a resume that starts at the right byte
    /// and delivers exactly the missing bytes installs, because the SHA-256 is the authority.
    @Test(arguments: ["bytes 100000-299999/999999", "bytes 100000-299999/*", "bytes 100000-"])
    func aResumeIsJudgedByItsStartAndItsBytesNotItsStatedTotal(contentRange: String) async throws {
        let content = T.content
        let server = try await MockHTTPServer.start { _ in
            MockResponse(status: 206, headers: ["Content-Range": contentRange], body: content.subdata(in: Self.resumeOffset..<content.count))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: content.prefix(Self.resumeOffset))
        try await E.installer(server, root: root).install { _ in }
        #expect(server.requests.count == 1)
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
    }

    // MARK: Content-Range presence and spelling

    /// Header names are case-insensitive (HTTP/2 and many proxies send them lowercase).
    @Test(arguments: ["content-range", "CONTENT-RANGE", "Content-range"])
    func theContentRangeHeaderNameIsCaseInsensitive(name: String) async throws {
        let content = T.content
        let server = try await MockHTTPServer.start { request in
            guard let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) else {
                return MockResponse(status: 200, body: content)
            }
            return MockResponse(status: 206, headers: [name: "bytes \(start)-\(content.count - 1)/\(content.count)"],
                                body: content.subdata(in: start..<content.count))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: content.prefix(Self.resumeOffset))
        try await E.installer(server, root: root).install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=\(Self.resumeOffset)-"])
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
    }

    /// A 206 without Content-Range names the problem, empties the partial, and the retry asks for the
    /// whole file — exactly two requests from a resume attempt to an installed model.
    @Test func aMissingContentRangeIsNamedAndTheRetryAsksForTheWholeFile() async throws {
        let content = T.content
        let server = try await Self.server(content, misbehaving: 1) { _ in
            MockResponse(status: 206, body: content.subdata(in: Self.resumeOffset..<content.count))
        }
        let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try E.prepare(root, partial: content.prefix(Self.resumeOffset))
        let installer = E.installer(server, root: root)
        do { try await installer.install { _ in }; Issue.record("accepted a 206 without Content-Range") } catch {
            #expect(error.localizedDescription == "Model download was interrupted: the server resumed at the wrong position (no Content-Range); "
                    + "retry to download from the start. Retry; downloads resume.")
        }
        #expect((Self.partialSize(root) ?? 0) == 0)   // removed after the refusal
        try await installer.install { _ in }
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=\(Self.resumeOffset)-", nil])
        #expect(try Data(contentsOf: Self.installedURL(root)) == content)
    }

    // MARK: Property: whatever the server sends, nothing unverified is installed

    /// Seeded fuzz over misbehaving servers: status (200/206), Content-Range start (right, wrong,
    /// missing), body length (short, exact, long) and a corrupt byte. Properties: the install never
    /// crashes; it succeeds only if the served bytes, placed where the installer put them, are the
    /// pinned file; a failure never leaves an installed file or a partial longer than the pinned
    /// size; and an honest server repairs it within two retries (a short transfer is kept for resume,
    /// so bytes that were both short and corrupt are only discarded by the next attempt's hash check),
    /// leaving no temporary files.
    @Test func noServerBehaviourInstallsUnverifiedBytesAndOneHonestRetryRepairs() async throws {
        let content = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) })
        let file = T.file(content: content)
        for seed in UInt64(1)...40 {
            var rng = SeededGenerator(seed: seed)
            let resumeAt = rng.next() % 2 == 0 ? 0 : Int(rng.next() % UInt64(content.count - 1)) + 1
            let status = rng.next() % 2 == 0 ? 200 : 206
            let startChoice = rng.next() % 3   // 0 right, 1 wrong, 2 missing
            let lengthDelta = [-1_000, -1, 0, 0, 0, 1, 50_000][Int(rng.next() % 7)]
            let corrupt = rng.next() % 5 == 0
            let servedStart = status == 200 ? 0 : resumeAt
            var served = content.subdata(in: servedStart..<content.count)
            if lengthDelta < 0 { served = served.prefix(max(0, served.count + lengthDelta)) } else { served += Data(repeating: 0xEE, count: lengthDelta) }
            if corrupt, !served.isEmpty { served[served.startIndex + served.count / 2] ^= 0x40 }
            let claimedStart = startChoice == 1 ? servedStart + 1 : servedStart
            var headers: [String: String] = [:]
            if status == 206, startChoice != 2 { headers["Content-Range"] = "bytes \(claimedStart)-\(servedStart + served.count - 1)/\(content.count)" }
            let honest = OSAllocatedUnfairLock(initialState: false)
            let server = try await MockHTTPServer.start { [served, headers] request in
                if !honest.withLock({ $0 }) { return MockResponse(status: status, headers: headers, body: served) }
                if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                    return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(content.count - 1)/\(content.count)"],
                                        body: content.subdata(in: start..<content.count))
                }
                return MockResponse(status: 200, body: content)
            }
            let root = T.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            if resumeAt > 0 { try E.prepare(root, partial: content.prefix(resumeAt)) }
            let installer = E.installer(server, root: root, files: [file])
            let label = "seed \(seed): resume \(resumeAt) status \(status) start \(startChoice) delta \(lengthDelta) corrupt \(corrupt)"
            // The only way the first attempt may succeed: the right bytes, at the right place.
            let aligned = status == 200 || (startChoice == 0 && servedStart == resumeAt) || (resumeAt == 0 && startChoice == 0)
            let shouldInstall = aligned && lengthDelta == 0 && !corrupt
            do {
                try await installer.install { _ in }
                #expect(shouldInstall, "installed unexpectedly — \(label)")
                #expect(try Data(contentsOf: Self.installedURL(root)) == content, "\(label)")
            } catch {
                #expect(!shouldInstall, "failed unexpectedly (\(error.localizedDescription)) — \(label)")
                #expect(!FileManager.default.fileExists(atPath: Self.installedURL(root).path), "\(label)")
                #expect((Self.partialSize(root) ?? 0) <= content.count, "\(label)")
                honest.withLock { $0 = true }
                if (try? await installer.install { _ in }) == nil { try await installer.install { _ in } }
                #expect(try Data(contentsOf: Self.installedURL(root)) == content, "\(label)")
            }
            #expect(E.leftovers(root).isEmpty, "\(label)")
        }
    }
}

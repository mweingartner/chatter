import Testing
import Foundation
@testable import ChatterCore

struct CoreTests {
    @Test func olderPreferencesKeepTheirValuesAndGainDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"port":19423,"allowLAN":false,"defaultVoiceID":"my-voice"}"#.utf8))
        #expect(settings.port == 19423)
        #expect(!settings.allowLAN)
        #expect(settings.defaultVoiceID == "my-voice")
        #expect(settings.queueCapacity == 1000)
        #expect(settings.nextJobSequence == 1)
    }
    @Test func requestBounds() throws {
        #expect(throws: ChatterError.self) { try SpeechRequest(voice:"v",text:" ").validated() }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice:"v",text:"Hello",pace:.nan).validated() }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice:"v",text:"Hello",pace:0.1).validated() }
        #expect(throws: ChatterError.self) { try SpeechRequest(voice:"v",text:String(repeating:"a",count:100001)).validated() }
        #expect(try SpeechRequest(voice:"v",text:"Hello",pace:0.5,mode:"save").validated().mode == "save")
    }
    @Test func incrementalHTTP() throws {
        let wire = Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for n in 0..<wire.count { #expect(try HTTPRequest.parse(Data(wire.prefix(n))) == nil) }
        let request = try #require(HTTPRequest.parse(wire)?.0)
        #expect(request.body == Data("{}".utf8)); #expect(request.path == "/mcp")
    }
    @Test func rejectSmugglingAndOversize() {
        let invalid = ["POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
                       "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
                       "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                       "POST / HTTP/1.1\r\nContent-Length: 2000001\r\n\r\n",
                       "GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n"]
        for wire in invalid { #expect(throws: ChatterError.self) { try HTTPRequest.parse(Data(wire.utf8)) } }
    }
    @Test func thousandReceiptsSurviveRestartInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobStore(directory: directory)
        for n in 1...1000 {
            var job = SpeechJob(request: SpeechRequest(voice:"v",text:"Request \(n)"),voiceName:"Voice")
            job.sequence = UInt64(n); job.requestID = "request-\(n)"
            try store.save(job)
        }
        let loaded = try JobStore(directory: directory).load()
        #expect(loaded.count == 1000)
        #expect(loaded.reversed().map(\.sequence) == Array(UInt64(1)...UInt64(1000)))
        #expect(Set(loaded.compactMap(\.requestID)).count == 1000)
        var first = try #require(loaded.last); first.state = "completed"; try store.save(first)
        #expect(try store.load().last?.state == "completed")
    }
    @Test func corruptQueueIsNotSilentlyDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("broken".utf8).write(to: directory.appending(path:"receipt.json"))
        #expect(throws: (any Error).self) { try JobStore(directory:directory).load() }
    }
}

/// Imports read only regular files, checked after opening, and never wait on a pipe.
struct RegularFileReadingTests {
    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func readsRegularFilesUpToOneByteOverTheLimit() throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "list.csv")
            try Data("SQL,sequel\n".utf8).write(to: file)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 100) == Data("SQL,sequel\n".utf8))
            try Data(repeating: 65, count: 1_000).write(to: file)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 10).count == 11)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 1_000).count == 1_000)
            let link = directory.appending(path: "link.csv")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(try ChatterPaths.readRegularFile(at: link, upTo: 2_000).count == 1_000)
            try Data().write(to: file)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 10).isEmpty)
        }
    }

    /// Stands in for a writer once `after` seconds have passed: it opens the pipe's write end, closes it
    /// half a second later, and repeats until stopped. A reader stuck in open() or read() is released,
    /// so a regression fails on time instead of hanging the suite.
    final class PipeWriterStandIn: @unchecked Sendable {
        private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pipe-writer-stand-in"))
        private var descriptor: Int32 = -1   // touched only on the timer's queue

        init(path: String, after seconds: Double) {
            timer.schedule(deadline: .now() + seconds, repeating: 0.5)
            timer.setEventHandler { [self] in
                if descriptor >= 0 { close(descriptor); descriptor = -1 } else { descriptor = open(path, O_WRONLY | O_NONBLOCK) }
            }
            timer.setCancelHandler { [self] in if descriptor >= 0 { close(descriptor); descriptor = -1 } }
            timer.resume()
        }

        func stop() { timer.cancel() }
    }

    /// A pipe, directly or through a link, is refused at once without waiting for a writer.
    @Test func pipesFoldersAndDevicesAreRefusedWithoutWaiting() throws {
        try Self.withDirectory { directory in
            let pipe = directory.appending(path: "pipe.csv")
            #expect(mkfifo(pipe.path, 0o600) == 0)
            let link = directory.appending(path: "pipe-link.csv")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pipe)
            let standIn = PipeWriterStandIn(path: pipe.path, after: 5)
            defer { standIn.stop() }
            let start = ContinuousClock.now
            for url in [pipe, link, directory, URL(filePath: "/dev/null"), URL(filePath: "/dev/zero")] {
                do { _ = try ChatterPaths.readRegularFile(at: url, upTo: 100); Issue.record("read \(url.path)") }
                catch { #expect(error.localizedDescription == "Choose a file, not a folder, pipe or device.", "\(url.path)") }
            }
            #expect(ContinuousClock.now - start < .seconds(4))
        }
    }

    @Test func missingFilesNameTheReason() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).csv")
        do { _ = try ChatterPaths.readRegularFile(at: missing, upTo: 10); Issue.record("read a missing file") }
        catch { #expect(error.localizedDescription == "Chatter couldn’t open “\(missing.lastPathComponent)”: No such file or directory.") }
    }

    /// A bound Unix-domain socket (directly or through a link) is refused at once: macOS can't open() one.
    @Test func socketsAreRefusedWithoutWaiting() throws {
        // sun_path holds 104 bytes, so the socket gets a short name in the temporary folder.
        let path = FileManager.default.temporaryDirectory.appending(path: "s\(UUID().uuidString.prefix(8)).sock").path
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(socketDescriptor >= 0)
        defer { close(socketDescriptor); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        try #require(path.utf8.count < capacity, "\(path) is too long for a socket")
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0, "bind: \(String(cString: strerror(errno)))")
        #expect(listen(socketDescriptor, 1) == 0)
        try Self.withDirectory { directory in
            let link = directory.appending(path: "socket-link.csv")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: path))
            let start = ContinuousClock.now
            for url in [URL(filePath: path), link] {
                do { _ = try ChatterPaths.readRegularFile(at: url, upTo: 100); Issue.record("read the socket at \(url.path)") }
                catch {
                    // open() fails on a socket; if a future macOS opened it, the type check must refuse it instead.
                    let refused = ["Chatter couldn’t open “\(url.lastPathComponent)”: \(String(cString: strerror(EOPNOTSUPP))).",
                                   "Choose a file, not a folder, pipe or device."]
                    #expect(refused.contains(error.localizedDescription), "\(error.localizedDescription)")
                }
            }
            #expect(ContinuousClock.now - start < .seconds(2))
        }
    }

    /// A file the user can't read names the reason instead of reading nothing.
    @Test(arguments: [0o000, 0o200])
    func unreadableFilesNameTheReason(permissions: Int) throws {
        guard getuid() != 0 else { return }   // root reads anything
        try Self.withDirectory { directory in
            let file = directory.appending(path: "locked.csv")
            try Data("SQL,sequel\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            do { _ = try ChatterPaths.readRegularFile(at: file, upTo: 100); Issue.record("read a file with permissions \(String(permissions, radix: 8))") }
            catch { #expect(error.localizedDescription == "Chatter couldn’t open “locked.csv”: Permission denied.") }
        }
    }

    /// A limit of 0 still reads one byte, so an empty file is told apart from one with anything in it.
    @Test func aLimitOfZeroReadsAtMostOneByte() throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "list.csv")
            for (size, expected) in [(0, 0), (1, 1), (2, 1), (4_096, 1)] {
                try Data(repeating: 0x41, count: size).write(to: file)
                #expect(try ChatterPaths.readRegularFile(at: file, upTo: 0) == Data(repeating: 0x41, count: expected), "size \(size)")
            }
            // At and around a limit: at it reads all, one over reads limit + 1, never more.
            try Data((0..<256).map { UInt8($0) }).write(to: file)
            for limit in [254, 255, 256, 257, 10_000] {
                #expect(try ChatterPaths.readRegularFile(at: file, upTo: limit) == Data((0..<min(256, limit + 1)).map { UInt8($0) }), "limit \(limit)")
            }
        }
    }

    /// Extreme limits neither trap nor misread: Int.max and its neighbours read the whole (small) file, and
    /// any negative limit, down to Int.min, reads as a limit of 0 (at most one byte).
    @Test(arguments: [Int.max, Int.max - 1, Int.max - 2, Int(Int32.max), -1, -2, -1_000_000, Int.min, Int.min + 1])
    func extremeLimitsNeitherTrapNorMisread(limit: Int) throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "list.csv")
            let contents = Data("SQL,sequel\nKubernetes,koo-ber-NET-eez\n".utf8)
            try contents.write(to: file)
            let expected = limit < 0 ? contents.prefix(1) : contents
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: limit) == expected, "limit \(limit)")
            try Data().write(to: file)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: limit).isEmpty, "limit \(limit)")
        }
    }

    /// With no effective limit the whole of a multi-megabyte file comes back, not just its first chunk.
    @Test func anUnlimitedReadReturnsTheWholeFile() throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "large.csv"), contents = Data((0..<3_000_001).map { UInt8($0 % 253) })
            try contents.write(to: file)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: Int.max) == contents)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: Int.max - 1) == contents)
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 3_000_001) == contents)                     // at the limit: all of it
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 3_000_000) == contents)                     // limit + 1 is the whole file
            #expect(try ChatterPaths.readRegularFile(at: file, upTo: 2_999_999) == contents.prefix(3_000_000))   // limit + 1, no more
        }
    }

    /// The import limit reads only limit + 1 bytes of a much larger file, and quickly.
    @Test func largeFilesAreReadOnlyToTheLimit() throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "large.csv")
            try Data(repeating: 0x61, count: 8_000_000).write(to: file)
            let start = ContinuousClock.now
            let data = try ChatterPaths.readRegularFile(at: file, upTo: 1_000_000)
            #expect(ContinuousClock.now - start < .seconds(2))
            #expect(data.count == 1_000_001)
        }
    }

    /// Descriptors open in this process on anything inside `directory`, found by asking each one for its
    /// path. Other tests run in parallel and open files of their own, so only ours are counted.
    static func descriptorsOpen(inside directory: URL) throws -> Int {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(directory.path, &resolved) != nil)
        let prefix = String(cString: resolved)
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let descriptor = Int32(name) else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH, &path) == 0, String(cString: path).hasPrefix(prefix) { count += 1 }
        }
        return count
    }

    /// No descriptor leaks on any path: read, read past the limit, refused after opening (a folder, a link
    /// to one, a device), or a failed open. A leak of one descriptor per call would leave hundreds open.
    @Test func noDescriptorLeaksAcrossManyCalls() throws {
        try Self.withDirectory { directory in
            let file = directory.appending(path: "list.csv"), missing = directory.appending(path: "missing.csv")
            let folderLink = directory.appending(path: "folder-link.csv"), sub = directory.appending(path: "sub")
            try Data("SQL,sequel\n".utf8).write(to: file)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: sub)
            let probe = open(file.path, O_RDONLY)   // proves the count sees an open descriptor on our file
            #expect(try Self.descriptorsOpen(inside: directory) == 1)
            close(probe)
            #expect(try Self.descriptorsOpen(inside: directory) == 0)
            for _ in 0..<500 {
                #expect(try ChatterPaths.readRegularFile(at: file, upTo: 100).count == 11)
                #expect(try ChatterPaths.readRegularFile(at: file, upTo: 3).count == 4)
                #expect(throws: ChatterError.self) { try ChatterPaths.readRegularFile(at: sub, upTo: 100) }
                #expect(throws: ChatterError.self) { try ChatterPaths.readRegularFile(at: folderLink, upTo: 100) }
                #expect(throws: ChatterError.self) { try ChatterPaths.readRegularFile(at: URL(filePath: "/dev/null"), upTo: 100) }
                #expect(throws: ChatterError.self) { try ChatterPaths.readRegularFile(at: missing, upTo: 100) }
            }
            #expect(try Self.descriptorsOpen(inside: directory) == 0)
        }
    }

    /// Many concurrent reads of one file all return the whole file.
    @Test func concurrentReadsAgree() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "list.csv"), contents = Data((0..<50_000).map { UInt8($0 % 251) })
        try contents.write(to: file)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<64 { group.addTask { try ChatterPaths.readRegularFile(at: file, upTo: 1_000_000) } }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        #expect(results.count == 64 && results.allSatisfy { $0 == contents })
    }
}

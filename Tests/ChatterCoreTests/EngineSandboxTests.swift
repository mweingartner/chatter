import Foundation
import Network
import Testing
@testable import ChatterCore

@Suite("Engine process isolation") struct EngineSandboxTests {
    @Test func helperCannotOpenNetworkConnections() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        defer { listener.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "isolation-listener"))
        }
        let port = try #require(listener.port)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try PrivateStorage.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = EngineSandbox.profile(root: root, bundle: URL(filePath: "/usr/bin"))
        func connect(isolated: Bool) throws -> Int32 {
            let process = Process()
            let command = ["/usr/bin/nc", "-z", "-G", "1", "127.0.0.1", String(port.rawValue)]
            process.executableURL = URL(filePath: isolated ? "/usr/bin/sandbox-exec" : command[0])
            process.arguments = isolated ? ["-p", profile] + command : Array(command.dropFirst())
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        #expect(try connect(isolated: false) == 0)
        #expect(try connect(isolated: true) != 0)
    }
    @Test func helperCanUseMediaButCannotReadCredentialsOrWriteOutsideItsDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "Home"), data = home.appending(path: "Chatter")
        let jobs = data.appending(path: "Jobs"), models = data.appending(path: "Models")
        let scratch = root.appending(path: "Scratch")
        for folder in [jobs, models, scratch] { try PrivateStorage.directory(folder) }
        let credential = data.appending(path: "api-token"), personal = home.appending(path: "personal.txt")
        let model = models.appending(path: "fixture")
        for file in [credential, personal, model] { try PrivateStorage.write(Data("canary".utf8), to: file) }
        let policy = EngineSandbox.profile(root: data, bundle: URL(filePath: "/bin"), home: home, temporary: scratch)
        func run(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", policy] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        #expect(try run(["/bin/cat", model.path]) == 0)
        #expect(try run(["/bin/cat", credential.path]) != 0)
        #expect(try run(["/bin/cat", personal.path]) != 0)
        let allowed = jobs.appending(path: "output"), denied = home.appending(path: "outside")
        #expect(try run(["/usr/bin/touch", allowed.path]) == 0)
        #expect(try run(["/usr/bin/touch", denied.path]) != 0)
        #expect(FileManager.default.fileExists(atPath: allowed.path))
        #expect(!FileManager.default.fileExists(atPath: denied.path))
    }
}

// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation
import os

/// Runs a child process to completion with piped stdin/stdout/stderr (Python's `subprocess.run`).
public enum ChildProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    /// Launches `executable`, feeds `input`, and collects both output streams without pipe deadlock.
    /// A bare command name (no `/`) is resolved through `PATH` via `/usr/bin/env`.
    public static func run(
        _ executable: String, _ arguments: [String] = [], input: Data = Data(),
        environment: [String: String]? = nil, currentDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        configure(process, executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        ignoreBrokenPipes()
        try process.run()
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            collected.withLock { $0 = data }
        }
        DispatchQueue.global().async(group: group) {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, standardOutput: output, standardError: collected.withLock { $0 })
    }

    static func configure(
        _ process: Process, executable: String, arguments: [String], environment: [String: String]?, currentDirectory: URL?
    ) {
        if executable.contains("/") {
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    }

    /// Writing to a child that already exited must raise EPIPE, not kill this process.
    static func ignoreBrokenPipes() { signal(SIGPIPE, SIG_IGN) }
}

/// A long-running MCP stdio server (e.g. `chatter-mcp`) driven one JSON-RPC line at a time.
public final class MCPStdioSession {
    private let process: Process
    private let input: FileHandle
    private let lines = LineBuffer()

    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil, currentDirectory: URL? = nil) throws {
        let process = Process()
        ChildProcess.configure(process, executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let buffer = lines
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            buffer.append(data)
        }
        ChildProcess.ignoreBrokenPipes()
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw VerificationFailure("Cannot launch the Chatter MCP transport \(executable): \(error.localizedDescription)")
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    /// Sends one line (a newline is appended).
    public func send(_ line: String) throws {
        do {
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            throw VerificationFailure("Installed Chatter MCP transport closed its input")
        }
    }

    /// The next complete stdout line, or `nil` on timeout or EOF.
    public func nextLine(timeout: TimeInterval) -> String? { lines.next(timeout: timeout) }

    /// Closes stdin and waits up to 5 s for exit, then terminates (and waits another 5 s).
    public func close() {
        try? input.close()
        if !waitForExit(seconds: 5) {
            process.terminate()
            _ = waitForExit(seconds: 5)
        }
    }

    private func waitForExit(seconds: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return !process.isRunning
    }
}

/// Splits streamed bytes into lines and hands them to a waiting reader.
private final class LineBuffer: Sendable {
    private struct State {
        var pending = Data()
        var lines: [String] = []
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let signal = DispatchSemaphore(value: 0)

    func append(_ data: Data) {
        state.withLock { state in
            if data.isEmpty {
                state.finished = true
                if !state.pending.isEmpty { state.lines.append(String(decoding: state.pending, as: UTF8.self)) }
                state.pending.removeAll()
                return
            }
            state.pending.append(data)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                state.lines.append(String(decoding: state.pending[..<newline], as: UTF8.self))
                state.pending.removeSubrange(...newline)
            }
        }
        signal.signal()
    }

    func next(timeout: TimeInterval) -> String? {
        let deadline = DispatchTime.now() + timeout
        while true {
            let (line, finished): (String?, Bool) = state.withLock { state in
                state.lines.isEmpty ? (nil, state.finished) : (state.lines.removeFirst(), false)
            }
            if let line { return line }
            if finished || signal.wait(timeout: deadline) == .timedOut { return nil }
        }
    }
}

/// Pauses Chatter's speech engine so queued jobs cannot drain during the queue stress test.
public protocol EngineSuspension: Sendable {
    /// Sends SIGSTOP (or equivalent) and returns the action that resumes the same engine.
    func suspend() throws -> EngineResumption
}

/// Resumes a suspended engine exactly once per call.
public struct EngineResumption: Sendable {
    private let action: @Sendable () throws -> Void

    public init(_ action: @escaping @Sendable () throws -> Void) { self.action = action }

    public func resume() throws { try action() }
}

/// Finds Chatter's engine helper as a direct child of the app process and signals it.
/// Formerly the Python `worker.py`; now the Swift `chatter-engine` helper.
public struct ChatterEngineProcess: EngineSuspension {
    public static let defaultAppName = "Chatter"
    public static let defaultEngineName = "chatter-engine"

    public let appName: String
    public let engineName: String

    public init(appName: String = defaultAppName, engineName: String = defaultEngineName) {
        self.appName = appName
        self.engineName = engineName
    }

    public func suspend() throws -> EngineResumption {
        let app = try Self.processIDs(["-x", appName])
        try verify(app.count == 1, "Expected one running \(appName) process; found \(app).")
        let engine = try Self.childProcessIDs(of: app[0], named: engineName)
        try verify(engine.count == 1, "Expected one \(engineName) child of \(appName) (pid \(app[0])); found \(engine).")
        let pid = engine[0]
        try Self.signal(pid, SIGSTOP)
        return EngineResumption { try Self.signal(pid, SIGCONT) }
    }

    /// Direct children of `parent` whose process name is exactly `name` (`pgrep -P parent -x name`).
    public static func childProcessIDs(of parent: pid_t, named name: String) throws -> [pid_t] {
        try processIDs(["-P", String(parent), "-x", name])
    }

    private static func processIDs(_ arguments: [String]) throws -> [pid_t] {
        let result = try ChildProcess.run("/usr/bin/pgrep", arguments)
        // pgrep exits 1 when nothing matches; anything else is a real failure.
        guard result.status == 0 || result.status == 1 else {
            throw VerificationFailure("pgrep \(arguments.joined(separator: " ")) failed with status \(result.status).")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private static func signal(_ pid: pid_t, _ signal: Int32) throws {
        guard kill(pid, signal) == 0 else {
            throw VerificationFailure("Cannot signal process \(pid): \(String(cString: strerror(errno))).")
        }
    }
}

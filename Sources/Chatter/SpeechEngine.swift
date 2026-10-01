import Foundation
import Observation
import ChatterCore

/// Supervises the `chatter-engine` helper: launches it, speaks the JSON-line protocol, restarts it
/// after a crash, and kills it if it stops making progress. The helper owns the speech models, so a
/// GPU fault there cannot take down the HTTP/MCP service or the durable queue.
@MainActor @Observable
final class SpeechEngine {
    var state = "stopped"
    var detail = "Engine has not started"
    var logTail = ""
    /// Profiles currently resident in the helper (`fast`, `quality`).
    var loadedProfiles: [String] = []
    /// Physical memory footprint of the helper, from its heartbeat.
    var footprintBytes: Int?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastHeard = ContinuousClock.now
    @ObservationIgnored var onReady: (() -> Void)?
    /// Whether the studio profile stays resident; applied at launch and on every restart.
    @ObservationIgnored var keepStudioLoaded = false

    /// A busy engine that reports no generated frame for this long is considered wedged.
    static let stallLimit: Double = 120
    /// A running engine that sends nothing (not even heartbeats) for this long is considered hung.
    static let silenceLimit: Duration = .seconds(45)

    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let event: ([String: Any]) -> Void
    }
    var ready: Bool { state == "ready" }

    /// The helper ships beside the app executable (Contents/MacOS in the bundle, the build directory in development).
    var executableURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "chatter-engine")
    }

    func start() {
        guard process == nil, validationTask == nil else { return }
        guard ModelInstaller().isInstalled else { state = "not installed"; detail = "Download the speech models in Engine settings."; return }
        state = "verifying"; detail = "Verifying installed speech models…"
        validationTask = Task { [weak self] in
            do {
                try await ModelInstaller().verifyInstalled(integrityCacheURL: ChatterPaths.root.appending(path: "model-integrity.json"))
                guard !Task.isCancelled, let self else { return }
                self.validationTask = nil; self.launchVerified()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.validationTask = nil; self.state = "error"; self.detail = "Model integrity check failed. Download / repair models in Engine settings."
            }
        }
    }
    private func launchVerified() {
        guard process == nil else { return }
        stopping = false
        guard ModelInstaller().isInstalled else {
            state = "not installed"; detail = "Download the speech models in Engine settings."; return
        }
        guard let executable = executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = "error"; detail = "The speech engine is missing from Chatter.app. Reinstall Chatter."; return
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        let logURL = ChatterPaths.root.appending(path: "Logs/engine.log")
        do {
            try rotateLogIfNeeded(logURL)
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd()
            let cache = ChatterPaths.root.appending(path: "EngineCache")
            try PrivateStorage.directory(cache)
            let temporary = cache.appending(path: "Temporary")
            try PrivateStorage.directory(temporary)
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw ChatterError.unavailable("The macOS engine isolation service is unavailable.") }
            p.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", EngineSandbox.profile(root: ChatterPaths.root, bundle: Bundle.main.bundleURL), executable.path]
            var env = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].contains($0.key) }
            env["CHATTER_DATA_ROOT"] = ChatterPaths.root.path
            env["TMPDIR"] = temporary.path + "/"
            env["CHATTER_KEEP_STUDIO"] = keepStudioLoaded ? "1" : "0"
            p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = log
            p.qualityOfService = .userInitiated
            let stream = AsyncStream<Data> { continuation in
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { continuation.finish() } else { continuation.yield(data) }
                }
                continuation.onTermination = { _ in stdout.fileHandleForReading.readabilityHandler = nil }
            }
            p.terminationHandler = { [weak self] process in
                Task { @MainActor in self?.terminated(process) }
            }
            try p.run(); process = p; input = stdin.fileHandleForWriting
            lastHeard = .now
            state = "warming"; detail = "Loading the speech model…"
            reader = Task { [weak self] in
                var buffer = Data()
                for await data in stream {
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self?.receive(object) }
                    }
                }
            }
            startWatchdog()
        } catch { state = "error"; detail = error.localizedDescription }
    }

    private func receive(_ event: [String: Any]) {
        lastHeard = .now
        guard let id = event["id"] as? String, let kind = event["event"] as? String else { return }
        if id == EngineProtocol.engineID {
            switch kind {
            case "hello":
                if (event["protocol"] as? Int) != EngineProtocol.version {
                    detail = "The speech engine speaks an incompatible protocol. Reinstall Chatter."
                    state = "error"; process?.terminate()
                }
            case "ready":
                state = "ready"; detail = "The speech engine is warm and ready"; failures = 0
                loadedProfiles = event["profiles"] as? [String] ?? loadedProfiles
                onReady?()
            case "error": state = "error"; detail = event["message"] as? String ?? "Engine error"
            case "heartbeat":
                loadedProfiles = event["profiles"] as? [String] ?? loadedProfiles
                footprintBytes = event["footprintBytes"] as? Int
                if let stalled = event["stalledSeconds"] as? Double, stalled > Self.stallLimit {
                    recover(reason: "The speech engine stopped making progress; restarting it.")
                }
            case "loaded", "unloaded":
                if let profile = event["profile"] as? String {
                    if kind == "loaded" { if !loadedProfiles.contains(profile) { loadedProfiles.append(profile) } }
                    else { loadedProfiles.removeAll { $0 == profile } }
                }
            case "loading":
                if !ready { state = "warming" }
                if !ready { detail = "Loading the \(event["profile"] as? String == "quality" ? "studio" : "speech") model…" }
            default: break
            }
            return
        }
        guard let request = pending[id] else { return }
        request.event(event)
        if kind == "done" { pending.removeValue(forKey: id); request.continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: event)) ?? Data()) }
        else if kind == "error" || kind == "cancelled" {
            pending.removeValue(forKey: id)
            request.continuation.resume(throwing: kind == "cancelled" ? ChatterError.cancelled : ChatterError.unavailable(event["message"] as? String ?? "Speech engine failed"))
        }
    }

    func command(_ value: [String: Any], timeout: Double = 3600, onEvent: @escaping ([String: Any]) -> Void = { _ in }) async throws -> [String: Any] {
        guard ready, input != nil else { throw ChatterError.unavailable(detail) }
        let id = value["id"] as? String ?? UUID().uuidString
        var payload = value; payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([10])
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.pending[id] != nil else { return }
            self.cancel(id)
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, self.pending[id] != nil { self.recover(reason: "Generation time limit reached; restarting the engine.") }
        }
        defer { deadline.cancel() }
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation, event: onEvent)
            do { try input?.write(contentsOf: data) }
            catch { pending.removeValue(forKey: id); continuation.resume(throwing: error) }
        }
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { throw ChatterError.unavailable("Invalid engine response") }
        return object
    }

    /// Forwards preferences that change engine residency (no reply is awaited).
    func configure(keepStudioLoaded: Bool) {
        self.keepStudioLoaded = keepStudioLoaded
        guard ready else { return }
        Task { _ = try? await command(["op": "configure", "keepStudioLoaded": keepStudioLoaded]) }
    }

    func cancel(_ id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["op":"cancel", "target":id]) else { return }
        try? input?.write(contentsOf: data + Data([10]))
    }

    func stop() {
        stopping = true; restartTask?.cancel(); reader?.cancel(); watchdog?.cancel(); validationTask?.cancel(); validationTask = nil
        try? input?.close(); input = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil; state = "stopped"; detail = "Engine stopped"; loadedProfiles = []; footprintBytes = nil
        failPending("Speech engine stopped")
    }

    func restart() { stop(); failures = 0; start() }

    private func failPending(_ reason: String) {
        let old = pending; pending.removeAll()
        for value in old.values { value.continuation.resume(throwing: ChatterError.unavailable(reason)) }
    }

    /// Kills a wedged helper; the termination handler fails its job visibly and restarts it.
    private func recover(reason: String) {
        guard let p = process, p.isRunning else { return }
        detail = reason
        p.terminate()
        let pid = p.processIdentifier
        Task { try? await Task.sleep(for: .seconds(3)); if p.isRunning { kill(pid, SIGKILL) } }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.process != nil else { return }
                if ContinuousClock.now - self.lastHeard > Self.silenceLimit { self.recover(reason: "The speech engine went silent; restarting it.") }
            }
        }
    }

    private func terminated(_ exited: Process) {
        guard !stopping, process === exited else { return }
        let code = exited.terminationStatus
        watchdog?.cancel()
        process = nil; input = nil; loadedProfiles = []; footprintBytes = nil
        failPending("Speech engine exited (\(code))")
        state = "error"; detail = "Speech engine exited (\(code))"
        failures += 1
        guard failures <= 3 else { detail += ". Open Engine settings to inspect the log and retry."; return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }; self?.start()
        }
    }

    /// Keeps the engine log bounded (one previous generation is retained).
    private func rotateLogIfNeeded(_ url: URL) throws {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 20 << 20 else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: url, to: previous)
    }

    func refreshLog() {
        let url = ChatterPaths.root.appending(path: "Logs/engine.log")
        logTail = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.suffix(12_000)) } ?? "No engine log yet."
    }
}

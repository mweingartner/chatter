// chatter-engine: Chatter's speech engine helper process.
//
// The app launches and supervises this process. Commands arrive as JSON lines on stdin; events
// leave as JSON lines on stdout, which carries nothing else. Diagnostics go to stderr (the app's
// engine log). The engine never accepts network connections and exits when its parent closes stdin.
import ChatterCore
import ChatterEngine
import Foundation

setvbuf(stdout, nil, _IOFBF, 1 << 16)
let host = EngineHost()
host.run()

final class EngineHost: @unchecked Sendable {
    private let outputLock = NSLock()
    private let queueLock = NSCondition()
    private var queue: [@Sendable (SpeechEngineCore) -> Void] = []
    private var engine: SpeechEngineCore!
    /// Written by the worker thread, read by the heartbeat and idle timers.
    private let status = HostStatus()
    private var ready = false   // worker thread only
    private let activity = ActivityClock()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timers: [DispatchSourceTimer] = []

    func emit(_ id: String, _ event: String, _ fields: [String: Any] = [:]) {
        var object = fields.mapValues(Self.jsonSafe)
        object["id"] = id; object["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            log("Could not encode \(event) event for \(id)"); return
        }
        outputLock.withLock {
            FileHandle.standardOutput.write(data + Data([10]))
        }
        activity.touch()
    }

    /// JSON has no NaN/Infinity; report them as null rather than corrupting the protocol.
    static func jsonSafe(_ value: Any) -> Any {
        if let d = value as? Double, !d.isFinite { return NSNull() }
        if let dict = value as? [String: Any] { return dict.mapValues(jsonSafe) }
        return value
    }

    func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    func run() {
        let environment = ProcessInfo.processInfo.environment
        let dataRoot = URL(filePath: environment["CHATTER_DATA_ROOT"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Chatter").path)
        var configuration = EngineConfiguration(modelsRoot: URL(filePath: environment["CHATTER_MODELS"] ?? dataRoot.appending(path: "Models").path), dataRoot: dataRoot)
        if environment["CHATTER_KEEP_STUDIO"] == "1" { configuration.keepStudioLoaded = true }
        engine = SpeechEngineCore(configuration: configuration) { [unowned self] id, event, fields in
            // The engine emits on the worker thread, where its profile list may be read.
            if id == EngineProtocol.engineID, event == "loaded" || event == "unloaded" { status.set(profiles: engine.loadedProfiles) }
            emit(id, event, fields)
        }
        let clock = activity
        engine.onActivity = { clock.touch() }
        emit(EngineProtocol.engineID, "hello", ["protocol": EngineProtocol.version, "engine": "chatter-engine",
                                                "version": EngineVersion.current, "pid": Int(getpid())])
        emit(EngineProtocol.engineID, "starting")

        let worker = Thread { [unowned self] in self.workLoop() }
        worker.name = "chatter-engine.worker"
        worker.stackSize = 16 << 20
        worker.qualityOfService = .userInitiated
        worker.start()
        startMonitors()
        readCommands()
    }

    private func readCommands() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            do {
                let command = try EngineCommand.decode(Data(line.utf8))
                switch command {
                case .cancel(let target): engine.requestCancel(target)
                default: enqueue(command)
                }
            } catch {
                // A malformed command is reported on its own id when one can be recovered.
                let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] as? String
                if let id { emit(id, "error", ["message": error.localizedDescription]) } else { log("Invalid command: \(error.localizedDescription)") }
            }
        }
        exit(0)   // Parent pipe closed: never leave an orphan model process.
    }

    private func enqueue(_ command: EngineCommand) {
        schedule { [unowned self] engine in
            let id = command.id
            do {
                guard ready else { throw EngineFailure.failed("The speech engine is not ready.") }
                status.set(job: id)
                defer { status.set(job: nil) }
                if engine.isCancelledExternally(id) { throw EngineFailure.cancelled }
                let result: [String: Any]
                switch command {
                case .synthesize(let c): result = try engine.synthesize(c)
                case .prepare(let c): result = try engine.prepare(c)
                case .precache(let c): try engine.precache(c); result = [:]
                case .analyze(let c): result = try engine.analyze(c)
                case .configure(let c): try engine.configure(c); result = engine.status()
                case .status: result = engine.status()
                case .cancel: result = [:]
                }
                emit(id, "done", result)
            } catch EngineFailure.cancelled {
                emit(id, "cancelled")
            } catch {
                log("\(id): \(error.localizedDescription)")
                emit(id, "error", ["message": error.localizedDescription])
            }
            engine.clearCancellation(id)
        }
    }

    private func schedule(_ task: @escaping @Sendable (SpeechEngineCore) -> Void) {
        queueLock.withLock { queue.append(task); queueLock.signal() }
    }

    private func workLoop() {
        do {
            try engine.start()
            ready = true
            emit(EngineProtocol.engineID, "ready", ["profiles": engine.loadedProfiles])
        } catch {
            log("Engine start failed: \(error.localizedDescription)")
            emit(EngineProtocol.engineID, "error", ["message": error.localizedDescription])
        }
        while true {
            queueLock.lock()
            while queue.isEmpty { queueLock.wait() }
            let task = queue.removeFirst()
            queueLock.unlock()
            autoreleasepool { task(engine) }
        }
    }

    private func startMonitors() {
        // Heartbeats let the app detect a wedged engine (stalled while busy) and show memory use.
        let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        heartbeat.schedule(deadline: .now() + 5, repeating: 5)
        heartbeat.setEventHandler { [unowned self] in
            let (job, profiles) = status.snapshot
            var fields: [String: Any] = ["busy": job != nil, "profiles": profiles, "footprintBytes": engine.footprintBytes]
            if let job { fields["job"] = job; fields["stalledSeconds"] = activity.secondsSinceTouch }
            outputLock.withLock {
                var object = fields; object["id"] = EngineProtocol.engineID; object["event"] = "heartbeat"
                if let data = try? JSONSerialization.data(withJSONObject: object) { FileHandle.standardOutput.write(data + Data([10])) }
            }
        }
        heartbeat.resume()
        // Release the studio profile after inactivity (evaluated between jobs on the worker thread).
        let idle = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        idle.schedule(deadline: .now() + 30, repeating: 30)
        idle.setEventHandler { [unowned self] in
            let empty = queueLock.withLock { queue.isEmpty }
            if empty, status.snapshot.job == nil { schedule { $0.idleTick() } }
        }
        idle.resume()
        timers = [heartbeat, idle]
        // Respond to macOS memory pressure instead of pushing the Mac into swap.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [unowned self] in
            let critical = pressure.data.contains(.critical)
            log("Memory pressure \(critical ? "critical" : "warning"); releasing caches.")
            schedule { $0.relieveMemoryPressure(critical: critical) }
        }
        pressure.resume()
        pressureSource = pressure
    }
}

/// The job in progress and the loaded profiles, as last set by the worker thread.
final class HostStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var job: String?
    private var profiles: [String] = []
    func set(job: String?) { lock.withLock { self.job = job } }
    func set(profiles: [String]) { lock.withLock { self.profiles = profiles } }
    var snapshot: (job: String?, profiles: [String]) { lock.withLock { (job, profiles) } }
}

/// Seconds since the engine last reported work (any emitted event or processed frame).
final class ActivityClock: @unchecked Sendable {
    private var last = Date()
    private let lock = NSLock()
    func touch() { lock.withLock { last = Date() } }
    var secondsSinceTouch: Double { lock.withLock { Date().timeIntervalSince(last) } }
}

// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// A validated `chatter-handoff.json`: scene order, completed-job receipts and timing settings.
public struct RemotionHandoffPlan: Sendable, Equatable {
    public struct Scene: Sendable, Equatable {
        public let id: String
        public let title: String
        /// The job ID exactly as written in the handoff (compared verbatim with Chatter's reply).
        public let jobID: String
    }

    /// Integer video frame rate, 1–120.
    public let fps: Int
    /// Silent frames appended after each scene: `ceil(tailSeconds × fps)`.
    public let tailFrames: Int
    public let scenes: [Scene]

    public static let defaultFPS = 30
    public static let defaultTailSeconds = 0.2
    public static let maximumSceneIDLength = 128

    /// Validates a decoded handoff with the Python helper's rules and messages.
    public init(validating plan: JSONValue) throws(RemotionHandoffError) {
        guard case .object(let object) = plan else { throw .invalidPlan("The handoff must be a JSON object.") }
        guard case .int(let fps) = object["fps"] ?? .int(Self.defaultFPS), (1...120).contains(fps) else {
            throw .invalidPlan("fps must be an integer from 1 to 120.")
        }
        let tail: Double
        switch object["tailSeconds"] ?? .double(Self.defaultTailSeconds) {
        case .int(let value): tail = Double(value)
        case .double(let value): tail = value
        default: throw .invalidPlan("tailSeconds must be between 0 and 5.")
        }
        guard tail.isFinite, (0...5).contains(tail) else { throw .invalidPlan("tailSeconds must be between 0 and 5.") }
        guard case .array(let rawScenes)? = object["scenes"], !rawScenes.isEmpty else {
            throw .invalidPlan("At least one scene is required.")
        }
        var seen = Set<[UInt8]>()
        var scenes: [Scene] = []
        for raw in rawScenes {
            guard case .object(let scene) = raw else { throw .invalidPlan("Each scene must be an object.") }
            // Uniqueness compares code points (like Python), not canonically-equivalent Swift strings.
            guard case .string(let id)? = scene["id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                id.unicodeScalars.count <= Self.maximumSceneIDLength, seen.insert(Array(id.utf8)).inserted
            else { throw .invalidPlan("Scene IDs must be nonempty, unique strings of at most 128 characters.") }
            guard case .string(let title) = scene["title"] ?? .string(id) else {
                throw .invalidPlan("Scene titles must be strings.")
            }
            guard case .string(let jobID)? = scene["jobID"], CanonicalUUID(jobID) != nil else {
                throw .invalidPlan("Scene \(id) needs a Chatter jobID.")
            }
            scenes.append(Scene(id: id, title: title, jobID: jobID))
        }
        self.fps = fps
        tailFrames = Int((tail * Double(fps)).rounded(.up))
        self.scenes = scenes
    }
}

/// Python `str(uuid.UUID(text))`: accepts optional `urn:`/`uuid:` markers, braces and hyphens,
/// and yields the lowercase 8-4-4-4-12 form used in content-addressed asset names.
struct CanonicalUUID: Sendable, Equatable, CustomStringConvertible {
    let description: String

    init?(_ text: String) {
        var hex = text.replacingOccurrences(of: "urn:", with: "").replacingOccurrences(of: "uuid:", with: "")
        hex = String(hex.trimmingPrefix(while: { $0 == "{" || $0 == "}" }))
        while let last = hex.last, last == "{" || last == "}" { hex.removeLast() }
        hex = hex.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.utf8.count == 32, hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        let characters = Array(hex)
        description = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }.joined(separator: "-")
    }
}

/// Where the stager reads job receipts and audio from (a live Chatter, or a test double).
public protocol ChatterJobSource: Sendable {
    /// The `chatter_job` structured content for `id`.
    func job(id: String) async throws -> JSONObject
    /// Writes the job's WAV (from its `audioURL`) to `destination`, which does not exist yet.
    func downloadAudio(for job: JSONObject, to destination: URL) async throws
}

/// Reads jobs through Chatter's MCP endpoint and audio through its authenticated audio route,
/// using the same `CHATTER_URL` / `CHATTER_TOKEN_FILE` settings as the bridge.
public struct ChatterServiceJobSource: ChatterJobSource {
    public static let downloadTimeout: TimeInterval = 30

    private let environment: [String: String]
    private let home: URL
    private let forwarder: ChatterMCPForwarder
    private let http = ChatterHTTPSession(timeout: Self.downloadTimeout)

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.home = home
        forwarder = ChatterMCPForwarder(environment: environment, home: home)
    }

    public func job(id: String) async throws -> JSONObject {
        let call: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "chatter_job", "arguments": ["id": .string(id)]],
        ]
        let reply = try await forwarder.forward(call)
        guard case .object(let envelope)? = reply, envelope["error"] == nil,
            case .object(let result) = envelope["result"] ?? .object(JSONObject()),
            !(result["isError"]?.isTruthy ?? false),
            case .object(let job)? = result["structuredContent"], !job.isEmpty
        else { throw RemotionHandoffError.jobUnreadable(jobID: id) }
        return job
    }

    public func downloadAudio(for job: JSONObject, to destination: URL) async throws {
        let connection = try ChatterConnection.resolve(environment: environment, home: home)
        guard case .string(let route)? = job["audioURL"] else { throw RemotionHandoffError.unexpectedAudioRoute }
        var request = URLRequest(url: try connection.url(for: route), timeoutInterval: Self.downloadTimeout)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        do {
            let response = try await http.download(request, to: destination)
            guard (200..<300).contains(response.statusCode) else { throw RemotionHandoffError.audioDownloadFailed }
        } catch {
            throw RemotionHandoffError.audioDownloadFailed
        }
    }
}

/// Stages completed Chatter jobs as local Remotion assets with sample-derived timing and publishes
/// `chatter-narration.json` atomically. Never submits speech or edits visual sources.
public struct RemotionStager: Sendable {
    public static let manifestFileName = "chatter-narration.json"
    /// Assets live under `public/chatter/` so Remotion's `staticFile("chatter/…")` finds them.
    public static let assetDirectory = "public/chatter"
    public static let maximumPollInterval: Double = 2

    private let source: any ChatterJobSource
    private let pause: @Sendable (Double) async throws -> Void

    /// - Parameter pause: Waits between polls of a queued job (injectable for tests).
    public init(
        source: any ChatterJobSource = ChatterServiceJobSource(),
        pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.source = source
        self.pause = pause
    }

    /// The manifest location for a project path (after `~` expansion and symlink resolution).
    public static func manifestURL(project: String) -> URL {
        resolvedProject(project).appending(path: manifestFileName)
    }

    /// Validates `plan`, resolves every receipt, stages verified WAVs and publishes the manifest.
    /// Any failure leaves the previous manifest untouched and removes partial downloads.
    @discardableResult
    public func prepare(plan: JSONValue, project: String, waitSeconds: Double = 0) async throws -> JSONValue {
        let handoff = try RemotionHandoffPlan(validating: plan)
        let project = Self.resolvedProject(project)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.appending(path: "package.json").path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { throw RemotionHandoffError.projectMissing }
        guard waitSeconds.isFinite, waitSeconds >= 0 else { throw RemotionHandoffError.invalidWaitSeconds }
        // Resolve every receipt first: a pending/failed job must not replace a usable manifest.
        let jobs = try await completedJobs(handoff.scenes, waitSeconds: waitSeconds)
        let assets = project.appending(path: Self.assetDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        // Staging inside the project keeps renames on one filesystem (atomic) and contains partial downloads.
        let staging = try Self.makeStagingDirectory(in: project)
        defer { try? FileManager.default.removeItem(at: staging) }

        var scenes: [JSONValue] = []
        var cursor = 0
        for (index, (scene, job)) in zip(handoff.scenes, jobs).enumerated() {
            let temporary = staging.appending(path: "\(index).wav")
            try await source.downloadAudio(for: job, to: temporary)
            let timing = try NarrationTiming(inspecting: temporary, fps: handoff.fps)
            let digest = try SHA256Digest.file(at: temporary)
            guard case .string(let jobID)? = job["id"], let uuid = CanonicalUUID(jobID) else {
                throw RemotionHandoffError.notSaveJob(scene: scene.id)
            }
            let name = "\(uuid)-\(digest.prefix(16)).wav"
            let destination = assets.appending(path: name)
            if !FileManager.default.fileExists(atPath: destination.path) || (try? SHA256Digest.file(at: destination)) != digest {
                try Self.atomicallyReplace(destination, with: temporary)
            }
            guard case .object(let request)? = job["request"], let text = request["text"], let voice = request["voice"],
                let pace = request["pace"]
            else { throw RemotionHandoffError.malformedJob(scene: scene.id) }
            let tone = request["tone"].flatMap { $0.isTruthy ? $0 : nil } ?? "natural"
            let durationInFrames = timing.audioFrames + handoff.tailFrames
            var entry: JSONObject = [
                "id": .string(scene.id), "title": .string(scene.title), "jobID": .string(jobID),
                "text": text, "voice": voice, "tone": tone, "pace": pace,
                "src": .string("chatter/\(name)"), "sha256": .string(digest),
                "from": .int(cursor), "durationInFrames": .int(durationInFrames), "tailFrames": .int(handoff.tailFrames),
                "durationSeconds": .double(timing.durationSeconds), "audioFrames": .int(timing.audioFrames),
                "sampleRate": .int(timing.sampleRate), "channels": .int(timing.channels),
                "bitsPerSample": .int(timing.bitsPerSample),
            ]
            try NarrationMetadata.add(to: &entry, request: request, job: job,
                                      timing: timing, fps: handoff.fps, scene: scene.id)
            scenes.append(.object(entry))
            cursor += durationInFrames
        }
        let manifest: JSONValue = [
            "schemaVersion": 1, "fps": .int(handoff.fps), "durationInFrames": .int(cursor), "scenes": .array(scenes),
        ]
        let staged = staging.appending(path: "manifest.json")
        try Data((manifest.encoded(.indented, asciiOnly: false) + "\n").utf8).write(to: staged)
        try Self.atomicallyReplace(project.appending(path: Self.manifestFileName), with: staged)
        return manifest
    }

    /// Polls each scene's receipt until completed (or the shared deadline passes), then checks it is
    /// the scene's own `mode=save` job with the expected audio route.
    func completedJobs(_ scenes: [RemotionHandoffPlan.Scene], waitSeconds: Double) async throws -> [JSONObject] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(waitSeconds))
        var jobs: [JSONObject] = []
        for scene in scenes {
            var job: JSONObject
            while true {
                job = try await source.job(id: scene.jobID)
                let state = job["state"]
                if state == "failed" || state == "cancelled" {
                    throw RemotionHandoffError.jobUnusable(scene: scene.id, state: state?.pythonDescription ?? "")
                }
                if state == "completed" { break }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw RemotionHandoffError.jobStillPending(
                        scene: scene.id, state: state?.pythonDescription ?? "unavailable")
                }
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                try await pause(min(Self.maximumPollInterval, max(0, seconds)))
            }
            let mode = job["request"]?["mode"]
            guard job["id"] == .string(scene.jobID), mode == "save" else {
                throw RemotionHandoffError.notSaveJob(scene: scene.id)
            }
            guard job["audioURL"] == .string("/v1/jobs/\(scene.jobID)/audio") else {
                throw RemotionHandoffError.unexpectedAudioRoute
            }
            jobs.append(job)
        }
        return jobs
    }

    static func resolvedProject(_ path: String) -> URL {
        let expanded = ChatterConnection.expandTilde(path, home: FileManager.default.homeDirectoryForCurrentUser)
        return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func makeStagingDirectory(in project: URL) throws -> URL {
        var template = Array(project.appending(path: ".chatter-stage-XXXXXXXX").path.utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw RemotionHandoffError.fileSystem("Cannot create a staging directory: \(String(cString: strerror(errno)))")
        }
        return URL(filePath: String(cString: created), directoryHint: .isDirectory)
    }

    /// POSIX `rename(2)`: replaces `destination` in one step, like Python's `Path.replace`.
    private static func atomicallyReplace(_ destination: URL, with source: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw RemotionHandoffError.fileSystem(
                "Cannot publish \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }
}

/// Sample-derived timing for one scene: audio frames round up so narration is never cut off.
public struct NarrationTiming: Sendable, Equatable {
    public let durationSeconds: Double
    public let audioFrames: Int
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int

    /// Reads and fully validates a downloaded WAV.
    public init(inspecting url: URL, fps: Int) throws {
        let format = try WAVFormat.read(from: url)
        guard format.frameCount >= 1, format.sampleRate >= 1 else { throw RemotionHandoffError.emptyAudio }
        guard format.isComplete else { throw RemotionHandoffError.truncatedAudio }
        durationSeconds = format.durationSeconds
        audioFrames = (format.frameCount * fps + format.sampleRate - 1) / format.sampleRate
        sampleRate = format.sampleRate
        channels = format.channels
        bitsPerSample = format.bitsPerSample
    }
}

/// Handoff failures with the Python helper's wording.
public enum RemotionHandoffError: ChatterToolingFailure, Sendable, Equatable {
    case invalidPlan(String)
    case projectMissing
    case invalidWaitSeconds
    case jobUnreadable(jobID: String)
    case jobUnusable(scene: String, state: String)
    case jobStillPending(scene: String, state: String)
    case notSaveJob(scene: String)
    case unexpectedAudioRoute
    case malformedJob(scene: String)
    case invalidDialogueTiming(scene: String)
    case audioDownloadFailed
    case emptyAudio
    case truncatedAudio
    case fileSystem(String)

    public var description: String {
        switch self {
        case .invalidPlan(let message): message
        case .projectMissing: "Choose an existing Remotion project containing package.json."
        case .invalidWaitSeconds: "wait_seconds must be a finite nonnegative number."
        case .jobUnreadable(let id): "Cannot read Chatter job \(id); check its receipt and connection."
        case .jobUnusable(let scene, let state): "Scene \(scene): Chatter job is \(state)."
        case .jobStillPending(let scene, let state):
            "Scene \(scene): narration is still \(state). Poll the existing job or rerun with --wait-seconds; do not submit a duplicate."
        case .notSaveJob(let scene): "Scene \(scene) must reference its completed mode=save job."
        case .unexpectedAudioRoute: "Unexpected Chatter audio route."
        case .malformedJob(let scene): "Scene \(scene): the Chatter job has no text, voice or pace."
        case .invalidDialogueTiming(let scene): "Scene \(scene): dialogue timing is missing or does not match the script and WAV."
        case .audioDownloadFailed: "Audio download failed. Check Chatter and retry the same handoff."
        case .emptyAudio: "Expected a nonempty PCM WAV from Chatter."
        case .truncatedAudio: "The downloaded WAV is truncated."
        case .fileSystem(let message): message
        }
    }
}

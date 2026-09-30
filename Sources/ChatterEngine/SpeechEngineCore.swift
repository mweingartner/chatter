import ChatterAudioKit
import ChatterCore
import Qwen3Speech
import CryptoKit
import Foundation
@preconcurrency import MLX

public enum EngineVersion { public static let current = "3.0.0" }
public enum SpeechProfile: String, Sendable, CaseIterable { case fast, quality, custom, design }
public struct EngineConfiguration: Sendable {
    public var modelsRoot: URL
    public var dataRoot: URL
    public var keepStudioLoaded = false
    public var studioIdleSeconds: Double = 600
    public var cacheLimitBytes = 1 << 30
    public var memoryLimitBytes = 40 << 30
    public init(modelsRoot: URL, dataRoot: URL) { self.modelsRoot = modelsRoot; self.dataRoot = dataRoot }
}
public enum EngineFailure: LocalizedError, Sendable {
    case cancelled, invalid(String), failed(String)
    public var errorDescription: String? { switch self { case .cancelled: "Cancelled"; case .invalid(let s), .failed(let s): s } }
}
/// Owned by the host's serial engine thread; only cancellation and activity cross threads.
public final class SpeechEngineCore: @unchecked Sendable {
    public typealias Emitter = (_ id: String, _ event: String, _ fields: [String: Any]) -> Void
    public private(set) var configuration: EngineConfiguration
    private let emit: Emitter
    private var models: [SpeechProfile: Qwen3TTSModel] = [:]
    private var lastUsed: [SpeechProfile: Date] = [:]
    private var conditioningCache: [String: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
    private let cancellation = CancellationRegistry()
    private let transcriber = LocalTranscriber()
    public private(set) var busy = false
    public var onActivity: (@Sendable () -> Void)?
    public init(configuration: EngineConfiguration, emit: @escaping Emitter) { self.configuration=configuration; self.emit=emit }
    public func start() throws {
        guard FileManager.default.fileExists(atPath:directory(.fast).appending(path:"config.json").path) else { throw EngineFailure.failed(Self.modelsMissing) }
        MemoryPolicy.apply(configuration)
        _ = try model(.fast)
        if configuration.keepStudioLoaded { _ = try model(.quality) }
        MemoryPolicy.relax()
    }
    public func configure(_ command: ConfigureCommand) throws {
        if let idle=command.studioIdleSeconds, idle.isFinite, idle>=0 { configuration.studioIdleSeconds=idle }
        if let keep=command.keepStudioLoaded { if keep { _ = try model(.quality) }; configuration.keepStudioLoaded=keep }
    }
    public var loadedProfiles: [String] { SpeechProfile.allCases.filter { models[$0] != nil }.map(\.rawValue) }
    public func idleTick(now: Date = Date()) {
        guard !busy else { return }
        for profile in SpeechProfile.allCases where profile != .fast && !(profile == .quality && configuration.keepStudioLoaded) {
            if models[profile] != nil, now.timeIntervalSince(lastUsed[profile] ?? .distantPast)>=configuration.studioIdleSeconds { unload(profile,reason:"idle") }
        }
    }
    public func relieveMemoryPressure(critical: Bool) {
        conditioningCache.removeAll()
        if !busy { for profile in SpeechProfile.allCases where profile != .fast && (critical || !configuration.keepStudioLoaded || profile != .quality) { unload(profile,reason:"memory pressure") } }
        MemoryPolicy.relax()
    }
    private func unload(_ profile: SpeechProfile, reason: String) {
        guard models.removeValue(forKey:profile) != nil else { return }
        conditioningCache = conditioningCache.filter { !$0.key.hasPrefix(profile.rawValue+"|") }
        MemoryPolicy.relax(); emit(EngineProtocol.engineID,"unloaded",["profile":profile.rawValue,"reason":reason])
    }
    public func requestCancel(_ id: String) { cancellation.cancel(id) }
    public func isCancelledExternally(_ id: String) -> Bool { cancellation.isCancelled(id) }
    public func clearCancellation(_ id: String) { cancellation.clear(id) }
    func isCancelled(_ id: String) -> Bool { cancellation.isCancelled(id) }
    func noteActivity() { onActivity?() }
    public var footprintBytes: Int { MemoryPolicy.physicalFootprint() }
    public func status() -> [String:Any] { ["profiles":loadedProfiles,"busy":busy,"memory":MemoryPolicy.snapshot(),"referenceSets":conditioningCache.count,"engine":"Qwen3-TTS","sampleRate":24000] }
    static let modelsMissing = "Qwen3-TTS models are not installed. Use Engine → Download / repair models."
    static let modelsDamaged = "Qwen3-TTS could not load. Use Engine → Download / repair models. Details are in the engine log."
    func directory(_ profile: SpeechProfile) -> URL { configuration.modelsRoot.appending(path:"Qwen3/\(profile.rawValue)") }
    func model(_ profile: SpeechProfile) throws -> Qwen3TTSModel {
        lastUsed[profile]=Date()
        if let loaded=models[profile] { return loaded }
        let folder=directory(profile)
        guard FileManager.default.fileExists(atPath:folder.appending(path:"config.json").path) else { throw EngineFailure.failed(Self.modelsMissing) }
        emit(EngineProtocol.engineID,"loading",["profile":profile.rawValue])
        do {
            let loaded = try runBlocking { try await Qwen3TTSModel.fromModelDirectory(folder) }
            models[profile]=loaded
            emit(EngineProtocol.engineID,"loaded",["profile":profile.rawValue]); return loaded
        } catch { FileHandle.standardError.write(Data("Qwen load failed: \(error)\n".utf8)); throw EngineFailure.failed(Self.modelsDamaged) }
    }
    func referenceURL(_ path: String) throws -> URL {
        let voices=configuration.dataRoot.appending(path:"Voices").path
        guard (try? PathPolicy.isInside(path,directory:voices))==true, let canonical=try? PathPolicy.canonical(path), URL(filePath:canonical).lastPathComponent=="reference.wav", FileManager.default.fileExists(atPath:canonical) else { throw EngineFailure.invalid("A voice recording is missing from the library. Re-import it or disable that take.") }
        return URL(filePath:canonical)
    }
    func conditioning(_ references: [EngineReference], profile: SpeechProfile, language: String) throws -> Qwen3TTSModel.Qwen3TTSReferenceConditioning {
        guard !references.isEmpty else { throw EngineFailure.invalid("Enable at least one recording in this voice set.") }
        var digest=SHA256()
        var urls:[URL]=[]
        for reference in references {
            let url=try referenceURL(reference.reference);urls.append(url)
            digest.update(data:try Data(contentsOf:url,options:.mappedIfSafe))
            digest.update(data:Data(reference.transcript.utf8))
            guard !reference.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw EngineFailure.invalid("Every enabled recording needs an exact transcript.") }
        }
        let key=profile.rawValue+"|"+language+"|"+digest.finalize().map { String(format:"%02x",$0) }.joined()
        if let cached=conditioningCache[key] { return cached }
        var samples:[Float]=[]
        for url in urls {
            if !samples.isEmpty { samples += [Float](repeating:0,count:2400) }
            samples += try AudioIO.readMono(url,sampleRate:24000)
            guard samples.count<=Int(QwenCapabilities.maximumReferenceSeconds*24000) else { throw EngineFailure.invalid("This voice set exceeds 180 seconds. Disable some takes; no recordings were silently omitted.") }
        }
        guard samples.count>=2400 else { throw EngineFailure.invalid("Use at least 0.1 seconds of reference speech.") }
        let loaded=try model(profile)
        let value=try loaded.prepareReferenceConditioning(refAudio:MLXArray(samples),refText:references.map { QwenPromptSafety.spokenText($0.transcript) }.joined(separator:" "),language:language)
        // Bounded cache. Each set may include long recordings; release all on pressure or edit.
        if conditioningCache.count>=8 { conditioningCache.removeAll() }
        conditioningCache[key]=value
        return value
    }
    public func precache(_ command: PrecacheCommand) throws {
        guard !command.references.isEmpty else { return }
        for profile in [SpeechProfile.fast,.quality] where models[profile] != nil {
            let language=command.language ?? "Auto"
            let prepared=try conditioning(command.references,profile:profile,language:language)
            let loaded=try model(profile)
            do { _ = try loaded.generateVoiceDesign(text:"Ready.",instruct:nil,language:language,conditioning:prepared,refAudio:nil,refText:nil,temperature:0.7,topK:50,topP:0.8,repetitionPenalty:1.05,minP:0,maxTokens:2,onToken:{ _ in self.noteActivity() },isCancelled:{ self.isCancelled(command.id) }) }
            catch AudioGenerationError.modelNotInitialized(let message) where message.contains("frame budget") {
                // Warm-up intentionally stops after two frames; user synthesis still requires EOS.
            }
        }
        MemoryPolicy.relax()
    }
    // MARK: Recordings

    public func analyze(_ command: AnalyzeCommand) throws -> [String: Any] {
        let health = RecordingHealth.inspect(try AudioIO.readMono44k(URL(filePath: command.source)))
        return try jsonObject(health)
    }

    public func prepare(_ command: PrepareCommand) throws -> [String: Any] {
        let voices = configuration.dataRoot.appending(path: "Voices")
        try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
        guard try PathPolicy.isInside(command.destination, directory: voices.path) else { throw EngineFailure.invalid("Recordings can only be prepared inside the voice library.") }
        let destination = URL(filePath: try PathPolicy.canonical(command.destination))
        let transcriber = self.transcriber, id = command.id
        let sink = UncheckedEmitter(emit: emit)
        let prepared = try runBlocking {
            try await ReferencePreparation.prepare(
                source: URL(filePath: command.source), destination: destination, transcript: command.transcript ?? "",
                transcribe: { samples in try await transcriber.transcribe(samples, sampleRate: 44_100) },
                progress: { message in sink.emit(id, "progress", ["message": message]) })
        }
        conditioningCache.removeAll()
        return try jsonObject(prepared)
    }


    public func synthesize(_ command: SynthesizeCommand) throws -> [String:Any] {
        busy=true
        defer { busy=false; cancellation.clear(command.id); MemoryPolicy.relax() }
        do { return try SynthesisJob(engine:self,command:command).run() } catch is CancellationError { throw EngineFailure.cancelled }
    }
    func send(_ id: String,_ event: String,_ fields:[String:Any]) { emit(id,event,fields) }
    func jsonObject<T: Encodable>(_ value: T) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any] }
}

/// Runs async work from the engine thread and waits for it (engine threads never run on the
/// cooperative pool, so blocking here cannot starve it).
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

/// Event emission is serialized by the host, so it may be called from the preparation task.
struct UncheckedEmitter: @unchecked Sendable { let emit: SpeechEngineCore.Emitter }

final class CancellationRegistry: @unchecked Sendable {
    private var cancelled = Set<String>()
    private let lock = NSLock()
    func cancel(_ id: String) { lock.withLock { _ = cancelled.insert(id) } }
    func isCancelled(_ id: String) -> Bool { lock.withLock { cancelled.contains(id) } }
    func clear(_ id: String) { lock.withLock { _ = cancelled.remove(id) } }
}

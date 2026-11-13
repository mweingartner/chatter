import Foundation

public struct Settings: Codable, Sendable {
    public var outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Chatter/Audio").path
    public var port = 18423
    public var queueCapacity = 1000
    public var allowLAN = false
    public var lanPort = 18424
    public var securityVersion = 1
    public var deleteExpiredAudio = false
    public var retentionDays = 30
    public var retainedJobLimit = 1000
    public var storageLimitGB = 20
    public var maximumSpeechMinutes = 30
    public var maximumGenerationMinutes = 60
    public var clientQueueLimit = 100
    public var launchAtLogin = true
    public var liveQuality = "responsive"
    public var defaultPace = 1.0
    public var studioTone = "natural"
    /// Keep the studio (BF16) model resident instead of loading it for studio work on demand.
    public var keepStudioLoaded = false
    /// Which model speaks for recorded voices at Responsive and Balanced quality (`RecordedVoiceModel`).
    public var recordedVoiceModel = RecordedVoiceModel.automatic.rawValue
    public var defaultVoiceID: String?
    public var nextJobSequence: UInt64 = 1
    /// Optional pronunciation assistant. The stored name remains compatible with earlier releases.
    public var expressionModel = "qwen3.8:27b-mlx"
    /// Legacy switches are retained for rollback; Qwen speech ignores both.
    public var expressionNotesInStudio = true
    public var expressionNotesForRequests = true
    public var ollamaAddress = OllamaClient.defaultAddress
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case lanPort, securityVersion, deleteExpiredAudio, retentionDays, retainedJobLimit, storageLimitGB, maximumSpeechMinutes, maximumGenerationMinutes, clientQueueLimit
        case outputDirectory, port, queueCapacity, allowLAN, launchAtLogin, liveQuality, defaultPace, defaultVoiceID, nextJobSequence, studioTone, keepStudioLoaded, recordedVoiceModel
        case expressionModel, expressionNotesInStudio, expressionNotesForRequests, ollamaAddress
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputDirectory = try values.decodeIfPresent(String.self, forKey: .outputDirectory) ?? outputDirectory
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        queueCapacity = try values.decodeIfPresent(Int.self, forKey: .queueCapacity) ?? queueCapacity
        // Existing plaintext LAN configurations require explicit consent to the new secure connection.
        securityVersion = try values.decodeIfPresent(Int.self, forKey: .securityVersion) ?? 0
        allowLAN = securityVersion >= 1 ? (try values.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false) : false
        securityVersion = 1
        lanPort = try values.decodeIfPresent(Int.self, forKey: .lanPort) ?? lanPort
        deleteExpiredAudio = try values.decodeIfPresent(Bool.self, forKey: .deleteExpiredAudio) ?? false
        retentionDays = min(365, max(1, try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays))
        retainedJobLimit = min(10000, max(100, try values.decodeIfPresent(Int.self, forKey: .retainedJobLimit) ?? retainedJobLimit))
        storageLimitGB = min(1000, max(1, try values.decodeIfPresent(Int.self, forKey: .storageLimitGB) ?? storageLimitGB))
        maximumSpeechMinutes = min(120, max(1, try values.decodeIfPresent(Int.self, forKey: .maximumSpeechMinutes) ?? maximumSpeechMinutes))
        maximumGenerationMinutes = min(240, max(1, try values.decodeIfPresent(Int.self, forKey: .maximumGenerationMinutes) ?? maximumGenerationMinutes))
        clientQueueLimit = min(1000, max(1, try values.decodeIfPresent(Int.self, forKey: .clientQueueLimit) ?? clientQueueLimit))
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        liveQuality = try values.decodeIfPresent(String.self, forKey: .liveQuality) ?? liveQuality
        studioTone = try values.decodeIfPresent(String.self, forKey: .studioTone) ?? studioTone
        if SpeechTone(rawValue: studioTone) == nil { studioTone = "natural" }
        keepStudioLoaded = try values.decodeIfPresent(Bool.self, forKey: .keepStudioLoaded) ?? keepStudioLoaded
        recordedVoiceModel = try values.decodeIfPresent(String.self, forKey: .recordedVoiceModel) ?? recordedVoiceModel
        if RecordedVoiceModel(rawValue: recordedVoiceModel) == nil { recordedVoiceModel = RecordedVoiceModel.automatic.rawValue }
        defaultPace = try values.decodeIfPresent(Double.self, forKey: .defaultPace) ?? defaultPace
        defaultVoiceID = try values.decodeIfPresent(String.self, forKey: .defaultVoiceID)
        nextJobSequence = try values.decodeIfPresent(UInt64.self, forKey: .nextJobSequence) ?? nextJobSequence
        expressionModel = try values.decodeIfPresent(String.self, forKey: .expressionModel) ?? expressionModel
        expressionNotesInStudio = try values.decodeIfPresent(Bool.self, forKey: .expressionNotesInStudio) ?? expressionNotesInStudio
        expressionNotesForRequests = try values.decodeIfPresent(Bool.self, forKey: .expressionNotesForRequests) ?? expressionNotesForRequests
        ollamaAddress = try values.decodeIfPresent(String.self, forKey: .ollamaAddress) ?? ollamaAddress
        if (try? OllamaClient.validatedAddress(ollamaAddress)) == nil { ollamaAddress = OllamaClient.defaultAddress }
    }
}

/// The model that speaks for recorded voices in live speech (Responsive and Balanced quality).
/// Studio quality and saved audio always use the studio model.
///
/// The 1.7B model is the one saved audio uses, so with it a reply sounds the same live as saved.
/// Measured on JARVIS's and Scar's recordings (2026-11-12), both models say the words equally well
/// and neither runs on once sampled without a top-p cut; JARVIS's timing for a sentence varied
/// slightly less from draw to draw with the 1.7B model (3 to 5 % against 5 %). It needs about 5 GB
/// of memory and a fast GPU to keep ahead of playback: 2.6 times real time on an M3 Ultra, against
/// 3.5 times for the 0.6B model.
public enum RecordedVoiceModel: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The studio model on a Mac with at least `automaticStudioMemory` of memory, else the fast one.
    case automatic
    /// 0.6B Base, 8-bit.
    case fast
    /// 1.7B Base, BF16.
    case studio
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: "Automatic"; case .fast: "Fast (0.6B)"; case .studio: "Studio (1.7B)" }
    }
    /// Macs with this much memory have the Max- and Ultra-class GPUs that run the studio model well
    /// ahead of real time.
    public static let automaticStudioMemory: UInt64 = 96 << 30

    public func usesStudio(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        switch self {
        case .automatic: physicalMemory >= Self.automaticStudioMemory
        case .fast: false
        case .studio: true
        }
    }
}

public enum ChatterPaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CHATTER_DATA_ROOT"] { return URL(filePath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Chatter")
    }
    public static var voices: URL { root.appending(path: "Voices") }
    public static var jobs: URL { root.appending(path: "Jobs") }
    public static var models: URL { root.appending(path: "Models") }
    public static func makeDirectories() throws {
        for path in [root, voices, jobs, root.appending(path: "Logs")] {
            try PrivateStorage.directory(path)
        }
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateStorage.write(encoder.encode(value), to: url)
    }
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Reads at most `limit + 1` bytes of the file at `url`, so a caller can tell a file over `limit`
    /// from one at it. The file is checked after it is opened, so a pipe, device or folder put in its
    /// place is refused rather than read, and opening a pipe never waits for a writer.
    public static func readRegularFile(at url: URL, upTo limit: Int) throws -> Data {
        var openError: Int32 = 0
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if descriptor < 0 { openError = errno }
            return descriptor
        }
        guard descriptor >= 0 else {
            let reason = openError == 0 ? "the path can’t be used" : String(cString: strerror(openError))
            throw ChatterError.invalid("Chatter couldn’t open “\(url.lastPathComponent)”: \(reason).")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ChatterError.invalid("Choose a file, not a folder, pipe or device.")
        }
        // Blocking reads again: some network file systems honor O_NONBLOCK on regular files.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        let count = limit < Int.max ? max(limit, 0) + 1 : Int.max
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: count) ?? Data()
    }
}

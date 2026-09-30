import CryptoKit
import Foundation

/// A model file pinned to an exact upstream revision and content hash.
public struct ModelFile: Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let path: String
    /// Location relative to the models directory.
    public let destination: String
    public let size: Int64
    public let sha256: String

    public init(repository: String, revision: String, path: String, destination: String, size: Int64, sha256: String) {
        self.repository = repository; self.revision = revision; self.path = path
        self.destination = destination; self.size = size; self.sha256 = sha256
    }

    func remoteURL(base: URL) -> URL { base.appending(path: "\(repository)/resolve/\(revision)/\(path)") }
}

/// Qwen3-TTS models, pinned to immutable revisions and verified SHA-256 (2026-09-29).
public enum ModelManifest {
    public static let qwenSourceRevision = "022e286b98fbec7e1e916cb940cdf532cd9f488e"
    public static let files: [ModelFile] = [
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "config.json", destination: "Qwen3/fast/config.json", size: 5522, sha256: "b404fb6f99dac6f7a81f3a03af5675b131ecf9936ac75a7c9d75e54044600044"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "generation_config.json", destination: "Qwen3/fast/generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "merges.txt", destination: "Qwen3/fast/merges.txt", size: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "model.safetensors", destination: "Qwen3/fast/model.safetensors", size: 1304461214, sha256: "9488e7005cc0cf44f8804eb543668d0763bb1c649ce6f1eddc663519524b3182"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "preprocessor_config.json", destination: "Qwen3/fast/preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "speech_tokenizer/config.json", destination: "Qwen3/fast/speech_tokenizer/config.json", size: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "speech_tokenizer/configuration.json", destination: "Qwen3/fast/speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "speech_tokenizer/model.safetensors", destination: "Qwen3/fast/speech_tokenizer/model.safetensors", size: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "speech_tokenizer/preprocessor_config.json", destination: "Qwen3/fast/speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "tokenizer_config.json", destination: "Qwen3/fast/tokenizer_config.json", size: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", revision: "50f45ef0047cde7e84c2ef04326acb8ada2436a7", path: "vocab.json", destination: "Qwen3/fast/vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "config.json", destination: "Qwen3/quality/config.json", size: 5317, sha256: "39ffdadc03c1a7c7f8116ee8830d6a577ac87039edcbd88759b4fcc4db272070"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "generation_config.json", destination: "Qwen3/quality/generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "merges.txt", destination: "Qwen3/quality/merges.txt", size: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "model.safetensors", destination: "Qwen3/quality/model.safetensors", size: 3857414009, sha256: "81fb76175ff74e69be25fef2cc3e54f016df3034f1514c8e1c89da06a3510cff"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "preprocessor_config.json", destination: "Qwen3/quality/preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "speech_tokenizer/config.json", destination: "Qwen3/quality/speech_tokenizer/config.json", size: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "speech_tokenizer/configuration.json", destination: "Qwen3/quality/speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "speech_tokenizer/model.safetensors", destination: "Qwen3/quality/speech_tokenizer/model.safetensors", size: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "speech_tokenizer/preprocessor_config.json", destination: "Qwen3/quality/speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "tokenizer_config.json", destination: "Qwen3/quality/tokenizer_config.json", size: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16", revision: "a6eb4f68e4b056f1215157bb696209bc82a6db48", path: "vocab.json", destination: "Qwen3/quality/vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "config.json", destination: "Qwen3/custom/config.json", size: 5853, sha256: "9c0f62abb48c432361fdcd54da1fd9fe00a993c0acccef5d45c2d3edd5932fb1"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "generation_config.json", destination: "Qwen3/custom/generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "merges.txt", destination: "Qwen3/custom/merges.txt", size: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "model.safetensors", destination: "Qwen3/custom/model.safetensors", size: 3833402589, sha256: "3a791fb8250fc32ab0259b679d834159d3c8516af62f033ff2b9f42913e3fab6"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "preprocessor_config.json", destination: "Qwen3/custom/preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "speech_tokenizer/config.json", destination: "Qwen3/custom/speech_tokenizer/config.json", size: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "speech_tokenizer/configuration.json", destination: "Qwen3/custom/speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "speech_tokenizer/model.safetensors", destination: "Qwen3/custom/speech_tokenizer/model.safetensors", size: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "speech_tokenizer/preprocessor_config.json", destination: "Qwen3/custom/speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "tokenizer_config.json", destination: "Qwen3/custom/tokenizer_config.json", size: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", revision: "52f4770fd9726457eae3d3b6aa92047a25a10776", path: "vocab.json", destination: "Qwen3/custom/vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "config.json", destination: "Qwen3/design/config.json", size: 5232, sha256: "8a9be83c045ee9ab9d2e6609655f547b9291a070f5acae3428c3ff07a365de40"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "generation_config.json", destination: "Qwen3/design/generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "merges.txt", destination: "Qwen3/design/merges.txt", size: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "model.safetensors", destination: "Qwen3/design/model.safetensors", size: 3833402589, sha256: "96ae28bec2205ec0b5e0c750bea2b8a5deac4f14d33a8a25a5f753299486b70e"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "preprocessor_config.json", destination: "Qwen3/design/preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "speech_tokenizer/config.json", destination: "Qwen3/design/speech_tokenizer/config.json", size: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "speech_tokenizer/configuration.json", destination: "Qwen3/design/speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "speech_tokenizer/model.safetensors", destination: "Qwen3/design/speech_tokenizer/model.safetensors", size: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "speech_tokenizer/preprocessor_config.json", destination: "Qwen3/design/speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "tokenizer_config.json", destination: "Qwen3/design/tokenizer_config.json", size: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        ModelFile(repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", revision: "7d3824abff87e49756bb0f83fb5411de75d160c4", path: "vocab.json", destination: "Qwen3/design/vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]
    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ModelInstallerError: LocalizedError, Sendable {
    case http(Int, String)
    case integrity(String)
    case interrupted(String)
    public var errorDescription: String? {
        switch self {
        case .http(let code, let file): "Model download failed with HTTP \(code) for \(file). Retry; downloads resume."
        case .integrity(let file): "\(file) failed its integrity check and was removed. Retry to download it again."
        case .interrupted(let reason): "Model download was interrupted: \(reason). Retry; downloads resume."
        }
    }
}

/// Installs, verifies and repairs Chatter's speech models without Python or package managers.
public final class ModelInstaller: @unchecked Sendable {
    public let modelsRoot: URL
    let files: [ModelFile]
    let baseURL: URL
    public init(modelsRoot: URL = ChatterPaths.models, files: [ModelFile] = ModelManifest.files,
                baseURL: URL = URL(string: "https://huggingface.co")!) {
        self.modelsRoot = modelsRoot; self.files = files; self.baseURL = baseURL
    }

    func url(_ file: ModelFile) -> URL { modelsRoot.appending(path: file.destination) }

    /// Fast presence check (sizes only), used at every launch.
    public var isInstalled: Bool { files.allSatisfy { size(at: url($0)) == $0.size } }

    public var missingBytes: Int64 {
        files.filter { size(at: url($0)) != $0.size }.reduce(0) { $0 + $1.size }
    }

    func size(at url: URL) -> Int64? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }

    /// Verify, resume, and repair the Qwen model catalog.
    public func install(progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        for file in files {
            try Task.checkCancellation()
            let target = url(file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if size(at: target) == file.size, try await hash(of: target) == file.sha256 {
                progress("Verified \(file.destination)\n"); continue
            }
            try await download(file, to: target, progress: progress)
        }
        progress("SETUP_COMPLETE\n")
    }

    public func hash(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { digest.update(data: chunk) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Resumable download to `<target>.partial`, hashing as it streams; renamed only when verified.
    func download(_ file: ModelFile, to target: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let partial = target.appendingPathExtension("partial")
        var offset = size(at: partial) ?? 0
        if offset > file.size { try FileManager.default.removeItem(at: partial); offset = 0 }
        // A complete partial (interrupted while it was being verified) needs no request: asking for
        // `bytes=<size>-` would be answered 416 on every retry. It is verified below like any other.
        if offset < file.size {
            progress("Downloading \(file.destination) (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))\(offset > 0 ? ", resuming" : "")…\n")
            let stream = DownloadStream(url: file.remoteURL(base: baseURL), offset: offset, partial: partial, expected: file.size,
                                        name: file.destination) { received in
                progress(String(format: "  %@ %.0f%%\n", file.destination, Double(received) / Double(file.size) * 100))
            }
            do { try await stream.run() } catch ModelInstallerError.integrity(let name) {
                try? FileManager.default.removeItem(at: partial)   // never resume from bytes a server overran
                throw ModelInstallerError.integrity(name)
            }
        }
        guard size(at: partial) == file.size, try await hash(of: partial) == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelInstallerError.integrity(file.destination)
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: partial)
    }
}

/// Streams one HTTP resource to a file with a Range resume, reporting progress every 5%.
final class DownloadStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL, partial: URL, expected: Int64
    /// How the file is named in messages (its installed path, which is unambiguous).
    let name: String
    private var offset: Int64
    private var handle: FileHandle?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var lastReported: Int64 = 0
    private let report: (Int64) -> Void
    private var failure: Error?

    init(url: URL, offset: Int64, partial: URL, expected: Int64, name: String? = nil, report: @escaping (Int64) -> Void) {
        self.url = url; self.offset = offset; self.partial = partial; self.expected = expected; self.report = report
        self.name = name ?? url.lastPathComponent
    }

    func run() async throws {
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seek(toOffset: UInt64(offset))
        self.handle = handle
        defer { try? handle.close() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 6 * 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        // The task exists before cancellation can be observed: creating one in a session that a
        // cancellation already invalidated raises an uncaught NSGenericException.
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // A task cancelled before it starts may complete before the continuation is stored.
                let early: Result<Void, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    self.continuation = continuation
                    return nil
                }
                if let early { continuation.resume(with: early) } else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    /// Resumes the waiting `run()` exactly once, or records the outcome if it is not waiting yet.
    private func complete(_ result: Result<Void, Error>) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { failure = ModelInstallerError.interrupted("no HTTP response"); return .cancel }
        switch http.statusCode {
        case 206:
            // Append only if the server says it resumes exactly where the partial file ends (a 206 must
            // carry Content-Range); otherwise the file would be misaligned and fail verification only
            // after a full transfer.
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? "no Content-Range"
            guard range.hasPrefix("bytes \(offset)-") else {
                try? handle?.truncate(atOffset: 0)
                failure = ModelInstallerError.interrupted("the server resumed at the wrong position (\(range.prefix(64))); retry to download from the start")
                return .cancel
            }
            return .allow
        case 200:
            // Server ignored the range: start over.
            offset = 0
            try? handle?.truncate(atOffset: 0)
            return .allow
        case 416:
            // Nothing exists past what was kept, so this partial can never be completed: start over.
            try? handle?.truncate(atOffset: 0)
            failure = ModelInstallerError.integrity(name)
            return .cancel
        default:
            failure = ModelInstallerError.http(http.statusCode, name)
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // After a refusal the task is being cancelled; a chunk already queued must not be written.
        guard failure == nil else { return }
        // Never write past the pinned size: a server that sends more cannot fill the disk.
        guard offset + Int64(data.count) <= expected else {
            try? handle?.truncate(atOffset: 0)
            offset = 0
            failure = ModelInstallerError.integrity(name)
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
            offset += Int64(data.count)
            if offset - lastReported >= expected / 20 { lastReported = offset; report(offset) }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let result = failure ?? error {
            complete(.failure(result is ModelInstallerError ? result : ModelInstallerError.interrupted(result.localizedDescription)))
        } else if offset < expected {
            // A clean but short transfer keeps what arrived, so the next attempt resumes from it.
            complete(.failure(ModelInstallerError.interrupted("the server ended the transfer early")))
        } else { complete(.success(())) }
    }
}

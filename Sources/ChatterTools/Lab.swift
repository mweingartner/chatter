import ChatterAudioKit
import ChatterCore
import Foundation
import MLX
import MLXRandom
import Qwen3Speech

/// `chatter-tools lab <config.json>`: generates the same passages under different sampler and decoder
/// settings, for measuring them against each other. One JSON object per generation on stdout; the
/// audio is written unshaped (no edge fades or trimming) so the model's own output can be inspected.
enum LabCommand {
    struct Reference: Decodable { var wav: String; var transcript: String; var crop: [Double]? }
    struct Variant: Decodable {
        var name: String
        var profile: String?
        var temperature: Float?, topP: Float?, topK: Int?, repetitionPenalty: Float?
        var preservesEOS: Bool?, minimumFrames: Int?, temperatureFirst: Bool?, overlaysText: Bool?, primed: Bool?
        var residualTemperature: Float?, residualTopP: Float?, residualTopK: Int?
        var window: Int?, unbounded: Bool?, trimsZeroCodes: Bool?, stream: Bool?, upstreamEncoder: Bool?, roundTrip: Bool?
        /// A JSON file of codec codes [quantizer][frame] to decode instead of generating.
        var decodeCodes: String?, chunkTokens: Int?
        var greedy: Bool?, dumpCodes: Bool?, framesAfterEnd: Int?, laterChunkSeconds: Double?
        /// A JSON file {"generations":[{"textIndex", "nonStreaming", "codes":[frame][16]}]} to follow.
        var forcing: String?
        var seeds: [UInt64]?
    }
    struct Config: Decodable {
        var models: String?
        var profile: String?
        var references: [Reference]
        var language: String?
        var texts: [String]
        var seeds: [UInt64]
        var out: String
        var variants: [Variant]
        /// Instead of generating: how close each listed WAV's speaker is to the reference's, as the
        /// cosine of `scoreProfile`'s speaker embeddings.
        var score: [String]?
        var scoreProfile: String?
    }

    static func run(_ arguments: [String]) async throws {
        guard let path = arguments.first else { throw ToolError.usage("lab <config.json>") }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(filePath: path)))
        let root = config.models.map { URL(filePath: $0) } ?? ChatterPaths.models
        let out = URL(filePath: config.out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Memory.cacheLimit = 1 << 30

        var samples: [Float] = []
        for reference in config.references {
            if !samples.isEmpty { samples += [Float](repeating: 0, count: 2400) }
            var take = try AudioIO.readMono(URL(filePath: reference.wav), sampleRate: 24000)
            if let crop = reference.crop, crop.count == 2 { take = Array(take[max(0, Int(crop[0] * 24000)) ..< min(take.count, Int(crop[1] * 24000))]) }
            samples += ReferencePreparation.trimmedForConditioning(take, sampleRate: 24000)
        }
        let transcript = config.references.map { QwenPromptSafety.spokenText($0.transcript) }.joined(separator: " ")

        if let wavs = config.score {
            let model = try await Qwen3TTSModel.fromModelDirectory(root.appending(path: "Qwen3/\(config.scoreProfile ?? "quality")"))
            guard let reference = model.speakerEmbedding(MLXArray(samples)) else { throw ToolError.usage("This model has no speaker encoder.") }
            func cosine(_ a: [Float], _ b: [Float]) -> Double {
                let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                let na = a.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot(), nb = b.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
                return dot / max(na * nb, 1e-12)
            }
            for wav in wavs {
                let audio = try AudioIO.readMono(URL(filePath: wav), sampleRate: 24000)
                guard audio.count >= 12_000, let embedding = model.speakerEmbedding(MLXArray(audio)) else { continue }
                emit(["event": "score", "wav": wav, "similarity": cosine(reference, embedding)])
            }
            return
        }

        var models: [String: Qwen3TTSModel] = [:]
        var conditionings: [String: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
        for variant in config.variants {
            let profile = variant.profile ?? config.profile ?? "fast"
            if models[profile] == nil {
                let started = ContinuousClock.now
                let loaded = try await Qwen3TTSModel.fromModelDirectory(root.appending(path: "Qwen3/\(profile)"))
                models[profile] = loaded
                emit(["event": "loaded", "profile": profile, "seconds": (ContinuousClock.now - started).seconds])
            }
            let model = models[profile]!
            let window: Int? = variant.unbounded == true ? nil : (variant.window ?? 72)
            model.decoderAttentionWindow = window
            model.encoderMatchesReference = variant.upstreamEncoder != true
            if let file = variant.decodeCodes {
                let codes = try JSONDecoder().decode([[Int32]].self, from: Data(contentsOf: URL(filePath: file)))
                let url = out.appending(path: "decoded-\(variant.name).wav")
                try AudioIO.writePCM24(model.decodeCodes(codes, chunkTokens: variant.chunkTokens ?? 300).asArray(Float.self), sampleRate: 24000, to: url)
                emit(["event": "decoded", "variant": variant.name, "wav": url.path])
                continue
            }
            if variant.roundTrip == true {
                try JSONEncoder().encode(model.encodeCodes(MLXArray(samples))).write(to: out.appending(path: "codes-\(variant.name).json"))
                let audio = model.roundTrip(MLXArray(samples)).asArray(Float.self)
                let url = out.appending(path: "roundtrip-\(variant.name).wav")
                try AudioIO.writePCM24(audio, sampleRate: 24000, to: url)
                try AudioIO.writePCM24(samples, sampleRate: 24000, to: out.appending(path: "roundtrip-source.wav"))
                emit(["event": "roundtrip", "variant": variant.name, "wav": url.path])
                continue
            }
            let key = "\(profile)|\(window.map(String.init) ?? "none")|\(variant.upstreamEncoder == true)"
            if conditionings[key] == nil {
                let started = ContinuousClock.now
                let prepared = try model.prepareReferenceConditioning(refAudio: MLXArray(samples), refText: transcript, language: config.language ?? "Auto")
                conditionings[key] = prepared
                emit(["event": "conditioned", "key": key, "seconds": (ContinuousClock.now - started).seconds, "referenceSeconds": Double(samples.count) / 24000,
                      "referenceFrames": prepared.referenceFrames, "referenceTextTokens": prepared.referenceTextTokens,
                      "zeroCodes": prepared.zeroFirstCodes,
                      "speakerEmbedding": prepared.speakerEmbedding.map { $0.asType(.float32).asArray(Float.self) } ?? []])
            }
            let conditioning = conditionings[key]!
            var options = QwenGenerationOptions()
            options.preservesEOS = variant.preservesEOS ?? false
            options.minimumFrames = variant.minimumFrames ?? 2
            options.temperatureFirst = variant.temperatureFirst ?? true
            options.overlaysText = variant.overlaysText ?? false
            options.usesPrimedDecoder = variant.primed ?? true
            options.residualTemperature = variant.residualTemperature
            options.residualTopP = variant.residualTopP
            options.residualTopK = variant.residualTopK
            options.framesAfterEnd = variant.framesAfterEnd ?? 0
            options.laterChunkSeconds = variant.laterChunkSeconds
            Qwen3TTSModel.trimsZeroCodes = variant.trimsZeroCodes ?? false
            let folder = out.appending(path: variant.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            struct Forced: Decodable { struct Generation: Decodable { var textIndex: Int; var nonStreaming: Bool; var codes: [[Int32]] }; var generations: [Generation] }
            let forcedSet = try variant.forcing.map { try JSONDecoder().decode(Forced.self, from: Data(contentsOf: URL(filePath: $0))) }
            for (textIndex, text) in config.texts.enumerated() {
                for seed in variant.seeds ?? config.seeds {
                    let forcing = forcedSet?.generations.first { $0.textIndex == textIndex && $0.nonStreaming == !(variant.overlaysText ?? false) }?.codes
                    var forcedLogits: [[Float]] = [], forcedResidual: [[Int32]] = []
                    MLXRandom.seed(seed)
                    var frames: [QwenFrameDiagnostics] = []
                    var streamed: [Float] = [], firstChunk: Double?, firstCodes: [Int32] = [], allCodes: [[Int32]] = []
                    let started = ContinuousClock.now
                    var record: [String: Any] = ["event": "generation", "variant": variant.name, "profile": profile, "text": text, "textIndex": textIndex, "seed": seed,
                                                 "textTokens": model.textTokenCount(text)]
                    do {
                        let audio = try model.generateVoiceDesign(
                            text: text, instruct: nil, language: config.language ?? "Auto", conditioning: conditioning, refAudio: nil, refText: nil,
                            temperature: variant.greedy == true ? 0 : variant.temperature ?? 0.7, topK: variant.topK ?? 50, topP: variant.topP ?? 0.8,
                            repetitionPenalty: variant.repetitionPenalty ?? 1.05, minP: 0, maxTokens: 2048, streamingInterval: 0.8,
                            onAudioChunk: variant.stream == true ? { chunk in
                                if firstChunk == nil { firstChunk = (ContinuousClock.now - started).seconds }
                                streamed += chunk.asArray(Float.self)
                            } : nil,
                            options: options, onFrame: { frames.append($0) },
                            onCodes: { codes in
                                firstCodes = codes[0, 0..., 0].asArray(Int32.self)
                                if variant.dumpCodes == true { allCodes = (0 ..< codes.dim(1)).map { codes[0, $0, 0...].asArray(Int32.self) } }
                            },
                            forcing: forcing, onForced: { _, logits, residual in forcedLogits.append(logits.asArray(Float.self)); forcedResidual.append(residual) })
                        let pcm = variant.stream == true ? streamed : audio.asArray(Float.self)
                        let url = folder.appending(path: "t\(textIndex)-s\(seed).wav")
                        try AudioIO.writePCM24(pcm, sampleRate: 24000, to: url)
                        record["wav"] = url.path; record["seconds"] = Double(pcm.count) / 24000; record["ended"] = true
                        if let firstChunk { record["firstChunkSeconds"] = firstChunk }
                    } catch AudioGenerationError.frameBudgetReached {
                        record["ended"] = false
                    }
                    record["elapsed"] = (ContinuousClock.now - started).seconds
                    record["frames"] = frames.count(where: { !$0.ended })
                    if let last = frames.last, last.ended {
                        record["endProbability"] = last.endProbability; record["endWasCandidate"] = last.endWasCandidate
                    }
                    // Where the end could have been drawn only because it was put back after top-k/top-p.
                    record["endOffered"] = frames.filter { !$0.endWasCandidate }.map { ["step": $0.step, "p": $0.endProbability] }.filter { ($0["p"] as! Float) > 1e-4 }
                    record["endTrace"] = frames.suffix(12).map { Double(($0.endProbability * 10000).rounded() / 10000) }
                    record["tokens"] = frames.map(\.token)
                    record["zeroCodes"] = firstCodes.count(where: { $0 == 0 })
                    if variant.dumpCodes == true { record["codes"] = allCodes }
                    if forcing != nil { record["forcedLogits"] = forcedLogits; record["forcedResidual"] = forcedResidual }
                    emit(record)
                    Memory.clearCache()
                }
            }
        }
    }

    /// `chatter-tools activity <wav>...`: what `SpeechActivity` makes of each file, fed in 0.8 s chunks
    /// as the engine feeds it.
    static func activity(_ paths: [String]) throws {
        for path in paths {
            let samples = try AudioIO.readMono(URL(filePath: path), sampleRate: 24000)
            var activity = SpeechActivity()
            var start = 0
            while start < samples.count { activity.append(Array(samples[start ..< min(samples.count, start + 19_200)])); start += 19_200 }
            emit(["path": path, "seconds": activity.seconds, "hasSpoken": activity.hasSpoken, "leadingSilence": activity.leadingSilence,
                  "trailingSilence": activity.trailingSilence, "spokenSpan": activity.spokenSpan, "longestPause": activity.longestPause])
        }
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

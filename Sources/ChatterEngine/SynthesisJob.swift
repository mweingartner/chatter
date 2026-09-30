import ChatterAudioKit
import ChatterCore
import Qwen3Speech
import Foundation
@preconcurrency import MLX

/// Serial Qwen generation, typed delivery instructions, native-rate PCM and one final pace pass.
struct SynthesisJob {
    let engine: SpeechEngineCore
    let command: SynthesizeCommand
    /// Dialogue forwards unpaced chunks while retaining one ordered parent job.
    var onChunk: (([Float]) throws -> Void)? = nil
    func run() throws -> [String:Any] {
        if let turns=command.dialogueTurns { return try DialogueSynthesis(engine:engine,command:command,turns:turns).run() }
        let c=command
        guard ["play","save"].contains(c.mode) else { throw EngineFailure.invalid("Mode must be play or save.") }
        guard c.pace.isFinite, (0.5...2).contains(c.pace) else { throw EngineFailure.invalid("Pace must be between 0.5 and 2.0.") }
        guard ["responsive","balanced","studio"].contains(c.quality ?? "balanced") else { throw EngineFailure.invalid("Quality must be responsive, balanced or studio.") }
        let voice=try (c.voiceConfiguration ?? QwenVoiceConfiguration()).validated()
        let language=try QwenCapabilities.language(c.language ?? voice.language)
        if !voice.kind.supportsInstructions, let instruction=c.instruction, !instruction.isEmpty { throw EngineFailure.invalid(QwenCapabilities.cloneDeliveryNotice) }
        let quality = SpeechQuality(rawValue: c.quality ?? "balanced") ?? .balanced
        let profile = SpeechProfile(rawValue: quality.modelProfile(for: voice.kind, mode: c.mode))!
        let (directory,output)=try paths()
        let start=ContinuousClock.now
        if profile == .quality, !engine.loadedProfiles.contains("quality") { engine.send(c.id,"progress",["message":"Loading the studio voice model…"]) }
        let model=try engine.model(profile)
        let conditioning=voice.kind == .cloned ? try engine.conditioning(c.references,profile:profile,language:language) : nil
        let instruction=[c.toneCue,c.instruction].compactMap { $0 }.joined(separator:" ")
        let passages=try DeliveryPassages.passages(QwenPromptSafety.spokenText(c.text),maxBytes:c.mode == "play" ? 220 : 380,instruction:instruction,supportsInstructions:voice.kind.supportsInstructions)
        guard !passages.isEmpty else { throw EngineFailure.invalid("Enter text to speak.") }
        let seed=c.seed ?? UInt64.random(in:0...UInt64(UInt32.max)); MLXRandom.seed(seed)
        let paced=abs(c.pace-1)>0.0001
        let unpaced=directory.appending(path:"unpaced.wav")
        let writer=try WAVStreamWriter(url:paced ? unpaced : output,sampleRate:24000)
        var complete=false
        defer { if !complete { writer.cancel(); try? FileManager.default.removeItem(at:output) } }
        var firstAudio:Double?, chunks=0,frames=0
        func deliver(_ samples:[Float]) throws {
            try checkCancelled()
            try writer.append(Self.validated(samples))
            if c.mode == "play" {
                if let onChunk { try onChunk(samples); return }
                let part=directory.appending(path:"part-\(chunks).wav")
                try AudioIO.writePCM24(samples,sampleRate:24000,to:part)
                if firstAudio == nil { firstAudio=(ContinuousClock.now-start).seconds }
                engine.send(c.id,"chunk",["path":part.path,"index":chunks,"firstAudioSeconds":firstAudio!]);chunks+=1
            }
        }
        for (index,passage) in passages.enumerated() {
            try checkCancelled()
            let prompt:String? = switch voice.kind {
            case .cloned: nil
            case .preset: [voice.speaker!,passage.instruction].filter { !$0.isEmpty }.joined(separator:", ")
            case .designed: [voice.description!,passage.instruction].filter { !$0.isEmpty }.joined(separator:" ")
            }
            let responsive=c.mode == "play" && quality.streamsChunks
            var envelope = PassageEnvelope()
            func deliverPassage(_ samples: [Float]) throws {
                let output = envelope.append(try Self.validated(samples))
                if !output.isEmpty { try deliver(output) }
            }
            let audio=try model.generateVoiceDesign(text:passage.text,instruct:prompt,language:language,conditioning:conditioning,refAudio:nil,refText:nil,temperature:Float(c.temperature ?? 0.7),topK:50,topP:0.8,repetitionPenalty:1.05,minP:0,maxTokens:2048,streamingInterval:0.8,onToken:{ _ in frames+=1;engine.noteActivity() },onAudioChunk:responsive ? { try deliverPassage($0.asArray(Float.self)) } : nil,isCancelled:{ engine.isCancelled(c.id) })
            if responsive {
                let tail = envelope.finish()
                if !tail.isEmpty { try deliver(tail) }
            } else {
                let body = envelope.append(try Self.validated(audio.asArray(Float.self)))
                try deliver(body + envelope.finish())
            }
            // Additional sentence breathing room, preserved in the final WAV and live playback.
            if index<passages.count-1 { try deliver([Float](repeating:0,count:7200)) }
            engine.send(c.id,"progress",["message":"Generated passage \(index+1) of \(passages.count)","segments":index+1])
        }
        try checkCancelled();try writer.finish()
        if paced { try PaceRenderer.render(input:unpaced,output:output,rate:Float(c.pace));try? FileManager.default.removeItem(at:unpaced) }
        try checkCancelled(removing:output);complete=true
        return ["path":output.path,"duration":try AudioIO.duration(of:output),"elapsedSeconds":(ContinuousClock.now-start).seconds,"firstAudioSeconds":firstAudio.map { $0 as Any } ?? NSNull(),"profile":profile.rawValue,"modelID":"Qwen3/\(profile.rawValue)","engineName":"Qwen3-TTS","sampleRate":24000,"bitsPerSample":24,"seed":seed,"frames":frames,"passages":passages.count]
    }
    static func validated(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw EngineFailure.failed("Model produced invalid audio.") }
        return samples
    }

    private func checkCancelled(removing output: URL? = nil) throws {
        guard engine.isCancelled(command.id) else { return }
        if let output { try? FileManager.default.removeItem(at: output) }
        throw EngineFailure.cancelled
    }

    /// The job directory must be inside the engine's data root; outputs must be WAV files.
    private func paths() throws -> (URL, URL) {
        let jobs = engine.configuration.dataRoot.appending(path: "Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        guard try PathPolicy.isInside(command.directory, directory: jobs.path) else { throw EngineFailure.invalid("Invalid job directory.") }
        let directory = URL(filePath: try PathPolicy.canonical(command.directory))
        let output = URL(filePath: try PathPolicy.canonical(command.output))
        guard output.pathExtension.lowercased() == "wav" else { throw EngineFailure.invalid("Output must be an absolute WAV path.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (directory, output)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

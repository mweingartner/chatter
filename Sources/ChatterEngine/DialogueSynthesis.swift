import Foundation
import ChatterCore
import ChatterAudioKit

/// A dialogue occupies one durable queue position. Other jobs cannot interleave its cast.
struct DialogueSynthesis {
    let engine: SpeechEngineCore
    let command: SynthesizeCommand
    let turns: [EngineDialogueTurn]
    func run() throws -> [String:Any] {
        guard !turns.isEmpty, turns.count<=500, command.pace.isFinite, (0.5...2).contains(command.pace), ["save","play"].contains(command.mode) else { throw EngineFailure.invalid("Invalid dialogue") }
        let gap=command.gapSeconds ?? 0.35
        guard gap.isFinite, (0...10).contains(gap) else { throw EngineFailure.invalid("Invalid turn spacing") }
        let directory=URL(filePath:command.directory)
        guard try PathPolicy.isInside(directory.path,directory:engine.configuration.dataRoot.appending(path:"Jobs").path) else { throw EngineFailure.invalid("Invalid dialogue directory") }
        let output=URL(filePath:command.output)
        guard output.pathExtension.lowercased()=="wav" else { throw EngineFailure.invalid("Output must be WAV") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        let unpaced=directory.appending(path:"dialogue-unpaced.wav")
        let writer=try WAVStreamWriter(url:unpaced,sampleRate:24000)
        var completed=false
        defer { if !completed { writer.cancel();try? FileManager.default.removeItem(at:output) };try? FileManager.default.removeItem(at:unpaced) }
        let start=ContinuousClock.now
        var timings:[DialogueTiming]=[],cursor=0.0,firstAudio:Double?,chunkIndex=0
        func deliver(_ samples: [Float]) throws {
            if engine.isCancelled(command.id) { throw EngineFailure.cancelled }
            guard command.mode == "play" else { return }
            let path=directory.appending(path:"part-\(chunkIndex).wav")
            try AudioIO.writePCM24(samples,sampleRate:24000,to:path)
            if firstAudio == nil { firstAudio=(ContinuousClock.now-start).seconds }
            engine.send(command.id,"chunk",["path":path.path,"index":chunkIndex,"firstAudioSeconds":firstAudio!])
            chunkIndex+=1
        }
        for (index,turn) in turns.enumerated() {
            if engine.isCancelled(command.id) { throw EngineFailure.cancelled }
            let child=Self.turnCommand(command,turn:turn,index:index)
            engine.send(command.id,"progress",["message":"\(turn.actor) • turn \(index+1) of \(turns.count)"])
            let result = try SynthesisJob(engine:engine,command:child,onChunk:deliver).run()
            let samples=try AudioIO.readMono(URL(filePath:child.output),sampleRate:24000)
            let duration=Double(samples.count)/24000
            timings.append(DialogueTiming(actor:turn.actor,start:cursor/command.pace,duration:duration/command.pace,modelID:result["modelID"] as? String))
            try writer.append(samples);cursor+=duration
            if index<turns.count-1 {
                let silence=[Float](repeating:0,count:Int(gap*24000))
                if !silence.isEmpty { try writer.append(silence);try deliver(silence) }
                cursor+=gap
            }
        }
        try writer.finish()
        if abs(command.pace-1)>0.0001 { try PaceRenderer.render(input:unpaced,output:output,rate:Float(command.pace)) }
        else { try FileManager.default.copyItem(at:unpaced,to:output) }
        if engine.isCancelled(command.id) { throw EngineFailure.cancelled }
        completed=true
        return ["path":output.path,"duration":try AudioIO.duration(of:output),"elapsedSeconds":(ContinuousClock.now-start).seconds,"firstAudioSeconds":firstAudio.map { $0 as Any } ?? NSNull(),"profile":"dialogue","sampleRate":24000,"bitsPerSample":24,"modelID":"Qwen3/dialogue","dialogueTiming":try engine.jsonObject(TimingEnvelope(turns:timings))["turns"]!]
    }
    /// Preserve the parent's live mode/quality; only pace is deferred to parent assembly/playback.
    static func turnCommand(_ parent: SynthesizeCommand, turn: EngineDialogueTurn, index: Int) -> SynthesizeCommand {
        var child=parent
        child.dialogueTurns=nil;child.voiceConfiguration=turn.configuration;child.text=turn.text
        child.references=turn.references;child.language=turn.language;child.instruction=turn.instruction;child.toneCue=turn.toneCue;child.pace=1
        let directory=URL(filePath:parent.directory).appending(path:"turn-\(index)")
        child.directory=directory.path;child.output=directory.appending(path:"speech.wav").path
        return child
    }
    private struct TimingEnvelope: Encodable { let turns:[DialogueTiming] }
}

import Foundation
import Testing
@testable import ChatterCore

struct TrainingDatasetTests {
    @Test func exportCopiesAllEnabledTakesWithOneStableReference() throws {
        let root=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        var voice=VoiceProfile(name:"Test speaker")
        let metrics=RecordingMetrics(duration:5,peak:0.5,rms:0.1,clippedFraction:0,silenceFraction:0,score:100,warnings:[])
        for index in 0..<3 {
            let sample=VoiceSample(id:"take-\(index)",label:"Take",transcript:"Line \(index).",metrics:metrics)
            voice.samples.append(sample)
            let folder=root.appending(path:voice.id).appending(path:sample.id)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data([UInt8(index)]).write(to:folder.appending(path:"reference.wav"))
        }
        voice.excludedSampleIDs=["take-1"]
        let output=root.appending(path:"dataset")
        try TrainingDataset.export(voice:voice,to:output,voicesRoot:root)
        let lines=try String(contentsOf:output.appending(path:"train.jsonl"),encoding:.utf8).split(separator:"\n")
        let records=try lines.map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:String] }
        #expect(records.map { $0["text"]! } == ["Line 0.","Line 2."])
        #expect(records.allSatisfy { $0["ref_audio"] == "take-0.wav" })
        #expect(try Data(contentsOf:output.appending(path:"take-1.wav")) == Data([2]))
        #expect(try Data(contentsOf:root.appending(path:voice.id).appending(path:"take-1/reference.wav")) == Data([1]))
    }
}

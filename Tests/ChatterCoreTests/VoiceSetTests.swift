import Testing
import Foundation
@testable import ChatterCore

struct VoiceSetTests {
    private func fixture() -> VoiceProfile {
        var voice = VoiceProfile(name: "Test speaker")
        let metrics = RecordingMetrics(duration: 20, peak: 0.7, rms: 0.1, clippedFraction: 0, silenceFraction: 0.1, score: 90, warnings: [])
        voice.samples = (1...3).map { VoiceSample(id: "take-\($0)", label: "Take \($0)", transcript: "Words for take \($0).", metrics: metrics) }
        voice.selectedSampleID = "take-2"
        return voice
    }
    @Test func oldLibraryIncludesEveryTakeByDefault() throws {
        let data = try JSONEncoder().encode(fixture())
        let voice = try JSONDecoder().decode(VoiceProfile.self, from: data)
        #expect(voice.useReferenceSet == nil)
        #expect(voice.usesReferenceSet)
        #expect(try voice.references().map(\.sampleID) == ["take-1", "take-2", "take-3"])
        #expect(voice.samples[0].originalFileName == nil)
    }
    @Test func subsetsAndExplicitSingleTakeKeepOrder() throws {
        var voice = fixture(); voice.excludedSampleIDs = ["take-2"]
        #expect(try voice.references().map(\.sampleID) == ["take-1", "take-3"])
        #expect(try voice.references(overriding: "take-2").map(\.sampleID) == ["take-2"])
        #expect(throws: ChatterError.self) { try voice.references(overriding: "missing") }
        voice.useReferenceSet = false
        #expect(try voice.references().map(\.sampleID) == ["take-2"])
        voice.useReferenceSet = true; voice.excludedSampleIDs = voice.samples.map(\.id)
        #expect(throws: ChatterError.self) { try voice.references() }
    }
    @Test func queuedSetSurvivesEditsAndRestart() throws {
        var voice = fixture()
        var job = SpeechJob(request: SpeechRequest(voice: voice.id, text: "New words."), voiceName: voice.name)
        job.references = try voice.references()
        let accepted = job.references
        voice.samples[0].transcript = "Edited after submission."
        voice.excludedSampleIDs = ["take-1", "take-3"]
        let restored = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job))
        #expect(restored.references == accepted)
        #expect(restored.references?.count == 3)
        #expect(restored.references?.first?.transcript == "Words for take 1.")
        var oldJob = job; oldJob.references = nil; oldJob.request.sampleID = "take-2"
        let restoredOld = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(oldJob))
        #expect(restoredOld.references == nil)
        #expect(try voice.references(overriding: restoredOld.request.sampleID).map(\.sampleID) == ["take-2"])
    }
}

import Testing
import Foundation
@testable import ChatterCore

struct SpeechToneTests {
    @Test func oldRequestsAndPreferencesDefaultToNatural() throws {
        let request = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"voice":"loki","text":"Hello.","pace":1,"mode":"save"}"#.utf8))
        #expect(request.tone == nil)
        #expect(try request.validated().effectiveTone == .natural)
        #expect(request.effectiveTone.cue.isEmpty)
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"port":18423}"#.utf8))
        #expect(settings.studioTone == "natural")
        let futureSettings = try JSONDecoder().decode(Settings.self, from: Data(#"{"studioTone":"unknown-preset"}"#.utf8))
        #expect(futureSettings.studioTone == "natural")
    }
    @Test func rejectUnknownTonesAndAcceptEveryPreset() throws {
        for tone in SpeechTone.allCases {
            let request = try SpeechRequest(voice: "loki", text: "My actual words.", tone: tone.rawValue).validated()
            #expect(request.effectiveTone == tone)
            #expect(request.text == "My actual words.")
            if tone != .natural { #expect(tone.cue.hasPrefix("Speak with a ")); #expect(!tone.cue.contains("[")) }
        }
        for invalid in ["", "Cheerful", "[cheerful]", "invented"] {
            #expect(throws: ChatterError.self) { try SpeechRequest(voice: "loki", text: "Hello", tone: invalid).validated() }
        }
    }
    @Test func queuedToneAndCueSurviveRelaunch() throws {
        var job = SpeechJob(request: SpeechRequest(voice: "loki", text: "Original text", tone: "optimistic"), voiceName: "loki")
        job.toneCue = SpeechTone.optimistic.cue
        let restored = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job))
        #expect(restored.request.effectiveTone == .optimistic)
        #expect(restored.toneCue == SpeechTone.optimistic.cue)
        #expect(restored.request.text == "Original text")
        job.request.tone = nil; job.toneCue = nil
        let legacy = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job))
        #expect(legacy.toneCue == nil)
        #expect(legacy.request.effectiveTone == .natural)
    }
}

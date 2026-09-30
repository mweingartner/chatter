import Foundation
import Testing
@testable import ChatterToolingKit

struct NarrationMetadataTests {
    @Test func preservesQwenControlsAndWarningsWithoutPrivatePaths() async throws {
        let fixture = try HandoffFixture(frames: [44100])
        defer { fixture.directory.remove() }
        fixture.source.update(fixture.jobIDs[0]) { job in
            var request = job["request"]!.objectValue!
            request["language"] = "English"; request["instruction"] = "Speak clearly."
            request["quality"] = "studio"; request["sampleID"] = "take-1"
            job["request"] = .object(request)
            job["voiceConfiguration"] = ["kind": "designed", "language": "English", "description": "Warm voice", "privatePath": "/secret"]
            job["warnings"] = ["Keep this warning"]
            job["engineName"] = "Qwen3-TTS"; job["modelID"] = "Qwen3/design"
            job["referenceSampleIDs"] = ["take-1"]
            job["references"] = [["reference": "/secret/reference.wav"]]
        }
        let result = try await fixture.prepare()
        let scene = try #require(result["scenes"]?[0])
        #expect(scene["instruction"] == "Speak clearly." && scene["language"] == "English")
        #expect(scene["quality"] == "studio" && scene["sampleID"] == "take-1")
        #expect(scene["warnings"] == ["Keep this warning"])
        #expect(scene["modelID"] == "Qwen3/design" && scene["referenceSampleIDs"] == ["take-1"])
        #expect(scene["voiceConfiguration"]?["kind"] == "designed")
        #expect(!result.encoded().contains("/secret") && !result.encoded().contains("/remote-host-only"))
    }

    static let script: JSONValue = ["cast": ["Host": "Michael", "Expert": "Ryan"], "gapSeconds": 0.1875,
        "turns": [["actor": "Host", "text": "Hello.", "language": "English"],
                  ["actor": "Expert", "text": "Welcome.", "tone": "optimistic", "instruction": "Sound upbeat."]]]
    static let timing: JSONValue = [["actor": "Host", "start": 0, "duration": 0.25, "modelID": "Qwen3/quality"],
                                    ["actor": "Expert", "start": 0.4, "duration": 0.35, "modelID": "Qwen3/custom"]]

    @Test func stagesDialogueWithPostPaceActorTiming() async throws {
        let fixture = try HandoffFixture(frames: [44100]); defer { fixture.directory.remove() }
        fixture.source.update(fixture.jobIDs[0]) { job in
            var request = job["request"]!.objectValue!; request["dialogue"] = Self.script
            job["request"] = .object(request); job["dialogueTiming"] = Self.timing
        }
        let result = try await fixture.prepare()
        let scene = try #require(result["scenes"]?[0])
        #expect(scene["dialogue"] == Self.script)
        #expect(scene["dialogueTiming"]?[0]?["voice"] == "Michael")
        #expect(scene["dialogueTiming"]?[1]?["voice"] == "Ryan")
        #expect(scene["dialogueTiming"]?[0]?["from"] == 0 && scene["dialogueTiming"]?[0]?["durationInFrames"] == 8)
        #expect(scene["dialogueTiming"]?[1]?["from"] == 12 && scene["dialogueTiming"]?[1]?["durationInFrames"] == 11)
        #expect(scene["dialogueTiming"]?[1]?["start"] == 0.4 && scene["dialogueTiming"]?[1]?["modelID"] == "Qwen3/custom")
    }

    @Test func rejectsMissingOrInvalidDialogueTimingWithoutReplacingManifest() async throws {
        let fixture = try HandoffFixture(frames: [44100]); defer { fixture.directory.remove() }
        _ = try await fixture.prepare()
        let original = try Data(contentsOf: fixture.manifestURL)
        let invalid: [JSONValue] = [.null, [],
            [["actor": "Host", "start": 0, "duration": 0.8], ["actor": "Expert", "start": 0.4, "duration": 0.3]],
            [["actor": "Host", "start": 0, "duration": 0.25], ["actor": "Expert", "start": 0.4, "duration": 2]],
            [["actor": "Wrong", "start": 0, "duration": 0.25], ["actor": "Expert", "start": 0.4, "duration": 0.3]]]
        for stamps in invalid {
            fixture.source.update(fixture.jobIDs[0]) { job in
                var request = job["request"]!.objectValue!; request["dialogue"] = Self.script
                job["request"] = .object(request); job["dialogueTiming"] = stamps
            }
            await #expect(throws: RemotionHandoffError.invalidDialogueTiming(scene: "scene-0")) { try await fixture.prepare() }
            #expect(try Data(contentsOf: fixture.manifestURL) == original)
        }
    }
}

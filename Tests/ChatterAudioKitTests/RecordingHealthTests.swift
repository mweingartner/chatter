// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Recording health")
struct RecordingHealthTests {
    static let cases = ["silence", "quiet", "clipping", "long", "short", "ideal", "tiny"]

    @Test("Matches Python inspect_audio", arguments: cases)
    func matchesPython(name: String) throws {
        let expected = try #require(try Fixtures.json("health_expected.json", as: [String: RecordingHealth].self)[name])
        let health = RecordingHealth.inspect(TestSignals.healthCase(name))
        #expect(health.duration == expected.duration)
        #expect(abs(health.peak - expected.peak) <= 1e-6)
        // numpy accumulated in float32; we accumulate in Double.
        #expect(abs(health.rms - expected.rms) <= max(1e-9, expected.rms * 1e-5))
        #expect(abs(health.clippedFraction - expected.clippedFraction) <= 1e-12)
        #expect(abs(health.silenceFraction - expected.silenceFraction) <= 1e-12)
        #expect(abs(health.score - expected.score) <= 1e-3)
        #expect(health.warnings == expected.warnings)
    }

    @Test("Warning texts are verbatim")
    func warningTexts() {
        let all = RecordingHealth.Advice.warnings(duration: 40, rms: 0.001, clipped: 0.5, silent: 0.9)
        #expect(all == [
            "A focused 10–30 second take usually responds faster. Split long recordings into natural passages.",
            "Clipping detected. Lower microphone gain and record again.",
            "Recording is quiet. Move closer to the microphone.",
            "This take contains substantial silence. Use a continuous, natural reading.",
        ])
        #expect(RecordingHealth.Advice.warnings(duration: 9.99, rms: 0.1, clipped: 0, silent: 0)
            == ["Record at least 10 seconds for a stronger voice reference."])
        #expect(RecordingHealth.Advice.warnings(duration: 22, rms: 0.015, clipped: 0.001, silent: 0.4).isEmpty)
    }

    @Test("Score formula and clamping")
    func score() {
        #expect(RecordingHealth.Advice.score(duration: 22, rms: 0.1, clipped: 0, silent: 0.15) == 100)
        #expect(abs(RecordingHealth.Advice.score(duration: 12, rms: 0.1, clipped: 0, silent: 0.25) - (100 - 7 - 5.5)) < 1e-9)
        #expect(abs(RecordingHealth.Advice.score(duration: 100, rms: 0.01, clipped: 0, silent: 0) - (100 - 21 - 20)) < 1e-9)
        #expect(RecordingHealth.Advice.score(duration: 22, rms: 0.1, clipped: 0.2, silent: 0) == 0)
    }

    @Test("JSON keys match the app's RecordingMetrics")
    func jsonKeys() throws {
        let health = RecordingHealth.inspect(TestSignals.healthCase("short"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(health)) as? [String: Any])
        #expect(Set(object.keys) == ["duration", "peak", "rms", "clippedFraction", "silenceFraction", "score", "warnings"])
        let decoded = try JSONDecoder().decode(RecordingHealth.self, from: JSONEncoder().encode(health))
        #expect(decoded == health)
    }

    @Test("Empty and sub-block recordings count as silent")
    func emptyInput() {
        let empty = RecordingHealth.inspect([])
        #expect(empty.duration == 0 && empty.peak == 0 && empty.rms == 0 && empty.clippedFraction == 0)
        #expect(empty.silenceFraction == 1)
        #expect(RecordingHealth.inspect([Float](repeating: 0.5, count: 440)).silenceFraction == 1)
        #expect(RecordingHealth.inspect([Float](repeating: 0.5, count: 441)).silenceFraction == 0)
    }

    @Test("Clipping threshold is float32 0.999")
    func clipThreshold() {
        let samples: [Float] = [0.999, -0.999, Float(0.999).nextDown, 1, 0]
        #expect(RecordingHealth.inspect(samples).clippedFraction == 3.0 / 5.0)
    }
}

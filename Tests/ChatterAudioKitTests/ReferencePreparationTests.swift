// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import CryptoKit
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Reference preparation")
struct ReferencePreparationTests {
    struct Expected: Decodable {
        let result: PreparedReference
        let lo: Int
        let hi: Int
        let gain: Double
        let referenceLength: Int
        let referenceSHA256: String
        let transcriptFile: String
    }

    /// Records progress messages and transcription calls from @Sendable closures.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func record(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    @Test("Matches Python prepare bit-for-bit (trim, gain, 24-bit output, files)")
    func matchesPython() async throws {
        let expected = try Fixtures.json("prepare_expected.json", as: Expected.self)
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let destination = scratch.url.appendingPathComponent("voice/take-1", isDirectory: true)
        let source = try Fixtures.url("prepare_source.wav")
        let prepared = try await ReferencePreparation.prepare(
            source: source, destination: destination, transcript: "  A synthetic test transcript.\n",
            transcribe: { _ in Issue.record("Transcription must not run when a transcript is given"); return "" },
            progress: { Issue.record("Unexpected progress \($0)") })

        #expect(prepared.transcript == expected.result.transcript)
        #expect(prepared.originalFileName == "original.wav")
        #expect(prepared.path == destination.appendingPathComponent("reference.wav").path(percentEncoded: false))
        #expect(prepared.metrics.warnings == expected.result.metrics.warnings)
        #expect(prepared.metrics.duration == expected.result.metrics.duration)
        #expect(abs(prepared.metrics.rms - expected.result.metrics.rms) < 1e-6)
        #expect(abs(prepared.metrics.score - expected.result.metrics.score) < 1e-3)

        let audio = try AudioIO.readMono44k(source)
        #expect(ReferencePreparation.speechBounds(audio, rms: prepared.metrics.rms) == expected.lo..<expected.hi)
        let trimmed = Array(audio[expected.lo..<expected.hi])
        let peak = Double(trimmed.map(abs).max() ?? 0)
        #expect(min(4.0, 0.89 / peak) == expected.gain)

        let reference = try Data(contentsOf: URL(filePath: prepared.path))
        #expect(SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined() == expected.referenceSHA256)
        #expect(try AudioIO.readMono44k(URL(filePath: prepared.path)).count == expected.referenceLength)
        #expect(try Data(contentsOf: destination.appendingPathComponent("original.wav")) == Data(contentsOf: source))
        let transcript = try Data(contentsOf: destination.appendingPathComponent("transcript.txt"))
        #expect(transcript == Data(expected.transcriptFile.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)).sorted()
            == ["original.wav", "reference.wav", "transcript.txt"])
    }

    @Test("Durations outside 3 s – 3 min are rejected before any file is written", arguments: [2.0, 200.0])
    func rejectsDuration(seconds: Double) async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let source = scratch.file("take.wav")
        try WAVBuilder.silentPCM16(frames: Int(seconds * 44100), sampleRate: 44100).write(to: source)
        let destination = scratch.file("out")
        let error = await #expect(throws: ChatterAudioError.unsupportedDuration) {
            try await ReferencePreparation.prepare(source: source, destination: destination, transcript: "Words",
                                                   transcribe: nil, progress: nil)
        }
        #expect(error?.localizedDescription == "Use an audio recording between 3 seconds and 3 minutes long.")
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test("Near-silent recordings are rejected")
    func rejectsSilence() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let source = scratch.file("quiet.wav")
        try AudioIO.writePCM24(TestSignals.tone(4, amplitude: 0.0012, frequency: 200), to: source)
        let error = await #expect(throws: ChatterAudioError.noSpeechLevel) {
            try await ReferencePreparation.prepare(source: source, destination: scratch.file("out"), transcript: "Words",
                                                   transcribe: nil, progress: nil)
        }
        #expect(error?.localizedDescription == "No usable speech level detected in this recording.")
    }

    @Test("A blank transcript is transcribed locally, with progress reported first")
    func transcribesWhenBlank() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let source = scratch.file("Take One.M4A.WAV")
        let tone = TestSignals.tone(3.5, amplitude: 0.2, frequency: 300)
        try AudioIO.writePCM24(tone, to: source)
        let events = Recorder()
        let prepared = try await ReferencePreparation.prepare(
            source: source, destination: scratch.file("out"), transcript: " \n\t",
            transcribe: { samples in
                events.record("transcribe \(samples.count)")
                return "  Spoken words.\n"
            },
            progress: { events.record($0) })
        #expect(events.values == ["Transcribing locally…", "transcribe \(tone.count)"])
        #expect(prepared.transcript == "Spoken words.")
        #expect(prepared.originalFileName == "original.wav")
        #expect(try String(contentsOf: scratch.file("out/transcript.txt"), encoding: .utf8) == "Spoken words.")
    }

    @Test("An empty transcription or missing transcriber reports no transcript")
    func noTranscript() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let source = scratch.file("take.wav")
        try AudioIO.writePCM24(TestSignals.tone(3.5, amplitude: 0.2, frequency: 300), to: source)
        let transcribers: [(@Sendable ([Float]) async throws -> String)?] = [{ _ in "   " }, nil]
        for transcribe in transcribers {
            let error = await #expect(throws: ChatterAudioError.noTranscript) {
                try await ReferencePreparation.prepare(source: source, destination: scratch.file("out"), transcript: "",
                                                       transcribe: transcribe, progress: nil)
            }
            #expect(error?.localizedDescription == "No transcript was detected. Enter the words spoken in the recording.")
        }
    }

    @Test("Re-preparing replaces previous files atomically")
    func overwrites() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let source = scratch.file("take.flac.wav")
        try AudioIO.writePCM24(TestSignals.tone(3.5, amplitude: 0.2, frequency: 300), to: source)
        let destination = scratch.file("out")
        _ = try await ReferencePreparation.prepare(source: source, destination: destination, transcript: "First",
                                                   transcribe: nil, progress: nil)
        _ = try await ReferencePreparation.prepare(source: source, destination: destination, transcript: "Second",
                                                   transcribe: nil, progress: nil)
        #expect(try String(contentsOf: destination.appendingPathComponent("transcript.txt"), encoding: .utf8) == "Second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)).sorted()
            == ["original.wav", "reference.wav", "transcript.txt"])
    }

    @Test("Original file suffix follows Python's Path.suffix", arguments: [
        ("take.WAV", ".WAV"), ("a.b.Mp3", ".Mp3"), ("noext", ""), (".hidden", ""), ("trailing.", ""), ("..m4a", ".m4a"),
    ])
    func suffix(name: String, expected: String) {
        #expect(ReferencePreparation.pythonSuffix(of: URL(filePath: "/tmp/\(name)")) == expected)
    }

    @Test("Edge-silence trim keeps 100 ms margins and whole signal when nothing is active")
    func trimBounds() {
        let signal = TestSignals.zeros(1) + TestSignals.tone(1, amplitude: 0.5, frequency: 220) + TestSignals.zeros(1)
        let bounds = ReferencePreparation.speechBounds(signal, rms: RecordingHealth.inspect(signal).rms)
        #expect(bounds == (44100 - 4410)..<(88200 + 4410))
        let silence = TestSignals.zeros(2)
        #expect(ReferencePreparation.speechBounds(silence, rms: 0) == silence.indices)
        #expect(ReferencePreparation.normalizedPeak(silence) == silence)
        #expect(ReferencePreparation.normalizedPeak([0.001, -0.002]) == [0.001 * 4, -0.002 * 4])
        #expect(ReferencePreparation.normalizedPeak([0.5, -1.78]) == [0.5 * Float(0.89 / Double(Float(1.78))), -1.78 * Float(0.89 / Double(Float(1.78)))])
    }
}

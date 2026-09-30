// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import CryptoKit
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Decoding and resampling")
struct AudioDecodingTests {
    struct FormatExpectation: Decodable { let length: Int; let rms: Double; let source: String }

    /// 48 kHz stereo, 4 s probes. Independent libsndfile/SciPy or FFmpeg decodes provide the reference.
    /// Ogg/Vorbis decodes 64 frames (at 48 kHz) shorter on AVFoundation, within the ±64 tolerance.
    /// Raw ADTS AAC carries no gapless metadata, so AVFoundation (like Chatter's former bundled
    /// decoder) keeps the encoder's 1024-frame priming plus 512-frame remainder: 1536 frames at
    /// 48 kHz = 1411.2 frames at 44.1 kHz longer.
    @Test("Decodes every supported format to 44.1 kHz mono",
          arguments: ["wav", "mp3", "m4a", "aac", "flac", "aiff", "caf", "ogg", "opus"])
    func decodesFormat(ext: String) throws {
        let expected = try #require(try Fixtures.json("formats_expected.json", as: [String: FormatExpectation].self)[ext])
        let samples = try AudioIO.readMono44k(Fixtures.url("probe.\(ext)"))
        let expectedLength = 176_400 + (ext == "aac" ? 1412 : 0)
        #expect(abs(samples.count - expectedLength) <= 64, "\(ext): \(samples.count) samples")
        let rms = Measure.rms(samples)
        #expect(abs(rms - expected.rms) / expected.rms < 0.01, "\(ext): rms \(rms) vs \(expected.rms)")
    }

    @Test("Resampling matches scipy resample_poly", arguments: [48000, 22050])
    func resamplingFidelity(rate: Int) throws {
        let expected = try Fixtures.floats("resample_expected_\(rate).f32")
        let samples = try AudioIO.readMono44k(Fixtures.url("resample_in_\(rate).wav"))
        #expect(samples.count == expected.count)
        let snr = Measure.snr(expected: expected, actual: samples)
        #expect(snr >= 60, "SNR \(snr) dB")
    }

    @Test("44.1 kHz input is passed through and channels are averaged")
    func downmix() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let left: [Float] = [0.5, -1, 0.25, 0.1], right: [Float] = [0.25, 1, -0.75, 0.3]
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        let url = scratch.file("stereo.wav")
        try WAVBuilder.float32(interleaved, channels: 2, sampleRate: 44100).write(to: url)
        #expect(try AudioIO.readMono44k(url) == zip(left, right).map { ($0 + $1) / 2 })
    }

    @Test("Reads beyond a single short read (full length at 48 kHz)")
    func readsWholeFile() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("long48.wav")
        let tone = (0..<(48000 * 3 + 17)).map { Float(0.3 * sin(Double($0) * 0.05)) }
        try WAVBuilder.float32(tone, channels: 1, sampleRate: 48000).write(to: url)
        #expect(try AudioIO.readMono44k(url).count == Int((Double(tone.count) * 44100 / 48000).rounded(.up)))
    }

    @Test("Undecodable files report the supported formats")
    func undecodable() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let garbage = scratch.file("garbage.mp3")
        try Data("not audio at all".utf8).write(to: garbage)
        for url in [garbage, scratch.file("missing.wav")] {
            let error = try #require(throws: ChatterAudioError.self) { try AudioIO.readMono44k(url) }
            guard case .undecodable = error else { Issue.record("Unexpected \(error)"); continue }
            #expect(error.localizedDescription.hasPrefix(
                "Cannot decode this recording. Use WAV, MP3, M4A/AAC, FLAC, AIFF, CAF, or Ogg/Opus audio. "))
        }
    }

    @Test("Empty or non-finite recordings are rejected")
    func invalidSamples() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let empty = scratch.file("empty.wav"), nan = scratch.file("nan.wav"), infinite = scratch.file("inf.wav")
        try WAVBuilder.float32([], channels: 1, sampleRate: 44100).write(to: empty)
        try WAVBuilder.float32([0.1, .nan, 0.2], channels: 1, sampleRate: 44100).write(to: nan)
        try WAVBuilder.float32([0.1, 0.2, 0.3, -.infinity], channels: 2, sampleRate: 48000).write(to: infinite)
        for url in [empty, nan, infinite] {
            #expect(throws: ChatterAudioError.emptyOrInvalidSamples) { try AudioIO.readMono44k(url) }
        }
        #expect(ChatterAudioError.emptyOrInvalidSamples.localizedDescription == "Recording is empty or contains invalid samples.")
    }

    @Test("Duration comes from the file header")
    func duration() throws {
        #expect(abs(try AudioIO.duration(of: Fixtures.url("probe.wav")) - 4.0) < 1e-9)
        #expect(abs(try AudioIO.duration(of: Fixtures.url("prepare_source.wav")) - 5.2) < 1e-9)
        #expect(throws: ChatterAudioError.self) { try AudioIO.duration(of: URL(filePath: "/nonexistent/x.wav")) }
    }
}

@Suite("24-bit WAV writing")
struct PCM24WritingTests {
    @Test("writePCM24 is bit-exact with soundfile PCM_24")
    func bitExact() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let samples = try Fixtures.floats("pcm24_input.f32")
        let url = scratch.file("out.wav")
        try AudioIO.writePCM24(samples, to: url)
        #expect(try Data(contentsOf: url) == Fixtures.data("pcm24_expected.wav"))
        // Odd data size: libsndfile appends a pad byte.
        try AudioIO.writePCM24(Array(samples.prefix(3)), to: url)
        #expect(try Data(contentsOf: url) == Fixtures.data("pcm24_expected_odd.wav"))
        #expect(try scratch.contents() == ["out.wav"])
    }

    @Test("Quantization rule", arguments: [
        (Float(0), 0), (1, 8_388_607), (-1, -8_388_608), (0.5, 4_194_304), (-0.5, -4_194_304),
        (1e-9, 0), (-1e-9, -1), (0.3, 2_516_582), (-0.3, -2_516_583), (2, 8_388_607), (-2, -8_388_608),
        (.infinity, 8_388_607), (-.infinity, -8_388_608), (Float(1).nextDown, 8_388_607),
    ])
    func quantize(sample: Float, expected: Int) throws {
        #expect(try Int(PCM24.quantize(sample)) == expected)
    }

    @Test("NaN samples are rejected, not silently zeroed")
    func rejectsNaN() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: ChatterAudioError.self) { try AudioIO.writePCM24([0, .nan], to: scratch.file("nan.wav")) }
        #expect(try scratch.contents().isEmpty)
    }

    @Test("Written files decode back to the same samples")
    func roundTrip() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let samples = TestSignals.tone(0.25, amplitude: 0.5, frequency: 440)
        let url = scratch.file("tone.wav")
        try AudioIO.writePCM24(samples, to: url)
        let decoded = try AudioIO.readMono44k(url)
        #expect(decoded.count == samples.count)
        #expect(zip(decoded, samples).allSatisfy { abs($0 - $1) <= 1.0 / 8_388_608 })
    }

    @Test("Stream writer output equals writePCM24", arguments: [0, 1, 3, 4, 44101])
    func streamMatches(count: Int) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let samples = TestSignals.noise(Double(count) / 44100, amplitude: 1.3, seed: 42)
        let whole = scratch.file("whole.wav"), streamed = scratch.file("streamed.wav")
        try AudioIO.writePCM24(samples, to: whole)
        let writer = try WAVStreamWriter(url: streamed)
        #expect(FileManager.default.fileExists(atPath: writer.partialURL.path(percentEncoded: false)))
        #expect(writer.partialURL.lastPathComponent == "streamed.wav.partial")
        var start = 0
        for size in [1, 2, 4097, 10000] where start < samples.count {
            let end = min(samples.count, start + size)
            try writer.append(Array(samples[start..<end]))
            start = end
        }
        try writer.append(Array(samples[start...]))
        #expect(writer.frameCount == samples.count)
        #expect(!FileManager.default.fileExists(atPath: streamed.path(percentEncoded: false)))
        try writer.finish()
        #expect(try Data(contentsOf: streamed) == Data(contentsOf: whole))
        #expect(try scratch.contents() == ["streamed.wav", "whole.wav"])
        #expect(throws: ChatterAudioError.self) { try writer.append([0]) }
        #expect(throws: ChatterAudioError.self) { try writer.finish() }
    }

    @Test("Cancel and abandonment leave no files")
    func cancelLeavesNothing() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WAVStreamWriter(url: scratch.file("cancelled.wav"))
        try writer.append([0.1, 0.2, 0.3])
        writer.cancel()
        writer.cancel()
        #expect(try scratch.contents().isEmpty)
        #expect(throws: ChatterAudioError.self) { try writer.append([0]) }
        do {
            let abandoned = try WAVStreamWriter(url: scratch.file("abandoned.wav"))
            try abandoned.append([0.5])
        }
        #expect(try scratch.contents().isEmpty)
    }

    @Test("Stream writer can be fed from concurrent tasks")
    func concurrentUse() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WAVStreamWriter(url: scratch.file("concurrent.wav"))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try? writer.append([Float](repeating: 0.25, count: 1000)) } }
        }
        try writer.finish()
        let decoded = try AudioIO.readMono44k(scratch.file("concurrent.wav"))
        #expect(decoded.count == 8000 && decoded.allSatisfy { $0 == 0.25 })
    }
}

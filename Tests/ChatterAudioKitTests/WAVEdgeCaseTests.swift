// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("WAV writing edge cases")
struct WAVEdgeCaseTests {
    /// Seeded SplitMix64 so failures replay.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 { data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }

    @Test("Header sizes, rate and pad byte are consistent for any length", arguments: [0, 1, 2, 3, 1000, 1001])
    func headerFields(frames: Int) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("h.wav")
        try AudioIO.writePCM24([Float](repeating: 0.25, count: frames), sampleRate: 22050, to: url)
        let data = try Data(contentsOf: url)
        let dataBytes = frames * 3, pad = dataBytes % 2
        #expect(data.count == 44 + dataBytes + pad)
        #expect(Self.u32(data, 4) == UInt32(36 + dataBytes + pad) && Self.u32(data, 40) == UInt32(dataBytes))
        #expect(Self.u32(data, 24) == 22050 && Self.u32(data, 28) == 22050 * 3)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: data[36..<40], as: UTF8.self) == "data")
        if pad == 1 { #expect(data.last == 0) }
    }

    @Test("Sample rates outside a WAV header's range are rejected",
          arguments: [0, 0.5, -44100, 44100.5, 768_001, .nan, .infinity])
    func invalidRates(rate: Double) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: ChatterAudioError.self) { try AudioIO.writePCM24([0], sampleRate: rate, to: scratch.file("r.wav")) }
        #expect(throws: ChatterAudioError.self) { try WAVStreamWriter(url: scratch.file("s.wav"), sampleRate: rate) }
        #expect(try scratch.contents().isEmpty)
        #expect(try PCM24.headerRate(1) == 1 && PCM24.headerRate(768_000) == 768_000)
    }

    @Test("The RIFF size limit is enforced exactly")
    func dataSizeBoundary() throws {
        let largest = (Int(UInt32.max) - 45) / 3
        #expect(try PCM24.dataSize(frames: largest) == UInt32(largest * 3))
        #expect(throws: ChatterAudioError.self) { try PCM24.dataSize(frames: largest + 1) }
        #expect(throws: ChatterAudioError.self) { try PCM24.dataSize(frames: -1) }
        #expect(ChatterAudioError.writeFailed(reason: "The recording is too long for a WAV file.").localizedDescription
                == "Cannot write audio. The recording is too long for a WAV file.")
    }

    /// Property: quantization is monotonic, within one step of the input, and odd-symmetric up to the floor shift.
    @Test("Quantization is monotonic and accurate over random samples")
    func quantizationProperties() throws {
        var rng = Seeded(state: 21)
        var samples = (0..<20_000).map { _ in Float.random(in: -1.2...1.2, using: &rng) }
        samples += [0, -0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1, -1, Float(1).nextDown, Float(-1).nextUp]
        samples.sort()
        var previous = Int32.min
        for sample in samples {
            let value = try PCM24.quantize(sample)
            #expect(value >= previous, "not monotonic at \(sample)")
            previous = value
            #expect((-8_388_608...8_388_607).contains(value))
            if abs(sample) < 1 { #expect(abs(Double(value) / 8_388_608 - Double(sample)) <= 1.0 / 8_388_608 + 1e-12, "\(sample)") }
            let mirrored = try PCM24.quantize(-sample)
            if abs(sample) < 0.999 { #expect(mirrored == -value || mirrored == -value - 1, "\(sample)") }
        }
    }

    @Test("A stale partial file is replaced, and paths with spaces and Unicode work")
    func stalePartialAndUnusualNames() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("Chatter 100% café 😀.wav")
        try Data(repeating: 0xEE, count: 5000).write(to: URL(filePath: url.path(percentEncoded: false) + ".partial"))
        let writer = try WAVStreamWriter(url: url)
        try writer.append([0.5, -0.5])
        try writer.finish()
        let reference = scratch.file("reference.wav")
        try AudioIO.writePCM24([0.5, -0.5], to: reference)
        #expect(try Data(contentsOf: url) == Data(contentsOf: reference))
        #expect(try scratch.contents() == ["Chatter 100% café 😀.wav", "reference.wav"])
    }

    @Test("Writers report a missing directory clearly and leave nothing behind")
    func missingDirectory() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let missing = scratch.file("no/such/dir/out.wav")
        let streamError = try #require(throws: ChatterAudioError.self) { try WAVStreamWriter(url: missing) }
        #expect(streamError.localizedDescription == "Cannot write audio. Cannot create out.wav.partial.")
        let writeError = try #require(throws: ChatterAudioError.self) { try AudioIO.writePCM24([0], to: missing) }
        #expect(writeError.localizedDescription.hasPrefix("Cannot write audio. "))
        #expect(try scratch.contents().isEmpty)
    }

    @Test("A destination that vanishes before finish fails and cleans up")
    func vanishedDestination() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let directory = scratch.file("job")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try WAVStreamWriter(url: directory.appendingPathComponent("speech.wav"))
        try writer.append([0.1, 0.2])
        // The job directory is replaced while the file is open: the rename target no longer exists.
        let partial = writer.partialURL
        try FileManager.default.moveItem(at: directory, to: scratch.file("moved"))
        let error = try #require(throws: ChatterAudioError.self) { try writer.finish() }
        #expect(error.localizedDescription.hasPrefix("Cannot write audio. Cannot move audio into place: "))
        #expect(!FileManager.default.fileExists(atPath: partial.path(percentEncoded: false)))
        writer.cancel()   // no effect after a failed finish
    }

    @Test("NaN appended mid-stream fails that append only; earlier audio is kept")
    func nanMidStream() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("s.wav")
        let writer = try WAVStreamWriter(url: url)
        try writer.append([0.25, 0.25])
        #expect(throws: ChatterAudioError.self) { try writer.append([0.5, .nan]) }
        #expect(writer.frameCount == 2)
        try writer.append([])
        try writer.finish()
        #expect(try AudioIO.readMono44k(url) == [0.25, 0.25])
    }

    @Test("Concurrent appends and a racing cancel never corrupt state")
    func appendCancelRace() async throws {
        for round in 0..<20 {
            let scratch = try ScratchDirectory()
            defer { scratch.remove() }
            let writer = try WAVStreamWriter(url: scratch.file("race.wav"))
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        if index == 4 { writer.cancel() } else { try? writer.append([Float](repeating: 0.1, count: 500)) }
                    }
                }
            }
            #expect(writer.frameCount % 500 == 0 && writer.frameCount <= 3500, "round \(round)")
            #expect(throws: ChatterAudioError.self) { try writer.finish() }
            #expect(try scratch.contents().isEmpty, "round \(round)")
        }
    }

    @Test("Streaming large audio keeps pace with real time")
    func streamingThroughput() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WAVStreamWriter(url: scratch.file("long.wav"))
        let block = [Float](repeating: 0.3, count: 16 * 2048)   // one steady decode block (~0.74 s)
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<80 { try writer.append(block) }   // ~1 minute of audio
        try writer.finish()
        #expect(clock.now - start < .seconds(10))
        let size = try FileManager.default.attributesOfItem(atPath: scratch.file("long.wav").path(percentEncoded: false))[.size] as? Int
        #expect(size == 44 + 80 * block.count * 3)
    }
}

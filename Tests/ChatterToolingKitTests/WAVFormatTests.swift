// Chatter integration tooling (Swift replacement for the former Python helpers).
@testable import ChatterToolingKit
import Foundation
import Testing

@Suite("WAV inspection follows Python's wave module")
struct WAVFormatTests {
    private func inspect(_ data: Data) throws -> WAVFormat {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("a.wav")
        try data.write(to: url)
        return try WAVFormat.read(from: url)
    }

    private func chunk(_ name: String, _ body: Data) -> Data {
        Data(name.utf8) + WAVFixture.le32(body.count) + body + (body.count.isMultiple(of: 2) ? Data() : Data([0]))
    }

    private func riff(_ chunks: Data...) -> Data {
        let body = chunks.reduce(Data("WAVE".utf8), +)
        return Data("RIFF".utf8) + WAVFixture.le32(body.count) + body
    }

    private func fmt(tag: Int = 1, channels: Int = 2, rate: Int = 48000, bits: Int = 16) -> Data {
        WAVFixture.le16(tag) + WAVFixture.le16(channels) + WAVFixture.le32(rate) + WAVFixture.le32(rate * channels * bits / 8)
            + WAVFixture.le16(channels * bits / 8) + WAVFixture.le16(bits)
    }

    @Test("Reads a Python-style PCM header")
    func pcm() throws {
        let format = try inspect(WAVFixture.data(frames: 44101))
        #expect(format.channels == 1 && format.sampleRate == 44100 && format.sampleWidth == 3 && format.frameCount == 44101)
        #expect(format.isComplete && format.bitsPerSample == 24)
        #expect(format.durationSeconds == 44101.0 / 44100)
    }

    @Test("Skips odd-sized chunks (with pad byte) before data and accepts WAVE_FORMAT_EXTENSIBLE PCM")
    func extensibleAndPadding() throws {
        let subformat = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        let extensible = fmt(tag: 0xFFFE, bits: 24) + WAVFixture.le16(22) + WAVFixture.le16(24) + WAVFixture.le32(3) + subformat
        let format = try inspect(riff(chunk("LIST", Data([1, 2, 3])), chunk("fmt ", extensible), chunk("data", Data(count: 60))))
        #expect(format.channels == 2 && format.sampleWidth == 3 && format.frameCount == 10 && format.isComplete)
        var otherSubformat = subformat
        otherSubformat[0] = 3
        let float = fmt(tag: 0xFFFE, bits: 32) + WAVFixture.le16(22) + WAVFixture.le16(32) + WAVFixture.le32(3) + otherSubformat
        #expect(throws: WAVFormatError.unknownExtendedFormat) { try inspect(riff(chunk("fmt ", float), chunk("data", Data(count: 8)))) }
    }

    @Test("Detects truncation bounded by the file, the data chunk and the RIFF size")
    func truncation() throws {
        let full = WAVFixture.data(frames: 100)
        #expect(!(try inspect(full.dropLast(1))).isComplete)
        var shortRIFF = full
        shortRIFF.replaceSubrange(4..<8, with: WAVFixture.le32(36 + 200))
        #expect(!(try inspect(shortRIFF)).isComplete)
        #expect(try inspect(full + Data(count: 10)).isComplete)
    }

    @Test(
        "Malformed headers fail with wave.Error wording",
        arguments: [
            (Data("RIFX\u{0}\u{0}\u{0}\u{0}WAVE".utf8), WAVFormatError.notRIFF),
            (Data("RIFF\u{4}\u{0}\u{0}\u{0}AVI ".utf8), .notWAVE),
            (Data("RIF".utf8), .incompleteHeader),
            (Data("RIFF\u{4}\u{0}\u{0}\u{0}WAVE".utf8), .missingChunks),
        ])
    func malformed(data: Data, error: WAVFormatError) {
        #expect(throws: error) { try inspect(data) }
    }

    @Test("Chunk order and fmt fields are validated")
    func fmtValidation() {
        #expect(throws: WAVFormatError.dataBeforeFormat) { try inspect(riff(chunk("data", Data(count: 4)), chunk("fmt ", fmt()))) }
        #expect(throws: WAVFormatError.unknownFormat(3)) { try inspect(riff(chunk("fmt ", fmt(tag: 3)), chunk("data", Data(count: 4)))) }
        #expect(throws: WAVFormatError.badSampleWidth) { try inspect(riff(chunk("fmt ", fmt(bits: 0)), chunk("data", Data(count: 4)))) }
        #expect(throws: WAVFormatError.badChannelCount) { try inspect(riff(chunk("fmt ", fmt(channels: 0)), chunk("data", Data(count: 4)))) }
        #expect(throws: WAVFormatError.incompleteHeader) { try inspect(riff(chunk("fmt ", Data(count: 10)), chunk("data", Data(count: 4)))) }
        #expect(throws: WAVFormatError.missingChunks) { try inspect(riff(chunk("fmt ", fmt()))) }
        #expect(WAVFormatError.unknownFormat(3).description == "unknown format: 3")
    }

    @Test("Narration timing: empty audio is rejected and frames round up")
    func timing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let empty = directory.file("empty.wav")
        try WAVFixture.write(to: empty, frames: 0)
        #expect(throws: RemotionHandoffError.emptyAudio) { try NarrationTiming(inspecting: empty, fps: 30) }
        let one = directory.file("one.wav")
        try WAVFixture.write(to: one, frames: 1)
        #expect(try NarrationTiming(inspecting: one, fps: 120).audioFrames == 1)
        let exact = directory.file("exact.wav")
        try WAVFixture.write(to: exact, frames: 44100 * 2, sampleRate: 44100, bytesPerSample: 2)
        let timing = try NarrationTiming(inspecting: exact, fps: 60)
        #expect(timing.audioFrames == 120 && timing.bitsPerSample == 16 && timing.durationSeconds == 2)
    }

    @Test("Random byte mutations never crash the parser")
    func fuzz() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var generator = SystemRandomNumberGenerator()
        let base = WAVFixture.data(frames: 32)
        for round in 0..<300 {
            var data = base
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if round.isMultiple(of: 3) { data = data.prefix(Int.random(in: 0...data.count, using: &generator)) }
            let url = directory.file("\(round).wav")
            try data.write(to: url)
            _ = try? WAVFormat.read(from: url)
        }
    }
}

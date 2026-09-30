// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Pace rendering")
struct PaceRendererTests {
    static let source = TestSignals.tone(3, amplitude: 0.5, frequency: 220)

    @Test("Changes duration and preserves pitch", arguments: [(Float(0.5), 6.0), (1.25, 2.4), (2.0, 1.5)])
    func renderFile(rate: Float, seconds: Double) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let input = scratch.file("in.wav"), output = scratch.file("out.wav")
        try AudioIO.writePCM24(Self.source, to: input)
        try PaceRenderer.render(input: input, output: output, rate: rate)
        #expect(abs(try AudioIO.duration(of: output) - seconds) / seconds < 0.01)
        let rendered = try AudioIO.readMono44k(output)
        #expect(abs(Double(rendered.count) / 44100 - seconds) / seconds < 0.01)
        let middle = rendered[(rendered.count / 4)..<(rendered.count * 3 / 4)]
        let original = Measure.zeroCrossingRate(Self.source[...])
        #expect(abs(Measure.zeroCrossingRate(middle) - original) / original < 0.02)
        #expect(try scratch.contents() == ["in.wav", "out.wav"])
    }

    @Test("In-memory rendering matches the requested length", arguments: [Float(0.5), 0.8, 1.5, 2.0])
    func renderSamples(rate: Float) throws {
        let rendered = try PaceRenderer.render(samples: Self.source, rate: rate)
        #expect(rendered.count == Int((Double(Self.source.count) / Double(rate)).rounded(.up)))
        let middle = rendered[(rendered.count / 4)..<(rendered.count * 3 / 4)]
        let original = Measure.zeroCrossingRate(Self.source[...])
        #expect(abs(Measure.zeroCrossingRate(middle) - original) / original < 0.02)
        #expect(Measure.rms(middle) > 0.2)
    }

    @Test("Unity pace copies the file byte-for-byte", arguments: [Float(1), 1.00005, 0.99995])
    func unityCopies(rate: Float) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let input = try Fixtures.url("probe.mp3"), output = scratch.file("same.mp3")
        try Data("stale".utf8).write(to: output)
        try PaceRenderer.render(input: input, output: output, rate: rate)
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
        #expect(try PaceRenderer.render(samples: Self.source, rate: rate) == Self.source)
    }

    @Test("Invalid paces are rejected", arguments: [Float(0.49), 2.01, 0, -1, .nan, .infinity])
    func rejectsInvalid(rate: Float) throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: ChatterAudioError.self) {
            try PaceRenderer.render(input: Fixtures.url("probe.wav"), output: scratch.file("x.wav"), rate: rate)
        }
        #expect(throws: ChatterAudioError.self) { try PaceRenderer.render(samples: [0.1], rate: rate) }
        #expect(try scratch.contents().isEmpty)
    }

    @Test("Unreadable input leaves no output")
    func unreadableInput() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let input = scratch.file("bad.wav")
        try Data("nope".utf8).write(to: input)
        #expect(throws: ChatterAudioError.self) { try PaceRenderer.render(input: input, output: scratch.file("o.wav"), rate: 1.5) }
        #expect(try scratch.contents() == ["bad.wav"])
    }
}

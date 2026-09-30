import ChatterAudioKit
import Foundation
import Testing

struct PassageEnvelopeTests {
    @Test func removesStepsWithoutChangingInteriorOrDuration() {
        var envelope = PassageEnvelope()
        let input = [Float](repeating: -0.027, count: 24_000)
        let output = envelope.append(input) + envelope.finish()
        #expect(output.count == input.count)
        #expect(output.first == 0)
        #expect(output.last == 0)
        #expect(Array(output[192..<23_808]) == Array(input[192..<23_808]))
        #expect(zip(output, output.dropFirst()).map { abs($1 - $0) }.max()! < 0.00023)
    }

    @Test(arguments: [1, 17, 191, 192, 193, 1_000, 24_000])
    func chunkBoundariesDoNotAlterSpeech(chunkSize: Int) {
        let input = (0..<24_000).map { Float(sin(Double($0) * 0.073)) * 0.7 }
        var whole = PassageEnvelope()
        let expected = whole.append(input) + whole.finish()
        var streaming = PassageEnvelope(), actual: [Float] = []
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            actual += streaming.append(Array(input[offset..<min(offset + chunkSize, input.count)]))
            #expect(streaming.append([]).isEmpty)
        }
        actual += streaming.finish()
        #expect(actual == expected)
        #expect(streaming.finish().isEmpty)
    }

    @Test(arguments: [0, 1, 2, 50, 191, 192, 193, 383, 384])
    func shortPassagesRemainFiniteAndBounded(count: Int) {
        var envelope = PassageEnvelope()
        let output = envelope.append([Float](repeating: 0.5, count: count)) + envelope.finish()
        #expect(output.count == count)
        #expect(output.allSatisfy { $0.isFinite && (0...0.5).contains($0) })
        if count > 0 { #expect(output.first == 0); #expect(output.last == 0) }
    }

    @Test func streamingHoldsOnlyEightMilliseconds() {
        var envelope = PassageEnvelope()
        let first = envelope.append([Float](repeating: 0.4, count: 19_200))
        #expect(first.count == 19_008)
        let second = envelope.append([Float](repeating: 0.4, count: 19_200))
        #expect(second.count == 19_200)
        #expect(second.allSatisfy { $0 == 0.4 })
        let tail = envelope.finish()
        #expect(tail.count == 192)
        #expect(tail.last == 0)
    }
}

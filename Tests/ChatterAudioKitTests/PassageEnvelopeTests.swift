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
        let expected = Self.shaped(input)
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

    @Test func streamingHoldsOnlyEightMillisecondsWhenSpeechStartsAtOnce() {
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

    // MARK: Cloned-voice room tone

    /// The reported defect: room tone before the first word started abruptly, like a microphone.
    @Test func roomToneBeforeSpeechBecomesSilenceAndSpeechIsUntouched() {
        let passage = Passage(leadIn: 6_000, speech: [.vowel(14_400)], trail: 7_200)
        let output = Self.shaped(passage.samples)
        #expect(output.count == passage.samples.count)
        // At most the 50 ms pre-roll plus one 20 ms analysis window precede the first word.
        #expect(output[..<(passage.speechStart - 1_200 - 480)].allSatisfy { $0 == 0 })
        #expect(passage.speechRange(of: output) == passage.speechRange(of: passage.samples))
        #expect(Self.largestStep(Array(output[..<passage.speechStart])) < 0.002)
    }

    @Test func roomToneAfterSpeechFadesToSilence() {
        let passage = Passage(leadIn: 6_000, speech: [.vowel(14_400)], trail: 7_200)
        let output = Self.shaped(passage.samples)
        // Speech end is found within one analysis window; the fade-out lasts 80 ms.
        #expect(output[(passage.speechEnd + 480 + 1_920)...].allSatisfy { $0 == 0 })
        #expect(Self.largestStep(Array(output[passage.speechEnd...])) < 0.002)
    }

    /// A fricative that barely changes the broadband level still opens the passage: "f", "s", "th".
    @Test func quietFricativeOpeningIsKeptWhole() {
        let passage = Passage(leadIn: 6_000, speech: [.fricative(2_880), .vowel(12_000)], trail: 4_800)
        #expect(Self.level(passage.part(0)) - Self.level(Array(passage.samples[..<6_000])) < 1)
        let output = Self.shaped(passage.samples)
        #expect(passage.speechRange(of: output) == passage.speechRange(of: passage.samples))
        #expect(output[..<(passage.speechStart - 1_200 - 480)].allSatisfy { $0 == 0 })
    }

    /// A faint "s" is only confirmed by the vowel after the 50 ms closure in "st…"; it must stay.
    @Test func stopClosureKeepsTheLeadingFricative() {
        let passage = Passage(leadIn: 6_000, speech: [.fricative(2_400, strength: 0.0012), .roomTone(1_200), .vowel(12_000)], trail: 4_800)
        let output = Self.shaped(passage.samples)
        #expect(passage.speechRange(of: output) == passage.speechRange(of: passage.samples))
    }

    @Test(arguments: [1, 120, 479, 4_800, 19_200])
    func roomToneShapingIsIndependentOfChunking(chunkSize: Int) {
        let passage = Passage(leadIn: 7_000, speech: [.fricative(1_500), .vowel(20_000), .roomTone(2_000), .vowel(9_000)], trail: 8_000)
        #expect(Self.shaped(passage.samples, chunkSize: chunkSize) == Self.shaped(passage.samples))
    }

    @Test func streamingWaitsForSpeechThenRetainsTheEnding() {
        let passage = Passage(leadIn: 6_000, speech: [.vowel(40_000)], trail: 4_800)
        var envelope = PassageEnvelope()
        // Still room tone: nothing can be released yet.
        #expect(envelope.append(Array(passage.samples[..<4_800])).isEmpty)
        // Speech is confirmed in this chunk; all but the 400 ms ending is released.
        #expect(envelope.append(Array(passage.samples[4_800..<19_200])).count == 19_200 - 9_600)
        #expect(envelope.append(Array(passage.samples[19_200...])).count == passage.samples.count - 19_200)
        #expect(envelope.finish().count == 9_600)
    }

    @Test func roomToneWithoutSpeechKeepsOnlyShortEdges() {
        let passage = Passage(leadIn: 48_000, speech: [], trail: 0)
        #expect(Self.shaped(passage.samples) == Self.plainEdges(passage.samples))
    }

    @Test func speechFromTheFirstSampleKeepsOnlyShortEdges() {
        let passage = Passage(leadIn: 0, speech: [.vowel(24_000)], trail: 0)
        #expect(Self.shaped(passage.samples) == Self.plainEdges(passage.samples))
    }

    /// Built-in voices open with digital silence; their speech must pass through unchanged.
    @Test func silentOpeningLeavesSpeechUnchanged() {
        let speech = Passage(leadIn: 0, speech: [.vowel(20_000)], trail: 0).samples
        let samples = [Float](repeating: 0, count: 2_000) + speech + [Float](repeating: 0, count: 3_000)
        let output = Self.shaped(samples)
        #expect(Array(output[2_000..<22_000]) == speech)
        #expect(output[..<2_000].allSatisfy { $0 == 0 })
    }

    /// Randomized layouts: duration, sign and finiteness hold, gain never exceeds one, the ending
    /// reaches zero, and chunking never changes the result.
    @Test(arguments: 0..<32)
    func shapingInvariantsHoldForVariedPassages(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0x5EED)
        var parts: [Passage.Part] = []
        for _ in 0..<random.next(1...4) {
            switch random.next(0...2) {
            case 0: parts.append(.vowel(random.next(2_400...30_000)))
            case 1: parts.append(.fricative(random.next(480...4_800), strength: Double(random.next(5...60)) / 10_000))
            default: parts.append(.roomTone(random.next(240...6_000)))
            }
        }
        let passage = Passage(leadIn: random.next(0...30_000), speech: parts, trail: random.next(0...12_000),
                              roomToneLevel: Float(random.next(2...300)) / 10_000, seed: UInt64(seed))
        let whole = Self.shaped(passage.samples)
        #expect(whole.count == passage.samples.count)
        #expect(zip(whole, passage.samples).allSatisfy { out, input in
            out.isFinite && abs(out) <= abs(input) && (out == 0 || (out > 0) == (input > 0))
        })
        #expect(whole.last == 0)
        #expect(Self.shaped(passage.samples, chunkSize: random.next(1...20_000)) == whole)
    }

    // MARK: Streaming contract

    @Test func appendingNothingChangesNothingInAnyState() {
        let layouts = [Passage(leadIn: 6_000, speech: [.vowel(14_400)], trail: 7_200).samples,   // room-tone opening
                       Passage(leadIn: 0, speech: [.vowel(24_000)], trail: 0).samples]           // loud opening
        for samples in layouts {
            var envelope = PassageEnvelope(), output: [Float] = []
            #expect(envelope.append([]).isEmpty)
            // Fewer than four analysis frames: still undecided.
            output += envelope.append(Array(samples[..<500]))
            #expect(output.isEmpty)
            #expect(envelope.append([]).isEmpty)
            output += envelope.append(Array(samples[500..<20_000]))
            #expect(!output.isEmpty)
            #expect(envelope.append([]).isEmpty)
            output += envelope.append(Array(samples[20_000...]))
            #expect(envelope.append([]).isEmpty)
            output += envelope.finish()
            #expect(envelope.finish().isEmpty)
            #expect(envelope.append([]).isEmpty)
            #expect(output == Self.shaped(samples))
        }
    }

    @Test func finishingWithoutAudioYieldsNothing() {
        var envelope = PassageEnvelope()
        #expect(envelope.finish().isEmpty)
        #expect(envelope.finish().isEmpty)
        #expect(envelope.append([]).isEmpty)
    }

    @Test(arguments: [1, 479, 480, 839, 840, 9_600, 38_399, 38_400, 60_000])
    func digitalSilenceStaysSilent(count: Int) {
        let zeros = [Float](repeating: 0, count: count)
        #expect(Self.shaped(zeros) == zeros)
        #expect(Self.shaped(zeros, chunkSize: 19_200) == zeros)
    }

    /// Streaming never holds more than the 1.6 s look-ahead plus the chunk that completes it.
    @Test func lookAheadReleasesAudioWithTheChunkThatCompletesIt() {
        // No speech: released as plain audio once 1.6 s (two SynthesisJob chunks) has arrived.
        let roomTone = Passage(leadIn: 96_000, speech: [], trail: 0).samples
        var plain = PassageEnvelope()
        let plainCounts = stride(from: 0, to: roomTone.count, by: 19_200).map { plain.append(Array(roomTone[$0..<$0 + 19_200])).count }
        #expect(plainCounts == [0, 38_208, 19_200, 19_200, 19_200])
        #expect(plain.finish().count == 192)
        // Speech confirmed late in the second chunk: everything but the 400 ms ending is released.
        let late = Passage(leadIn: 30_000, speech: [.vowel(40_000)], trail: 6_800).samples
        var shaping = PassageEnvelope()
        let lateCounts = stride(from: 0, to: late.count, by: 19_200).map { shaping.append(Array(late[$0..<min($0 + 19_200, late.count)])).count }
        #expect(lateCounts == [0, 38_400 - 9_600, 19_200, 19_200])
        #expect(shaping.finish().count == 9_600)
    }

    /// Randomized chunk sizes, including empty and one-sample appends: once 1.6 s has arrived at most
    /// 400 ms is held, and the result matches whole-passage shaping.
    @Test(arguments: 0..<24)
    func heldAudioStaysBoundedForAnyChunking(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0xC0FFEE)
        let samples = Self.randomPassage(&random, seed: seed).samples
        var envelope = PassageEnvelope(), output: [Float] = [], offset = 0
        while offset < samples.count {
            let size = random.next(0...3) == 0 ? random.next(0...64) : random.next(1...24_000)
            let end = min(samples.count, offset + size)
            output += envelope.append(Array(samples[offset..<end]))
            offset = end
            let held = offset - output.count
            #expect(held >= 0)
            if offset >= 38_400 { #expect(held <= 9_600, "seed \(seed): \(held) samples held after \(offset)") }
        }
        output += envelope.finish()
        #expect(output == Self.shaped(samples), "seed \(seed)")
    }

    /// Cuts at every decision boundary: four frames, the look-ahead, the held ending and the final edge,
    /// with runs of one-sample appends around them.
    @Test(arguments: ["room tone then speech", "speech in the last look-ahead frame", "speech after the look-ahead",
                      "room tone only", "speech from the first sample", "shorter than the hold", "digital silence"])
    func adversarialChunkBoundariesDoNotChangeTheResult(layout: String) {
        let samples: [Float] = switch layout {
        case "room tone then speech": Passage(leadIn: 7_000, speech: [.fricative(1_500), .vowel(30_000)], trail: 8_000).samples
        case "speech in the last look-ahead frame": Step.signal([.room(38_399), .square(20_000), .room(4_800)])
        case "speech after the look-ahead": Step.signal([.room(38_400), .square(20_000), .room(4_800)])
        case "room tone only": Passage(leadIn: 50_000, speech: [], trail: 0).samples
        case "speech from the first sample": Passage(leadIn: 0, speech: [.vowel(48_000)], trail: 0).samples
        case "shorter than the hold": Step.signal([.room(3_600), .square(3_600), .room(1_200)])
        default: [Float](repeating: 0, count: 45_000)
        }
        let n = samples.count
        let cuts = [1, 2, 479, 480, 481, 38_399, 38_400, 38_401, n - 9_601, n - 9_600, n - 9_599, n - 193, n - 192, n - 191, n - 1]
            + Array(835...845) + Array((n - 9_605)...(n - 9_595)) + Array((n - 200)...(n - 185))
        let expected = Self.shaped(samples)
        #expect(Self.shaped(samples, cuts: cuts) == expected)
        #expect(Self.shaped(samples, chunkSize: 19_200) == expected)
        #expect(Self.isEnveloped(samples, expected))
    }

    // MARK: Exact envelope shape

    /// Frames start every 120 samples and span 480, so the first frame touching speech at 6,000 starts
    /// at 5,640. The fade-in is a 50 ms raised cosine ending there; everything earlier is silence.
    @Test func fadeInIsAFiftyMillisecondRaisedCosineEndingAtTheOnsetFrame() {
        let input = Step.signal([.room(6_000), .square(12_000), .room(4_800)])
        let output = Self.shaped(input)
        #expect(output[..<4_440].allSatisfy { $0 == 0 })
        let fade = (4_440..<5_640).map { input[$0] * Float(0.5 - 0.5 * cos(Double.pi * Double($0 - 4_440) / 1_199)) }
        #expect(Array(output[4_440..<5_640]) == fade)
        #expect(Array(output[5_640..<18_000]) == Array(input[5_640..<18_000]))
    }

    /// The held ending starts at 13,200. Pre-emphasis carries the last speech step into the first
    /// room-tone sample (18,000), so the last speech frame is the one starting there; it ends at 18,480.
    /// An 80 ms raised cosine follows, then silence.
    @Test func fadeOutIsAnEightyMillisecondRaisedCosineAfterTheLastSpeechFrame() {
        let input = Step.signal([.room(6_000), .square(12_000), .room(4_800)])
        let output = Self.shaped(input)
        #expect(Array(output[5_640..<18_480]) == Array(input[5_640..<18_480]))
        let fade = (0..<1_920).map { input[18_480 + $0] * Float(0.5 - 0.5 * cos(Double.pi * Double(1_919 - $0) / 1_919)) }
        #expect(Array(output[18_480..<20_400]) == fade)
        #expect(output[20_400...].allSatisfy { $0 == 0 })
    }

    @Test func speechRunningToTheLastSampleKeepsOnlyTheFinalEdge() {
        let input = Step.signal([.room(6_000), .square(20_000)])
        let output = Self.shaped(input)
        #expect(Array(output[5_640..<25_808]) == Array(input[5_640..<25_808]))
        #expect(Array(output[25_808...]) == Array(Self.plainEdges(input)[25_808...]))
        #expect(output.last == 0)
    }

    /// The whole passage is shorter than the 400 ms ending, so streaming releases it all at the end.
    @Test func passageShorterThanTheHeldEndingIsShapedWhole() {
        let input = Step.signal([.room(3_600), .square(3_600), .room(1_200)])
        var envelope = PassageEnvelope(), released: [Float] = []
        for offset in stride(from: 0, to: input.count, by: 1_000) {
            released += envelope.append(Array(input[offset..<min(offset + 1_000, input.count)]))
        }
        #expect(released.isEmpty)
        let output = envelope.finish()
        #expect(output == Self.shaped(input))
        #expect(output[..<2_040].allSatisfy { $0 == 0 })
        #expect(Array(output[3_240..<7_680]) == Array(input[3_240..<7_680]))
        #expect(Self.isEnveloped(input, output))
        #expect(Self.largestStep(Array(output[7_680...])) < 0.01)
    }

    /// Only the held 400 ms is searched for the end of speech. Room tone before it is kept and the held
    /// audio, all room tone, fades out from its start.
    @Test func roomToneLongerThanTheHeldEndingFadesFromTheHeldAudio() {
        let input = Step.signal([.room(6_000), .square(12_000), .room(14_400)])
        let output = Self.shaped(input)
        let held = input.count - 9_600
        #expect(Array(output[5_640..<held]) == Array(input[5_640..<held]))
        let fade = (0..<1_920).map { input[held + $0] * Float(0.5 - 0.5 * cos(Double.pi * Double(1_919 - $0) / 1_919)) }
        #expect(Array(output[held..<(held + 1_920)]) == fade)
        #expect(output[(held + 1_920)...].allSatisfy { $0 == 0 })
    }

    // MARK: Thresholds

    /// Speech confirmed by the last frame inside the 1.6 s look-ahead (38,399 touches the frame starting
    /// at 37,920) is shaped; speech starting at 38,400 is outside it and only the short edges apply.
    @Test(arguments: [12_000, 38_340, 38_399, 38_400, 38_401, 40_000])
    func lookAheadEndsAtOnePointSixSeconds(speechStart: Int) {
        let input = Step.signal([.room(speechStart), .square(20_000), .room(4_800)])
        let output = Self.shaped(input)
        #expect(Self.shaped(input, chunkSize: 19_200) == output)
        if speechStart < 38_400 {
            let onset = (speechStart - 480) / 120 * 120 + 120
            #expect(output[..<(onset - 1_200)].allSatisfy { $0 == 0 })
            #expect(Array(output[onset..<(speechStart + 20_000)]) == Array(input[onset..<(speechStart + 20_000)]))
        } else {
            #expect(output == Self.plainEdges(input))
        }
    }

    /// Speech arriving inside the opening frames is never attenuated after the first 8 ms, whichever
    /// branch the opening takes. Once the first four frames are room tone it is always shaped.
    @Test(arguments: [0, 1, 100, 191, 192, 300, 500, 700, 839, 840, 1_200, 1_320, 4_800])
    func speechStartingEarlyIsNeverAttenuated(start: Int) {
        let input = Step.signal([.room(start), .square(24_000), .room(4_800)])
        let output = Self.shaped(input)
        let kept = max(start, 192)..<(start + 24_000)
        #expect(Array(output[kept]) == Array(input[kept]))
        if start >= 840 { #expect(output[..<max(0, start - 479 - 1_200)].allSatisfy { $0 == 0 }) }
        #expect(Self.isEnveloped(input, output))
    }

    /// 16 quieter hops are bridged back to an earlier quiet part (a fricative before a stop closure);
    /// 17 are not. A 10 dB part rises in frames overlapping it by 240 samples, not 120, so a gap of
    /// 2,160 samples leaves 16 quieter frames and 2,280 leaves 17.
    @Test(arguments: [2_160, 2_280])
    func quietPartsAreBridgedAcrossAtMostSixteenHops(gap: Int) {
        let quiet = Step.amplitude(rise: 10)
        let input = Step.signal([.room(6_000), .square(2_400, quiet), .room(gap), .square(12_000), .room(4_800)])
        let output = Self.shaped(input)
        let loud = 8_400 + gap
        if gap <= 2_160 {
            #expect(output[..<4_560].allSatisfy { $0 == 0 })
            #expect(Array(output[5_760..<(loud + 12_000)]) == Array(input[5_760..<(loud + 12_000)]))
        } else {
            #expect(output[..<(loud - 360 - 1_200)].allSatisfy { $0 == 0 })
            #expect(Array(output[(loud - 360)..<(loud + 12_000)]) == Array(input[(loud - 360)..<(loud + 12_000)]))
        }
    }

    /// Only a 15 dB rise confirms speech; a 14 dB murmur throughout leaves the room tone alone.
    @Test(arguments: [14.0, 15.3])
    func onlyAFifteenDecibelRiseConfirmsSpeech(rise: Double) {
        let input = Step.signal([.room(6_000), .square(36_000, Step.amplitude(rise: rise)), .room(4_800)])
        let output = Self.shaped(input)
        if rise < 15 {
            #expect(output == Self.plainEdges(input))
        } else {
            #expect(output[..<4_440].allSatisfy { $0 == 0 })
            #expect(Array(output[6_000..<42_000]) == Array(input[6_000..<42_000]))
        }
    }

    /// A decoder click in the first 10 ms (frames 0 and 1, −28 dBFS) must not set the room-tone floor:
    /// the median of the four opening frames stays near the room tone, so the opening is still shaped.
    @Test func aClickInTheOpeningDoesNotHideTheRoomTone() {
        let input = Step.signal([.room(120), .square(120, 0.08), .room(5_760), .square(12_000), .room(4_800)])
        let output = Self.shaped(input)
        #expect(output[..<4_440].allSatisfy { $0 == 0 })
        #expect(Array(output[5_640..<18_000]) == Array(input[5_640..<18_000]))
    }

    /// Room tone louder than −30 dBFS is treated as speech from the first sample.
    @Test(arguments: [-30.6, -29.4])
    func roomToneLouderThanMinusThirtyDecibelsIsKept(level: Double) {
        let noise = Float((3 * pow(10, level / 10)).squareRoot())
        let input = Step.signal([.room(6_000), .square(20_000, 0.5), .room(4_800)], noise: noise)
        let output = Self.shaped(input)
        if level > -30 {
            #expect(output == Self.plainEdges(input))
        } else {
            #expect(output[..<4_440].allSatisfy { $0 == 0 })
            #expect(Array(output[5_640..<26_000]) == Array(input[5_640..<26_000]))
        }
    }

    // MARK: Sample rates

    @Test(arguments: [16_000, 22_050, 44_100, 48_000])
    func roomToneShapingScalesWithSampleRate(rate: Int) {
        let timing = Timing(rate)
        let passage = Passage(leadIn: rate / 4, speech: [.vowel(rate * 6 / 10)], trail: rate * 3 / 10, sampleRate: rate)
        let input = passage.samples, n = input.count
        let output = Self.shaped(input, sampleRate: rate)
        #expect(Self.isEnveloped(input, output))
        #expect(output[..<(passage.speechStart - timing.window + 1 - timing.preRoll)].allSatisfy { $0 == 0 })
        #expect(passage.speechRange(of: output) == passage.speechRange(of: input))
        let silentFrom = max(n - timing.tail, passage.speechEnd + timing.window) + timing.postRoll
        #expect(silentFrom < n)
        #expect(output[silentFrom...].allSatisfy { $0 == 0 })
        #expect(Self.shaped(input, chunkSize: rate * 8 / 10, sampleRate: rate) == output)
        #expect(Self.shaped(input, chunkSize: 997, sampleRate: rate) == output)
        var streaming = PassageEnvelope(sampleRate: rate)
        #expect(streaming.append(input).count == n - timing.tail)
        #expect(streaming.finish().count == timing.tail)
    }

    @Test(arguments: [16_000, 22_050, 44_100, 48_000])
    func shortEdgesScaleWithSampleRate(rate: Int) {
        let timing = Timing(rate)
        let input = Passage(leadIn: 0, speech: [.vowel(rate)], trail: 0, sampleRate: rate).samples
        var streaming = PassageEnvelope(sampleRate: rate)
        let body = streaming.append(input)
        #expect(body.count == rate - timing.edge)
        #expect(body + streaming.finish() == Self.plainEdges(input, edge: timing.edge))
    }

    /// Rates too low for any real use still preserve duration and never amplify.
    @Test(arguments: [1, 2, 3, 7, 100, 1_000])
    func degenerateSampleRatesKeepTheInvariants(rate: Int) {
        var random = SeededRandom(seed: UInt64(rate))
        let input = (0..<2_000).map { _ in Float(random.unit() * 0.4) }
        let output = Self.shaped(input, sampleRate: rate)
        #expect(Self.isEnveloped(input, output))
        #expect(Self.shaped(input, chunkSize: 333, sampleRate: rate) == output)
    }

    // MARK: Property and metamorphic

    /// Arbitrary signals (silence, DC, noise, tones and impulses from subnormal to the Float maximum) at
    /// varied sample rates: the envelope invariants hold, the applied gain only rises then falls,
    /// chunking never matters, and negating the input negates the output exactly.
    @Test(arguments: 0..<40)
    func arbitrarySignalsKeepTheEnvelopeInvariants(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &* 0x9E37 &+ 1)
        let rate = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000][random.next(0...5)]
        let input = Self.arbitrarySignal(&random)
        let output = Self.shaped(input, sampleRate: rate)
        #expect(Self.isEnveloped(input, output), "seed \(seed), rate \(rate), \(input.count) samples")
        #expect(Self.gainRisesThenFalls(input, output), "seed \(seed), rate \(rate)")
        #expect(Self.shaped(input, chunkSize: random.next(1_000...30_000), sampleRate: rate) == output, "seed \(seed)")
        #expect(Self.shaped(input.map { -$0 }, sampleRate: rate) == output.map { -$0 }, "seed \(seed)")
    }

    /// Decisions depend only on levels relative to the opening room tone, so scaling a cloned passage by
    /// a power of two scales the result exactly; and every sample of speech survives bit for bit.
    @Test(arguments: 0..<16)
    func clonedPassagesKeepSpeechAndScaleExactly(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0xAB1E)
        var parts: [Passage.Part] = [.vowel(random.next(2_400...20_000))]
        for _ in 0..<random.next(0...3) {
            parts.append(random.next(0...1) == 0 ? .roomTone(random.next(240...4_800)) : .fricative(random.next(480...4_800)))
            parts.append(.vowel(random.next(2_400...20_000)))
        }
        let passage = Passage(leadIn: random.next(1_000...30_000), speech: parts, trail: random.next(0...12_000),
                              roomToneLevel: Float(random.next(2...150)) / 10_000, seed: UInt64(seed))
        let input = passage.samples, n = input.count
        let output = Self.shaped(input)
        #expect(passage.speechRange(of: output) == passage.speechRange(of: input), "seed \(seed)")
        #expect(output[..<max(0, passage.speechStart - 479 - 1_200)].allSatisfy { $0 == 0 }, "seed \(seed)")
        #expect(output[min(n, max(n - 9_600, passage.speechEnd + 480) + 1_920)...].allSatisfy { $0 == 0 }, "seed \(seed)")
        #expect(Self.gainRisesThenFalls(input, output), "seed \(seed)")
        for scale: Float in [0.25, 0.5, 2] {
            #expect(Self.shaped(input.map { $0 * scale }) == output.map { $0 * scale }, "seed \(seed), scale \(scale)")
        }
    }

    // MARK: Non-functional

    /// A minute of cloned speech is shaped well within real time, whole or in SynthesisJob's chunks,
    /// and as 40 ms chunks (no per-append cost that grows with the passage).
    @Test func aMinuteOfAudioIsShapedQuickly() {
        let unit = Passage(leadIn: 6_000, speech: [.vowel(24_000)], trail: 7_200).samples
        let input = Array(unit[..<30_000]) + Array([[Float]](repeating: Array(unit[6_000..<30_000]), count: 59).joined()) + Array(unit[30_000...])
        #expect(input.count > 1_440_000)
        let clock = ContinuousClock()
        var whole: [Float] = [], chunked: [Float] = [], small: [Float] = []
        let wholeTime = clock.measure { whole = Self.shaped(input) }
        let chunkedTime = clock.measure { chunked = Self.shaped(input, chunkSize: 19_200) }
        let smallTime = clock.measure { small = Self.shaped(input, chunkSize: 960) }
        #expect(chunked == whole && small == whole)
        #expect(wholeTime < .seconds(2), "whole: \(wholeTime)")
        #expect(chunkedTime < .seconds(2), "19,200-sample chunks: \(chunkedTime)")
        #expect(smallTime < .seconds(3), "960-sample chunks: \(smallTime)")
    }

    fileprivate static func arbitrarySignal(_ random: inout SeededRandom) -> [Float] {
        let amplitudes: [Float] = [0, .leastNonzeroMagnitude, 1e-30, 1e-7, 1e-4, 0.003, 0.03, 0.3, 1, 30_000, .greatestFiniteMagnitude]
        var samples: [Float] = []
        let target = random.next(0...60_000)
        while samples.count < target {
            let count = min(target - samples.count, random.next(1...12_000))
            let amplitude = amplitudes[random.next(0...(amplitudes.count - 1))]
            let kind = random.next(0...4), sign: Float = random.next(0...1) == 0 ? 1 : -1
            let frequency = Double(random.next(20...8_000)) / 24_000
            for i in 0..<count {
                switch kind {
                case 0: samples.append(0)
                case 1: samples.append(sign * amplitude)
                case 2: samples.append(amplitude * Float(random.unit()))
                case 3: samples.append(amplitude * Float(sin(2 * .pi * frequency * Double(i))))
                default: samples.append(random.next(0...200) == 0 ? sign * amplitude : 0)
                }
            }
        }
        return samples
    }

    // MARK: Helpers

    static func shaped(_ samples: [Float], chunkSize: Int? = nil, sampleRate: Int = 24_000) -> [Float] {
        var envelope = PassageEnvelope(sampleRate: sampleRate), output: [Float] = []
        let size = max(1, chunkSize ?? samples.count)
        for offset in stride(from: 0, to: samples.count, by: size) {
            output += envelope.append(Array(samples[offset..<min(offset + size, samples.count)]))
        }
        return output + envelope.finish()
    }

    /// Streams `samples` split at each of `cuts` (out-of-range and repeated cuts are ignored).
    static func shaped(_ samples: [Float], cuts: [Int], sampleRate: Int = 24_000) -> [Float] {
        var envelope = PassageEnvelope(sampleRate: sampleRate), output: [Float] = [], start = 0
        for end in Set(cuts.filter { 0 < $0 && $0 < samples.count } + [samples.count]).sorted() {
            output += envelope.append(Array(samples[start..<end]))
            start = end
        }
        return output + envelope.finish()
    }

    /// The gain actually applied (output ÷ input) only rises, then only falls: the envelope never
    /// re-fades inside a passage (for example at a chunk boundary). Tolerates Float rounding.
    static func gainRisesThenFalls(_ input: [Float], _ output: [Float]) -> Bool {
        var falling = false, previous = -Double.infinity
        for (x, y) in zip(input, output) where abs(x) >= 1e-30 {
            let ratio = Double(y) / Double(x)
            if falling {
                if ratio > previous + 1e-5 { return false }
            } else if ratio < previous - 1e-5 {
                falling = true
            }
            previous = ratio
        }
        return true
    }

    /// Duration, finiteness, gain at most one, sign, and silent first and last samples.
    static func isEnveloped(_ input: [Float], _ output: [Float]) -> Bool {
        output.count == input.count
            && zip(output, input).allSatisfy { out, x in out.isFinite && abs(out) <= abs(x) && (out == 0 || (out > 0) == (x > 0)) }
            && (output.isEmpty || (output.first == 0 && output.last == 0))
    }

    /// The varied cloned-voice layouts used by the randomized tests.
    fileprivate static func randomPassage(_ random: inout SeededRandom, seed: Int, sampleRate: Int = 24_000) -> Passage {
        var parts: [Passage.Part] = []
        for _ in 0..<random.next(1...4) {
            switch random.next(0...2) {
            case 0: parts.append(.vowel(random.next(2_400...30_000)))
            case 1: parts.append(.fricative(random.next(480...4_800), strength: Double(random.next(5...60)) / 10_000))
            default: parts.append(.roomTone(random.next(240...6_000)))
            }
        }
        return Passage(leadIn: random.next(0...30_000), speech: parts, trail: random.next(0...12_000),
                       roomToneLevel: Float(random.next(2...300)) / 10_000, seed: UInt64(seed), sampleRate: sampleRate)
    }

    /// The 8 ms raised-cosine edges used when no room-tone opening is found.
    static func plainEdges(_ samples: [Float], edge: Int = 192) -> [Float] {
        func gain(_ d: Int) -> Float { Float(0.5 - 0.5 * cos(Double.pi * Double(min(d, edge - 1)) / Double(edge - 1))) }
        var output = samples
        for i in 0..<min(edge, output.count) { output[i] *= gain(i) }
        for i in max(0, output.count - edge)..<output.count { output[i] *= gain(output.count - 1 - i) }
        return output
    }

    static func level(_ samples: [Float]) -> Double {
        10 * log10(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)) + 1e-14)
    }

    static func largestStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }
}

/// A synthetic passage (24 kHz unless stated): low-frequency room tone throughout (a cloned voice continues its
/// reference recording's), with voiced "vowels" and high-frequency "fricatives" on top.
fileprivate struct Passage {
    enum Part {
        case vowel(Int)
        /// Differenced noise; the default strength sits ~9 dB below the room tone broadband.
        case fricative(Int, strength: Double = 0.0035)
        case roomTone(Int)
    }

    private(set) var samples: [Float] = []
    private(set) var speechStart = 0, speechEnd = 0
    private var parts: [Range<Int>] = []
    private var random: SeededRandom
    private let roomToneLevel: Float
    private let sampleRate: Double

    init(leadIn: Int, speech: [Part], trail: Int, roomToneLevel: Float = 0.0126, seed: UInt64 = 7, sampleRate: Int = 24_000) {
        random = SeededRandom(seed: seed)
        self.roomToneLevel = roomToneLevel
        self.sampleRate = Double(sampleRate)
        appendRoomTone(leadIn)
        for part in speech {
            let start = samples.count
            switch part {
            case .vowel(let count): appendVowel(count)
            case .fricative(let count, let strength): appendFricative(count, strength: strength)
            case .roomTone(let count): appendRoomTone(count)
            }
            parts.append(start..<samples.count)
        }
        speechStart = parts.first?.lowerBound ?? samples.count
        speechEnd = parts.last?.upperBound ?? samples.count
        appendRoomTone(trail)
    }

    func part(_ index: Int) -> [Float] { Array(samples[parts[index]]) }
    func speechRange(of audio: [Float]) -> [Float] { Array(audio[speechStart..<speechEnd]) }

    /// Mains hum with a little hiss.
    private mutating func roomTone() -> Float {
        let t = Double(samples.count) / sampleRate
        return roomToneLevel * Float(0.9 * sin(2 * .pi * 60 * t) + 0.05 * random.unit())
    }

    private mutating func appendRoomTone(_ count: Int) {
        for _ in 0..<count { samples.append(roomTone()) }
    }

    private mutating func appendVowel(_ count: Int) {
        for _ in 0..<count {
            let t = Double(samples.count) / sampleRate
            let voice = (1...8).reduce(0.0) { $0 + sin(2 * .pi * 140 * Double($1) * t) / Double($1) }
            samples.append(Float(0.12 * voice) + roomTone())
        }
    }

    private mutating func appendFricative(_ count: Int, strength: Double) {
        var previous = 0.0
        for _ in 0..<count {
            let noise = random.unit()
            samples.append(Float((noise - previous) * strength) + roomTone())
            previous = noise
        }
    }
}

fileprivate struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func nextBits() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [-1, 1).
    mutating func unit() -> Double { Double(nextBits() >> 11) / Double(1 << 52) - 1 }

    mutating func next(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextBits() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

/// Exact layouts for white-box checks: room tone is white noise (about −55 dBFS by default) and
/// "speech" a square wave switching every 40 samples, so every frame touching it rises sharply.
fileprivate enum Step {
    enum Part {
        case room(Int)
        case square(Int, Float = 0.3)
    }

    static func signal(_ parts: [Part], noise: Float = 0.003, seed: UInt64 = 11) -> [Float] {
        var random = SeededRandom(seed: seed), samples: [Float] = []
        for part in parts {
            let (count, amplitude): (Int, Float) = switch part {
            case .room(let count): (count, 0)
            case .square(let count, let amplitude): (count, amplitude)
            }
            for _ in 0..<count {
                let square = (samples.count / 40) % 2 == 0 ? amplitude : -amplitude
                samples.append(square + noise * Float(random.unit()))
            }
        }
        return samples
    }

    /// The square-wave amplitude whose frames sit `rise` dB above the default room tone.
    static func amplitude(rise: Double) -> Float {
        let roomPower = 0.003 * 0.003 / 3.0
        return Float(((pow(10, rise / 10) - 1) * roomPower).squareRoot())
    }
}

/// The envelope's durations in samples at `rate`, derived as the implementation derives them.
private struct Timing {
    let edge, hop, window, preRoll, postRoll, lookAhead, tail: Int
    init(_ rate: Int) {
        func frames(_ seconds: Double) -> Int { max(1, Int(Double(rate) * seconds)) }
        (edge, hop, window) = (max(2, frames(0.008)), frames(0.005), frames(0.020))
        (preRoll, postRoll, lookAhead, tail) = (frames(0.050), frames(0.080), frames(1.6), frames(0.4))
    }
}

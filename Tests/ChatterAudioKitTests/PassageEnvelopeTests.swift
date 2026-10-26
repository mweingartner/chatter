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

    /// The engine asks whether a streamed passage has spoken before it decides how to recover from a
    /// run-on: repeating a passage that already played would say it twice.
    @Test func heardSpeechFollowsTheOpeningDecision() {
        // Room tone, then speech: undecided until the onset is confirmed, then heard.
        let roomThenSpeech = Passage(leadIn: 6_000, speech: [.vowel(40_000)], trail: 4_800)
        var envelope = PassageEnvelope()
        #expect(!envelope.heardSpeech, "nothing appended")
        _ = envelope.append(Array(roomThenSpeech.samples[..<4_800]))
        #expect(!envelope.heardSpeech, "room tone only, still undecided")
        _ = envelope.append(Array(roomThenSpeech.samples[4_800...]))
        #expect(envelope.heardSpeech)
        _ = envelope.finish()
        #expect(envelope.heardSpeech, "finishing keeps the decision")

        // Speech from the first sample.
        var loud = PassageEnvelope()
        _ = loud.append(Passage(leadIn: 0, speech: [.vowel(24_000)], trail: 0).samples)
        #expect(loud.heardSpeech)

        // A run-on that never speaks: the look-ahead ends with room tone alone.
        var silent = PassageEnvelope()
        _ = silent.append(Passage(leadIn: 48_000, speech: [], trail: 0).samples)
        #expect(!silent.heardSpeech, "1.6 s of room tone is not speech")
        _ = silent.finish()
        #expect(!silent.heardSpeech)

        // Digital silence, as a built-in voice or a looping clone can produce.
        var zeros = PassageEnvelope()
        _ = zeros.append([Float](repeating: 0, count: 48_000))
        #expect(!zeros.heardSpeech)
    }

    /// Metamorphic: `heardSpeech` scans the passage on a fixed hop grid from its first sample, so
    /// every chunking reaches the same answer as one append. It is monotone (once heard, always heard;
    /// never a value it later contradicts), and finishing never changes a decided answer.
    @Test(arguments: 0..<24)
    func heardSpeechIsTheSameForAnyChunking(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0x4EA2D)
        let samples: [Float] = switch seed % 4 {
        case 0: Self.randomPassage(&random, seed: seed).samples
        case 1: Passage(leadIn: random.next(0...60_000), speech: [], trail: 0, roomToneLevel: Float(random.next(2...300)) / 10_000, seed: UInt64(seed)).samples
        case 2: Step.signal([.room(random.next(30_000...46_000)), .square(random.next(1...20_000)), .room(random.next(0...9_000))])
        default: Self.arbitrarySignal(&random)
        }
        var whole = PassageEnvelope()
        _ = whole.append(samples)
        let decidedWhole = whole.heardSpeech
        _ = whole.finish()
        let final = whole.heardSpeech
        #expect(!decidedWhole || final, "seed \(seed): finishing withdrew speech")

        var streaming = PassageEnvelope(), offset = 0, previous = false
        while offset < samples.count {
            let size = random.next(0...3) == 0 ? random.next(0...64) : random.next(1...24_000)
            let end = min(samples.count, offset + size)
            _ = streaming.append(Array(samples[offset..<end]))
            offset = end
            let heard = streaming.heardSpeech
            #expect(!previous || heard, "seed \(seed): heard speech, then not, at \(offset)")
            #expect(!heard || final, "seed \(seed): heard speech the whole passage does not have, at \(offset)")
            previous = heard
        }
        #expect(streaming.heardSpeech == decidedWhole, "seed \(seed): \(samples.count) samples streamed")
        _ = streaming.finish()
        #expect(streaming.heardSpeech == final, "seed \(seed)")
    }

    /// Around the 1.6 s look-ahead boundary (frames start every 120 samples; the last whole frame
    /// inside it starts at 37,920), speech is heard wherever it starts: inside the look-ahead it
    /// decides the opening, after it the room tone keeps being measured, at any chunking. Room tone
    /// alone is never heard. A passage too short to decide (under four 20 ms frames) has heard
    /// nothing, even when loud.
    @Test(arguments: [0, 6_000, 38_399, 38_400, 60_000])
    func heardSpeechIsFoundWhereverItStarts(speechStart: Int) {
        let input = Step.signal([.room(speechStart), .square(20_000), .room(4_800)])
        let roomOnly = Step.signal([.room(speechStart + 24_800)])
        for chunk in [input.count, 19_200, 997, 120] {
            var envelope = PassageEnvelope(), quiet = PassageEnvelope()
            for offset in stride(from: 0, to: input.count, by: chunk) { _ = envelope.append(Array(input[offset..<min(offset + chunk, input.count)])) }
            for offset in stride(from: 0, to: roomOnly.count, by: chunk) { _ = quiet.append(Array(roomOnly[offset..<min(offset + chunk, roomOnly.count)])) }
            #expect(envelope.heardSpeech, "speech at \(speechStart), \(chunk)-sample chunks")
            #expect(!quiet.heardSpeech, "room tone only, \(chunk)-sample chunks")
        }
        for count in [1, 500, 839] {
            var short = PassageEnvelope()
            _ = short.append([Float](repeating: 0.5, count: count))
            #expect(!short.heardSpeech, "\(count) samples: undecided")
            _ = short.finish()
            #expect(!short.heardSpeech, "\(count) samples: too short to decide")
        }
        var decided = PassageEnvelope()
        _ = decided.append([Float](repeating: 0.5, count: 840))
        #expect(decided.heardSpeech, "four frames of a loud opening")
    }

    /// The opening decision scales with the sample rate, and so does `heardSpeech`.
    @Test(arguments: [8_000, 16_000, 22_050, 44_100, 48_000])
    func heardSpeechScalesWithSampleRate(rate: Int) {
        let speech = Passage(leadIn: rate / 4, speech: [.vowel(rate * 6 / 10)], trail: rate * 3 / 10, sampleRate: rate).samples
        let room = Passage(leadIn: rate * 2, speech: [], trail: 0, sampleRate: rate).samples
        var heard = PassageEnvelope(sampleRate: rate), silent = PassageEnvelope(sampleRate: rate)
        _ = heard.append(speech)
        _ = silent.append(room)
        #expect(heard.heardSpeech && !silent.heardSpeech, "\(rate) Hz")
    }

    /// SynthesisJob keeps a streamed run-on (instead of generating it again) when `heardSpeech` is
    /// true, so that nothing is said twice. The opening is decided within the first 1.6 s, but a
    /// passage that opens with longer room tone keeps being measured against it: words that follow
    /// the look-ahead are still heard, so a run-on after them is kept rather than said again.
    @Test func speechAfterTheLookAheadIsHeard() {
        let passage = Passage(leadIn: 40_000, speech: [.vowel(24_000)], trail: 200_000)
        var envelope = PassageEnvelope(), delivered = 0
        for offset in stride(from: 0, to: passage.samples.count, by: 19_200) {
            delivered += envelope.append(Array(passage.samples[offset..<min(offset + 19_200, passage.samples.count)])).count
        }
        #expect(delivered >= passage.speechEnd, "the words have been released for playback")
        #expect(envelope.heardSpeech, "speech after the look-ahead is still heard")
    }

    /// The other half of the same decision: an opening louder than −30 dBFS counts as speech from the
    /// first sample, so a run-on that never says a word in a noisy cloned voice reports speech, and the
    /// job keeps it ("ran on after its words; continuing") instead of generating it again: the
    /// passage's words are never spoken.
    @Test func loudRoomToneAloneIsNotSpeech() {
        let noise = Float((3 * pow(10, -28 / 10.0)).squareRoot())
        let runOn = Step.signal([.room(240_000)], noise: noise)
        var envelope = PassageEnvelope()
        for offset in stride(from: 0, to: runOn.count, by: 19_200) { _ = envelope.append(Array(runOn[offset..<min(offset + 19_200, runOn.count)])) }
        withKnownIssue("a loud opening is taken as speech without any rise above it") {
            #expect(!envelope.heardSpeech, "10 s of −28 dBFS room tone and no words")
        }
    }

    // MARK: Late speech (after a no-speech look-ahead)

    /// Property: after 1.6 s of room tone the opening is plain, so the audio must be exactly the 8 ms
    /// edges (an independent reference) whatever follows and however it is chunked, NaN and infinity
    /// included: the late scan only reads. For finite input `heardSpeech` after any append equals that
    /// of the same prefix appended whole, it switches on exactly when the frame (on the 120-sample
    /// grid) that completes a sustained rise has been appended, and never off.
    @Test(arguments: 0..<16)
    func lateScanNeverChangesTheAudioAndIsChunkInvariant(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed) &+ 0x1A7E)
        let roomLevels: [Float] = [0, 1e-30, 1e-6, 0.003, 0.02]
        var samples = Step.signal([.room(random.next(38_400...50_000))], noise: roomLevels[random.next(0...4)], seed: UInt64(seed))
        samples += Self.arbitrarySignal(&random).prefix(30_000)
        let nonFinite = seed % 6 == 5
        if nonFinite, !samples.isEmpty {
            for _ in 0..<random.next(1...3) { samples[random.next(38_400...(samples.count - 1))] = random.next(0...1) == 0 ? .nan : -.infinity }
        }
        let reference = Self.plainEdges(samples)
        var streaming = PassageEnvelope(), output: [Float] = [], offset = 0, flags: [(Int, Bool)] = []
        while offset < samples.count {
            let size = [1, 119, 121, 479, 960, 997, 19_200, random.next(0...30_000)][random.next(0...7)]
            let end = min(samples.count, offset + size)
            output += streaming.append(Array(samples[offset..<end]))
            offset = end
            flags.append((offset, streaming.heardSpeech))
        }
        output += streaming.finish()
        #expect(Self.bits(output) == Self.bits(reference), "seed \(seed): the late scan changed the audio")
        #expect(Self.bits(Self.shaped(samples)) == Self.bits(reference), "seed \(seed): whole")
        #expect(zip(flags, flags.dropFirst()).allSatisfy { !$0.1 || $1.1 }, "seed \(seed): heard, then not")
        guard !nonFinite else { return }
        // Where the whole-prefix envelope first hears speech: bracketed by the streamed flags, found on
        // the 120-sample grid by a third chunking, then confirmed with whole prefixes on either side.
        func heard(_ n: Int) -> Bool { var e = PassageEnvelope(); _ = e.append(Array(samples[..<n])); return e.heardSpeech }
        guard let first = flags.firstIndex(where: \.1) else {
            #expect(!heard(samples.count), "seed \(seed): the whole passage heard speech that streaming did not")
            return
        }
        // (Before 38,400 samples the opening is undecided, and no late frame can have completed.)
        let before = max(38_400, first > 0 ? flags[first - 1].0 : 0)
        var probe = PassageEnvelope(), onset = before
        _ = probe.append(Array(samples[..<before]))
        while !probe.heardSpeech, onset < flags[first].0 {
            let next = min(flags[first].0, (onset / 120 + 1) * 120)
            _ = probe.append(Array(samples[onset..<next]))
            onset = next
        }
        #expect(probe.heardSpeech, "seed \(seed): heard after \(flags[first].0) samples streamed, but not in 120-sample steps")
        #expect(onset % 120 == 0 && onset >= 38_520, "seed \(seed): heard at \(onset), not when a frame on the grid completed")
        #expect(heard(onset) && !heard(onset - 1), "seed \(seed): whole prefixes disagree about \(onset)")
        for (n, flag) in flags {
            #expect(flag == (n >= onset), "seed \(seed): streamed flag \(flag) after \(n) samples, onset \(onset)")
        }
    }

    /// No blind spot at the look-ahead's edge: a 125 ms word wherever it starts is heard exactly when
    /// the 16th consecutive 20 ms frame touching it is complete (frames start every 120 samples),
    /// inside the 1.6 s or after it, appended whole or ending in one-sample appends. A 1 ms click in
    /// the same places is never heard: a blip in a silence loop is not speech.
    @Test(arguments: [6_000, 37_919, 37_920, 38_039, 38_040, 38_041, 38_279, 38_399, 38_400, 38_401, 38_519, 38_520, 38_521, 45_007, 120_000])
    func aWordIsHeardWhenItsSustainedRiseCompletes(start: Int) {
        var click = PassageEnvelope()
        _ = click.append(Step.signal([.room(start), .square(24), .room(9_600)]))
        #expect(!click.heardSpeech, "click at \(start)")
        let input = Step.signal([.room(start), .square(3_000), .room(9_600)])
        let onset = ((start - 480) / 120 + 1) * 120 + 480 + (PassageEnvelopeTests.heardFrames - 1) * 120
        var streamed = PassageEnvelope()
        for offset in stride(from: 0, to: onset - 3, by: 9_600) { _ = streamed.append(Array(input[offset..<min(onset - 3, offset + 9_600)])) }
        for i in (onset - 3)..<(onset - 1) { _ = streamed.append([input[i]]) }
        #expect(!streamed.heardSpeech, "word at \(start): heard before sample \(onset)")
        _ = streamed.append([input[onset - 1]])
        #expect(streamed.heardSpeech, "word at \(start): not heard at sample \(onset)")
        var whole = PassageEnvelope(), before = PassageEnvelope()
        _ = whole.append(Array(input[..<onset]))
        _ = before.append(Array(input[..<(onset - 1)]))
        #expect(whole.heardSpeech && !before.heardSpeech, "word at \(start), whole prefixes")
    }

    /// The same at other sample rates, where the look-ahead's last frame does not end on it.
    @Test(arguments: [16_000, 22_050, 44_100])
    func lateScanHasNoBlindSpotAtOtherRates(rate: Int) {
        let timing = Timing(rate)
        let lastFrameEnd = (timing.lookAhead - timing.window) / timing.hop * timing.hop + timing.window
        for start in [lastFrameEnd - 1, lastFrameEnd, (lastFrameEnd + timing.lookAhead) / 2, timing.lookAhead - 1, timing.lookAhead, timing.lookAhead + timing.hop + 7] {
            let input = Step.signal([.room(start), .square(rate / 8, 0.6), .room(rate / 2)])
            let onset = max(0, (start - timing.window) / timing.hop + 1) * timing.hop + timing.window + (Self.heardFrames - 1) * timing.hop
            var at = PassageEnvelope(sampleRate: rate), justBefore = PassageEnvelope(sampleRate: rate)
            _ = justBefore.append(Array(input[..<(onset - 1)]))
            _ = at.append(Array(input[..<(onset - 1)]))
            _ = at.append([input[onset - 1]])
            #expect(!justBefore.heardSpeech && at.heardSpeech, "\(rate) Hz, click at \(start): expected at \(onset)")
        }
    }

    /// A quiet fricative ("f", "s") barely rises in broadband level (under 2 dB here): only its
    /// pre-emphasized level marks it, after the look-ahead as within it. A fainter one is heard in
    /// neither place: the rule is the same on both sides of 1.6 s.
    @Test(arguments: [0.0035, 0.002])
    func aQuietFricativeIsHeardAfterTheLookAheadAsWithinIt(strength: Double) {
        for leadIn in [6_000, 45_000] {
            let passage = Passage(leadIn: leadIn, speech: [.fricative(2_880, strength: strength)], trail: 4_800)
            let floor = Self.level(Array(passage.samples[..<960]))
            let rise = stride(from: leadIn - 480, to: leadIn + 2_880, by: 120).map { Self.level(Array(passage.samples[$0..<($0 + 480)])) - floor }.max()!
            #expect(rise < 2, "lead-in \(leadIn): the fricative is not quiet (\(rise) dB)")
            for chunk in [passage.samples.count, 960, 121] {
                var envelope = Self.streamedAfterTheLookAhead(passage.samples, chunk: chunk)
                #expect(envelope.heardSpeech == (strength > 0.003), "strength \(strength), lead-in \(leadIn), \(chunk)-sample chunks")
                _ = envelope.finish()
                #expect(envelope.heardSpeech == (strength > 0.003), "strength \(strength), lead-in \(leadIn), finished")
            }
        }
    }

    /// After the look-ahead too, only a 15 dB rise is speech: a 14 dB murmur is not.
    @Test(arguments: [14.0, 15.3])
    func onlyAFifteenDecibelRiseIsLateSpeech(rise: Double) {
        let input = Step.signal([.room(45_000), .square(9_600, Step.amplitude(rise: rise)), .room(4_800)])
        for chunk in [input.count, 960, 119] {
            let envelope = Self.streamedAfterTheLookAhead(input, chunk: chunk)
            #expect(envelope.heardSpeech == (rise >= 15), "\(rise) dB, \(chunk)-sample chunks")
        }
    }

    /// Pre-emphasis runs across appends: each append's first sample is emphasized against the previous
    /// append's last. A cloned voice with a DC offset shows why it matters: emphasized against zero
    /// instead, the first sample of each append keeps the whole offset, lifting its frame about 0.1 dB,
    /// enough to make a hiss 14.95 dB above the opening heard in 40 ms chunks but not whole. (DC plus a
    /// tone at half the sample rate, with no noise, so the levels are exact.)
    @Test(arguments: [14.95, 15.05])
    func preEmphasisCarriesAcrossAppends(rise: Double) {
        let offset: Float = 0.02, hiss = Float((0.0025 * 0.02 * 0.02 * (pow(10, rise / 10) - 1) / 3.8025).squareRoot())
        let input = [Float](repeating: offset, count: 45_000) + (0..<20_000).map { offset + ($0 % 2 == 0 ? hiss : -hiss) }
        for chunk in [input.count, 960, 997, 121] {
            let envelope = Self.streamedAfterTheLookAhead(input, chunk: chunk)
            #expect(envelope.heardSpeech == (rise >= 15), "\(rise) dB, \(chunk)-sample chunks")
        }
    }

    /// Non-finite samples never reach the envelope from SynthesisJob (`validated` rejects them), but
    /// it stays total: a single infinite or NaN sample after the look-ahead is not sustained speech,
    /// and neither changes the audio from the plain edges.
    @Test(arguments: [Float.infinity, -.infinity, .nan])
    func nonFiniteLateSamplesAreHandled(value: Float) {
        var input = Step.signal([.room(60_000)])
        input[50_000] = value
        for chunk in [input.count, 960, 121] {
            var output: [Float] = []
            var envelope = Self.streamedAfterTheLookAhead(input, chunk: chunk) { output += $0 }
            #expect(!envelope.heardSpeech, "\(value), \(chunk)-sample chunks")
            output += envelope.finish()
            #expect(Self.bits(output) == Self.bits(Self.plainEdges(input)), "\(value), \(chunk)-sample chunks")
        }
    }

    /// A run-on is about 170 s of room tone. The late scan keeps less than one 20 ms frame between
    /// appends and the plain opening holds only its 8 ms edge, so after 160 s in SynthesisJob-sized
    /// 40 ms chunks an append costs what it did just after the look-ahead. (Timed by interleaving the
    /// two envelopes' appends and taking the fastest of each, so parallel tests slow both alike.) Once
    /// speech is heard the scan lets go.
    @Test func aLongRunOnKeepsTheScanBoundedAndLinear() throws {
        var random = SeededRandom(seed: 160)
        let chunk = 960, count = 4_000, clock = ContinuousClock()
        let room = (0..<(chunk * 64)).map { _ in Float(0.003 * random.unit()) }
        func next(_ i: Int) -> [Float] { let offset = (i % 64) * chunk; return Array(room[offset..<(offset + chunk)]) }
        var old = PassageEnvelope(), young = PassageEnvelope(), largestScan = 0, largestPending = 0
        for i in 0..<count {
            _ = old.append(next(i))
            // The opening is decided by the 40th chunk (1.6 s); until then it holds the look-ahead.
            if i >= 40, i % 10 == 0 {
                let state = try Self.state(of: old)
                largestScan = max(largestScan, state.scan); largestPending = max(largestPending, state.pending)
                if largestScan >= 480 || largestPending > 192 { break }   // fail now, not after a quadratic run
            }
        }
        #expect(!old.heardSpeech)
        #expect(largestScan > 0 && largestScan < 480, "scan buffer reached \(largestScan) samples")
        #expect(largestPending == 192, "held \(largestPending) samples")
        for i in 0..<41 { _ = young.append(next(i)) }
        var oldTimes: [Duration] = [], youngTimes: [Duration] = []
        for i in 0..<200 {
            let samples = next(i)
            oldTimes.append(clock.measure { _ = old.append(samples) })
            youngTimes.append(clock.measure { _ = young.append(samples) })
        }
        let early = youngTimes.min()!, late = oldTimes.min()!
        #expect(late < early * 2 + .microseconds(50), "an append after 160 s took \(late), after 1.6 s \(early)")
        _ = old.append(Step.signal([.square(chunk * 3)]))
        #expect(old.heardSpeech, "a word after 160 s of room tone")
        #expect(try Self.state(of: old).scan == 0)
        _ = old.append(next(0))
        #expect(try Self.state(of: old).scan == 0, "the scan stops once speech is heard")
    }

    // MARK: Sustained runs

    /// Property against an independent reference (`referenceHeard`: every frame of the whole passage
    /// summed directly, no running sums, no 1.6 s blocks): after every append `heardSpeech` is true
    /// exactly once the frame that completes 16 consecutive 15 dB frames has arrived. Layouts mix
    /// room-tone, plain and loud openings with bursts mostly too short or too quiet to count and short
    /// gaps that break a run, over up to 8 s (several scan blocks). Appends run from one sample to
    /// several blocks, landing 130 samples before the reference onset and then one sample at a time.
    @Test(arguments: 0..<16)
    func heardSpeechMatchesAnIndependentFrameScan(seed: Int) throws {
        var random = SeededRandom(seed: UInt64(seed) &+ 0x0B5E)
        var samples: [Float] = [], reference: (at: Int?, margin: Double) = (nil, 0)
        for _ in 0..<8 {   // redraw any layout with a frame within rounding of a threshold
            samples = Self.burstyPassage(&random, seed: seed)
            reference = Self.referenceHeard(samples)
            if reference.margin > 1e-3 { break }
        }
        try #require(reference.margin > 1e-3, "seed \(seed): no layout clear of the thresholds")
        var envelope = PassageEnvelope(), offset = 0
        while offset < samples.count {
            // While undecided every append re-measures the look-ahead, so those appends are larger.
            var size = offset < 38_400 ? [960, 4_799, 19_200, 38_400, 100_000][random.next(0...4)]
                : [1, 119, 120, 121, 479, 480, 481, 960, 4_800, 38_040, 38_400, random.next(0...120_000)][random.next(0...11)]
            if let at = reference.at {
                if offset < at - 130, offset + size > at - 130 { size = at - 130 - offset }
                if (at - 130)..<(at + 2) ~= offset { size = 1 }
            }
            let end = min(samples.count, offset + size)
            _ = envelope.append(Array(samples[offset..<end]))
            offset = end
            let expected = reference.at.map { offset >= $0 } ?? false
            guard envelope.heardSpeech == expected else {
                Issue.record("seed \(seed): heardSpeech \(!expected) after \(offset) of \(samples.count) samples, reference onset \(reference.at.map(String.init) ?? "none")")
                return
            }
        }
        _ = envelope.finish()
        #expect(envelope.heardSpeech == (reference.at != nil), "seed \(seed): finished")
    }

    /// The scan measures 1.6 s blocks of 317 frames from wherever its buffer starts: the first sample
    /// for one whole append (seams at the frames starting 38,040, 76,080, 114,120), or where an earlier
    /// append left it (after 50,000 samples, 49,560, so the next append's seam is 87,600). A word whose
    /// 16-frame run has `before` frames ahead of a seam is heard exactly when its 16th frame completes:
    /// not early (a frame counted twice), not late or never (one skipped, or the run reset at the seam).
    @Test(arguments: [0, 1, 2, 8, 14, 15, 16])
    func aRunAcrossAScanBlockSeamIsCountedOnce(before: Int) {
        for (first, seam) in [(nil, 76_080), (nil, 114_120), (50_000, 87_600)] as [(Int?, Int)] {
            let firstFrame = seam - before * 120
            // 361 samples into the frame starting at `firstFrame`, so it touches that frame and not the one before.
            let input = Step.signal([.room(firstFrame + 361), .square(3_000), .room(4_800)])
            let onset = firstFrame + (Self.heardFrames - 1) * 120 + 480
            #expect(Self.referenceHeard(input).at == onset, "\(before) frames before \(seam): the reference disagrees")
            func heard(_ n: Int) -> Bool {
                var envelope = PassageEnvelope()
                if let first {
                    _ = envelope.append(Array(input[..<first]))
                    _ = envelope.append(Array(input[first..<n]))
                } else {
                    _ = envelope.append(Array(input[..<n]))
                }
                return envelope.heardSpeech
            }
            #expect(heard(onset) && !heard(onset - 1), "\(before) frames before the seam at \(seam), first append \(first.map(String.init) ?? "whole"): expected at \(onset)")
        }
    }

    /// Pre-emphasis also runs across the scan's 1.6 s blocks within one append: a block's first sample
    /// is emphasized against the previous block's last. With a DC offset, 15 frames of loud hiss end at
    /// the seam at 76,080 and the frame starting there holds a hiss 14.95 dB above the opening (with
    /// the loud hiss carried into its first sample, still under 15 dB). Emphasized against zero
    /// instead, that sample keeps the whole offset and lifts the frame over 15 dB: a 16th frame that
    /// is not there. (DC plus tones at half the sample rate, with no noise, so the levels are exact.)
    @Test func preEmphasisCarriesAcrossScanBlocks() {
        let offset: Float = 0.03, seam = 76_080
        func hiss(_ rise: Double) -> Float { Float((0.0025 * Double(offset * offset) * (pow(10, rise / 10) - 1) / 3.8025).squareRoot()) }
        let loud = hiss(25), quiet = hiss(14.95)
        let input = (0..<(seam + 4_800)).map { i -> Float in
            let h: Float = (seam - 1_440)..<seam ~= i ? loud : seam..<(seam + 2_400) ~= i ? quiet : 0
            return offset + (i % 2 == 0 ? h : -h)
        }
        let reference = Self.referenceFrames(input), seamFrame = seam / 120
        #expect(Array(reference.passes[(seamFrame - 16)...(seamFrame + 1)]) == [false] + [Bool](repeating: true, count: 15) + [false, false])
        #expect(reference.margins[seamFrame] > 0.01, "the frame on the seam is \(reference.margins[seamFrame]) dB from 15 dB")
        #expect(Self.referenceHeard(input).at == nil)
        var whole = PassageEnvelope()
        _ = whole.append(input)
        #expect(!whole.heardSpeech, "a 16th frame was counted at the seam")
        _ = whole.finish()
        #expect(!whole.heardSpeech)
    }

    /// A sustained rise interrupted by one quiet frame starts counting again: 15 rising frames, one
    /// quiet frame and 15 more is not speech, at any chunking, inside the look-ahead (a room-tone
    /// opening) or after it (plain). One more rising frame at the end is, exactly when it completes.
    @Test(arguments: [6_000, 45_000])
    func oneQuietFrameRestartsTheCount(start: Int) throws {
        // `start` is on the 120-sample grid. The first burst touches the 15 frames from start − 360;
        // the 480-sample gap holds exactly the frame at start + 1,440 (at this room tone, the burst's
        // last step carried into it by pre-emphasis stays well under 15 dB); the second burst touches
        // the 15 (or 16) frames from start + 1,560.
        func input(second: Int) -> [Float] {
            Step.signal([.room(start), .square(1_440), .room(480), .square(second), .room(4_800)], noise: 0.006)
        }
        let broken = input(second: 1_440), completed = input(second: 1_560), base = start / 120
        let run = [Bool](repeating: true, count: 15)
        try #require(Array(Self.referenceFrames(broken).passes[(base - 4)...(base + 28)]) == [false] + run + [false] + run + [false],
                     "the layout does not have the frames it describes")
        #expect(Self.referenceHeard(broken).at == nil)
        let onset = start + 3_360 + 480
        #expect(Self.referenceHeard(completed).at == onset)
        let first = start < 38_400 ? 0 : 38_437
        for chunk in [broken.count, 960, 479, 119] {
            var envelope = Self.streamedAfterTheLookAhead(broken, chunk: chunk, first: first)
            #expect(!envelope.heardSpeech, "15 + 15 frames at \(start), \(chunk)-sample chunks")
            _ = envelope.finish()
            #expect(!envelope.heardSpeech, "15 + 15 frames at \(start), \(chunk)-sample chunks, finished")
            #expect(Self.streamedAfterTheLookAhead(completed, chunk: chunk, first: first).heardSpeech, "16 frames at \(start), \(chunk)-sample chunks")
        }
        // One sample at a time from before the quiet frame to past the onset: every position of an
        // append boundary relative to the quiet frame and to the frame that completes the run.
        for layout in [broken, completed] {
            var envelope = PassageEnvelope(), switchedOn: Int?
            _ = envelope.append(Array(layout[..<(start + 1_300)]))
            for n in (start + 1_300)..<(onset + 240) {
                _ = envelope.append([layout[n]])
                if envelope.heardSpeech, switchedOn == nil { switchedOn = n + 1 }
            }
            #expect(switchedOn == (layout == completed ? onset : nil), "\(start): heard after \(switchedOn.map(String.init) ?? "never")")
        }
    }

    /// The deciding append can end anywhere in a word's sustained run: the frames it has measured are
    /// counted then, and the run carries on into the next append. (The frame starting at 5,640 decides
    /// a room-tone opening when 6,120 samples have arrived; the run completes at 7,920.)
    @Test func theRunCarriesOnFromTheDecidingAppend() {
        let input = Step.signal([.room(6_000), .square(3_000), .room(4_800)])
        #expect(Self.referenceHeard(input).at == 7_920)
        for cut in [6_119, 6_120, 6_121, 6_239, 6_240, 6_600, 7_799, 7_800, 7_801, 7_919, 7_920, 7_921] {
            var envelope = PassageEnvelope()
            _ = envelope.append(Array(input[..<cut]))
            #expect(envelope.heardSpeech == (cut >= 7_920), "decided at \(cut)")
            _ = envelope.append(Array(input[cut..<max(cut, 7_919)]))
            #expect(envelope.heardSpeech == (cut >= 7_920), "\(cut), then up to 7,919")
            _ = envelope.append(Array(input[max(cut, 7_919)...]))
            #expect(envelope.heardSpeech, "\(cut), then the rest")
        }
    }

    /// A quiet fricative of 120 ms or more is still heard (at the default strength from about 80 ms):
    /// in the look-ahead, after it, across a scan block's seam within one append, over other room tone,
    /// in any chunking.
    @Test(arguments: [2_880, 4_800, 12_000])
    func aQuietFricativeOfAHundredAndTwentyMillisecondsIsHeard(length: Int) {
        for (leadIn, seed) in [(6_000, 7), (45_000, 8), (76_080 - length / 2, 9), (114_120 - 1_440, 10)] {
            let passage = Passage(leadIn: leadIn, speech: [.fricative(length)], trail: 4_800, seed: UInt64(seed))
            for chunk in [passage.samples.count, 960, 121] {
                var envelope = Self.streamedAfterTheLookAhead(passage.samples, chunk: chunk, first: leadIn < 38_400 ? 0 : 38_437)
                #expect(envelope.heardSpeech, "\(length)-sample fricative at \(leadIn), \(chunk)-sample chunks")
                _ = envelope.finish()
                #expect(envelope.heardSpeech, "\(length)-sample fricative at \(leadIn), \(chunk)-sample chunks, finished")
            }
        }
    }

    /// A blip touching at most 15 frames is never heard, however loud, at any phase of the 120-sample
    /// grid and on either side of the look-ahead. At full level, where pre-emphasis also lifts the frame
    /// starting on the first sample after it, that is up to 1,320 samples (55 ms): because frames
    /// overlap, a loud burst only 1,321 samples long can touch 16. Nor is a silence loop of such blips
    /// 25 ms apart heard, with exactly one quiet frame between them.
    @Test(arguments: [24, 480, 1_200, 1_320])
    func aLoudBlipIsNeverHeard(length: Int) {
        for base in [6_000, 45_000] {
            for phase in [0, 1, 60, 119] {
                let input = Step.signal([.room(base + phase), .square(length, 0.9), .room(9_600)])
                var envelope = PassageEnvelope()
                _ = envelope.append(input)
                #expect(!envelope.heardSpeech, "\(length)-sample blip at \(base + phase)")
                _ = envelope.finish()
                #expect(!envelope.heardSpeech, "\(length)-sample blip at \(base + phase), finished")
            }
            let loop = Step.signal([.room(base)] + [Step.Part](repeating: .square(length, 0.9), count: 40).flatMap { [$0, .room(600)] })
            var envelope = PassageEnvelope()
            _ = envelope.append(loop)
            #expect(!envelope.heardSpeech, "a loop of \(length)-sample blips from \(base)")
        }
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

    /// Appends the 1.6 s look-ahead and 37 samples more at once (deciding the opening, off the 120-sample
    /// grid), then the rest in `chunk`-sample appends: the late scan sees every chunking, without the
    /// cost of re-deciding an undecided opening on each small append.
    /// (`first: 0` streams in `chunk`-sample appends from the first sample.)
    static func streamedAfterTheLookAhead(_ samples: [Float], chunk: Int, first: Int = 38_437, output: ([Float]) -> Void = { _ in }) -> PassageEnvelope {
        var envelope = PassageEnvelope()
        let first = min(samples.count, first)
        output(envelope.append(Array(samples[..<first])))
        for offset in stride(from: first, to: samples.count, by: chunk) { output(envelope.append(Array(samples[offset..<min(offset + chunk, samples.count)]))) }
        return envelope
    }

    /// A passage that opens with digital silence measures nothing but its own quiet: faint hiss after
    /// it is not speech however far it rises above zero, and a word is, inside the look-ahead or after.
    /// (A run-on that opened that way and looped faint hiss was kept, its words never spoken.)
    @Test(arguments: [2_000, 45_000])
    func faintHissAfterDigitalSilenceIsNotSpeech(zeros: Int) {
        // Down to −56 dBFS: pre-emphasis lifts white hiss about 3 dB, so −52 dBFS hiss reaches the −50 bar.
        for hiss in [-105.0, -85.0, -65.0, -56.0] {
            let amplitude = Float((3 * pow(10, hiss / 10)).squareRoot())
            let input = [Float](repeating: 0, count: zeros) + Step.signal([.room(60_000)], noise: amplitude)
            for chunk in [input.count, 960] {
                var envelope = PassageEnvelope()
                for offset in stride(from: 0, to: input.count, by: chunk) { _ = envelope.append(Array(input[offset..<min(offset + chunk, input.count)])) }
                #expect(!envelope.heardSpeech, "\(hiss) dBFS hiss after \(zeros) zeros, \(chunk)-sample chunks")
            }
        }
        var word = PassageEnvelope()
        _ = word.append([Float](repeating: 0, count: zeros) + Step.signal([.square(3_000)]))
        #expect(word.heardSpeech, "a word after \(zeros) zeros")
    }

    /// `PassageEnvelope.heardFrames`: consecutive frames that make a rise sustained speech.
    static let heardFrames = 16

    /// An independent reference for the speech scan at 24 kHz: every 20 ms frame of the whole passage,
    /// every 120 samples, summed directly (no running sums, no 1.6 s blocks), pre-emphasized as one
    /// stream, against the median of the first four frames. `passes[i]`: frame i is 15 dB above that
    /// floor and at least −50 dBFS, broadband or pre-emphasized. `loud`: the opening is over −30 dBFS
    /// (nil under four frames). `margins[i]`: how near frame i came to either threshold, in dB.
    static func referenceFrames(_ x: [Float]) -> (passes: [Bool], margins: [Double], loud: Bool?, loudMargin: Double) {
        let hop = 120, window = 480
        guard x.count >= window + 3 * hop else { return ([], [], nil, .infinity) }
        var emphasized = x, previous: Float = 0
        for i in emphasized.indices { let current = emphasized[i]; emphasized[i] = current - 0.95 * previous; previous = current }
        func level(_ s: [Float], _ start: Int) -> Double {
            var sum = 0.0
            for i in start..<(start + window) { sum += Double(s[i]) * Double(s[i]) }
            return 10 * log10(sum / Double(window) + 1e-14)
        }
        let starts = Array(stride(from: 0, through: x.count - window, by: hop))
        let broadband = starts.map { level(x, $0) }, emphasis = starts.map { level(emphasized, $0) }
        func median(_ v: ArraySlice<Double>) -> Double { let s = v.sorted(); return (s[1] + s[2]) / 2 }
        let opening = (median(broadband.prefix(4)), median(emphasis.prefix(4)))
        let bars = (max(opening.0 + 15, -50), max(opening.1 + 15, -50))
        let rises = starts.indices.map { (broadband[$0] - bars.0, emphasis[$0] - bars.1) }
        return (rises.map { $0.0 >= 0 || $0.1 >= 0 }, rises.map { min(abs($0.0), abs($0.1)) },
                opening.0 > -30, abs(opening.0 + 30))
    }

    /// The sample count after which `heardSpeech` must first be true (nil: never), from
    /// `referenceFrames`, and the smallest threshold margin among the frames that decide it.
    static func referenceHeard(_ x: [Float]) -> (at: Int?, margin: Double) {
        let frames = referenceFrames(x)
        guard let loud = frames.loud else { return (nil, .infinity) }
        if loud { return (840, frames.loudMargin) }
        var run = 0, margin = frames.loudMargin
        for i in frames.passes.indices {
            margin = min(margin, frames.margins[i])
            run = frames.passes[i] ? run + 1 : 0
            if run >= heardFrames { return (i * 120 + 480, margin) }
        }
        return (nil, margin)
    }

    /// Room tone (over 1.6 s for a plain opening, shorter for a room-tone one, none for a loud one),
    /// then up to 8 s of square bursts 8 to 40 dB above it, mostly too short to be sustained (1 to
    /// 100 ms), apart by nothing to 250 ms: many runs that break, reach 15 frames, or cross a scan
    /// block's seam.
    fileprivate static func burstyPassage(_ random: inout SeededRandom, seed: Int) -> [Float] {
        let noise: Float = [0.001, 0.003, 0.01][random.next(0...2)]
        let leadIn = seed % 8 == 7 ? 0 : seed % 4 == 0 ? random.next(900...30_000) : random.next(38_400...90_000)
        var parts: [Step.Part] = [.room(leadIn)], total = leadIn
        let target = random.next(40_000...200_000)
        while total < target {
            let gap = [0, random.next(1...600), random.next(600...6_000)][random.next(0...2)]
            let rise = [8.0, 14.0, 17.0, 25.0, 40.0][random.next(0...4)]
            let length = random.next(0...5) == 0 ? random.next(2_400...6_000) : random.next(24...2_400)
            parts += [.room(gap), .square(length, Float(((pow(10, rise / 10) - 1) * Double(noise * noise) / 3).squareRoot()))]
            total += gap + length
        }
        return Step.signal(parts, noise: noise, seed: UInt64(seed))
    }

    /// Bit patterns, so NaN outputs compare equal to the same NaN.
    static func bits(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }

    /// White-box: the envelope's private buffer sizes, read by reflection (fails if they are renamed).
    static func state(of envelope: PassageEnvelope) throws -> (scan: Int, pending: Int) {
        let children = Dictionary(Mirror(reflecting: envelope).children.compactMap { child in child.label.map { ($0, child.value) } }) { first, _ in first }
        let scan = try #require(children["scan"] as? [Float], "PassageEnvelope.scan not found")
        let pending = try #require(children["pending"] as? [Float], "PassageEnvelope.pending not found")
        return (scan.count, pending.count)
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

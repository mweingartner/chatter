import Accelerate
import ChatterAudioKit
import Foundation
import Testing

/// `PassageEnvelope.trimmingEdgeSilence` keeps 50 ms of silence before a whole passage's first sound
/// and 100 ms after its last, where sound is a frame 6 dB above the opening room tone and within 40 dB
/// of the loudest frame, and the first and last sound belong to a sustained run (95 ms) or lie within
/// 250 ms of one. It never removes sound.
struct EdgeSilenceTests {
    static let rate = 24_000
    static let lead = 1_200, trail = 2_400   // 50 ms, 100 ms
    static let hop = 120, window = 480

    /// Uniform noise with the given RMS level (dBFS); deterministic.
    static func noise(_ count: Int, dB: Double, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        let amplitude = Float((3 * pow(10, dB / 10)).squareRoot())
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / 16_777_216 * 2 - 1) * amplitude
        }
    }

    /// A vowel-like tone at the given RMS level (dBFS).
    static func tone(_ count: Int, dB: Double, frequency: Double = 180) -> [Float] {
        let amplitude = pow(10, dB / 20) * 2.squareRoot()
        return (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / Double(rate))) }
    }

    static func trimmed(_ samples: [Float]) -> [Float] { PassageEnvelope().trimmingEdgeSilence(samples) }

    /// Where the output must start when the first sound begins at `soundStart`: 50 ms before the first
    /// 20 ms frame (on the 5 ms grid) measured as sound, which touches `soundStart` at the earliest and
    /// starts at it at the latest.
    static func expectedStart(_ soundStart: Int) -> ClosedRange<Int> {
        let earliest = soundStart >= window ? ((soundStart - window) / hop + 1) * hop : 0
        let latest = (soundStart + hop - 1) / hop * hop
        return max(0, earliest - lead)...max(0, latest - lead)
    }

    /// Where the output must end when the last sound ends at `soundEnd`: 100 ms past the last frame
    /// measured as sound, which covers at least the sound's final 20 ms and, through pre-emphasis,
    /// may start on the sample right after it.
    static func expectedEnd(_ soundEnd: Int) -> ClosedRange<Int> {
        let lastFrameEnd = soundEnd / hop * hop + window
        return (lastFrameEnd - window + trail)...(lastFrameEnd + trail)
    }

    /// The slice `output` was taken from, if it is one, compared bit for bit (so NaN matches itself).
    static func slice(_ output: [Float], of input: [Float]) -> Range<Int>? {
        guard !output.isEmpty, output.count <= input.count else { return nil }
        let m = output.count
        return input.withUnsafeBufferPointer { haystack in
            output.withUnsafeBufferPointer { needle in
                // Three anchors first, so long runs of digital silence do not make every start a full comparison.
                let (first, middle, last) = (needle[0].bitPattern, needle[m / 2].bitPattern, needle[m - 1].bitPattern)
                for start in 0...(haystack.count - m) {
                    guard haystack[start].bitPattern == first, haystack[start + m - 1].bitPattern == last,
                          haystack[start + m / 2].bitPattern == middle else { continue }
                    if memcmp(haystack.baseAddress! + start, needle.baseAddress!, m * MemoryLayout<Float>.size) == 0 { return start..<(start + m) }
                }
                return nil
            }
        }
    }

    /// JARVIS: seconds of near-digital silence before and after the sentence, each with a faint blip
    /// that would hold the silence in place if any sound frame counted.
    @Test func longSilencesAroundASentenceAreTrimmed() {
        let before = Self.noise(48_000, dB: -110) + Self.tone(720, dB: -50) + Self.noise(24_000, dB: -110, seed: 2)
        let sentence = Self.tone(24_000, dB: -18)
        let after = Self.noise(30_000, dB: -90, seed: 3) + Self.tone(720, dB: -50) + Self.noise(30_000, dB: -90, seed: 4)
        let samples = before + sentence + after
        let output = Self.trimmed(samples)
        let range = Self.slice(output, of: samples)
        #expect(range.map { Self.expectedStart(before.count).contains($0.lowerBound) } == true, "kept \(String(describing: range))")
        #expect(range.map { Self.expectedEnd(before.count + sentence.count).contains($0.upperBound) } == true, "kept \(String(describing: range))")
    }

    /// Scar: room tone at −38 dB before and after the speech is within 40 dB of it, but not 6 dB above
    /// the opening, so it is silence.
    @Test func roomToneAroundASentenceIsTrimmed() {
        let samples = Self.noise(9_600, dB: -38) + Self.tone(24_000, dB: -12) + Self.noise(24_000, dB: -38, seed: 5)
        let range = Self.slice(Self.trimmed(samples), of: samples)
        #expect(range.map { Self.expectedStart(9_600).contains($0.lowerBound) && Self.expectedEnd(33_600).contains($0.upperBound) } == true,
                "kept \(String(describing: range))")
    }

    /// A passage that opens with speech has nothing before its first sound to trim, and no room tone
    /// to measure: the 40 dB range alone decides its ending.
    @Test func aLoudOpeningUsesTheRangeAlone() {
        let samples = Self.tone(24_000, dB: -10) + Self.noise(48_000, dB: -70, seed: 6)
        let output = Self.trimmed(samples)
        #expect(output == Array(samples.prefix(output.count)), "starts at the first sample")
        #expect(Self.expectedEnd(24_000).contains(output.count), "kept \(output.count) samples")
        let loudTail = Self.tone(24_000, dB: -10) + Self.noise(48_000, dB: -40, seed: 7)
        #expect(Self.trimmed(loudTail) == loudTail, "a tail 30 dB below a loud opening is sound")
    }

    /// The pause between two words of a passage is never touched, and a quieter last word is sound.
    @Test func aQuietLastWordAfterAPauseIsKept() {
        let samples = Self.noise(4_800, dB: -60) + Self.tone(12_000, dB: -10) + Self.noise(36_000, dB: -60, seed: 8)
            + Self.tone(4_800, dB: -36) + Self.noise(48_000, dB: -60, seed: 9)
        let range = Self.slice(Self.trimmed(samples), of: samples)
        #expect(range.map { Self.expectedStart(4_800).contains($0.lowerBound) && Self.expectedEnd(57_600).contains($0.upperBound) } == true,
                "kept \(String(describing: range))")
    }

    /// A short burst within 250 ms of a word belongs to it: the release of a final "t" after its
    /// closure, a breath before the first word. Further away, it is a blip and is trimmed.
    @Test(arguments: [(2_400, true), (5_400, true), (7_200, false)])
    func burstsNearAWordBelongToIt(gap: Int, attached: Bool) {
        let room = Self.noise(24_000, dB: -55)
        let burst = Self.tone(600, dB: -20, frequency: 2_000)
        let word = Self.tone(24_000, dB: -12)
        let after = room + word + Self.noise(gap, dB: -55, seed: 10) + burst + Self.noise(24_000, dB: -55, seed: 11)
        let afterRange = Self.slice(Self.trimmed(after), of: after)
        let wordEnd = 48_000, burstEnd = wordEnd + gap + burst.count
        #expect(afterRange.map { Self.expectedEnd(attached ? burstEnd : wordEnd).contains($0.upperBound) } == true,
                "burst \(gap) samples after the word: kept \(String(describing: afterRange))")
        let before = room + burst + Self.noise(gap, dB: -55, seed: 12) + word + Self.noise(24_000, dB: -55, seed: 13)
        let beforeRange = Self.slice(Self.trimmed(before), of: before)
        #expect(beforeRange.map { Self.expectedStart(attached ? 24_000 : 24_000 + burst.count + gap).contains($0.lowerBound) } == true,
                "burst \(gap) samples before the word: kept \(String(describing: beforeRange))")
    }

    /// A final "s": hiss that barely rises broadband above a hum but clearly does once pre-emphasized.
    @Test func aFinalFricativeIsKept() {
        let hum = Self.tone(4_800, dB: -45, frequency: 60)
        var fricative = Self.noise(3_600, dB: -48, seed: 14)
        for i in fricative.indices.reversed() where i > 0 { fricative[i] -= fricative[i - 1] }   // differenced: high frequencies
        let samples = hum + Self.tone(12_000, dB: -12) + fricative + Self.tone(48_000, dB: -45, frequency: 60)
        let range = Self.slice(Self.trimmed(samples), of: samples)
        #expect(range.map { Self.expectedEnd(4_800 + 12_000 + 3_600).contains($0.upperBound) } == true, "kept \(String(describing: range))")
    }

    @Test func passagesWithLittleSilenceAreUnchanged() {
        let tight = Self.noise(1_000, dB: -50) + Self.tone(24_000, dB: -12) + Self.noise(2_000, dB: -50, seed: 15)
        #expect(Self.trimmed(tight) == tight, "under 50 ms before and 100 ms after")
    }

    /// Nothing to measure, or nothing sustained, leaves the passage whole.
    @Test func passagesWithoutSustainedSoundAreUnchanged() {
        let blips = Self.noise(24_000, dB: -60) + Self.tone(1_200, dB: -12) + Self.noise(24_000, dB: -60, seed: 16)
        for samples in [[Float](), [0.5, -0.5], [Float](repeating: 0.2, count: 839), [Float](repeating: 0, count: 48_000),
                        Self.noise(48_000, dB: -50), blips] {
            #expect(Self.trimmed(samples) == samples, "\(samples.count) samples")
        }
    }

    /// The envelope still shapes a trimmed passage: the 50 ms kept before the first sound is room tone,
    /// so it measures its floor there and fades in from silence; the passage ends at zero.
    @Test func aTrimmedPassageIsStillShaped() {
        let samples = Self.noise(9_600, dB: -40) + Self.tone(24_000, dB: -12) + Self.noise(24_000, dB: -40, seed: 17)
        var envelope = PassageEnvelope()
        let trimmed = envelope.trimmingEdgeSilence(samples)
        let output = envelope.append(trimmed) + envelope.finish()
        #expect(output.count == trimmed.count && trimmed.count < samples.count)
        #expect(output.first == 0 && output.last == 0)
        #expect(envelope.heardSpeech, "the opening was decided as room tone, then speech")
    }

    /// Seeded fuzz over passages of room tone, words and pauses at random levels: the result is one
    /// contiguous slice of the input that holds every word whole, with at most 50 ms (plus one frame)
    /// before the first and 100 ms (plus one frame) after the last. Trimming again measures the room
    /// tone from other samples, so a borderline edge frame may move by one 5 ms hop, never more.
    @Test(arguments: 0..<24)
    func trimmingKeepsEveryWordAndLittleElse(seed: Int) {
        var state = UInt64(seed) &+ 0x7A11
        func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
        let roomLevel = Double(next(-110 ... -40))
        var samples = Self.noise(next(1_000...48_000), dB: roomLevel, seed: UInt64(seed))
        let firstWord = samples.count
        var lastWordEnd = 0
        for word in 0..<next(1...4) {
            if word > 0 { samples += Self.noise(next(0...30_000), dB: roomLevel, seed: UInt64(seed * 31 + word)) }
            // Words 100 ms or longer, 10 to 30 dB above the room tone.
            samples += Self.tone(next(2_400...20_000), dB: min(-6, roomLevel + Double(next(10...30))))
            lastWordEnd = samples.count
        }
        samples += Self.noise(next(0...120_000), dB: roomLevel + Double(next(-20...3)), seed: UInt64(seed) &+ 99)
        let output = Self.trimmed(samples)
        guard let range = Self.slice(output, of: samples) else { Issue.record("seed \(seed): not a slice"); return }
        #expect(range.lowerBound <= firstWord && range.upperBound >= lastWordEnd, "seed \(seed): \(range) cut a word (\(firstWord)..<\(lastWordEnd))")
        #expect(firstWord - range.lowerBound <= Self.lead + Self.window, "seed \(seed): kept \(firstWord - range.lowerBound) before the first word")
        #expect(range.upperBound - lastWordEnd <= Self.trail + Self.window, "seed \(seed): kept \(range.upperBound - lastWordEnd) after the last word")
        let again = Self.slice(Self.trimmed(output), of: output)
        #expect(again.map { $0.lowerBound <= Self.hop && output.count - $0.upperBound <= Self.hop } == true,
                "seed \(seed): trimming twice kept \(String(describing: again)) of \(output.count)")
    }

    // MARK: Exact frame grid

    // With `Grid`'s room tone (−55.2 dB, −52.4 dB pre-emphasized) and 0.3 squares (−10.5 dB), the bars
    // are −49.2 dB broadband and −46.4 dB pre-emphasized: every frame touching a square sample, or the
    // pre-emphasized sample just after one, is sound, and no frame of room tone is. A square of `L`
    // samples starting on the 120-sample grid at `b` is sound in frames `(b − 360) / 120` through
    // `(b + L) / 120`, which is `L / 120 + 4` frames.

    /// A rise touching 15 frames (55 ms) is a blip, whatever its level; 16 frames (60 ms) is sustained.
    /// The kept range is then exact: from 50 ms before the first sound frame (frame 197, at 23,640) to
    /// 100 ms past the end of the last (frame 212, at 25,440 + 480).
    @Test(arguments: [(1_320, false), (1_440, true)])
    func sixteenFramesAreSustainedAndFifteenAreNot(length: Int, sustained: Bool) {
        let samples = Grid.signal([.room(24_000), .square(length), .room(24_000)])
        let output = Self.trimmed(samples)
        if sustained {
            #expect(Self.slice(output, of: samples) == 22_440..<28_320)
        } else {
            #expect(output == samples, "a \(length)-sample rise holds nothing in place")
        }
    }

    /// The reach is 50 frames past the last sustained frame (frame 300, the pre-emphasized sample after
    /// a word ending at 36,000), so frame 350, from 42,000 to 42,479, is the last that attaches a burst.
    /// An attached burst is kept whole: the end is 100 ms past the last frame touching it (with its
    /// pre-emphasized trailing sample), though only its first sample is in reach.
    @Test(arguments: [(42_479, true), (42_480, false)])
    func aBurstAttachesAfterTheWordUpToFiftyFrames(burstStart: Int, attached: Bool) {
        let samples = Grid.signal([.room(24_000), .square(12_000), .room(burstStart - 36_000), .square(240), .room(24_000)])
        let range = Self.slice(Self.trimmed(samples), of: samples)
        let lastTouching = (burstStart + 240) / 120
        #expect(range?.upperBound == (attached ? lastTouching * 120 + 480 + 2_400 : 36_000 + 2_880), "burst at \(burstStart): kept \(String(describing: range))")
        if attached { #expect(range.map { $0.upperBound >= burstStart + 240 + 1 } == true, "the burst is whole") }
    }

    /// Before a word starting at 30,000, the first sustained frame is 247 (from 29,640), so the reach
    /// begins at frame 197 (23,640). A burst whose pre-emphasized trailing sample falls there attaches
    /// and is kept whole: the start is 50 ms before the first frame touching it, so the 50 ms kept is
    /// room tone.
    @Test(arguments: [(23_640, true), (23_639, false)])
    func aBurstAttachesBeforeTheWordFromFiftyFrames(burstEnd: Int, attached: Bool) {
        let samples = Grid.signal([.room(burstEnd - 240), .square(240), .room(30_000 - burstEnd), .square(12_000), .room(24_000)])
        let range = Self.slice(Self.trimmed(samples), of: samples)
        let firstTouching = (burstEnd - 240 - 480) / 120 + 1
        let expected = (attached ? firstTouching * 120 : 29_640) - 1_200
        #expect(range?.lowerBound == expected, "burst ending at \(burstEnd): kept \(String(describing: range))")
        if attached { #expect(range.map { $0.lowerBound <= burstEnd - 240 } == true, "the burst is whole") }
    }

    /// Sustained sound in the first or the last frame keeps that edge, including the samples past the
    /// last whole frame (here 77 that no frame measures).
    @Test func sustainedSoundAtEitherEdgeKeepsThatEdge() {
        let opensWithSpeech = Grid.signal([.square(12_000), .room(24_000)])
        #expect(Self.slice(Self.trimmed(opensWithSpeech), of: opensWithSpeech) == 0..<(12_000 + 2_880))
        let endsWithSpeech = Grid.signal([.room(24_000), .square(12_077)])
        #expect(Self.slice(Self.trimmed(endsWithSpeech), of: endsWithSpeech) == (23_640 - 1_200)..<endsWithSpeech.count)
        let both = Grid.signal([.square(12_000), .room(30_000), .square(12_077)])
        #expect(Self.trimmed(both) == both, "the pause between is never trimmed")
        // A burst in the first frames, within 250 ms of the word, holds the start at sample 0.
        let burstFirst = Grid.signal([.square(240), .room(4_800), .square(12_000), .room(24_000)])
        #expect(Self.slice(Self.trimmed(burstFirst), of: burstFirst)?.lowerBound == 0)
    }

    /// No frame extends past either end, so a rise at the very edge is measured by fewer frames than the
    /// same rise inside the passage: a square of `L` samples is sound in `L / 120 + 1` frames from
    /// sample 0 and in `L / 120` frames running to the last sample, against `L / 120 + 4` inside. A
    /// 70 ms rise at the start, or a 75 ms rise at the end, far from the words is a blip and is trimmed;
    /// 75 ms at the start, 80 ms at the end, or 55 ms inside, is sustained and kept.
    @Test func aRiseAtTheVeryEdgeNeedsMoreFramesToBeSustained() {
        let opening = { (length: Int) in Grid.signal([.square(length), .room(24_000), .square(12_000), .room(24_000)]) }
        #expect(Self.slice(Self.trimmed(opening(1_680)), of: opening(1_680))?.lowerBound == 1_680 + 24_000 - 360 - 1_200)
        #expect(Self.slice(Self.trimmed(opening(1_800)), of: opening(1_800))?.lowerBound == 0)
        let ending = { (length: Int, after: Int) in Grid.signal([.square(12_000), .room(24_000), .square(length), .room(after)]) }
        #expect(Self.slice(Self.trimmed(ending(1_800, 0)), of: ending(1_800, 0)) == 0..<(12_000 + 2_880))
        #expect(Self.trimmed(ending(1_920, 0)) == ending(1_920, 0))
        #expect(Self.slice(Self.trimmed(ending(1_800, 4_800)), of: ending(1_800, 4_800)) == 0..<(36_000 + 1_800 + 2_880))
        #expect(Self.slice(Self.trimmed(ending(1_320, 4_800)), of: ending(1_320, 4_800)) == 0..<(12_000 + 2_880), "55 ms inside is a blip")
    }

    /// A 15-frame burst straddling the start of the 250 ms reach (frames 183 to 197, of which only 197
    /// is in reach) is kept whole: the start moves back to the burst's first frame, so the 50 ms kept
    /// before it is room tone and the envelope still measures its floor there and shapes the opening.
    @Test func aBurstStraddlingTheReachIsKeptWholeAndTheFloorIsRoomTone() throws {
        let samples = Grid.signal([.room(22_320), .square(1_320), .room(30_000 - 23_640), .square(12_000), .room(24_000)])
        let output = Self.trimmed(samples)
        let range = try #require(Self.slice(output, of: samples))
        var whole = PassageEnvelope(), part = PassageEnvelope()
        _ = whole.append(samples) + whole.finish()
        _ = part.append(output) + part.finish()
        #expect(Self.opening(of: whole)?.kind == "roomTone")
        #expect(range.lowerBound <= 22_320, "kept \(range)")
        #expect(Self.opening(of: part)?.kind == "roomTone", "the envelope measured \(String(describing: Self.opening(of: part)?.floors))")
    }

    /// Known issue: the envelope confirms speech 15 dB above the room tone and reaches back over gaps of
    /// at most 80 ms, so a first word 6 to 15 dB above it, before a louder word within the 1.6 s
    /// look-ahead, is faded out as room tone. Untrimmed, a lead longer than the look-ahead hid the
    /// louder word, so the envelope kept only its 8 ms edges and the first word played; trimmed to
    /// 50 ms, the louder word is in view and the first word is silenced. (With a short lead the
    /// untrimmed passage loses the word the same way: the envelope's rule, now reached by long leads.)
    @Test func aQuietFirstWordAfterALongLeadIsKept() throws {
        let samples = Self.noise(48_000, dB: -50) + Self.tone(9_600, dB: -38) + Self.noise(14_400, dB: -50, seed: 2)
            + Self.tone(12_000, dB: -20) + Self.noise(12_000, dB: -50, seed: 3)
        let word = 48_000..<57_600
        let untrimmed = PassageEnvelopeTests.shaped(samples)
        #expect(Array(untrimmed[word]) == Array(samples[word]), "untrimmed, the first word plays")
        let output = Self.trimmed(samples)
        let range = try #require(Self.slice(output, of: samples))
        #expect(range.lowerBound <= word.lowerBound && range.upperBound >= 81_600 + 2_400, "the trim keeps both words: \(range)")
        let shaped = PassageEnvelopeTests.shaped(output)
        withKnownIssue("the envelope fades in before the first word 15 dB above the room tone") {
            #expect(Array(shaped[(word.lowerBound - range.lowerBound)..<(word.upperBound - range.lowerBound)]) == Array(samples[word]))
        }
    }

    /// Every edge is on the 5 ms grid and holds exactly 50 ms before the first sound frame and 100 ms
    /// after the last, wherever the word falls between grid points.
    @Test(arguments: [24_000, 24_001, 24_059, 24_060, 24_119])
    func theKeptSilenceIsExactOffTheGrid(wordStart: Int) {
        let samples = Grid.signal([.room(wordStart), .square(12_000), .room(24_000)])
        let range = Self.slice(Self.trimmed(samples), of: samples)
        let wordEnd = wordStart + 12_000
        #expect(range?.lowerBound == Self.firstFrame(touching: wordStart) - 1_200, "word at \(wordStart): kept \(String(describing: range))")
        // The last sound frame holds the pre-emphasized sample at `wordEnd`.
        #expect(range?.upperBound == wordEnd / 120 * 120 + 2_880, "word at \(wordStart): kept \(String(describing: range))")
    }

    // MARK: Inputs at the limits

    /// Fewer than four frames (840 samples) cannot be measured; a sustained run needs 16 frames, so a
    /// shorter rise, or one with nothing around it, is returned whole.
    @Test(arguments: [0, 1, 479, 480, 839, 840, 841, 2_279, 2_280])
    func shortPassagesAreReturnedWhole(count: Int) {
        let loud = Grid.signal([.square(count)])
        #expect(Self.trimmed(loud) == loud)
        let quiet = Grid.signal([.room(count)])
        #expect(Self.trimmed(quiet) == quiet)
    }

    /// About the shortest passage that is trimmed at all: 50 ms of room tone before a 16-frame rise,
    /// whose last frame ends 2,880 samples before the end; only the one sample past those is removed.
    @Test func theShortestTrimmablePassage() {
        let samples = Grid.signal([.room(1_560), .square(1_440), .room(2_881)])
        #expect(Self.slice(Self.trimmed(samples), of: samples) == 0..<(3_000 + 2_880))
    }

    /// Non-finite samples never reach here (`SynthesisJob.validated` rejects them), but the trim stays
    /// total: wherever one falls it returns a contiguous slice of the input and never traps. The same
    /// holds for the largest finite magnitude, whose square still fits a Double.
    @Test(arguments: [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.leastNonzeroMagnitude])
    func extremeSamplesNeverTrap(value: Float) {
        let base = Grid.signal([.room(9_600), .square(24_000), .room(24_000)])
        for position in [0, 9_000, 20_000, base.count - 1] {
            var samples = base
            samples[position] = value
            let output = Self.trimmed(samples)
            #expect(Self.slice(output, of: samples) != nil, "\(value) at \(position): not a slice")
        }
        for count in [840, 4_800] {
            let uniform = [Float](repeating: value, count: count)
            #expect(Self.bits(Self.trimmed(uniform)) == Self.bits(uniform), "\(count) samples of \(value)")
        }
    }

    /// The durations follow the sample rate. Degenerate rates (one-sample frames) never trap; from
    /// 8 kHz the word is kept whole with at most 50 ms plus a frame before it and 100 ms plus a frame
    /// after it.
    @Test(arguments: [1, 2, 3, 7, 100, 1_000, 8_000, 16_000, 22_050, 44_100, 48_000])
    func trimmingScalesWithSampleRate(rate: Int) {
        func frames(_ seconds: Double) -> Int { max(1, Int(Double(rate) * seconds)) }
        let room = Self.noise(rate, dB: -55), word = Self.noise(rate, dB: -12, seed: 2), after = Self.noise(2 * rate, dB: -55, seed: 3)
        let samples = room + word + after
        let output = PassageEnvelope(sampleRate: rate).trimmingEdgeSilence(samples)
        guard let range = Self.slice(output, of: samples) else { Issue.record("rate \(rate): not a slice"); return }
        guard rate >= 8_000 else { return }
        let (window, lead, trail) = (frames(0.020), frames(0.05), frames(0.10))
        #expect(range.lowerBound <= rate && range.upperBound >= 2 * rate, "rate \(rate): kept \(range) of a word at \(rate)..<\(2 * rate)")
        #expect(rate - range.lowerBound <= lead + window && range.upperBound - 2 * rate <= trail + window, "rate \(rate): kept \(range)")
        #expect(range.lowerBound > 0 && range.upperBound < samples.count, "rate \(rate): trimmed both edges")
    }

    // MARK: Properties against an independent reading

    /// A frame-by-frame reference (each frame summed on its own, its own run and reach logic) predicts
    /// the kept range exactly whenever no frame sits within 0.01 dB of a bar, for arbitrary signals: bursts, decays,
    /// digital silence, levels from denormal to far above full scale. Where a frame is that close, every
    /// sustained run and every sound within reach of one that the reference finds by a clear margin
    /// is kept. Negating the input negates the output exactly, and digital silence appended after an
    /// edge that was trimmed changes nothing.
    @Test(arguments: 0..<40)
    func trimmingMatchesAnIndependentFrameReading(seed: Int) {
        var random = EdgeRandom(seed: UInt64(seed) &* 0x51_7CC1 &+ 3)
        let samples = Self.arbitraryPassage(&random)
        let output = Self.trimmed(samples)
        guard let range = Self.slice(output, of: samples) ?? (output.isEmpty && samples.isEmpty ? 0..<0 : nil) else {
            Issue.record("seed \(seed): not a slice"); return
        }
        let reference = Self.reference(samples)
        if reference.margin > 0.01 {
            #expect(range == reference.kept, "seed \(seed): kept \(range), the reference \(reference.kept) (\(samples.count) samples)")
        }
        for required in reference.required {
            #expect(range.lowerBound <= required.lowerBound && required.upperBound <= range.upperBound,
                    "seed \(seed): \(required) is sound that must stay, but kept \(range)")
        }
        #expect(Self.bits(Self.trimmed(samples.map { -$0 })) == Self.bits(output.map { -$0 }), "seed \(seed): negation")
        // Frames past the last whole frame would measure the final samples, so the relation starts from
        // a passage that already ends in more than a frame of digital silence.
        let ended = samples + [Float](repeating: 0, count: 600), endedOutput = Self.trimmed(ended)
        if let endedRange = Self.slice(endedOutput, of: ended), endedRange.upperBound < ended.count - 7_000 {
            let padded = ended + [Float](repeating: 0, count: random.next(1...30_000))
            #expect(Self.trimmed(padded) == endedOutput, "seed \(seed): appended silence changed the result")
        }
    }

    /// At least most of the arbitrary passages are decided clearly, so the exact check above is real.
    @Test func mostArbitraryPassagesAreDecidedClearly() {
        let clear = (0..<40).filter { seed in
            var random = EdgeRandom(seed: UInt64(seed) &* 0x51_7CC1 &+ 3)
            return Self.reference(Self.arbitraryPassage(&random)).margin > 0.01
        }
        #expect(clear.count >= 30, "only \(clear.count) of 40 passages had every frame 0.01 dB clear of a bar")
    }

    /// Realistic words: a soft attack, an exponential decay into the room tone, sometimes a breath
    /// before. Everything 12 dB or more above the room tone survives, and trimming
    /// again moves each edge by at most one 5 ms hop.
    @Test(arguments: 0..<16)
    func decayingWordsSurviveAndRetrimmingIsStable(seed: Int) {
        var random = EdgeRandom(seed: UInt64(seed) &+ 0xDECA)
        let roomLevel = Double(random.next(-90 ... -40))
        var samples = Self.noise(random.next(2_400...36_000), dB: roomLevel, seed: random.nextBits())
        var loud: [Range<Int>] = []
        for word in 0..<random.next(1...3) {
            if word > 0 { samples += Self.noise(random.next(0...20_000), dB: roomLevel, seed: random.nextBits()) }
            let level = min(-6, roomLevel + Double(random.next(20...40)))
            if random.next(0...1) == 0 {   // a breath 20 dB below the word, up to 200 ms before it
                samples += Self.noise(random.next(1_200...3_600), dB: level - 20, seed: random.nextBits())
                samples += Self.noise(random.next(0...4_800), dB: roomLevel, seed: random.nextBits())
            }
            let shaped = Self.word(attack: random.next(120...720), body: random.next(2_400...14_400),
                                   decay: Double(random.next(240...1_440)), dB: level, frequency: Double(random.next(110...320)))
            let room = Self.noise(shaped.count, dB: roomLevel, seed: random.nextBits())
            let start = samples.count
            samples += zip(shaped, room).map { $0 + $1 }
            // The word holds while its amplitude is 12 dB or more above the room tone.
            let floor = Float(pow(10, (roomLevel + 12) / 20))
            if let first = shaped.firstIndex(where: { abs($0) >= floor }), let last = shaped.lastIndex(where: { abs($0) >= floor }) {
                loud.append((start + first)..<(start + last + 1))
            }
        }
        samples += Self.noise(random.next(0...30_000), dB: roomLevel, seed: random.nextBits())
        let output = Self.trimmed(samples)
        guard let range = Self.slice(output, of: samples), let first = loud.first, let last = loud.last else {
            Issue.record("seed \(seed): not a slice"); return
        }
        #expect(range.lowerBound <= first.lowerBound && last.upperBound <= range.upperBound, "seed \(seed): kept \(range), words \(loud)")
        let again = Self.slice(Self.trimmed(output), of: output)
        #expect(again.map { $0.lowerBound <= Self.hop && output.count - $0.upperBound <= Self.hop } == true,
                "seed \(seed): trimming twice kept \(String(describing: again)) of \(output.count)")
    }

    // MARK: The envelope after a trim

    /// For room-tone, digital-silence, hiss-after-silence, loud-click and over-long openings: the
    /// trimmed passage is still shaped from silence. The envelope decides on room tone, measured from
    /// the kept 50 ms rather than from a word; every word passes at unity; the first 8 ms rise no faster
    /// than the shortest raised cosine (no onset click, 3.1.1); the passage ends in silence. Where the
    /// untrimmed passage was shaped from room tone too (room-tone and digital-silence openings), the
    /// trimmed one is shaped exactly as that slice of it was, from the first sample to the last word.
    /// Where it was not (a loud click, or room tone longer than the 1.6 s look-ahead), the trim lets the
    /// envelope silence the room tone it previously played.
    @Test(arguments: 0..<25)
    func theEnvelopeShapesATrimmedPassageFromSilence(seed: Int) throws {
        var random = EdgeRandom(seed: UInt64(seed) &+ 0xE1DE)
        let opening = ["room tone", "digital silence", "hiss after silence", "a loud click", "long room tone"][seed % 5]
        let roomLevel = Double(opening == "a loud click" ? random.next(-95 ... -60) : random.next(-95 ... -36))
        let hissLevel = Double(random.next(-100 ... -75))
        func grid(_ range: ClosedRange<Int>) -> Int { random.next(range) * 120 }
        func room(_ count: Int) -> [Float] {
            switch opening {
            case "digital silence": [Float](repeating: 0, count: count)
            case "hiss after silence": Self.noise(count, dB: hissLevel, seed: random.nextBits())
            default: Self.noise(count, dB: roomLevel, seed: random.nextBits())
            }
        }
        var samples: [Float]
        switch opening {
        case "hiss after silence": samples = [Float](repeating: 0, count: grid(0...150)) + room(grid(10...150))
        case "a loud click":
            let click = grid(4...10)
            samples = Self.tone(click, dB: Double(random.next(-20 ... -10)), frequency: 2_000) + room(grid(80...250) - click)
        case "long room tone": samples = room(grid(334...500))
        default: samples = room(grid(10...300))
        }
        // Every word at least 18 dB above the room tone, so the envelope confirms on the first (see
        // aQuietFirstWordAfterALongLeadIsKept for one it cannot).
        let base = opening == "room tone" || opening == "long room tone" ? min(-3, roomLevel + Double(random.next(28...40)))
            : opening == "a loud click" ? Double(random.next(-12 ... -6)) : Double(random.next(-30 ... -6))
        var words: [Range<Int>] = []
        for word in 0..<random.next(1...3) {
            if word > 0 { samples += room(grid(0...150)) }
            let start = samples.count
            samples += Self.tone(grid(20...160), dB: base - Double(random.next(0...10)), frequency: Double(random.next(120...400)))
            words.append(start..<samples.count)
        }
        samples += room(grid(0...200))

        let trimmed = Self.trimmed(samples)
        let r = try #require(Self.slice(trimmed, of: samples), "seed \(seed): not a slice")
        var whole = PassageEnvelope(), part = PassageEnvelope()
        let untrimmedShape = whole.append(samples) + whole.finish()
        let shape = part.append(trimmed) + part.finish()
        let before = try #require(Self.opening(of: whole)), after = try #require(Self.opening(of: part))
        let context = "seed \(seed), \(opening): kept \(r) of \(samples.count), words \(words), decided \(before.kind) then \(after.kind)"

        #expect(PassageEnvelopeTests.isEnveloped(trimmed, shape), "\(context)")
        #expect(PassageEnvelopeTests.gainRisesThenFalls(trimmed, shape), "\(context)")
        // Every word at unity, up to the final 8 ms edge every passage ends with.
        for word in words {
            let end = min(word.upperBound, r.upperBound - 192)
            #expect(Array(shape[(word.lowerBound - r.lowerBound)..<(end - r.lowerBound)]) == Array(samples[word.lowerBound..<end]), "\(context): \(word)")
        }
        for i in 0..<min(192, shape.count) {
            let rise = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / 191))
            if abs(shape[i]) > abs(trimmed[i]) * rise * (1 + 1e-6) { Issue.record("\(context): sample \(i) rose too fast"); break }
        }
        // Room tone, not a word, sets the floor, and everything before the fade-in is silence.
        #expect(after.kind == "roomTone", "\(context)")
        let firstWord = words[0].lowerBound - r.lowerBound
        #expect(shape[..<max(0, firstWord - 1_200 - 480)].allSatisfy { $0 == 0 }, "\(context)")
        let keptOpening = Double(opening == "digital silence" ? -140 : opening == "hiss after silence" ? hissLevel : roomLevel)
        #expect(after.floors.map { $0.broadband <= keptOpening + 1.5 } == true, "\(context): floors \(String(describing: after.floors))")
        // The ending fades within 100 ms of the last word's final frame.
        let lastWordEnd = words[words.count - 1].upperBound - r.lowerBound
        #expect(shape[min(shape.count, lastWordEnd + 2_400)...].allSatisfy { $0 == 0 }, "\(context)")

        switch opening {
        case "room tone", "digital silence":
            #expect(before.kind == "roomTone", "\(context)")
            #expect(Array(shape[..<lastWordEnd]) == Array(untrimmedShape[r.lowerBound..<(r.lowerBound + lastWordEnd)]), "\(context)")
            if let a = after.floors, let b = before.floors {
                #expect(abs(a.broadband - b.broadband) < 1 && abs(a.emphasized - b.emphasized) < 1, "\(context): \(a) against \(b)")
            }
        case "a loud click":
            #expect(before.kind == "plain" && before.speech == true, "\(context): the click made the opening loud")
        case "long room tone":
            #expect(before.kind == "plain" && before.speech == false, "\(context): no speech within the look-ahead")
            #expect(untrimmedShape[r.lowerBound..<(r.lowerBound + 240)].contains { $0 != 0 }, "\(context): the room tone played")
        default: break
        }
    }

    // MARK: Non-functional

    /// A passage trims in linear time: 30 s, fastest of three runs, takes under 30 times a tenth of it
    /// plus 50 ms (linear is about 10 times), with a 10 s ceiling, so a slow runner slows both alike.
    @Test func longPassagesTrimInLinearTime() {
        func passage(_ seconds: Int) -> [Float] {
            Self.noise(7_200, dB: -60) + Self.tone(24_000, dB: -12) + Self.noise(seconds * 24_000 - 60_000, dB: -60, seed: 2)
                + Self.tone(24_000, dB: -12) + Self.noise(4_800, dB: -60, seed: 3)
        }
        let long = passage(30), tenth = passage(3)
        // 50 ms before the first frame touching the first word (6,840); 100 ms past the last frame
        // touching the second (which ends at 715,200, on a zero crossing, so no pre-emphasized frame).
        #expect(Self.slice(Self.trimmed(long), of: long) == 5_640..<717_960, "the long pause between the words stays; only the edges go")
        let clock = ContinuousClock()
        func fastest(_ samples: [Float]) -> Duration { (0..<3).map { _ in clock.measure { _ = Self.trimmed(samples) } }.min()! }
        let big = fastest(long), small = fastest(tenth)
        #expect(big < small * 30 + .milliseconds(50), "30 s took \(big), 3 s \(small)")
        #expect(big < .seconds(10), "30 s took \(big)")
    }

    // MARK: Helpers

    static func bits(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }

    /// The start of the first frame on the 120-sample grid that touches sample `index`.
    static func firstFrame(touching index: Int) -> Int { index < window ? 0 : (index - window) / hop * hop + hop }

    /// A tone rising over `attack` samples, held for `body`, then decaying with time constant `decay`
    /// samples until it is 80 dB down.
    static func word(attack: Int, body: Int, decay: Double, dB: Double, frequency: Double) -> [Float] {
        let tail = Int(decay * log(10_000)), amplitude = pow(10, dB / 20) * 2.squareRoot()
        return (0..<(attack + body + tail)).map { i in
            let gain = i < attack ? Double(i) / Double(attack) : i < attack + body ? 1 : exp(-Double(i - attack - body) / decay)
            return Float(amplitude * gain * sin(2 * .pi * frequency * Double(i) / Double(rate)))
        }
    }

    /// Arbitrary passages: digital silence, noise, tones, decays and isolated bursts at levels from
    /// denormal to 30 dB above full scale, up to about 2.5 s.
    fileprivate static func arbitraryPassage(_ random: inout EdgeRandom) -> [Float] {
        let levels = [-300.0, -140, -110, -90, -70, -60, -50, -40, -30, -20, -12, -6, 0, 30]
        var samples: [Float] = []
        for _ in 0..<random.next(1...8) {
            let count = [random.next(1...600), random.next(600...2_400), random.next(2_400...24_000)][random.next(0...2)]
            let dB = levels[random.next(0...(levels.count - 1))] + Double(random.next(0...9))
            switch random.next(0...4) {
            case 0: samples += [Float](repeating: 0, count: count)
            case 1: samples += Self.noise(count, dB: dB, seed: random.nextBits())
            case 2: samples += Self.tone(count, dB: dB, frequency: Double(random.next(60...6_000)))
            case 3: samples += Self.word(attack: random.next(1...600), body: count, decay: Double(random.next(60...2_400)), dB: dB, frequency: Double(random.next(100...500)))
            default:
                var burst = [Float](repeating: 0, count: count)
                for i in stride(from: random.next(0...max(0, count - 1)), to: count, by: random.next(200...4_000)) { burst[i] = Float(pow(10, dB / 20)) }
                samples += burst
            }
        }
        return samples
    }

    /// The rule read frame by frame, each frame summed on its own: what must be kept and, when every
    /// decision is clear, exactly what is. `margin` is how close (dB) the nearest frame, or the
    /// opening's −30 dB test, came to deciding the other way. `required` lists the sample spans of every frame of a
    /// sustained run, and of every sound frame within 50 frames of one, that clears its bar by 0.01 dB.
    static func reference(_ x: [Float]) -> (kept: Range<Int>, margin: Double, required: [Range<Int>]) {
        let window = 480, hop = 120, n = x.count
        guard n >= window + 3 * hop else { return (0..<n, .infinity, []) }
        var emphasized = x
        for i in stride(from: n - 1, to: 0, by: -1) { emphasized[i] = x[i] - 0.95 * x[i - 1] }
        // Each frame summed on its own (vDSP, in Float: within 0.001 dB of the implementation's running
        // Double sums for these signals), not from running sums.
        func levels(_ s: [Float]) -> [Double] {
            s.withUnsafeBufferPointer { buffer in
                stride(from: 0, through: n - window, by: hop).map { start in
                    var power: Float = 0
                    vDSP_svesq(buffer.baseAddress! + start, 1, &power, vDSP_Length(window))
                    return 10 * log10(Double(power) / Double(window) + 1e-14)
                }
            }
        }
        let broadband = levels(x), emph = levels(emphasized), starts = broadband.indices
        func median(_ v: [Double]) -> Double { let s = v.prefix(4).sorted(); return (s[1] + s[2]) / 2 }
        let floors = (median(broadband), median(emph)), loudest = broadband.max()!
        let roomTone = floors.0 <= -30
        let bars = (max(roomTone ? floors.0 + 6 : -.infinity, loudest - 40), max(roomTone ? floors.1 + 6 : -.infinity, loudest - 40))
        let margins = starts.indices.map { max(broadband[$0] - bars.0, emph[$0] - bars.1) }
        var margin = abs(floors.0 + 30)
        for m in margins where !m.isNaN { margin = min(margin, abs(m)) }
        func runs(_ sound: [Bool]) -> [Range<Int>] {
            var result: [Range<Int>] = [], begin: Int?
            for f in 0...sound.count {
                if f < sound.count && sound[f] { begin = begin ?? f } else if let b = begin { if f - b >= 16 { result.append(b..<f) }; begin = nil }
            }
            return result
        }
        func span(_ f: Int) -> Range<Int> { (f * hop)..<(f * hop + window) }
        // Every frame that clears its bar by 0.01 dB, sustained or within reach of a sustained run, stays.
        let clear = margins.map { $0 >= 0.01 }, clearRuns = runs(clear)
        var required: [Range<Int>] = []
        for run in clearRuns {
            required += run.map(span)
            required += ((run.lowerBound - 50)..<run.lowerBound).filter { $0 >= 0 && clear[$0] }.map(span)
            required += (run.upperBound..<(run.upperBound + 50)).filter { $0 < clear.count && clear[$0] }.map(span)
        }
        let sound = margins.map { $0 >= 0 }, soundRuns = runs(sound)
        guard let first = soundRuns.first, let last = soundRuns.last else { return (0..<n, margin, required) }
        var firstSound = first.lowerBound, lastSound = last.upperBound - 1
        for f in stride(from: first.lowerBound - 1, through: max(0, first.lowerBound - 50), by: -1) where sound[f] { firstSound = f }
        for f in last.upperBound..<min(sound.count, last.upperBound + 50) where sound[f] { lastSound = f }
        return (max(0, firstSound * hop - 1_200)..<min(n, lastSound * hop + window + 2_400), margin, required)
    }

    /// White-box: how the envelope decided its opening, read by reflection (fails if it is renamed).
    static func opening(of envelope: PassageEnvelope) -> (kind: String, speech: Bool?, floors: (broadband: Double, emphasized: Double)?)? {
        guard let opening = Mirror(reflecting: envelope).children.first(where: { $0.label == "opening" })?.value else { return nil }
        guard let decided = Mirror(reflecting: opening).children.first, let kind = decided.label else { return ("\(opening)", nil, nil) }
        let fields = Dictionary(Mirror(reflecting: decided.value).children.compactMap { child in child.label.map { ($0, child.value) } }) { first, _ in first }
        let floors = fields["floors"].flatMap { value -> (broadband: Double, emphasized: Double)? in
            let mirror = Mirror(reflecting: value)
            let unwrapped: Any? = mirror.displayStyle == .optional ? mirror.children.first?.value : value
            let parts = unwrapped.map { Mirror(reflecting: $0).children.compactMap { $0.value as? Double } } ?? []
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        return (kind, fields["speech"] as? Bool, floors)
    }
}

/// Exact layouts on the 120-sample frame grid: room tone is uniform noise of amplitude 0.003
/// (−55.2 dB), a square is ±0.3 (−10.5 dB) switching every 40 samples of the whole passage.
fileprivate enum Grid {
    enum Part {
        case room(Int)
        case square(Int)
    }

    static func signal(_ parts: [Part]) -> [Float] {
        var random = EdgeRandom(seed: 11), samples: [Float] = []
        for part in parts {
            let (count, amplitude): (Int, Float) = switch part {
            case .room(let count): (count, 0)
            case .square(let count): (count, 0.3)
            }
            for _ in 0..<count {
                let square = (samples.count / 40) % 2 == 0 ? amplitude : -amplitude
                samples.append(square + 0.003 * Float(random.unit()))
            }
        }
        return samples
    }
}

fileprivate struct EdgeRandom {
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



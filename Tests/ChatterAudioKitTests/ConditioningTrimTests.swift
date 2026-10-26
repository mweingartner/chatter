import Foundation
import Testing
@testable import ChatterAudioKit

/// `trimmedForConditioning` trims a take's edges like the import trim, but a burst shorter than 60 ms
/// (a click, a blip of noise) never counts as speech, so it cannot hold a long silent tail in place.
struct ConditioningTrimTests {
    static let rate = Int(TestSignals.rate)

    /// One second of "speech" (a tone) with `before` and `after` around it.
    static func take(_ before: [Float], _ after: [Float]) -> [Float] {
        before + TestSignals.tone(1, amplitude: 0.5, frequency: 220) + after
    }

    static func blip(_ seconds: Double) -> [Float] { TestSignals.tone(seconds, amplitude: 0.3, frequency: 1000) }

    @Test func withoutBurstsItKeepsTheImportTrim() {
        let signal = Self.take(TestSignals.zeros(1), TestSignals.zeros(1))
        let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: Self.rate)
        #expect(bounds == (44100 - 4410)..<(88200 + 4410))
        #expect(bounds == ReferencePreparation.speechBounds(signal, rms: RecordingHealth.inspect(signal).rms))
    }

    /// JARVIS's reference ended in 1.7 s of near-silence with two faint blips, which kept all of it.
    @Test func clicksInATrailingSilenceAreTrimmedWithIt() {
        let tail = TestSignals.zeros(0.7) + Self.blip(0.02) + TestSignals.zeros(0.5) + Self.blip(0.05) + TestSignals.zeros(0.4)
        let signal = Self.take(TestSignals.zeros(0.5), tail)
        let speechEnd = TestSignals.count(1.5)
        #expect(ReferencePreparation.conditioningBounds(signal, sampleRate: Self.rate) == (TestSignals.count(0.5) - 4410)..<(speechEnd + 4410))
        // The import trim keeps everything up to the last blip.
        #expect(ReferencePreparation.speechBounds(signal, rms: RecordingHealth.inspect(signal).rms).upperBound > speechEnd + TestSignals.count(1))
    }

    @Test func clicksBeforeTheFirstWordAreTrimmedToo() {
        let lead = TestSignals.zeros(0.3) + Self.blip(0.03) + TestSignals.zeros(0.9)
        let signal = Self.take(lead, TestSignals.zeros(0.2))
        let speechStart = TestSignals.count(1.23)
        #expect(ReferencePreparation.conditioningBounds(signal, sampleRate: Self.rate).lowerBound == speechStart - 4410)
    }

    /// A short word (60 ms or more) is speech, wherever it is.
    @Test func burstsOfSixtyMillisecondsCountAsSpeech() {
        let signal = Self.take(TestSignals.zeros(0.5), TestSignals.zeros(0.8) + Self.blip(0.08) + TestSignals.zeros(0.6))
        let wordEnd = TestSignals.count(0.5 + 1 + 0.8 + 0.08)
        let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: Self.rate)
        #expect(abs(bounds.upperBound - (wordEnd + 4410)) <= 441, "ends 100 ms after the last word, to the frame")
    }

    @Test func aTakeWithNothingLongEnoughIsKeptWhole() {
        let blips = TestSignals.zeros(0.4) + Self.blip(0.04) + TestSignals.zeros(0.4) + Self.blip(0.03) + TestSignals.zeros(0.4)
        #expect(ReferencePreparation.trimmedForConditioning(blips, sampleRate: Self.rate) == blips)
        let silence = TestSignals.zeros(2)
        #expect(ReferencePreparation.trimmedForConditioning(silence, sampleRate: Self.rate) == silence)
        #expect(ReferencePreparation.trimmedForConditioning([], sampleRate: Self.rate).isEmpty)
        let tiny: [Float] = [0.5, -0.5, 0.25]
        #expect(ReferencePreparation.trimmedForConditioning(tiny, sampleRate: Self.rate) == tiny, "shorter than one frame")
    }

    /// The engine conditions at 24 kHz: the same take trims to the same times at either rate.
    @Test func trimmingFollowsTheSampleRate() {
        func signal(rate: Double) -> [Float] {
            func n(_ seconds: Double) -> Int { Int(seconds * rate) }
            let tone = (0..<n(1)).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
            let blip = (0..<n(0.02)).map { Float(0.3 * sin(2 * Double.pi * 1000 * Double($0) / rate)) }
            return [Float](repeating: 0, count: n(0.5)) + tone + [Float](repeating: 0, count: n(0.6)) + blip + [Float](repeating: 0, count: n(0.5))
        }
        for rate in [24_000, 44_100, 48_000] {
            let bounds = ReferencePreparation.conditioningBounds(signal(rate: Double(rate)), sampleRate: rate)
            let seconds = (Double(bounds.lowerBound) / Double(rate), Double(bounds.upperBound) / Double(rate))
            #expect(abs(seconds.0 - 0.4) <= 0.011 && abs(seconds.1 - 1.6) <= 0.011, "\(rate) Hz kept \(seconds)")
        }
    }

    /// Seeded fuzz: speech framed by random silences, noise floors and clicks. Every sample of the
    /// speech is kept, at most 100 ms (plus one frame) of anything else remains on either side, and the
    /// result is a contiguous slice of the take.
    @Test func speechIsNeverTrimmedAndEdgesNeverStayLong() {
        var generator = SplitMix(state: 0x7A11)
        for trial in 0..<200 {
            func silence() -> [Float] {
                var out: [Float] = []
                for _ in 0..<Int.random(in: 0...3, using: &generator) {
                    out += TestSignals.noise(Double.random(in: 0.05...0.6, using: &generator), amplitude: Double.random(in: 0...0.002, using: &generator), seed: generator.next())
                    // A click of up to 35 ms touches at most five 10 ms frames, wherever it falls.
                    if Bool.random(using: &generator) { out += Self.blip(Double.random(in: 0.005...0.035, using: &generator)) }
                }
                // At least 30 ms of silence, so no click touches the speech and joins its burst.
                return out + TestSignals.zeros(Double.random(in: 0.03...0.3, using: &generator))
            }
            let before = silence(), after = silence()
            let speech = TestSignals.tone(Double.random(in: 0.2...3, using: &generator), amplitude: Double.random(in: 0.1...0.8, using: &generator), frequency: 180)
            let signal = before + speech + after
            let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: Self.rate)
            let speechRange = before.count..<(before.count + speech.count)
            #expect(bounds.lowerBound <= speechRange.lowerBound && bounds.upperBound >= speechRange.upperBound, "trial \(trial): speech \(speechRange) cut to \(bounds)")
            #expect(speechRange.lowerBound - bounds.lowerBound <= 4410 + 441, "trial \(trial): \(speechRange.lowerBound - bounds.lowerBound) samples kept before")
            #expect(bounds.upperBound - speechRange.upperBound <= 4410 + 441, "trial \(trial): \(bounds.upperBound - speechRange.upperBound) samples kept after")
            #expect(ReferencePreparation.trimmedForConditioning(signal, sampleRate: Self.rate) == Array(signal[bounds]))
        }
    }

    // MARK: Edges and frame alignment

    /// Speech that touches the first or the last sample is never cut, and the 100 ms margins clamp to
    /// the take instead of running past it. A trailing partial frame (here 7 samples at 24 kHz) is
    /// never measured, but the margin always covers it.
    @Test func runsTouchingTheEdgesClampToTheTake() {
        let rate = 24_000, frame = 240, margin = 2_400
        let loud = Self.square(frames: 100, frame: frame)
        #expect(ReferencePreparation.conditioningBounds(loud, sampleRate: rate) == loud.indices, "all speech")
        let fromStart = loud + [Float](repeating: 0, count: 200 * frame)
        #expect(ReferencePreparation.conditioningBounds(fromStart, sampleRate: rate) == 0..<(100 * frame + margin))
        let toEnd = [Float](repeating: 0, count: 200 * frame) + loud + [Float](repeating: 0, count: 7)
        #expect(ReferencePreparation.conditioningBounds(toEnd, sampleRate: rate) == (200 * frame - margin)..<toEnd.count)
        // Speech that runs into the partial frame: the partial samples stay.
        let intoPartial = [Float](repeating: 0, count: 200 * frame) + Self.square(frames: 100, frame: frame) + Array(Self.square(frames: 1, frame: frame)[..<7])
        #expect(ReferencePreparation.conditioningBounds(intoPartial, sampleRate: rate).upperBound == intoPartial.count)
    }

    /// The shortest speech is exactly six frame-aligned 10 ms frames: five are a blip, six are a word.
    @Test(arguments: [24_000, 44_100, 48_000])
    func sixFramesAreTheShortestSpeech(rate: Int) {
        let frame = rate / 100, margin = rate / 10
        let silence = [Float](repeating: 0, count: 80 * frame)
        let word = Self.square(frames: 50, frame: frame)
        for frames in 1...8 {
            let signal = silence + word + silence + Self.square(frames: frames, frame: frame) + silence
            let wordEnd = 80 * frame + 50 * frame, burstEnd = 210 * frame + frames * frame
            let expected = frames >= 6 ? burstEnd + margin : wordEnd + margin
            #expect(ReferencePreparation.conditioningBounds(signal, sampleRate: rate) == (80 * frame - margin)..<expected,
                    "\(rate) Hz, \(frames)-frame burst")
        }
    }

    /// Bursts are measured by the frames they touch, so the guarantee depends on alignment: a loud burst
    /// of at most 40 ms plus one sample touches at most five frames and never counts, wherever it falls;
    /// one of 70 ms always holds six whole frames and always counts. (Between the two, a burst counts
    /// when its partial frames are loud enough.)
    @Test func burstLengthGuaranteesHoldAtEveryAlignment() {
        let rate = 24_000, frame = 240, margin = 2_400
        let lead = [Float](repeating: 0, count: 80 * frame), word = Self.square(frames: 50, frame: frame)
        let gap = [Float](repeating: 0, count: 50 * frame)
        let wordOnly = (80 * frame - margin)..<(130 * frame + margin)
        for offset in stride(from: 0, to: frame, by: 7) + [frame - 1] {
            let pad = [Float](repeating: 0, count: offset)
            let click = lead + word + gap + pad + Self.square(samples: 4 * frame + 1) + gap
            #expect(ReferencePreparation.conditioningBounds(click, sampleRate: rate) == wordOnly, "click at offset \(offset)")
            let short = lead + word + gap + pad + Self.square(samples: 7 * frame) + gap
            let burstEnd = 180 * frame + offset + 7 * frame
            let bounds = ReferencePreparation.conditioningBounds(short, sampleRate: rate)
            #expect(bounds.lowerBound == wordOnly.lowerBound && bounds.upperBound >= burstEnd + margin - frame
                    && bounds.upperBound <= burstEnd + margin + frame, "70 ms word at offset \(offset): \(bounds)")
        }
    }

    /// The level threshold is max(0.004, 6 % of the take's RMS), and a frame must exceed it.
    @Test func theThresholdHasAnAbsoluteFloorAndARelativePart() {
        let rate = 24_000, frame = 240, margin = 2_400
        let silence = [Float](repeating: 0, count: 300 * frame)
        // A faint word (RMS 0.05 over 10 of 610 frames: 6 % of the take's RMS is 0.0004), so the floor rules.
        let faint = Self.square(frames: 10, frame: frame, amplitude: 0.05)
        for (level, counts): (Float, Bool) in [(0.0039, false), (0.0041, true)] {
            let signal = silence + faint + silence + Self.square(frames: 8, frame: frame, amplitude: level) + [Float](repeating: 0, count: 50 * frame)
            let upper = ReferencePreparation.conditioningBounds(signal, sampleRate: rate).upperBound
            #expect(upper == (counts ? 618 * frame + margin : 310 * frame + margin), "burst at \(level)")
        }
        // A loud take: 6 % of its RMS is far above the floor. A 50-frame tail at a fraction f of the take's
        // RMS (which includes the tail: rms² = (300 · 0.25 + 50 · f² · rms²) / 700) counts only above 6 %.
        let word = Self.square(frames: 300, frame: frame, amplitude: 0.5)
        for (fraction, counts) in [(0.059, false), (0.061, true)] {
            let rms = (75.0 / 700.0 / (1 - 50 * fraction * fraction / 700)).squareRoot()
            let tail = Self.square(frames: 50, frame: frame, amplitude: Float(rms * fraction))
            let signal = [Float](repeating: 0, count: 100 * frame) + word + [Float](repeating: 0, count: 100 * frame) + tail + [Float](repeating: 0, count: 150 * frame)
            let upper = ReferencePreparation.conditioningBounds(signal, sampleRate: rate).upperBound
            #expect(upper == (counts ? 550 * frame + margin : 400 * frame + margin), "tail at \(fraction) of the take's RMS")
        }
    }

    /// Rates that are not multiples of 100 round the frame down (22,050 Hz: 220 samples) and keep
    /// 100 ms; rates below 100 Hz measure single samples. None trap, and the result is a slice of the take.
    @Test(arguments: [1, 7, 99, 100, 101, 8_000, 11_025, 16_000, 22_050, 32_000, 88_200, 96_000])
    func unusualSampleRatesKeepTheSpeech(rate: Int) {
        func n(_ seconds: Double) -> Int { max(1, Int(seconds * Double(rate))) }
        let speech = Self.square(samples: max(n(1), 12))
        let signal = [Float](repeating: 0, count: n(1)) + speech + [Float](repeating: 0, count: n(0.5)) + Self.square(samples: max(1, n(0.02))) + [Float](repeating: 0, count: n(1))
        let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: rate)
        let speechRange = n(1)..<(n(1) + speech.count)
        #expect(bounds.lowerBound >= 0 && bounds.upperBound <= signal.count)
        #expect(bounds.lowerBound <= speechRange.lowerBound && bounds.upperBound >= speechRange.upperBound, "\(rate) Hz: \(bounds) for \(speechRange)")
        if rate >= 100 {
            let frame = rate / 100, margin = rate / 10
            #expect(speechRange.lowerBound - bounds.lowerBound <= margin + frame, "\(rate) Hz before")
            #expect(bounds.upperBound - speechRange.upperBound <= margin + frame, "\(rate) Hz after: the 20 ms blip is trimmed")
        }
    }

    /// Takes shorter than a frame, or with fewer than six frames, are kept whole.
    @Test(arguments: [0, 1, 239, 240, 241, 1_439, 1_440])
    func takesTooShortForSpeechAreKeptWhole(count: Int) {
        let take = Self.square(samples: count)
        let bounds = ReferencePreparation.conditioningBounds(take, sampleRate: 24_000)
        #expect(bounds == take.indices, "\(count) samples")
    }

    // MARK: Non-finite and extreme samples

    /// References are PCM, so these cannot arrive from a file; the trim must still never trap and never
    /// cut speech. A NaN only silences the frame it is in; an infinity or a near-Float.max spike lifts
    /// the threshold above everything else, so the take is kept whole rather than cut on garbage.
    @Test func nonFiniteAndExtremeSamplesNeverCutSpeech() {
        let rate = 24_000, frame = 240, margin = 2_400
        let silence = [Float](repeating: 0, count: 100 * frame)
        let word = Self.square(frames: 100, frame: frame)
        let wordOnly = (100 * frame - margin)..<(200 * frame + margin)
        var nanInSilence = silence + word + silence
        nanInSilence[250 * frame] = .nan
        #expect(ReferencePreparation.conditioningBounds(nanInSilence, sampleRate: rate) == wordOnly, "a NaN in the tail is not speech")
        var nanInWord = silence + word + silence
        nanInWord[150 * frame] = .nan
        #expect(ReferencePreparation.conditioningBounds(nanInWord, sampleRate: rate) == wordOnly, "the word's halves are both speech")
        for spike: Float in [.infinity, -.infinity, .greatestFiniteMagnitude] {
            var signal = silence + word + silence
            signal[250 * frame] = spike
            let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: rate)
            #expect(bounds.lowerBound <= 100 * frame && bounds.upperBound >= 200 * frame, "spike \(spike): \(bounds)")
        }
        let allNaN = [Float](repeating: .nan, count: 10 * frame)
        #expect(ReferencePreparation.conditioningBounds(allNaN, sampleRate: rate) == allNaN.indices)
    }

    // MARK: Properties

    /// Seeded fuzz over exact frame layouts (frame-aligned square-wave runs of 1 to 40 frames between
    /// silences or faint noise, at five sample rates, with a partial final frame): the kept range is
    /// exactly from 100 ms before the first run of six or more frames to 100 ms after the last, clamped;
    /// no frame of such a run is ever removed; trimming again changes nothing; and scaling the take by a
    /// power of two keeps the same range.
    @Test(arguments: 0..<8)
    func frameLayoutsTrimExactlyAndIdempotently(seed: Int) {
        var generator = SplitMix(state: 0xC0DE_0000 &+ UInt64(seed))
        for trial in 0..<24 {
            let rate = [8_000, 16_000, 24_000, 44_100, 48_000][Int.random(in: 0...4, using: &generator)]
            let frame = rate / 100, margin = rate / 10
            var signal: [Float] = [], loud: [Bool] = []
            var isLoud = Bool.random(using: &generator)
            for _ in 0..<Int.random(in: 1...12, using: &generator) {
                let frames = isLoud ? Int.random(in: 1...40, using: &generator) : Int.random(in: 1...60, using: &generator)
                if isLoud {
                    signal += Self.square(frames: frames, frame: frame, amplitude: Float.random(in: 0.1...0.8, using: &generator))
                } else {
                    let floor = Bool.random(using: &generator) ? Float.random(in: 0...0.002, using: &generator) : 0
                    signal += (0..<(frames * frame)).map { _ in floor * Float.random(in: -1...1, using: &generator) }
                }
                loud += [Bool](repeating: isLoud, count: frames)
                isLoud.toggle()
            }
            signal += [Float](repeating: 0, count: Int.random(in: 0..<frame, using: &generator))
            // The oracle, from the layout rather than from measured levels.
            var runs: [Range<Int>] = [], start: Int?
            for (index, on) in (loud + [false]).enumerated() {
                if on, start == nil { start = index }
                if !on, let begin = start { runs.append(begin..<index); start = nil }
            }
            let speech = runs.filter { $0.count >= 6 }
            let expected = speech.isEmpty ? signal.indices
                : max(0, speech.first!.lowerBound * frame - margin)..<min(signal.count, speech.last!.upperBound * frame + margin)
            let context = "seed \(seed) trial \(trial) at \(rate) Hz"
            let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: rate)
            #expect(bounds == expected, "\(context): \(bounds) instead of \(expected)")
            for run in speech { #expect(bounds.contains(run.lowerBound * frame) && bounds.contains(run.upperBound * frame - 1), "\(context): cut \(run)") }
            let trimmed = ReferencePreparation.trimmedForConditioning(signal, sampleRate: rate)
            #expect(trimmed == Array(signal[bounds]), "\(context)")
            #expect(ReferencePreparation.trimmedForConditioning(trimmed, sampleRate: rate) == trimmed, "\(context): not idempotent")
            for scale: Float in [0.5, 2] {
                #expect(ReferencePreparation.conditioningBounds(signal.map { $0 * scale }, sampleRate: rate) == bounds, "\(context) scaled by \(scale)")
            }
        }
    }

    /// Arbitrary signals, including NaN, infinities, subnormals and Float.max, at arbitrary rates: the
    /// trim never traps, returns a contiguous non-empty slice of a non-empty take, is deterministic, and
    /// keeps every frame-aligned run of six frames that it measured as loud.
    @Test(arguments: 0..<16)
    func arbitraryTakesNeverTrapAndStayContiguous(seed: Int) {
        var generator = SplitMix(state: 0xF022 &+ UInt64(seed) &* 0x1_0000)
        let values: [Float] = [0, .leastNonzeroMagnitude, 1e-30, 0.001, 0.004, 0.0041, 0.05, 0.5, 1, -1, 30_000, .greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        for trial in 0..<12 {
            let rate = [1, 50, 101, 8_000, 22_050, 24_000, 44_100][Int.random(in: 0...6, using: &generator)]
            var signal: [Float] = []
            for _ in 0..<Int.random(in: 0...10, using: &generator) {
                let value = values.randomElement(using: &generator)!, count = Int.random(in: 0...6_000, using: &generator)
                let rare = Int.random(in: 0...20, using: &generator) == 0
                signal += (0..<count).map { i in rare && i % 97 != 0 ? 0 : (i % 2 == 0 ? value : -value) }
            }
            let bounds = ReferencePreparation.conditioningBounds(signal, sampleRate: rate)
            let context = "seed \(seed) trial \(trial): \(signal.count) samples at \(rate) Hz"
            #expect(bounds.lowerBound >= 0 && bounds.upperBound <= signal.count, "\(context)")
            #expect(signal.isEmpty || !bounds.isEmpty, "\(context)")
            #expect(ReferencePreparation.conditioningBounds(signal, sampleRate: rate) == bounds, "\(context): not deterministic")
            let trimmed = ReferencePreparation.trimmedForConditioning(signal, sampleRate: rate)
            #expect(trimmed.count == bounds.count && zip(trimmed, signal[bounds]).allSatisfy { $0.bitPattern == $1.bitPattern }, "\(context)")
        }
    }

    // MARK: Non-functional

    /// The longest voice set (180 s at the engine's 24 kHz) trims in well under the time a passage takes.
    @Test func aLongTakeTrimsQuickly() {
        let rate = 24_000
        var take = [Float](repeating: 0, count: 180 * rate)
        for second in stride(from: 1, to: 179, by: 2) {
            for i in (second * rate)..<((second + 1) * rate) { take[i] = Float(0.4 * sin(Double(i) * 0.05)) }
        }
        var trimmed: [Float] = []
        let elapsed = ContinuousClock().measure { trimmed = ReferencePreparation.trimmedForConditioning(take, sampleRate: rate) }
        #expect(trimmed.count == (178 - 1) * rate + 2 * rate / 10)
        #expect(elapsed < .seconds(1), "180 s take: \(elapsed)")
    }

    // MARK: Helpers

    /// ±`amplitude` alternating every sample: every whole frame of it has RMS exactly `amplitude`.
    static func square(frames: Int, frame: Int, amplitude: Float = 0.3) -> [Float] { square(samples: frames * frame, amplitude: amplitude) }
    static func square(samples: Int, amplitude: Float = 0.3) -> [Float] { (0..<samples).map { $0 % 2 == 0 ? amplitude : -amplitude } }
}

/// SplitMix64: a small deterministic generator for seeded fuzz.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

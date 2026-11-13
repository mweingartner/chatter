import ChatterAudioKit
import Foundation
import Testing

/// Synthetic passages at 24 kHz: a 220 Hz tone stands for speech, uniform noise for room tone.
private enum Passage {
    static let rate = 24_000
    static func count(_ seconds: Double) -> Int { Int((seconds * Double(rate)).rounded()) }
    static func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0 ..< count(seconds)).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
    }
    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: count(seconds)) }
    /// Room tone `below` dB under a full-level tone of amplitude 0.3.
    static func roomTone(_ seconds: Double, below: Double, seed: UInt64 = 7) -> [Float] {
        var state = seed
        let amplitude = Float(0.3 / 2.0.squareRoot() * pow(10, -below / 20) * 3.0.squareRoot())
        return (0 ..< count(seconds)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 23) - 1)
        }
    }
    static func activity(_ samples: [Float], chunk: Int? = nil) -> SpeechActivity {
        var activity = SpeechActivity()
        guard let chunk else { activity.append(samples); return activity }
        var start = 0
        while start < samples.count { activity.append(Array(samples[start ..< min(samples.count, start + chunk)])); start += chunk }
        return activity
    }
}

struct SpeechActivityTests {
    @Test func aCleanPassageIsMeasuredFromFirstToLastSound() {
        let activity = Passage.activity(Passage.silence(0.3) + Passage.speech(1.0) + Passage.silence(0.5))
        #expect(activity.hasSpoken)
        #expect(abs(activity.seconds - 1.8) < 0.021)
        #expect(abs(activity.leadingSilence - 0.3) <= 0.02)
        #expect(abs(activity.trailingSilence - 0.5) <= 0.02)
        #expect(abs(activity.spokenSpan - 1.0) <= 0.04)
        #expect(activity.longestPause == 0)
    }

    /// Scar's recording has a background only 25 dB below her speech; it is silence all the same.
    @Test(arguments: [25.0, 30, 45])
    func roomToneIsSilenceHoweverLoud(below: Double) {
        let passage = Passage.roomTone(0.4, below: below) + Passage.add(Passage.speech(0.8), Passage.roomTone(0.8, below: below, seed: 9))
            + Passage.roomTone(2.0, below: below, seed: 11)
        let activity = Passage.activity(passage)
        #expect(activity.hasSpoken)
        #expect(abs(activity.leadingSilence - 0.4) <= 0.04, "\(activity.leadingSilence)")
        #expect(abs(activity.trailingSilence - 2.0) <= 0.04, "\(activity.trailingSilence)")
    }

    @Test func roomToneAloneIsNeverSpeech() {
        for below in [20.0, 25, 40] {
            let activity = Passage.activity(Passage.roomTone(4, below: below))
            #expect(!activity.hasSpoken, "room tone \(below) dB down")
            #expect(activity.leadingSilence >= 3.98 && activity.trailingSilence == 0)
        }
        #expect(!Passage.activity(Passage.silence(3)).hasSpoken)
    }

    @Test func aClickDoesNotStartSpeech() {
        let click = Passage.silence(0.3) + Passage.speech(0.03) + Passage.silence(1.0)
        #expect(!Passage.activity(click).hasSpoken)
        let word = Passage.silence(0.3) + Passage.speech(0.12) + Passage.silence(1.0)
        #expect(Passage.activity(word).hasSpoken)
    }

    @Test func aPassageThatOpensLoudHasSpokenFromItsFirstSample() {
        let activity = Passage.activity(Passage.speech(0.5) + Passage.silence(0.2))
        #expect(activity.hasSpoken && activity.leadingSilence == 0)
        #expect(abs(activity.trailingSilence - 0.2) <= 0.02)
    }

    @Test func theLongestPauseIsTheLongestSilenceBetweenSpeech() {
        let passage = Passage.silence(0.2) + Passage.speech(0.5) + Passage.silence(0.3) + Passage.speech(0.4) + Passage.silence(0.7) + Passage.speech(0.5)
        var activity = Passage.activity(passage)
        #expect(abs(activity.longestPause - 0.7) <= 0.04, "\(activity.longestPause)")
        #expect(activity.trailingSilence == 0)
        // A silence still running is not a pause until speech follows it.
        activity.append(Passage.silence(1.2))
        #expect(abs(activity.longestPause - 0.7) <= 0.04)
        #expect(abs(activity.trailingSilence - 1.2) <= 0.02)
        activity.append(Passage.speech(0.2))
        #expect(abs(activity.longestPause - 1.2) <= 0.04)
    }

    /// The same passage gives the same measures however it is cut into chunks.
    @Test(arguments: [1, 7, 479, 480, 481, 1920, 9600, 19_200])
    func measuresDoNotDependOnChunking(chunk: Int) {
        let passage = Passage.roomTone(0.35, below: 30) + Passage.speech(0.6) + Passage.roomTone(0.45, below: 30, seed: 3) + Passage.speech(0.3) + Passage.roomTone(0.9, below: 30, seed: 5)
        let whole = Passage.activity(passage), cut = Passage.activity(passage, chunk: chunk)
        #expect(cut.hasSpoken == whole.hasSpoken)
        #expect(cut.leadingSilence == whole.leadingSilence && cut.trailingSilence == whole.trailingSilence)
        #expect(cut.longestPause == whole.longestPause && cut.spokenSpan == whole.spokenSpan && cut.seconds == whole.seconds)
    }
}

/// What the engine does about a passage that never starts, goes quiet, or has said its words.
struct PassageWatchTests {
    @Test func aVoiceThatHasNotStartedInTimeNeverWill() {
        #expect(PassageWatch.verdict(Passage.activity(Passage.silence(1.5)), tokens: 5) == .carryOn)
        #expect(PassageWatch.verdict(Passage.activity(Passage.silence(1.6)), tokens: 5) == .neverSpoke)
        #expect(PassageWatch.verdict(Passage.activity(Passage.roomTone(2.4, below: 25)), tokens: 5) == .neverSpoke)
        // JARVIS starts up to half a second in; that is not a fault.
        #expect(PassageWatch.verdict(Passage.activity(Passage.silence(0.5) + Passage.speech(1.2)), tokens: 5) == .carryOn)
    }

    @Test func silenceAfterTheWordsEndsThePassage() {
        // Five tokens need 4 frames of speech, about a third of a second.
        let said = Passage.silence(0.2) + Passage.speech(1.2)
        #expect(PassageWatch.verdict(Passage.activity(said + Passage.silence(1.4)), tokens: 5) == .carryOn)
        #expect(PassageWatch.verdict(Passage.activity(said + Passage.silence(1.5)), tokens: 5) == .finished)
        // A noisy recording's voice opens and closes in its room tone, which is silence too.
        let noisy = Passage.roomTone(0.2, below: 25, seed: 1) + Passage.add(Passage.speech(1.2), Passage.roomTone(1.2, below: 25, seed: 2))
        #expect(PassageWatch.verdict(Passage.activity(noisy + Passage.roomTone(1.2, below: 25)), tokens: 5) == .carryOn)
        #expect(PassageWatch.verdict(Passage.activity(noisy + Passage.roomTone(3, below: 25)), tokens: 5) == .finished)
    }

    @Test func silenceWithTooLittleSaidIsAStall() {
        // Twenty tokens need 16 frames, 1.3 seconds; a third of a second cannot be all of it.
        let started = Passage.silence(0.2) + Passage.speech(0.35)
        #expect(PassageWatch.verdict(Passage.activity(started + Passage.silence(1.0)), tokens: 20) == .carryOn)
        #expect(PassageWatch.verdict(Passage.activity(started + Passage.silence(1.6)), tokens: 20) == .stalled)
        #expect(!PassageWatch.saysEnough(Passage.activity(started), tokens: 20))
        #expect(PassageWatch.saysEnough(Passage.activity(Passage.speech(2.2)), tokens: 20))
    }

    /// One or two words are over too quickly to judge by their length.
    @Test func aVeryShortPassageOnlyHasToSpeak() {
        let yes = Passage.silence(0.1) + Passage.speech(0.12) + Passage.silence(0.3)
        #expect(PassageWatch.saysEnough(Passage.activity(yes), tokens: 2))
        #expect(PassageWatch.saysEnough(Passage.activity(yes), tokens: 3))
        #expect(!PassageWatch.saysEnough(Passage.activity(yes), tokens: 4))
        #expect(!PassageWatch.saysEnough(Passage.activity(Passage.silence(0.5)), tokens: 2))
        #expect(PassageWatch.verdict(Passage.activity(yes + Passage.silence(1.4)), tokens: 2) == .finished)
    }

    /// A sentence's last words can be 25 dB below its loudest and are still speech.
    @Test func quietLastWordsAreStillSpeech() {
        let passage = Passage.silence(0.2) + Passage.speech(0.6) + Passage.speech(0.5, amplitude: 0.3 * Float(pow(10, -25.0 / 20)))
        let activity = Passage.activity(passage)
        #expect(abs(activity.spokenSpan - 1.1) <= 0.04, "\(activity.spokenSpan)")
        #expect(activity.trailingSilence == 0)
    }

    @Test func aPauseInsideAHealthyPassageCarriesOn() {
        let passage = Passage.speech(1.0) + Passage.silence(0.8) + Passage.speech(1.0)
        #expect(PassageWatch.verdict(Passage.activity(passage), tokens: 12) == .carryOn)
    }
}

private extension Passage {
    static func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }
}

/// `PassageEnvelope`'s options for speech as Chatter delivers it: edges trimmed while streaming, and
/// a soft ending for a passage that is still sounding at its last sample.
struct PassageEnvelopeDeliveryTests {
    static func streamed(_ samples: [Float], chunk: Int, trimsEdges: Bool = true, softensEnding: Bool = true) -> [Float] {
        var envelope = PassageEnvelope(trimsEdges: trimsEdges, softensEnding: softensEnding)
        var output: [Float] = [], start = 0
        while start < samples.count { output += envelope.append(Array(samples[start ..< min(samples.count, start + chunk)])); start += chunk }
        return output + envelope.finish()
    }

    @Test(arguments: [480, 9600, 19_200, 96_000])
    func aStreamedPassageDropsItsLeadingAndTrailingRoomTone(chunk: Int) {
        let passage = Passage.roomTone(0.6, below: 40) + Passage.add(Passage.speech(1.0), Passage.roomTone(1.0, below: 40, seed: 2)) + Passage.roomTone(0.3, below: 40, seed: 4)
        let output = Self.streamed(passage, chunk: chunk)
        // 50 ms fade-in before the first sound, the second of speech, and 100 ms after it.
        let expected = Passage.count(0.05 + 1.0 + 0.1)
        #expect(abs(output.count - expected) <= Passage.count(0.03), "\(Double(output.count) / 24_000) s")
        #expect(output.first == 0 && output.last == 0)
        // The speech itself is untouched.
        let middle = output[Passage.count(0.2) ..< Passage.count(0.9)]
        #expect(abs(Double(middle.map(abs).max() ?? 0) - 0.3) < 0.02)
    }

    @Test func trimmingNeverChangesWhatUntrimmedStreamingAlreadyPlays() {
        let passage = Passage.roomTone(0.6, below: 40) + Passage.add(Passage.speech(1.0), Passage.roomTone(1.0, below: 40, seed: 2)) + Passage.roomTone(0.3, below: 40, seed: 4)
        let kept = Self.streamed(passage, chunk: 9600, trimsEdges: false, softensEnding: false)
        #expect(kept.count == passage.count, "without trimming a passage keeps its length")
    }

    @Test func aPassageStillSoundingAtItsEndFadesOutGently() {
        let passage = Passage.roomTone(0.3, below: 40) + Passage.speech(1.0)
        let soft = Self.streamed(passage, chunk: 9600), hard = Self.streamed(passage, chunk: 9600, softensEnding: false)
        #expect(soft.count == hard.count)
        // 30 ms before the end: the 8 ms edge has not begun, the 60 ms one is half way down.
        func level(_ samples: [Float], endingBefore seconds: Double) -> Float {
            let end = samples.count - Passage.count(seconds)
            return samples[(end - 240) ..< end].map(abs).max() ?? 0
        }
        #expect(level(hard, endingBefore: 0.025) > 0.29)
        #expect(level(soft, endingBefore: 0.025) < 0.2 && level(soft, endingBefore: 0.025) > 0.03)
        #expect(level(soft, endingBefore: 0.07) > 0.29, "the fade is confined to the last 60 ms")
        #expect(soft.last == 0 && hard.last == 0)
    }

    /// The largest change between neighbouring samples in the last `seconds` of `samples`.
    static func largestStep(_ samples: [Float], last seconds: Double) -> Float {
        let tail = Array(samples.suffix(Passage.count(seconds)))
        return zip(tail, tail.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    /// Qwen ends a passage by cutting to digital silence, here from a background 25 dB below the
    /// speech and 150 ms after the last word, with silence after the cut. The background is livelier
    /// than the room tone the passage opened with (35 dB below), as Scar's is, so it is judged to be
    /// speech and the room-tone fade does not reach it. Heard as a click unless it fades into the
    /// silence.
    @Test(arguments: [4800, 9600, 96_000])
    func aBackgroundThatCutsToSilenceFadesIntoIt(chunk: Int) {
        let noisy = Passage.roomTone(0.3, below: 35) + Passage.add(Passage.speech(1.0), Passage.roomTone(1.0, below: 25, seed: 2))
            + Passage.roomTone(0.15, below: 25, seed: 3)
        let passage = noisy + Passage.silence(0.12)
        let cut = noisy.count
        let hard = Self.streamed(passage, chunk: chunk, trimsEdges: false, softensEnding: false)
        let soft = Self.streamed(passage, chunk: chunk, trimsEdges: false, softensEnding: true)
        #expect(soft.count == passage.count && hard.count == passage.count)
        func level(_ samples: [Float], endingAt end: Int) -> Double {
            let block = samples[(end - 120) ..< end]
            return 10 * log10(Double(block.map { $0 * $0 }.reduce(0, +)) / 120 + 1e-14)
        }
        // Without softening the background runs at full level into the cut.
        #expect(abs(level(hard, endingAt: cut) - level(passage, endingAt: cut)) < 0.5)
        // The last 5 ms before the cut: nearly gone when softened; and 60 ms before it, untouched.
        #expect(level(soft, endingAt: cut) < level(passage, endingAt: cut) - 30)
        #expect(abs(level(soft, endingAt: cut - 1440) - level(passage, endingAt: cut - 1440)) < 0.5)
        #expect(soft[cut...].allSatisfy { $0 == 0 })
        // A burst of sound after the cut would put the fade in the wrong place; there is none here,
        // and nothing after the cut is louder than before.
        #expect(Self.largestStep(soft, last: 0.125) < 0.002, "the last 5 ms of sound and the silence after it")
        #expect(Self.largestStep(hard, last: 0.125) > 0.01)
    }

    /// The same when the cut is the passage's very last sample, on speech at full level.
    @Test func aPassageCutAtFullLevelFadesToo() {
        let passage = Passage.roomTone(0.3, below: 40) + Passage.speech(1.0)
        let soft = Self.streamed(passage, chunk: 9600, trimsEdges: false, softensEnding: true)
        #expect(Self.largestStep(soft, last: 0.01) < 0.004)
        #expect(soft.last == 0)
    }

    /// A passage whose sound has already died away is not changed where it can be heard.
    @Test func aPassageThatHasDiedAwayIsLeftAlone() {
        let decay = Passage.speech(0.5).enumerated().map { index, sample in sample * Float(exp(-Double(index) / 600)) }
        let passage = Passage.roomTone(0.3, below: 60) + Passage.speech(1.0) + decay + Passage.silence(0.2)
        let soft = Self.streamed(passage, chunk: 9600, trimsEdges: false, softensEnding: true)
        let plain = Self.streamed(passage, chunk: 9600, trimsEdges: false, softensEnding: false)
        let worst = zip(soft, plain).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 0.001, "\(worst)")
    }
}

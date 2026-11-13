import Accelerate
import Foundation

/// Follows a passage while it is generated and tells speech from silence, so the engine can notice a
/// voice that never starts, or one that has gone quiet, without waiting for the model to say so.
///
/// Qwen occasionally keeps generating room tone: before the first word, in the middle of a sentence,
/// or after the last word without ever signalling the end. Each is plain to see in the audio long
/// before the frame budget runs out.
///
/// Levels are measured in 20 ms frames. The first four give the opening room tone; a frame is speech
/// when it is at least `rise` dB above that room tone, at least `quietest` dBFS, and within `range` dB
/// of the loudest frame so far. A noisy recording's background is therefore silence (Scar's sits
/// 27 dB below her speech, so her bar is 21 dB below it), and so is a clean one's digital silence,
/// while a sentence's quiet last words still count as speech. A passage that opens loud has no room
/// tone to measure and uses the other two bars alone.
public struct SpeechActivity: Sendable {
    /// A frame must rise this far above the opening room tone (dB).
    public static let rise = 6.0
    /// ...be at least this loud (dBFS)...
    public static let quietest = -50.0
    /// ...and lie within this many dB of the loudest frame so far.
    public static let range = 30.0
    /// An opening louder than this (dBFS) is speech from the first sample.
    public static let loudOpening = -30.0
    /// Speech starts with this many speech frames in a row (60 ms), so a click does not count.
    public static let onsetFrames = 3

    public let sampleRate: Int
    private let frame: Int
    private var carry: [Float] = []
    private var opening: [Double] = []
    private var floor: Double?
    private var loudest = -Double.infinity
    private var run = 0
    private var frames = 0
    private var firstSpeechFrame: Int?
    private var lastSpeechFrame: Int?
    private var longestPauseFrames = 0

    public init(sampleRate: Int = 24_000) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
        frame = max(1, sampleRate / 50)
    }

    /// Seconds of audio measured so far (whole frames).
    public var seconds: Double { Double(frames * frame) / Double(sampleRate) }
    /// Whether sustained speech has been heard.
    public var hasSpoken: Bool { firstSpeechFrame != nil }
    /// Seconds before the first speech, or all of it when there is none yet.
    public var leadingSilence: Double { Double((firstSpeechFrame ?? frames) * frame) / Double(sampleRate) }
    /// Seconds since the last speech frame; zero before any speech.
    public var trailingSilence: Double {
        guard let last = lastSpeechFrame else { return 0 }
        return Double((frames - 1 - last) * frame) / Double(sampleRate)
    }
    /// Seconds from the first speech to the end of the last.
    public var spokenSpan: Double {
        guard let first = firstSpeechFrame, let last = lastSpeechFrame else { return 0 }
        return Double((last + 1 - first) * frame) / Double(sampleRate)
    }
    /// The longest silence between two stretches of speech, in seconds. A silence still running at
    /// the end is `trailingSilence`, not a pause, until speech follows it.
    public var longestPause: Double { Double(longestPauseFrames * frame) / Double(sampleRate) }

    public mutating func append(_ samples: [Float]) {
        carry.append(contentsOf: samples)
        var start = 0
        carry.withUnsafeBufferPointer { buffer in
            while buffer.count - start >= frame {
                let power = vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: buffer[start ..< start + frame]))
                measure(10 * log10(Double(power) / Double(frame) + 1e-14))
                start += frame
            }
        }
        if start > 0 { carry.removeFirst(start) }
    }

    private mutating func measure(_ level: Double) {
        defer { frames += 1 }
        guard floor == nil else { classify(level, at: frames); return }
        opening.append(level)
        guard opening.count == 4 else { return }
        let sorted = opening.sorted()
        let median = (sorted[1] + sorted[2]) / 2
        floor = median > Self.loudOpening ? -Double.infinity : median
        // Judge the opening frames now that there is a room tone to judge them by.
        for (index, level) in opening.enumerated() { classify(level, at: index) }
        opening = []
    }

    private mutating func classify(_ level: Double, at index: Int) {
        loudest = max(loudest, level)
        let bar = max((floor ?? -.infinity) + Self.rise, Self.quietest, loudest - Self.range)
        guard level >= bar else { run = 0; return }
        run += 1
        if firstSpeechFrame == nil {
            guard run >= Self.onsetFrames else { return }
            firstSpeechFrame = index - run + 1
            lastSpeechFrame = index
            return
        }
        if let last = lastSpeechFrame { longestPauseFrames = max(longestPauseFrames, index - last - 1) }
        lastSpeechFrame = index
    }
}

/// What the engine does about a passage as `SpeechActivity` follows it.
public enum PassageWatch {
    /// A voice that has not started within this many seconds is not going to.
    public static let latestStart = 1.6
    /// After this much silence following speech, the passage is over, whether or not the model has
    /// said so. The longest pause inside a healthy passage measured 0.8 s (480 passages, 2026-11-12).
    public static let longestSilence = 1.5
    /// A passage whose speech covers fewer frames than this for each text token has not said all of
    /// it. The fastest healthy passages measured 1.9 frames per token from start to end, and 1.4 by
    /// this measure, which can miss a quiet last word; this catches a sentence cut to half or less.
    public static let fewestFramesPerToken = 0.8
    /// A passage of this many tokens or fewer ("Yes.", "Thank you.") is too short to judge that way.
    public static let fewestTokensJudged = 4

    public enum Verdict: Equatable, Sendable {
        case carryOn
        /// The words are said and the voice has gone quiet: end the passage here.
        case finished
        /// No speech yet, and too late for it to start.
        case neverSpoke
        /// The voice went quiet with too little said for the text.
        case stalled
    }

    /// `tokens`: text tokens in the passage. `frameRate`: codec frames per second.
    public static func verdict(_ activity: SpeechActivity, tokens: Int, frameRate: Double = 12.5) -> Verdict {
        guard activity.hasSpoken else { return activity.seconds >= latestStart ? .neverSpoke : .carryOn }
        guard activity.trailingSilence >= longestSilence else { return .carryOn }
        return saysEnough(activity, tokens: tokens, frameRate: frameRate) ? .finished : .stalled
    }

    /// Whether the speech heard is long enough to have covered the text.
    public static func saysEnough(_ activity: SpeechActivity, tokens: Int, frameRate: Double = 12.5) -> Bool {
        guard tokens >= fewestTokensJudged else { return activity.hasSpoken }
        return activity.spokenSpan * frameRate >= fewestFramesPerToken * Double(tokens)
    }
}

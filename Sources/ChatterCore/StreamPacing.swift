import Foundation

/// Decides when streamed speech may start playing, so the player never runs dry in the middle of a
/// word. Speech is generated faster than it plays, but it arrives a chunk at a time: if the first
/// chunk plays out before the second arrives, the listener hears a hole. Playback therefore starts,
/// and starts again after running dry, only when the audio waiting covers the time the next chunk
/// should take, judged from how chunks have been arriving.
public struct StreamPacing: Sendable, Equatable {
    /// Arrival time per second of audio assumed before any chunk has been timed.
    public static let initialRatio = 0.5
    /// The least and most audio ever held back, in seconds.
    public static let holdRange = 0.15...1.5

    /// Seconds a chunk takes to arrive per second of audio it holds, smoothed: the engine's
    /// real-time factor as playback sees it.
    public private(set) var ratio: Double
    /// The usual length of a chunk in seconds, smoothed.
    public private(set) var chunkSeconds: Double
    /// Audio waiting to play, in seconds, while playback is held back.
    public private(set) var heldSeconds = 0.0
    /// Whether chunks are being played as they arrive.
    public private(set) var flowing = false
    private var lastArrival: ContinuousClock.Instant?

    public init(ratio: Double = initialRatio, chunkSeconds: Double = 0.8) {
        self.ratio = ratio; self.chunkSeconds = chunkSeconds
    }

    /// A new job: keep what was learned about the engine's pace, forget the last job's audio.
    public mutating func restart() { heldSeconds = 0; flowing = false; lastArrival = nil }

    /// The audio that must be waiting before playback starts: what should play while the next chunk
    /// is on its way, with a quarter to spare and a tenth of a second for scheduling.
    public var requiredSeconds: Double {
        min(Self.holdRange.upperBound, max(Self.holdRange.lowerBound, chunkSeconds * ratio * 1.25 + 0.1))
    }

    /// Records a chunk of `seconds` of audio arriving at `now`. `playerIsDry`: nothing scheduled is
    /// still playing. Returns whether to play everything held, this chunk included, and whether the
    /// player ran dry while chunks were flowing.
    public mutating func arrived(seconds: Double, at now: ContinuousClock.Instant, playerIsDry: Bool) -> (play: Bool, underrun: Bool) {
        // Only chunks of speech tell how fast the engine runs: the short silences between sentences
        // arrive at once, and the first chunk of a sentence also waited for its prompt.
        if let lastArrival, seconds >= 0.2 {
            let elapsed = (now - lastArrival) / .seconds(1)
            let sample = min(4, max(0.02, elapsed / seconds))
            ratio += 0.3 * (sample - ratio)
            chunkSeconds += 0.3 * (min(2, seconds) - chunkSeconds)
        }
        lastArrival = now
        let underrun = flowing && playerIsDry
        if underrun { flowing = false; heldSeconds = 0 }
        if flowing { return (true, false) }
        heldSeconds += seconds
        guard heldSeconds >= requiredSeconds else { return (false, underrun) }
        flowing = true; heldSeconds = 0
        return (true, underrun)
    }
}

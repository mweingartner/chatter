import ChatterCore
import Foundation
import Testing

/// Streamed speech starts, and restarts after running dry, only when the audio waiting covers the
/// time the next chunk should take to arrive.
struct StreamPacingTests {
    let start = ContinuousClock.now
    func at(_ seconds: Double) -> ContinuousClock.Instant { start + .seconds(seconds) }

    @Test func aChunkTooShortToOutlastTheNextOneIsHeld() {
        var pacing = StreamPacing(ratio: 0.5, chunkSeconds: 0.8)
        #expect(abs(pacing.requiredSeconds - 0.6) < 1e-9)
        // 0.4 s of audio, and the next chunk is about 0.4 s away: too close to start on.
        let first = pacing.arrived(seconds: 0.4, at: at(0), playerIsDry: true)
        #expect(first.play == false && first.underrun == false)
        #expect(!pacing.flowing && abs(pacing.heldSeconds - 0.4) < 1e-9)
        // With the second chunk there is enough: everything held plays, and later chunks play at once.
        #expect(pacing.arrived(seconds: 0.8, at: at(0.4), playerIsDry: true).play)
        #expect(pacing.flowing && pacing.heldSeconds == 0)
        let third = pacing.arrived(seconds: 0.8, at: at(0.8), playerIsDry: false)
        #expect(third.play && !third.underrun)
    }

    @Test func aFastEngineStartsOnItsFirstChunk() {
        var pacing = StreamPacing(ratio: 0.2, chunkSeconds: 0.4)
        #expect(abs(pacing.requiredSeconds - 0.2) < 1e-9)
        #expect(pacing.arrived(seconds: 0.4, at: at(0), playerIsDry: true).play)
    }

    @Test func theRequiredAudioStaysWithinItsRange() {
        #expect(StreamPacing(ratio: 0.001, chunkSeconds: 0.1).requiredSeconds == StreamPacing.holdRange.lowerBound)
        #expect(StreamPacing(ratio: 4, chunkSeconds: 2).requiredSeconds == StreamPacing.holdRange.upperBound)
    }

    @Test func runningDryMidStreamHoldsAgainAndIsCounted() {
        var pacing = StreamPacing(ratio: 0.3, chunkSeconds: 0.4)
        #expect(pacing.arrived(seconds: 0.4, at: at(0), playerIsDry: true).play)
        // The engine stalls: this chunk took two seconds, and the player has nothing left.
        let late = pacing.arrived(seconds: 0.4, at: at(2), playerIsDry: true)
        #expect(late.underrun)
        #expect(pacing.ratio > 1, "the stall is learned: \(pacing.ratio)")
        // The pace it has now seen needs more than this chunk alone, so it waits for the next.
        #expect(late.play == false && !pacing.flowing)
        let next = pacing.arrived(seconds: 0.4, at: at(2.2), playerIsDry: true)
        #expect(next.play && !next.underrun && pacing.flowing)
    }

    @Test func thePaceIsLearnedFromSpeechChunksOnly() {
        var pacing = StreamPacing(ratio: 0.5, chunkSeconds: 0.8)
        _ = pacing.arrived(seconds: 0.8, at: at(0), playerIsDry: true)
        // 0.8 s of audio every 0.2 s: a real-time factor of 0.25.
        for index in 1 ... 20 { _ = pacing.arrived(seconds: 0.8, at: at(0.2 * Double(index)), playerIsDry: false) }
        #expect(abs(pacing.ratio - 0.25) < 0.01, "\(pacing.ratio)")
        // The silence between sentences arrives with the chunk before it and says nothing about pace.
        let learned = pacing.ratio
        _ = pacing.arrived(seconds: 0.18, at: at(4.0001), playerIsDry: false)
        #expect(pacing.ratio == learned)
    }

    @Test func aNewJobKeepsThePaceAndForgetsTheAudio() {
        var pacing = StreamPacing(ratio: 0.5, chunkSeconds: 0.8)
        _ = pacing.arrived(seconds: 0.3, at: at(0), playerIsDry: true)
        for index in 1 ... 20 { _ = pacing.arrived(seconds: 0.4, at: at(0.1 * Double(index)), playerIsDry: false) }
        let (ratio, chunk) = (pacing.ratio, pacing.chunkSeconds)
        pacing.restart()
        #expect(pacing.ratio == ratio && pacing.chunkSeconds == chunk)
        #expect(!pacing.flowing && pacing.heldSeconds == 0)
        // The first chunk of the new job is not timed against the old job's last one.
        _ = pacing.arrived(seconds: 0.4, at: at(600), playerIsDry: true)
        #expect(pacing.ratio == ratio)
    }

    @Test func aDryPlayerBeforePlaybackStartsIsNotAnUnderrun() {
        var pacing = StreamPacing(ratio: 1, chunkSeconds: 0.8)
        #expect(pacing.arrived(seconds: 0.2, at: at(0), playerIsDry: true).underrun == false)
        #expect(pacing.arrived(seconds: 0.2, at: at(0.5), playerIsDry: true).underrun == false)
    }
}

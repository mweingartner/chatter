// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Accelerate
import Foundation

/// Quality metrics for a voice recording (the app decodes these JSON keys as `RecordingMetrics`).
public struct RecordingHealth: Codable, Sendable, Equatable {
    /// Length in seconds.
    public var duration: Double
    /// Largest absolute sample value.
    public var peak: Double
    /// Root-mean-square level of the whole recording.
    public var rms: Double
    /// Fraction of samples at or above 0.999 full scale.
    public var clippedFraction: Double
    /// Fraction of 10 ms blocks quieter than max(0.006, 8 % of the RMS level).
    public var silenceFraction: Double
    /// Overall suitability as a voice reference, 0...100.
    public var score: Double
    /// User-facing advice, in a fixed order.
    public var warnings: [String]

    public init(duration: Double, peak: Double, rms: Double, clippedFraction: Double,
                silenceFraction: Double, score: Double, warnings: [String]) {
        self.duration = duration
        self.peak = peak
        self.rms = rms
        self.clippedFraction = clippedFraction
        self.silenceFraction = silenceFraction
        self.score = score
        self.warnings = warnings
    }

    /// Measures a mono recording. Exact port of the Python worker's `inspect_audio`, with sums
    /// accumulated in Double (numpy used float32, so values can differ in the last float32 digit).
    ///
    /// An empty recording (rejected earlier by `AudioIO.readMono44k`) yields zero level metrics
    /// and a silence fraction of 1.
    public static func inspect(_ samples: [Float], sampleRate: Double = 44100) -> RecordingHealth {
        let duration = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let level = SignalLevel(samples)
        let silence = silenceFraction(samples, rms: level.rms, block: max(1, Int(sampleRate / 100)))
        return RecordingHealth(duration: duration, peak: level.peak, rms: level.rms,
                               clippedFraction: level.clippedFraction, silenceFraction: silence,
                               score: Advice.score(duration: duration, rms: level.rms,
                                                   clipped: level.clippedFraction, silent: silence),
                               warnings: Advice.warnings(duration: duration, rms: level.rms,
                                                         clipped: level.clippedFraction, silent: silence))
    }

    /// Fraction of whole blocks whose RMS is below max(0.006, rms · 0.08); a recording shorter
    /// than one block counts as entirely silent (numpy's `np.array([0.0])` fallback).
    private static func silenceFraction(_ samples: [Float], rms: Double, block: Int) -> Double {
        let threshold = max(0.006, rms * 0.08)
        let energies = SignalLevel.blockRMS(samples, block: block)
        guard !energies.isEmpty else { return 1 }  // threshold ≥ 0.006 > 0
        return Double(energies.count { $0 < threshold }) / Double(energies.count)
    }

    /// The warning thresholds and score formula of Chatter's recording check.
    enum Advice {
        static func warnings(duration: Double, rms: Double, clipped: Double, silent: Double) -> [String] {
            var warnings: [String] = []
            if duration < 10 { warnings.append("Record at least 10 seconds for a stronger voice reference.") }
            if duration > 35 {
                warnings.append("A focused 10–30 second take usually responds faster. Split long recordings into natural passages.")
            }
            if clipped > 0.001 { warnings.append("Clipping detected. Lower microphone gain and record again.") }
            if rms < 0.015 { warnings.append("Recording is quiet. Move closer to the microphone.") }
            if silent > 0.4 { warnings.append("This take contains substantial silence. Use a continuous, natural reading.") }
            return warnings
        }

        static func score(duration: Double, rms: Double, clipped: Double, silent: Double) -> Double {
            let raw = 100 - min(abs(duration - 22), 30) * 0.7 - clipped * 2000 - max(0, silent - 0.15) * 55
                - (rms < 0.015 ? 20 : 0)
            return max(0.0, min(100.0, raw))
        }
    }
}

/// Whole-signal level statistics, computed with vDSP and accumulated in Double.
struct SignalLevel {
    /// numpy compares float32 samples against the float32 rounding of 0.999.
    static let clipLevel = Float(0.999)
    private static let chunk = 65536

    var peak: Double = 0
    var rms: Double = 0
    var clippedFraction: Double = 0

    init(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        peak = Double(vDSP.maximumMagnitude(samples))
        var squares = 0.0
        var clipped = 0
        samples.withUnsafeBufferPointer { all in
            var start = 0
            while start < all.count {
                let slice = UnsafeBufferPointer(rebasing: all[start..<min(start + Self.chunk, all.count)])
                squares += Self.sumOfSquares(slice)
                clipped += slice.count { abs($0) >= Self.clipLevel }
                start += Self.chunk
            }
        }
        rms = (squares / Double(samples.count)).squareRoot()
        clippedFraction = Double(clipped) / Double(samples.count)
    }

    /// RMS of each whole `block`-sample block (a trailing partial block is ignored, as in numpy).
    static func blockRMS(_ samples: [Float], block: Int) -> [Double] {
        let blocks = samples.count / block
        guard blocks > 0 else { return [] }
        return samples.withUnsafeBufferPointer { all in
            (0..<blocks).map { index in
                let slice = UnsafeBufferPointer(rebasing: all[(index * block)..<((index + 1) * block)])
                return (sumOfSquares(slice) / Double(block)).squareRoot()
            }
        }
    }

    /// Σx² with each sample widened to Double before squaring and summing.
    static func sumOfSquares(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let wide = [Double](unsafeUninitializedCapacity: samples.count) { buffer, count in
            vDSP.convertElements(of: samples, to: &buffer)
            count = samples.count
        }
        return vDSP.sumOfSquares(wide)
    }
}

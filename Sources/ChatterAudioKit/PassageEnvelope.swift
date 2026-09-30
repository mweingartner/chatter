import Foundation

/// Removes hard transitions to/from silence at passage boundaries without changing timing.
/// Retains only 8 ms so streaming can fade the actual end, never individual decoder chunks.
public struct PassageEnvelope {
    private let fadeFrames: Int
    private var pending: [Float] = []
    private var emittedFrames = 0

    public init(sampleRate: Int = 24_000) {
        precondition(sampleRate > 0)
        fadeFrames = max(2, Int(Double(sampleRate) * 0.008))
    }

    public mutating func append(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        let count = max(0, pending.count - fadeFrames)
        guard count > 0 else { return [] }
        var output = Array(pending.prefix(count))
        pending = Array(pending.suffix(fadeFrames))
        fadeIn(&output)
        emittedFrames += count
        return output
    }

    public mutating func finish() -> [Float] {
        var output = pending
        pending.removeAll(keepingCapacity: true)
        fadeIn(&output)
        for i in output.indices {
            output[i] *= gain(output.count - 1 - i)
        }
        emittedFrames += output.count
        return output
    }

    private func fadeIn(_ samples: inout [Float]) {
        for i in 0..<min(samples.count, max(0, fadeFrames - emittedFrames)) {
            samples[i] *= gain(emittedFrames + i)
        }
    }

    /// Raised cosine reaches zero with a flat slope, avoiding a new abrupt gain change.
    private func gain(_ distance: Int) -> Float {
        Float(0.5 - 0.5 * cos(Double.pi * Double(distance) / Double(fadeFrames - 1)))
    }
}

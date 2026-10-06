import Foundation

/// Shapes each generated passage's edges so speech starts and ends from true silence, without
/// changing timing or depending on how the passage arrives in chunks.
///
/// A cloned voice continues its reference recording's room tone for a few codec frames before the
/// first word and after the last. Played after digital silence, that tone switches on and off like a
/// microphone. When a passage opens with room tone well below the speech that follows, the room tone
/// becomes silence, with a short fade-in ending where speech begins and a short fade-out after speech
/// ends. Speech is measured against the opening room tone both broadband and pre-emphasized, so quiet
/// initial fricatives ("f", "s", "th", "h") count as speech. A passage that opens loud, or shows no
/// speech within the look-ahead, gets only an 8 ms raised-cosine edge at each end.
///
/// Streaming emits nothing until the opening is decided (normally within the first decoded chunk),
/// then retains the last 400 ms so the ending can be shaped.
public struct PassageEnvelope {
    private enum Opening {
        case undecided
        /// Only the short raised-cosine edges.
        case plain
        /// Silence before `fadeStart`, a raised-cosine fade-in over `fadeLength` samples, then unity.
        /// `floors` are the opening room-tone levels in dB (broadband, pre-emphasized).
        case roomTone(fadeStart: Int, fadeLength: Int, floors: (broadband: Double, emphasized: Double))
    }

    /// An opening louder than this (dBFS) is speech from the first sample.
    static let loudOpening = -30.0
    /// A frame is speech when it rises this far above the opening room tone (dB).
    static let speechRise = 6.0
    /// The opening is decided once a frame rises this far above the room tone (dB).
    static let speechConfirm = 15.0

    private let edgeFrames, hop, window, preRoll, postRoll, lookAhead, tailFrames: Int
    /// 80 ms of quieter frames are bridged, so a stop closure ("st…", "sp…") stays with its word.
    private let bridgeHops = 16
    private var opening = Opening.undecided
    private var pending: [Float] = []
    private var emittedFrames = 0

    public init(sampleRate: Int = 24_000) {
        precondition(sampleRate > 0)
        func frames(_ seconds: Double) -> Int { max(1, Int(Double(sampleRate) * seconds)) }
        edgeFrames = max(2, frames(0.008))
        hop = frames(0.005)
        window = frames(0.020)
        preRoll = frames(0.050)
        postRoll = frames(0.080)
        lookAhead = frames(1.6)
        tailFrames = frames(0.4)
    }

    public mutating func append(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        if case .undecided = opening {
            guard let decided = decideOpening(final: false) else { return [] }
            opening = decided
        }
        let count = max(0, pending.count - heldFrames)
        guard count > 0 else { return [] }
        var output = Array(pending.prefix(count))
        pending.removeFirst(count)
        applyOpening(&output, from: emittedFrames)
        emittedFrames += count
        return output
    }

    public mutating func finish() -> [Float] {
        if case .undecided = opening { opening = decideOpening(final: true) ?? .plain }
        var output = pending
        pending.removeAll(keepingCapacity: true)
        applyOpening(&output, from: emittedFrames)
        if case .roomTone(_, _, let floors) = opening { silenceTrailingRoomTone(&output, floors: floors) }
        for i in output.indices { output[i] *= gain(output.count - 1 - i, length: edgeFrames) }
        emittedFrames += output.count
        return output
    }

    private var heldFrames: Int {
        if case .roomTone = opening { return tailFrames }
        return edgeFrames
    }

    // MARK: Opening

    /// Uses only the first `lookAhead` samples and, once speech is confirmed, only frames up to the
    /// confirming one, so every chunking reaches the same decision. Nil means more audio is needed.
    private func decideOpening(final: Bool) -> Opening? {
        let prefix = pending.prefix(lookAhead)
        let broadband = Self.levels(prefix, hop: hop, window: window)
        let emphasized = Self.levels(Self.preEmphasized(prefix), hop: hop, window: window)
        guard broadband.count >= 4 else { return final ? .plain : nil }
        let floors = (broadband: Self.median(broadband.prefix(4)), emphasized: Self.median(emphasized.prefix(4)))
        if floors.broadband > Self.loudOpening { return .plain }
        func rises(_ i: Int, by threshold: Double) -> Bool {
            broadband[i] >= floors.broadband + threshold || emphasized[i] >= floors.emphasized + threshold
        }
        guard let confirmed = broadband.indices.first(where: { rises($0, by: Self.speechConfirm) }) else {
            return final || pending.count >= lookAhead ? .plain : nil
        }
        var onsetHop = confirmed, gap = 0
        for i in stride(from: confirmed, through: 0, by: -1) {
            if rises(i, by: Self.speechRise) { onsetHop = i; gap = 0 } else {
                gap += 1
                if gap > bridgeHops { break }
            }
        }
        let onset = onsetHop * hop, fadeStart = max(0, onset - preRoll)
        return .roomTone(fadeStart: fadeStart, fadeLength: max(edgeFrames, onset - fadeStart), floors: floors)
    }

    private func applyOpening(_ samples: inout [Float], from start: Int) {
        var fadeStart = 0, fadeLength = edgeFrames
        if case .roomTone(let s, let l, _) = opening { (fadeStart, fadeLength) = (s, l) }
        let end = fadeStart + fadeLength
        guard start < end else { return }
        for i in 0..<min(samples.count, end - start) {
            let position = start + i
            samples[i] *= position < fadeStart ? 0 : gain(position - fadeStart, length: fadeLength)
        }
    }

    // MARK: Ending

    /// Speech ends with the last frame above the opening room tone; after a short fade-out the rest is
    /// silence. Held audio that is all room tone fades from its start. Audio shorter than one analysis
    /// window is left to the final edge.
    private func silenceTrailingRoomTone(_ samples: inout [Float], floors: (broadband: Double, emphasized: Double)) {
        guard samples.count >= window else { return }
        let broadband = Self.levels(samples[...], hop: hop, window: window)
        let emphasized = Self.levels(Self.preEmphasized(samples[...]), hop: hop, window: window)
        let last = broadband.indices.last {
            broadband[$0] >= floors.broadband + Self.speechRise || emphasized[$0] >= floors.emphasized + Self.speechRise
        }
        let speechEnd = last.map { $0 * hop + window } ?? 0
        for i in speechEnd..<samples.count {
            let distance = i - speechEnd
            samples[i] *= distance < postRoll ? gain(postRoll - 1 - distance, length: postRoll) : 0
        }
    }

    // MARK: Measures

    /// Raised cosine reaches zero with a flat slope, avoiding a new abrupt gain change.
    private func gain(_ distance: Int, length: Int) -> Float {
        guard length > 1 else { return 1 }
        return Float(0.5 - 0.5 * cos(Double.pi * Double(min(distance, length - 1)) / Double(length - 1)))
    }

    /// Mean power in dB of each `window`-sample frame, every `hop` samples.
    static func levels(_ samples: ArraySlice<Float>, hop: Int, window: Int) -> [Double] {
        guard samples.count >= window else { return [] }
        var cumulative = [Double](repeating: 0, count: samples.count + 1)
        for (i, sample) in samples.enumerated() { cumulative[i + 1] = cumulative[i] + Double(sample) * Double(sample) }
        return stride(from: 0, through: samples.count - window, by: hop).map {
            10 * log10((cumulative[$0 + window] - cumulative[$0]) / Double(window) + 1e-14)
        }
    }

    /// y[n] = x[n] − 0.95·x[n−1]: lifts fricatives above low-frequency room tone.
    static func preEmphasized(_ samples: ArraySlice<Float>) -> ArraySlice<Float> {
        var output = Array(samples), previous: Float = 0
        for i in output.indices {
            let current = output[i]
            output[i] = current - 0.95 * previous
            previous = current
        }
        return output[...]
    }

    static func median(_ values: ArraySlice<Double>) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

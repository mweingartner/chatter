import Foundation

/// Shapes each generated passage's edges so speech starts and ends from true silence, without
/// changing timing or depending on how the passage arrives in chunks. (A whole passage may first be
/// shortened by `trimmingEdgeSilence`; a streamed one cannot be, once it has played.)
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
        /// Only the short raised-cosine edges. `speech`: the passage opened loud, rather than showing
        /// no speech within the look-ahead; `floors` are then that opening's room-tone levels.
        case plain(speech: Bool, floors: (broadband: Double, emphasized: Double)?)
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
    /// `heardSpeech` needs this many consecutive frames that far above the room tone: a rise held for
    /// 55 to 95 ms, depending on where it falls on the 5 ms frame grid. A burst that touches at most 15
    /// frames, such as a click or a blip in a silence loop, is never heard; a spoken vowel is longer.
    static let heardFrames = 16
    /// Each of those frames must also be at least this loud (dBFS), so a passage that opens with
    /// digital silence does not hear faint hiss as speech. Chatter's speech sits 10 to 40 dB above it.
    static let heardLevel = -50.0

    /// Sound, for `trimmingEdgeSilence`, is within this many dB of the passage's loudest frame.
    static let soundRange = 40.0

    private let edgeFrames, hop, window, preRoll, postRoll, lookAhead, tailFrames, leadKeep, trailKeep, attach: Int
    /// 80 ms of quieter frames are bridged, so a stop closure ("st…", "sp…") stays with its word.
    private let bridgeHops = 16
    private var opening = Opening.undecided
    private var pending: [Float] = []
    private var emittedFrames = 0
    /// Once the opening is decided, the whole passage, from its first sample and on the opening's hop
    /// grid, is measured against the opening room tone for `heardSpeech`, so it notices words after the
    /// look-ahead too. Only the flag depends on it; the audio is shaped as before.
    private var heard = false
    private var run = 0
    private var scan: [Float] = [], scanPrevious: Float = 0

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
        leadKeep = frames(0.05)
        trailKeep = frames(0.10)
        attach = frames(0.25)
    }

    public mutating func append(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        if case .undecided = opening {
            guard let decided = decideOpening(final: false) else { return [] }
            opening = decided
            startSpeechScan()
        } else {
            scanForSpeech(samples[...])
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
        if case .undecided = opening { opening = decideOpening(final: true) ?? .plain(speech: false, floors: nil); startSpeechScan() }
        var output = pending
        pending.removeAll(keepingCapacity: true)
        applyOpening(&output, from: emittedFrames)
        if case .roomTone(_, _, let floors) = opening { silenceTrailingRoomTone(&output, floors: floors) }
        for i in output.indices { output[i] *= gain(output.count - 1 - i, length: edgeFrames) }
        emittedFrames += output.count
        return output
    }

    /// Whether the passage has shown sustained speech yet: `heardFrames` consecutive frames 15 dB
    /// above its opening room tone and at least `heardLevel` (broadband or pre-emphasized), anywhere
    /// in it, or a loud opening.
    /// False while the opening is undecided, and for room tone with only clicks or blips. A loud
    /// opening counts as speech even if it is only loud room tone. Levels come from running sums, so a
    /// frame within rounding of the threshold may fall either side depending on how audio arrives.
    public var heardSpeech: Bool {
        switch opening {
        case .undecided: false
        case .plain(true, _): true
        case .plain(false, _), .roomTone: heard
        }
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
        guard broadband.count >= 4 else { return final ? .plain(speech: false, floors: nil) : nil }
        let floors = (broadband: Self.median(broadband.prefix(4)), emphasized: Self.median(emphasized.prefix(4)))
        if floors.broadband > Self.loudOpening { return .plain(speech: true, floors: floors) }
        func rises(_ i: Int, by threshold: Double) -> Bool {
            broadband[i] >= floors.broadband + threshold || emphasized[i] >= floors.emphasized + threshold
        }
        guard let confirmed = broadband.indices.first(where: { rises($0, by: Self.speechConfirm) }) else {
            return final || pending.count >= lookAhead ? .plain(speech: false, floors: floors) : nil
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

    /// Once the opening is decided, nothing has been emitted yet, so `pending` is the whole passage.
    private mutating func startSpeechScan() { scanForSpeech(pending[...]) }

    /// The opening room tone the speech scan measures against; nil when there is nothing to scan.
    private var scanFloors: (broadband: Double, emphasized: Double)? {
        switch opening {
        case .roomTone(_, _, let floors): floors
        case .plain(false, let floors): floors
        case .undecided, .plain(true, _): nil
        }
    }

    private mutating func scanForSpeech(_ samples: ArraySlice<Float>) {
        guard let floors = scanFloors, !heard, !samples.isEmpty else { return }
        scan.append(contentsOf: samples)
        // Measured a look-ahead at a time, so a long append stops measuring once speech is heard.
        var start = 0
        while !heard, scan.count - start >= window {
            let block = scan[start..<min(scan.count, start + lookAhead)]
            let broadband = Self.levels(block, hop: hop, window: window)
            let emphasized = Self.levels(Self.preEmphasized(block, previous: start > 0 ? scan[start - 1] : scanPrevious), hop: hop, window: window)
            let bars = (broadband: max(floors.broadband + Self.speechConfirm, Self.heardLevel), emphasized: max(floors.emphasized + Self.speechConfirm, Self.heardLevel))
            for i in broadband.indices {
                run = broadband[i] >= bars.broadband || emphasized[i] >= bars.emphasized ? run + 1 : 0
                if run >= Self.heardFrames { heard = true; break }
            }
            start += broadband.count * hop
        }
        if heard { scan = []; return }
        // Keep what the next frames still need, at the same hop alignment.
        if start > 0 { scanPrevious = scan[start - 1]; scan.removeFirst(start) }
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

    /// For a whole passage, before `append`: keeps only 50 ms of silence before its first sound and
    /// 100 ms after its last. A cloned voice leads into each passage with 150 to 400 ms of its
    /// recording's room tone and trails off with more, and Qwen sometimes generates seconds of
    /// near-silence at either end (measured 2026-10-26: about 0.5 s between Scar's sentences, up to
    /// 7 s for JARVIS). Sound is a frame at least 6 dB above the opening room tone, broadband or
    /// pre-emphasized as for speech, and within `soundRange` of the passage's loudest broadband frame,
    /// so neither room tone nor a loop of near-digital silence counts. (One scale for both measures:
    /// pre-emphasis lowers a vowel by about 20 dB but not hiss.) The first and last sound belong to a
    /// sustained run of `heardFrames` frames, or lie within 250 ms of one, like a breath before a word
    /// or the release of a final "t", so a blip in a long silence holds nothing in place. A loud
    /// opening has no room tone to measure and uses the range alone. A passage with no frame to
    /// measure, or no sustained sound, is returned whole. No sustained sound, nor any sound within
    /// 250 ms of it, is ever removed; a short burst further out is a blip and may be. The 50 ms kept
    /// before the first sound still holds the four frames the envelope measures its room tone from.
    public func trimmingEdgeSilence(_ samples: [Float]) -> [Float] {
        let broadband = Self.levels(samples[...], hop: hop, window: window)
        let emphasized = Self.levels(Self.preEmphasized(samples[...]), hop: hop, window: window)
        guard broadband.count >= 4, let loudest = broadband.max() else { return samples }
        let floors = (broadband: Self.median(broadband.prefix(4)), emphasized: Self.median(emphasized.prefix(4)))
        let roomTone = floors.broadband <= Self.loudOpening
        let bars = (broadband: max(roomTone ? floors.broadband + Self.speechRise : -.infinity, loudest - Self.soundRange),
                    emphasized: max(roomTone ? floors.emphasized + Self.speechRise : -.infinity, loudest - Self.soundRange))
        let sound = broadband.indices.map { broadband[$0] >= bars.broadband || emphasized[$0] >= bars.emphasized }
        var sustained: [Range<Int>] = [], run: Int?
        for index in 0...sound.count {
            if index < sound.count, sound[index] { if run == nil { run = index }; continue }
            if let begin = run, index - begin >= Self.heardFrames { sustained.append(begin..<index) }
            run = nil
        }
        guard let first = sustained.first, let last = sustained.last else { return samples }
        let reach = attach / hop
        var firstSound = (max(0, first.lowerBound - reach)..<first.lowerBound).first { sound[$0] } ?? first.lowerBound
        var lastSound = (last.upperBound..<min(sound.count, last.upperBound + reach)).last { sound[$0] } ?? (last.upperBound - 1)
        // A burst that straddles the reach is kept whole, so the 50 ms before it is room tone.
        while firstSound > 0, sound[firstSound - 1] { firstSound -= 1 }
        while lastSound < sound.count - 1, sound[lastSound + 1] { lastSound += 1 }
        let start = max(0, firstSound * hop - leadKeep), end = min(samples.count, lastSound * hop + window + trailKeep)
        return start == 0 && end == samples.count ? samples : Array(samples[start..<end])
    }

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
    static func preEmphasized(_ samples: ArraySlice<Float>, previous initial: Float = 0) -> ArraySlice<Float> {
        var output = Array(samples), previous = initial
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

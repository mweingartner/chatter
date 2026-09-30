import Foundation

public struct RecordingMetrics: Codable, Sendable {
    public var duration: Double
    public var peak: Double
    public var rms: Double
    public var clippedFraction: Double
    public var silenceFraction: Double
    public var score: Double
    public var warnings: [String]
}

public struct VoiceSample: Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var transcript: String
    public var originalFileName: String?
    public var metrics: RecordingMetrics
    public var createdAt: Date
    public init(id: String, label: String, transcript: String, metrics: RecordingMetrics) {
        self.id = id; self.label = label; self.transcript = transcript; self.metrics = metrics; createdAt = .now
    }
}

public struct VoiceProfile: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var notes: String
    public var createdAt: Date
    public var samples: [VoiceSample]
    public var selectedSampleID: String?
    public var qwen: QwenVoiceConfiguration?
    public var synthesisConfiguration: QwenVoiceConfiguration { qwen ?? QwenVoiceConfiguration() }
    public var kind: VoiceKind { synthesisConfiguration.kind }
    public var isReady: Bool { kind != .cloned || !referenceSamples.isEmpty }
    // Optional for migration: existing libraries now use all their takes together.
    public var useReferenceSet: Bool?
    public var excludedSampleIDs: [String]?
    public var usesReferenceSet: Bool { useReferenceSet ?? true }
    public var referenceSamples: [VoiceSample] {
        usesReferenceSet ? samples.filter { !(excludedSampleIDs ?? []).contains($0.id) } : selectedSample.map { [$0] } ?? []
    }
    public func references(overriding sampleID: String? = nil) throws -> [VoiceReference] {
        if kind != .cloned {
            guard sampleID == nil else { throw ChatterError.invalid("A single-take override applies only to recorded voices.") }
            return []
        }
        let chosen: [VoiceSample]
        if let sampleID {
            guard let sample = samples.first(where: { $0.id == sampleID }) else { throw ChatterError.invalid("Unknown recording for this voice.") }
            chosen = [sample]
        } else { chosen = referenceSamples }
        guard !chosen.isEmpty else { throw ChatterError.invalid("Enable at least one recording in this voice set before speaking.") }
        return chosen.map { VoiceReference(sampleID: $0.id, transcript: $0.transcript) }
    }
    public init(name: String) {
        id = UUID().uuidString; self.name = name; notes = ""; createdAt = .now; samples = []
    }
    public var selectedSample: VoiceSample? { samples.first { $0.id == selectedSampleID } ?? samples.max { $0.metrics.score < $1.metrics.score } }
    public func sampleDirectory(_ sample: VoiceSample) -> URL { ChatterPaths.voices.appending(path: id).appending(path: sample.id) }
}

/// Frozen when a speech job is accepted, so later edits cannot change queued speech.
public struct VoiceReference: Codable, Sendable, Equatable {
    public var sampleID: String
    public var transcript: String
    public init(sampleID: String, transcript: String) { self.sampleID = sampleID; self.transcript = transcript }
}

// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Accelerate
import Foundation

/// A voice reference ready for synthesis: trimmed, normalized `reference.wav` plus its transcript.
public struct PreparedReference: Codable, Sendable, Equatable {
    /// The words spoken in the recording (trimmed).
    public var transcript: String
    /// Health of the recording as supplied, before trimming and normalization.
    public var metrics: RecordingHealth
    /// Absolute path of the prepared `reference.wav`.
    public var path: String
    /// File name of the preserved original, e.g. `original.m4a`.
    public var originalFileName: String

    public init(transcript: String, metrics: RecordingHealth, path: String, originalFileName: String) {
        self.transcript = transcript
        self.metrics = metrics
        self.path = path
        self.originalFileName = originalFileName
    }
}

/// Turns a user recording into a voice reference (port of the Python worker's `prepare`).
public enum ReferencePreparation {
    /// Accepted recording length in seconds (the speech codec cannot encode more than ~190 s).
    public static let acceptedDuration: ClosedRange<Double> = 3...180
    /// Message reported before on-device transcription starts.
    public static let transcribingMessage = "Transcribing locally…"

    /// Decodes `source`, checks it, transcribes it when `transcript` is blank, then writes into
    /// `destination`: the untouched original (`original.<ext>`), `reference.wav` (edge silence
    /// trimmed, peak-normalized, 24-bit 44.1 kHz) and `transcript.txt` (UTF-8, no trailing newline).
    ///
    /// - Parameters:
    ///   - transcribe: Transcribes 44.1 kHz mono samples; used only when `transcript` is blank.
    ///   - progress: Receives user-facing status messages.
    public static func prepare(source: URL, destination: URL, transcript: String,
                               transcribe: (@Sendable ([Float]) async throws -> String)?,
                               progress: (@Sendable (String) -> Void)?) async throws -> PreparedReference {
        let audio = try AudioIO.readMono(source, sampleRate: 44100, maximumSeconds: acceptedDuration.upperBound)
        let metrics = RecordingHealth.inspect(audio)
        guard acceptedDuration.contains(metrics.duration) else { throw ChatterAudioError.unsupportedDuration }
        guard metrics.rms >= 0.001 else { throw ChatterAudioError.noSpeechLevel }
        var words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty, let transcribe {
            progress?(transcribingMessage)
            words = try await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !words.isEmpty else { throw ChatterAudioError.noTranscript }
        try Task.checkCancellation()

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        let originalFileName = "original" + (pythonSuffix(of: source).lowercased().nilIfEmpty ?? ".audio")
        try AtomicFile.copy(source, to: destination.appendingPathComponent(originalFileName))

        let reference = normalizedPeak(trimmedEdgeSilence(audio, rms: metrics.rms))
        let referenceURL = destination.appendingPathComponent("reference.wav")
        try AudioIO.writePCM24(reference, sampleRate: AudioIO.sampleRate, to: referenceURL)
        try AtomicFile.write(Data(words.utf8), to: destination.appendingPathComponent("transcript.txt"))
        return PreparedReference(transcript: words, metrics: metrics,
                                 path: referenceURL.path(percentEncoded: false), originalFileName: originalFileName)
    }

    /// Removes only leading/trailing silence, preserving internal pauses: finds the first and last
    /// 10 ms frame louder than max(0.004, 6 % of the recording RMS) and keeps 100 ms beyond each.
    static func trimmedEdgeSilence(_ audio: [Float], rms: Double) -> [Float] {
        let bounds = speechBounds(audio, rms: rms)
        return Array(audio[bounds])
    }

    /// The sample range kept by `trimmedEdgeSilence` (the whole signal when no frame is active).
    static func speechBounds(_ audio: [Float], rms: Double) -> Range<Int> {
        let frame = 441, margin = 4410
        let threshold = max(0.004, rms * 0.06)
        let energies = SignalLevel.blockRMS(audio, block: frame)
        guard let first = energies.firstIndex(where: { $0 > threshold }),
              let last = energies.lastIndex(where: { $0 > threshold }) else { return audio.indices }
        return max(0, first * frame - margin)..<min(audio.count, (last + 1) * frame + margin)
    }

    /// Conservative peak normalization (no gate or denoise): gain min(4, 0.89 / peak), applied in
    /// float32 like numpy's `float32_array * python_float`.
    static func normalizedPeak(_ audio: [Float]) -> [Float] {
        guard !audio.isEmpty else { return audio }
        let peak = Double(vDSP.maximumMagnitude(audio))
        guard peak > 0 else { return audio }
        return vDSP.multiply(Float(min(4.0, 0.89 / peak)), audio)
    }

    /// Python's `Path.suffix`: the final `.ext` of the file name, or "" for none or a leading dot.
    static func pythonSuffix(of url: URL) -> String {
        let name = url.lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return ""
        }
        return String(name[dot...])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation

/// Errors surfaced by ChatterAudioKit. `errorDescription` is the user-facing message; the texts for
/// decoding, duration, level and transcript failures match Chatter's former Python worker verbatim.
public enum ChatterAudioError: LocalizedError, Equatable, Sendable {
    /// The recording has no samples, or contains NaN/infinite samples.
    case emptyOrInvalidSamples
    /// The file could not be opened or decoded; carries the underlying reason.
    case undecodable(reason: String)
    /// A reference recording is outside the accepted 3 s – 3 min range.
    case unsupportedDuration
    /// A reference recording is effectively silent (RMS below 0.001).
    case noSpeechLevel
    /// No transcript was supplied and none could be transcribed.
    case noTranscript
    /// Sample-rate conversion to 44.1 kHz failed.
    case resamplingFailed(reason: String)
    /// Samples could not be encoded or the file could not be written.
    case writeFailed(reason: String)
    /// The requested speech pace is not a finite value within 0.5...2.
    case invalidPace(Float)
    /// Offline pace rendering failed.
    case renderingFailed(reason: String)
    /// On-device transcription is unavailable or failed.
    case transcriptionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .emptyOrInvalidSamples: "Recording is empty or contains invalid samples."
        case .undecodable(let reason):
            "Cannot decode this recording. Use WAV, MP3, M4A/AAC, FLAC, AIFF, CAF, or Ogg/Opus audio. " + reason
        case .unsupportedDuration: "Use an audio recording between 3 seconds and 3 minutes long."
        case .noSpeechLevel: "No usable speech level detected in this recording."
        case .noTranscript: "No transcript was detected. Enter the words spoken in the recording."
        case .resamplingFailed(let reason): "Cannot convert this recording to 44.1 kHz. " + reason
        case .writeFailed(let reason): "Cannot write audio. " + reason
        case .invalidPace: "Speech pace must be between 0.5× and 2×."
        case .renderingFailed(let reason): "Cannot change speech pace. " + reason
        case .transcriptionFailed(let reason): "Local transcription failed. " + reason
        }
    }
}

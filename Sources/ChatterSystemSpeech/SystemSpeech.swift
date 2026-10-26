import AppKit
import AVFoundation
import ChatterCore

/// macOS's own voices, used only to start an accented recorded voice (Qwen voice design cannot
/// produce accents). Rendering happens locally; nothing is played or sent anywhere.
///
/// This uses AppKit's synthesizer, not AVSpeechSynthesizer: on macOS 27, AVFoundation neither
/// lists nor resolves downloaded voices (Aman, Tara, every premium voice) in a third-party app, and
/// its `write` delivers an empty buffer between long passages' segments, which looks like the end.
public enum SystemSpeech {
    /// The voices installed on this Mac, including voices people add in System Settings ›
    /// Accessibility › Spoken Content. AVFoundation supplies the novelty trait and quality where it
    /// knows the voice; otherwise quality comes from the identifier. The first call takes about half
    /// a second; views use `SystemVoiceList` to list off the main actor.
    public static func installedVoices() -> [SystemVoiceOption] { AppKitSpeech.installedVoices() }

    /// "Aman" from AppKit's "Aman (English (India))".
    static func displayName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.range(of: " (").map { String(name[..<$0.lowerBound]) } ?? name
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 2 premium, 1 enhanced, 0 otherwise, from identifiers such as "com.apple.voice.Aman.premium".
    static func quality(fromIdentifier identifier: String) -> Int {
        let lowered = identifier.lowercased()
        return lowered.contains("premium") ? 2 : lowered.contains("enhanced") ? 1 : 0
    }

    public enum RenderError: LocalizedError {
        case unknownVoice, noAudio, timedOut
        public var errorDescription: String? {
            switch self {
            case .unknownVoice: "That macOS voice is no longer installed."
            case .noAudio: "The macOS voice produced no audio."
            case .timedOut: "The macOS voice took too long to speak."
            }
        }
    }

    /// Speaks `text` with an installed voice into a new AIFF file at `file`, in a folder only this
    /// process writes. Throws if anything, even a dangling symlink, is already there, or if the
    /// result is not a regular file; on any failure the output is removed.
    @MainActor
    public static func render(_ text: String, voiceIdentifier: String, to file: URL, timeout: Duration = .seconds(60)) async throws {
        // attributesOfItem does not follow symlinks.
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)) == nil else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.path])
        }
        do {
            try await AppKitSpeech.speak(text, voiceIdentifier: voiceIdentifier, to: file, timeout: timeout)
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path])
            }
            guard try AVAudioFile(forReading: file).length > 0 else { throw RenderError.noAudio }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Speaks `text` into mono samples at the voice's own sample rate, through a temporary file.
    @MainActor
    static func render(_ text: String, voiceIdentifier: String, timeout: Duration = .seconds(60)) async throws -> (samples: [Float], sampleRate: Double) {
        let file = FileManager.default.temporaryDirectory.appending(path: "chatter-macos-voice-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        try await AppKitSpeech.speak(text, voiceIdentifier: voiceIdentifier, to: file, timeout: timeout)
        return try readMono(file)
    }

    /// The first channel of an audio file as floats, with its sample rate.
    private static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw RenderError.noAudio }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw RenderError.noAudio }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }
}

/// Lists installed voices off the main actor, one caller at a time: AppKit doesn't document its
/// speech class methods as thread-safe.
public actor SystemVoiceList {
    public static let shared = SystemVoiceList()
    public func installed() -> [SystemVoiceOption] { SystemSpeech.installedVoices() }
}

/// AppKit's synthesizer: deprecated since macOS 14, yet the only macOS API that lists and speaks
/// downloaded voices in a third-party app. Marked deprecated itself so its uses don't each warn.
@available(macOS, deprecated: 14.0, message: "AVSpeechSynthesizer cannot list or speak downloaded voices; see SystemSpeech")
private enum AppKitSpeech {
    static func installedVoices() -> [SystemVoiceOption] {
        NSSpeechSynthesizer.availableVoices.compactMap { voice in
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
            guard let locale = attributes[.localeIdentifier] as? String, !locale.isEmpty else { return nil }
            let known = AVSpeechSynthesisVoice(identifier: voice.rawValue)
            let gender = attributes[.gender] as? String
            return SystemVoiceOption(
                id: voice.rawValue,
                name: known?.name ?? SystemSpeech.displayName(attributes[.name] as? String) ?? voice.rawValue,
                language: locale.replacingOccurrences(of: "_", with: "-"),
                gender: gender == NSSpeechSynthesizer.VoiceGender.male.rawValue ? .male
                    : gender == NSSpeechSynthesizer.VoiceGender.female.rawValue ? .female : nil,
                quality: known.map { $0.quality == .premium ? 2 : $0.quality == .enhanced ? 1 : 0 } ?? SystemSpeech.quality(fromIdentifier: voice.rawValue),
                isNovelty: known?.voiceTraits.contains(.isNoveltyVoice) ?? false)
        }
    }

    /// Writes `text` spoken by the voice to an AIFF file, returning once the synthesizer finishes.
    @MainActor
    static func speak(_ text: String, voiceIdentifier: String, to file: URL, timeout: Duration) async throws {
        let name = NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier)
        guard NSSpeechSynthesizer.availableVoices.contains(name), let synthesizer = NSSpeechSynthesizer(voice: name) else {
            throw SystemSpeech.RenderError.unknownVoice
        }
        let finish = Finish()
        synthesizer.delegate = finish
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finish.continuation = continuation
                guard synthesizer.startSpeaking(text, to: file) else {
                    finish.complete(.failure(SystemSpeech.RenderError.noAudio))
                    return
                }
                timer = Task { @MainActor in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    if finish.complete(.failure(SystemSpeech.RenderError.timedOut)) { synthesizer.stopSpeaking() }
                }
            }
        } catch SystemSpeech.RenderError.timedOut {
            // Stopping is asynchronous. Keep the synthesizer until the speech service has stopped
            // (at most 2 s), so the next render does not start behind an abandoned one: on GitHub's
            // runner a render straight after a timed-out one hung for its whole 60 s.
            for _ in 0..<100 where synthesizer.isSpeaking { try? await Task.sleep(for: .milliseconds(20)) }
            throw SystemSpeech.RenderError.timedOut
        }
    }

    /// Resumes the render exactly once: when the synthesizer finishes, fails to start, or times out.
    private final class Finish: NSObject, NSSpeechSynthesizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?

        func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
            complete(finishedSpeaking ? .success(()) : .failure(SystemSpeech.RenderError.noAudio))
        }

        /// Whether this call was the one that resumed the render.
        @discardableResult
        func complete(_ result: Result<Void, Error>) -> Bool {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
    }
}

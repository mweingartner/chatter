// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import AVFoundation
import Foundation
import os
import Speech

/// On-device transcription with SpeechAnalyzer + SpeechTranscriber (replaces mlx-whisper).
public actor LocalTranscriber {
    /// Used when the current locale has no on-device transcriber.
    public static let fallbackLocale = Locale(identifier: "en-US")
    private static let logger = Logger(subsystem: "ChatterAudioKit", category: "LocalTranscriber")

    private let preferredLocale: Locale?
    private let installsMissingAssets: Bool

    /// - Parameters:
    ///   - locale: Transcription locale; `nil` picks `Locale.current` when supported, else en-US.
    ///   - installsMissingAssets: Download the speech model when it is not installed. When `false`,
    ///     a missing model is reported as an error instead.
    public init(locale: Locale? = nil, installsMissingAssets: Bool = true) {
        self.preferredLocale = locale
        self.installsMissingAssets = installsMissingAssets
    }

    /// Whether the on-device model for `locale` is installed (matched by BCP-47 identifier).
    public static func isInstalled(_ locale: Locale) async -> Bool {
        let identifier = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == identifier }
    }

    /// `Locale.current` if SpeechTranscriber supports it, otherwise en-US.
    public static func defaultLocale() async -> Locale {
        let current = Locale.current.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == current } ? Locale.current : fallbackLocale
    }

    /// Transcribes mono samples and returns the concatenated final results, trimmed.
    public func transcribe(_ samples: [Float], sampleRate: Double = 44100) async throws -> String {
        let locale: Locale
        if let preferredLocale { locale = preferredLocale } else { locale = await Self.defaultLocale() }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [])
        try await ensureAssets(for: transcriber, locale: locale)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatter-transcribe-\(UUID().uuidString).wav")
        defer {
            do {
                try FileManager.default.removeItem(at: temporary)
            } catch {
                Self.logger.error("Cannot remove temporary transcription audio: \(error.localizedDescription, privacy: .public)")
            }
        }
        try AudioIO.writePCM24(samples, sampleRate: sampleRate, to: temporary)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: temporary)
        } catch {
            throw ChatterAudioError.transcriptionFailed(reason: error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text = Self.finalText(of: transcriber)
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            // Finishing the analyzer ends the results stream so the pending reader can complete.
            await analyzer.cancelAndFinishNow()
            _ = try? await text  // Drain the reader; the analyzer error below is the one to report.
            throw ChatterAudioError.transcriptionFailed(reason: error.localizedDescription)
        }
        do {
            return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ChatterAudioError.transcriptionFailed(reason: error.localizedDescription)
        }
    }

    /// Concatenates the final (non-volatile) results until the analyzer finishes.
    private static func finalText(of transcriber: SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }

    /// Makes sure the on-device model for `locale` is present, downloading it when allowed.
    private func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let identifier = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == identifier }) else {
            throw ChatterAudioError.transcriptionFailed(reason: "On-device transcription does not support \(identifier).")
        }
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw ChatterAudioError.transcriptionFailed(
                reason: "Cannot check the speech model for \(identifier): \(error.localizedDescription)")
        }
        guard let request else { return }
        guard installsMissingAssets else {
            throw ChatterAudioError.transcriptionFailed(reason: "The speech model for \(identifier) is not installed.")
        }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw ChatterAudioError.transcriptionFailed(
                reason: "Cannot download the speech model for \(identifier): \(error.localizedDescription)")
        }
    }
}

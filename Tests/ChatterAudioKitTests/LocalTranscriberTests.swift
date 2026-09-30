// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Local transcription")
struct LocalTranscriberTests {
    static let english = Locale(identifier: "en-US")
    // Optional private fixture: no user's speech recording is distributed with the tests.
    static var recording: URL? {
        ProcessInfo.processInfo.environment["CHATTER_TEST_RECORDING"].map { URL(filePath: $0) }
    }

    /// Runs only when the en-US model is already installed; the transcriber is told never to download.
    @Test("Transcribes a real recording on device",
          .enabled("en-US speech assets are installed and the recording exists") {
              guard let recording, FileManager.default.fileExists(atPath: recording.path(percentEncoded: false)) else { return false }
              return await LocalTranscriber.isInstalled(english)
          },
          .timeLimit(.minutes(1)))
    func transcribesRecording() async throws {
        let recording = try #require(Self.recording)
        let samples = try AudioIO.readMono44k(recording)
        let text = try await LocalTranscriber(locale: Self.english, installsMissingAssets: false).transcribe(samples)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let expected = ProcessInfo.processInfo.environment["CHATTER_TEST_TRANSCRIPT"] {
            #expect(text.contains(expected), "\(text)")
        }
    }

    @Test("Default locale is the current one when supported, else en-US")
    func defaultLocale() async {
        let locale = await LocalTranscriber.defaultLocale()
        #expect(locale == Locale.current || locale == LocalTranscriber.fallbackLocale)
    }
}

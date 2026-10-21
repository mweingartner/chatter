@testable import ChatterSystemSpeech
import ChatterCore
import Foundation
import Testing

@Suite(.serialized) @MainActor struct SystemSpeechTests {
    /// An ordinary English voice; every Mac has at least one.
    static func englishVoice() throws -> SystemVoiceOption {
        try #require(SystemSpeech.installedVoices().first { $0.language.hasPrefix("en") && !$0.isNovelty && !$0.id.contains(".eloquence.") })
    }

    @Test func installedVoicesHaveIdentifiersAndLanguages() {
        let voices = SystemSpeech.installedVoices()
        #expect(!voices.isEmpty)
        for voice in voices {
            #expect(!voice.id.isEmpty && !voice.language.isEmpty && (0...2).contains(voice.quality))
            #expect(!voice.language.contains("_"), "languages are BCP 47, like en-IN")
        }
    }

    @Test func voicesCanBeListedOffTheMainActor() async {
        let voices = await Task.detached { SystemSpeech.installedVoices() }.value
        #expect(voices.map(\.id) == SystemSpeech.installedVoices().map(\.id))
    }

    @Test func appKitNamesLoseTheirLanguageSuffix() {
        #expect(SystemSpeech.displayName("Aman (English (India))") == "Aman")
        #expect(SystemSpeech.displayName("Bad News") == "Bad News")
        #expect(SystemSpeech.displayName(" (English)") == nil)
        #expect(SystemSpeech.displayName(nil) == nil)
        #expect(!SystemSpeech.installedVoices().contains { $0.name.contains("(") })
    }

    @Test func qualityComesFromTheIdentifierWhenAVFoundationDoesNotKnowTheVoice() {
        #expect(SystemSpeech.quality(fromIdentifier: "com.apple.voice.Aman.premium") == 2)
        #expect(SystemSpeech.quality(fromIdentifier: "com.apple.voice.premium.en-US.Zoe") == 2)
        #expect(SystemSpeech.quality(fromIdentifier: "com.apple.voice.enhanced.en-GB.Daniel") == 1)
        #expect(SystemSpeech.quality(fromIdentifier: "com.apple.voice.Aman") == 0)
        #expect(SystemSpeech.quality(fromIdentifier: "com.apple.voice.compact.en-IN.Rishi") == 0)
    }

    @Test func aMacOSVoiceRendersSpeech() async throws {
        let rendered = try await SystemSpeech.render("Hello, this is a short test.", voiceIdentifier: Self.englishVoice().id)
        #expect(rendered.sampleRate >= 8_000)
        let seconds = Double(rendered.samples.count) / rendered.sampleRate
        #expect((0.5...10).contains(seconds))
        #expect(rendered.samples.allSatisfy { $0.isFinite })
        #expect(rendered.samples.contains { abs($0) > 0.01 })
    }

    /// AVSpeechSynthesizer stopped this passage halfway (an empty buffer between segments); the
    /// transcript then described audio that wasn't there.
    @Test func theWholeReferencePassageIsSpoken() async throws {
        let passage = VoiceAccents.referencePassage
        let rendered = try await SystemSpeech.render(passage, voiceIdentifier: Self.englishVoice().id)
        let seconds = Double(rendered.samples.count) / rendered.sampleRate
        let words = Double(passage.split(separator: " ").count)
        #expect(seconds >= words / 5, "\(Int(words)) words in \(seconds) s: the passage was cut short")
        let tail = rendered.samples.suffix(Int(rendered.sampleRate * seconds / 4))
        #expect(tail.contains { abs($0) > 0.01 }, "the last quarter is silent")
    }

    /// The app's path: a new AIFF in a folder it owns. An existing file is never overwritten, and a
    /// failed render leaves no file behind.
    @Test func rendersIntoANewFileAndCleansUpAfterFailures() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chatter-system-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let voice = try Self.englishVoice()

        let file = folder.appending(path: "voice.aiff")
        try await SystemSpeech.render("A short sentence.", voiceIdentifier: voice.id, to: file)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size > 1_000)

        await #expect(throws: CocoaError.self) {
            try await SystemSpeech.render("Overwrite it.", voiceIdentifier: voice.id, to: file)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == size, "the existing file changed")

        let unknown = folder.appending(path: "unknown.aiff")
        await #expect(throws: SystemSpeech.RenderError.unknownVoice) {
            try await SystemSpeech.render("Hello.", voiceIdentifier: "com.example.not-a-voice", to: unknown)
        }
        let late = folder.appending(path: "late.aiff")
        await #expect(throws: SystemSpeech.RenderError.timedOut) {
            try await SystemSpeech.render(VoiceAccents.referencePassage, voiceIdentifier: voice.id, to: late, timeout: .milliseconds(1))
        }
        #expect(!FileManager.default.fileExists(atPath: unknown.path) && !FileManager.default.fileExists(atPath: late.path))
    }

    @Test func voicesListThroughTheSharedActorMatchTheDirectList() async {
        let listed = await SystemVoiceList.shared.installed()
        #expect(listed.map(\.id) == SystemSpeech.installedVoices().map(\.id))
    }

    @Test func anUnknownVoiceIsReported() async {
        do {
            _ = try await SystemSpeech.render("Hello.", voiceIdentifier: "com.example.not-a-voice")
            Issue.record("an unknown voice rendered")
        } catch {
            #expect(error as? SystemSpeech.RenderError == .unknownVoice)
        }
    }
}

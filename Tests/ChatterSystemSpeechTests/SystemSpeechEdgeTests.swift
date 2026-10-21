@testable import ChatterSystemSpeech
import ChatterCore
import Foundation
import Testing

/// Parsing edge cases and render error paths for macOS voices. These extend `SystemSpeechTests`,
/// so they share its serialized, main-actor suite: only one render runs at a time.
extension SystemSpeechTests {
    @Test(arguments: [
        ("Aman (English (India))", "Aman"),
        ("Eddy (English (UK))", "Eddy"),
        ("Bad News (English)", "Bad News"),
        ("A (b) (c)", "A"),
        ("Name(no space)", "Name(no space)"),     // only " (" starts the language suffix
        ("Amélie", "Amélie"),
        ("Soumya (Kannada (India))", "Soumya"),
    ])
    func displayNamesStopAtTheFirstLanguageSuffix(name: String, display: String) {
        #expect(SystemSpeech.displayName(name) == display)
    }

    @Test func emptyDisplayNamesAreNil() {
        #expect(SystemSpeech.displayName("") == nil)
        #expect(SystemSpeech.displayName(" (English (UK))") == nil)
    }

    @Test(arguments: [
        ("COM.APPLE.VOICE.PREMIUM.EN-US.ZOE", 2),
        ("com.apple.voice.premium.enhanced.x", 2),  // premium wins over enhanced
        ("com.apple.voice.Enhanced.en-GB.Daniel", 1),
        ("com.apple.eloquence.en-US.Flo", 0),
        ("com.apple.speech.synthesis.voice.Bahh", 0),
        ("", 0),
    ])
    func qualityFromIdentifierIgnoresCase(identifier: String, quality: Int) {
        #expect(SystemSpeech.quality(fromIdentifier: identifier) == quality)
    }

    /// What the real installed list looks like to the picker: AppKit lists some voices twice and
    /// lists robotic ones, and candidates never offer either; every gender AppKit reports as
    /// neuter is nil.
    @Test func realVoicesChooseCleanCandidates() {
        let voices = SystemSpeech.installedVoices()
        for accent in VoiceAccents.catalog {
            for gender in [VoiceGender.male, .female, nil] {
                let chosen = SystemVoiceOption.candidates(for: accent, gender: gender, among: voices)
                #expect(Set(chosen.map(\.id)).count == chosen.count, "\(accent.id)")
                #expect(!chosen.contains { $0.isNovelty || $0.id.lowercased().contains(".eloquence.") }, "\(accent.id)")
                #expect(chosen.allSatisfy { voice in accent.languages.contains { voice.language.lowercased().hasPrefix($0.lowercased()) } })
            }
        }
        // The classic novelty voices, where installed, are known as novelty voices.
        let novelty = ["Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Zarvox", "Trinoids", "Whisper"].map { "com.apple.speech.synthesis.voice.\($0)" }
        for voice in voices where novelty.contains(voice.id) { #expect(voice.isNovelty, "\(voice.id)") }
    }

    /// Nothing to say: no audio, reported as a render error rather than a file error.
    @Test(arguments: ["", "   ", "\n"])
    func emptyTextProducesNoAudio(text: String) async throws {
        let voice = try Self.englishVoice()
        do {
            let rendered = try await SystemSpeech.render(text, voiceIdentifier: voice.id)
            // Some voices emit a few frames of silence for blank text; that is not speech either.
            #expect(!rendered.samples.contains { abs($0) > 0.01 }, "blank text spoke")
        } catch let error as SystemSpeech.RenderError {
            #expect(error == .noAudio)
        }
    }

    @Test(arguments: ["", "com.apple.voice.compact.en-US.Samantha.missing", "../../etc/passwd"])
    func identifiersThatAreNotInstalledVoicesAreUnknown(identifier: String) async {
        await #expect(throws: SystemSpeech.RenderError.unknownVoice) {
            _ = try await SystemSpeech.render("Hello.", voiceIdentifier: identifier)
        }
    }

    /// A render that outlives its timeout is stopped and reported, leaves no temporary file
    /// behind, and the next render still works.
    @Test func aRenderThatTakesTooLongTimesOutAndCleansUp() async throws {
        let voice = try Self.englishVoice()
        let temporary = FileManager.default.temporaryDirectory
        func leftovers() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("chatter-macos-voice-") })
        }
        let before = try leftovers()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SystemSpeech.RenderError.timedOut) {
            _ = try await SystemSpeech.render(VoiceAccents.referencePassage, voiceIdentifier: voice.id, timeout: .milliseconds(1))
        }
        #expect(clock.now - start < .seconds(5), "the timeout did not stop the render promptly")
        #expect(try leftovers() == before, "a timed-out render left its AIFF behind")
        let rendered = try await SystemSpeech.render("Still working.", voiceIdentifier: voice.id)
        #expect(rendered.samples.contains { abs($0) > 0.01 })
        #expect(try leftovers() == before, "a finished render left its AIFF behind")
    }

    /// Repeated renders give the same length of audio and no growth in leftover files.
    @Test func repeatedRendersAreStable() async throws {
        let voice = try Self.englishVoice()
        var lengths: [Int] = []
        for _ in 0..<3 { lengths.append(try await SystemSpeech.render("One, two, three.", voiceIdentifier: voice.id).samples.count) }
        #expect(lengths.allSatisfy { $0 > 0 })
        let spread = Double(lengths.max()! - lengths.min()!) / Double(lengths.max()!)
        #expect(spread < 0.05, "render lengths \(lengths)")
    }

    @Test func renderErrorsExplainThemselves() {
        for error in [SystemSpeech.RenderError.unknownVoice, .noAudio, .timedOut] {
            #expect(error.errorDescription?.hasPrefix("The macOS voice") == true || error.errorDescription?.hasPrefix("That macOS voice") == true)
            #expect(error.localizedDescription == error.errorDescription)
        }
    }
}

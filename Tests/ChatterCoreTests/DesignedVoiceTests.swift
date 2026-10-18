import ChatterCore
import Testing

struct DesignedVoiceTests {
    /// A designed voice is drawn from its description each passage: the VoiceDesign model's
    /// published settings keep it consistent. Other kinds keep Chatter's steadier sampling.
    @Test func designedVoicesUseTheVoiceDesignReferenceSettings() {
        #expect(QwenGeneration.settings(for: .designed) == QwenGeneration(temperature: 0.9, topP: 1.0, topK: 50, wholeTextFirst: true))
        for kind in [VoiceKind.cloned, .preset] {
            #expect(QwenGeneration.settings(for: kind) == QwenGeneration(temperature: 0.7, topP: 0.8, topK: 50, wholeTextFirst: false))
        }
    }

    @Test(arguments: [
        ("A warm, clear adult male voice with a slight Indian accent.", true),
        ("Speaks with a heavy ACCENT", true),
        ("Accent: Scottish.", true),
        ("Regional accents from the north", true),
        ("Lightly accented English", true),
        ("Accentuated pauses between ideas", false),
        ("A deep, gravelly narrator voice", false),
        ("", false),
    ])
    func accentRequestsAreRecognised(description: String, expected: Bool) {
        #expect(QwenCapabilities.describesAccent(description) == expected)
    }

    @Test func aDesignedAccentIsWarnedAboutInTheReceipt() throws {
        let request = SpeechRequest(voice: "Arvind", text: "Hello.")
        let accented = QwenVoiceConfiguration(kind: .designed, description: "Adult male with a slight Indian accent.", language: "English")
        #expect(QwenCapabilities.warnings(configuration: accented, request: request) == [QwenCapabilities.designAccentNotice])
        let plain = QwenVoiceConfiguration(kind: .designed, description: "Adult male, mature delivery.", language: "English")
        #expect(QwenCapabilities.warnings(configuration: plain, request: request).isEmpty)
        #expect(QwenCapabilities.describesAccent(nil) == false)
        // Recorded voices keep their own notice; an accent there comes from the recording.
        var toned = request; toned.tone = "optimistic"
        #expect(QwenCapabilities.warnings(configuration: QwenVoiceConfiguration(kind: .cloned), request: toned) == [QwenCapabilities.cloneDeliveryNotice])
    }

    @Test func toneCuesUseTheRightArticle() {
        #expect(SpeechTone.optimistic.cue.hasPrefix("Speak with an optimistic delivery."))
        #expect(SpeechTone.excited.cue.hasPrefix("Speak with an excited delivery."))
        #expect(SpeechTone.warm.cue.hasPrefix("Speak with a warm delivery."))
        #expect(SpeechTone.natural.cue.isEmpty)
    }
}

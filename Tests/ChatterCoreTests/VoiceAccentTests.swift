import ChatterCore
import Testing

struct VoiceAccentTests {
    @Test(arguments: [
        ("A warm, clear adult male voice with a slight Indian accent.", "indian"),
        ("Speaks English with a Mumbai accent", "indian"),
        ("A Scottish accent from Glasgow", "scottish"),
        ("A soft Irish accent", "irish"),
        ("A London accent, slightly posh", "british"),
        ("Received Pronunciation accent, very proper", "british"),
        ("An Aussie accent from Sydney", "australian"),
        ("A South African accent", "south-african"),
        ("Speaks Indian English, warm and mature", "indian"),
        ("A regional dialect from Edinburgh", "scottish"),
    ])
    func requestedAccentsAreRecognised(description: String, accent: String) {
        #expect(VoiceAccents.requested(in: description)?.id == accent)
    }

    @Test(arguments: [
        "A deep, gravelly narrator voice",
        "A French accent",                        // asked for, but no macOS English voice carries it
        "A man from India",                       // no accent asked for
        "Indianapolis sports announcer with an accent",
    ])
    func noCatalogAccentForTheseDescriptions(description: String) {
        #expect(VoiceAccents.requested(in: description) == nil)
    }

    @Test func dialectsAndNamedVarietiesCountAsAccentRequests() {
        #expect(QwenCapabilities.describesAccent("A Sichuan dialect"))
        #expect(QwenCapabilities.describesAccent("Speaks British English"))
        #expect(!QwenCapabilities.describesAccent("Speaks English clearly"))
    }

    @Test(arguments: [
        ("A warm adult male voice", VoiceGender.male),
        ("An elderly woman, gentle", .female),
        ("She speaks softly", .female),
        ("A baritone narrator", .male),
        ("A voice for him and her", nil),
        ("A calm, neutral voice", nil),
    ] as [(String, VoiceGender?)])
    func genderIsReadFromTheDescription(description: String, gender: VoiceGender?) {
        #expect(VoiceGender.requested(in: description) == gender)
    }

    static let indian = VoiceAccents.catalog.first { $0.id == "indian" }!
    static let british = VoiceAccents.catalog.first { $0.id == "british" }!
    static let installed = [
        SystemVoiceOption(id: "com.apple.voice.compact.en-IN.Rishi", name: "Rishi", language: "en-IN", gender: .male, quality: 0),
        SystemVoiceOption(id: "com.apple.voice.enhanced.en-IN.Aman", name: "Aman", language: "en-IN", gender: .male, quality: 1),
        SystemVoiceOption(id: "com.apple.voice.enhanced.en-IN.Tara", name: "Tara", language: "en-IN", gender: .female, quality: 1),
        SystemVoiceOption(id: "com.apple.eloquence.en-IN.Eddy", name: "Eddy", language: "en-IN", gender: nil, quality: 0),
        SystemVoiceOption(id: "com.apple.speech.synthesis.voice.Bahh", name: "Bahh", language: "en-IN", gender: nil, quality: 0, isNovelty: true),
        SystemVoiceOption(id: "com.apple.voice.compact.en-GB.Daniel", name: "Daniel", language: "en-GB", gender: .male, quality: 0),
        SystemVoiceOption(id: "com.apple.voice.compact.en-GB-u-sd-gbsct.Fiona", name: "Fiona", language: "en-GB-u-sd-gbsct", gender: .female, quality: 0),
        SystemVoiceOption(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", gender: .female, quality: 0),
    ]

    @Test func theRequestedGenderAndHigherQualityComeFirst() {
        #expect(SystemVoiceOption.candidates(for: Self.indian, gender: .male, among: Self.installed).map(\.name) == ["Aman", "Rishi", "Tara"])
        #expect(SystemVoiceOption.candidates(for: Self.indian, gender: .female, among: Self.installed).map(\.name) == ["Tara", "Aman", "Rishi"])
        #expect(SystemVoiceOption.candidates(for: Self.indian, gender: nil, among: Self.installed).map(\.name) == ["Aman", "Tara", "Rishi"])
    }

    @Test func noveltyEloquenceDuplicatesAndOtherAccentsAreNeverOffered() {
        let superCompact = SystemVoiceOption(id: "com.apple.voice.super-compact.en-IN.Rishi", name: "Rishi", language: "en-IN", gender: .male, quality: 0)
        let doubled = Self.installed + Self.installed + [superCompact]
        let indian = SystemVoiceOption.candidates(for: Self.indian, gender: nil, among: doubled)
        #expect(indian.count == 3 && Set(indian.map(\.id)).count == 3)
        #expect(!indian.contains(superCompact))
        #expect(!indian.contains { $0.name == "Eddy" || $0.name == "Bahh" || $0.name == "Samantha" })
        // Scottish voices share the en-GB prefix but are not offered for a British request.
        #expect(SystemVoiceOption.candidates(for: Self.british, gender: nil, among: Self.installed).map(\.name) == ["Daniel"])
        let scottish = VoiceAccents.catalog.first { $0.id == "scottish" }!
        #expect(SystemVoiceOption.candidates(for: scottish, gender: nil, among: Self.installed).map(\.name) == ["Fiona"])
        #expect(SystemVoiceOption.candidates(for: Self.indian, gender: .male, among: []).isEmpty)
    }

    @Test func pickerTitlesNameTheQuality() {
        #expect(SystemVoiceOption(id: "a", name: "Aman", language: "en-IN", gender: .male, quality: 1).title == "Aman (enhanced)")
        #expect(SystemVoiceOption(id: "b", name: "Ava", language: "en-US", gender: .female, quality: 2).title == "Ava (premium)")
        #expect(SystemVoiceOption(id: "c", name: "Rishi", language: "en-IN", gender: .male, quality: 0).title == "Rishi")
    }

    /// The reference passage is the voice's exact transcript and must fit Qwen's ideal 10–30 s.
    @Test func theReferencePassageIsAFocusedTake() {
        let words = VoiceAccents.referencePassage.split(separator: " ").count
        #expect((45...90).contains(words))
        #expect(!VoiceAccents.referencePassage.contains("<|"))
    }
}

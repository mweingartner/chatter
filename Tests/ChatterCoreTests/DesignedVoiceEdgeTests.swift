import Foundation
import Testing
@testable import ChatterCore

/// Edge cases, seeded properties and budgets for designed-voice sampling, the accent notice and the
/// tone cue's article. Every generator is seeded, so a failure names its seed and input.
struct DesignedVoiceEdgeTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    // MARK: Recognising an accent request

    /// Punctuation, hyphenation, case and Unicode around the word. A word boundary on each side is
    /// what decides: "accent" inside another word ("accentuated", "unaccented") is not a request.
    @Test(arguments: [
        ("Accents?", true),
        ("(accent)", true),
        ("“accent”", true),
        ("«accent»", true),
        ("accent.", true),
        ("accent’s warmth", true),
        ("Mid-Atlantic-accented delivery", true),
        ("British-accent, mature", true),
        ("AcCeNtEd English", true),
        ("line one\naccent\nline three", true),
        ("\u{A0}accent\u{A0}", true),
        ("tab\taccent\tseparated", true),
        ("中文accent中文", false), // CJK ideographs are word characters: no boundary either side.
        ("😀accent😀", true),
        ("avec un léger accent indien", true), // French spells it the same way.
        ("accentuated pauses", false),
        ("accentual rhythm", false),
        ("unaccented English", false),
        ("accenting each beat", false),
        ("accent_heavy", false),
        ("accent2", false),
        ("accenté", false),
        ("accen t", false),
        ("a c c e n t", false),
        ("   ", false),
    ])
    func accentWordBoundaries(description: String, expected: Bool) {
        #expect(QwenCapabilities.describesAccent(description) == expected, "\(description.debugDescription)")
    }

    /// Asking for no accent still names one, so the notice still shows. That is the conservative
    /// side to err on: the notice is advice, and a neutral American voice is what the model gives.
    @Test(arguments: ["non-accented English", "accent-free, neutral American", "no accent at all", "without an accent"])
    func negatedAccentRequestsStillShowTheNotice(description: String) {
        #expect(QwenCapabilities.describesAccent(description))
    }

    /// Detection is by the English (and French) word only. Descriptions written in the other
    /// supported languages get no notice; this pins that scope so a change to it is deliberate.
    @Test(arguments: ["带有轻微印度口音的成年男性", "Erwachsener Mann mit leichtem indischen Akzent", "Hombre adulto con acento indio",
                      "Uomo adulto con un leggero accento indiano", "Взрослый мужчина с лёгким индийским акцентом", "インド訛りの大人の男性"])
    func otherLanguagesAreOutsideTheDetector(description: String) {
        #expect(!QwenCapabilities.describesAccent(description))
    }

    // MARK: Budget

    /// The setup view calls this on every keystroke, and its TextEditor is not capped at the
    /// 2,000-byte save limit. A megabyte of text, including near-miss prefixes that make a regex
    /// backtrack, must stay well inside a frame budget per call when repeated.
    @Test func detectionIsLinearOnVeryLongDescriptions() {
        let nearMisses = String(repeating: "accen accentu xaccent ", count: 50_000) // ~1.1 MB, no match
        let late = String(repeating: "warm mature voice ", count: 60_000) + "slight accent"
        let clock = ContinuousClock()
        var results: [Bool] = []
        let elapsed = clock.measure {
            for _ in 0..<3 { results.append(QwenCapabilities.describesAccent(nearMisses)); results.append(QwenCapabilities.describesAccent(late)) }
        }
        #expect(results == [false, true, false, true, false, true])
        #expect(elapsed < .seconds(3), "six scans of ~1 MB took \(elapsed)")
        // The realistic case, a description at the 2,000-byte save limit, is far below a millisecond.
        let saved = String(repeating: "warm mature ", count: 166)
        let small = clock.measure { for _ in 0..<1_000 { _ = QwenCapabilities.describesAccent(saved) } }
        #expect(small < .seconds(1), "1,000 scans of 2 KB took \(small)")
    }

    // MARK: Seeded properties

    static let pieces = ["warm", " ", "mature", ", ", ".", "-", "\n", "voice", "é", "中文", "😀", "accentuated", "un", "x", "_", "2",
                         "(", ")", "’", "\u{A0}", "deep", "Indian", "slight", "accen", "t", "ed", "s"]

    static func description(_ rng: inout Seeded) -> String {
        (0..<Int.random(in: 0...30, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    /// Reference oracle: lowercase ASCII-letter runs plus the other word characters that occur in the
    /// pieces, tokenised by hand, then compared against "accent", "accents" and "accented".
    static func oracle(_ text: String) -> Bool {
        var words: [String] = [], current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" { current.append(ch) } else { words.append(current); current = "" }
        }
        words.append(current)
        return words.contains { ["accent", "accents", "accented"].contains($0) }
    }

    /// Property and metamorphic relations over generated descriptions: agrees with a hand-written
    /// tokeniser; deterministic; case-insensitive; adding a separated "accent" always turns it on;
    /// and joining two descriptions with a space is an OR.
    @Test func describesAccentAgreesWithAWordOracle() {
        for seed in UInt64(1)...1_500 {
            var rng = Seeded(state: seed)
            let a = Self.description(&rng), b = Self.description(&rng)
            let found = QwenCapabilities.describesAccent(a)
            #expect(found == Self.oracle(a), "seed \(seed): \(a.debugDescription)")
            #expect(QwenCapabilities.describesAccent(a) == found, "seed \(seed) not deterministic")
            #expect(QwenCapabilities.describesAccent(a.uppercased()) == found, "seed \(seed): \(a.debugDescription)")
            #expect(QwenCapabilities.describesAccent(a + " accent"), "seed \(seed): \(a.debugDescription)")
            #expect(QwenCapabilities.describesAccent("Accented " + a), "seed \(seed): \(a.debugDescription)")
            #expect(QwenCapabilities.describesAccent(a + " " + b) == (found || QwenCapabilities.describesAccent(b)),
                    "seed \(seed): \(a.debugDescription) + \(b.debugDescription)")
        }
    }

    // MARK: Receipt warnings

    static let accented = "Adult male of Indian origin with a slight accent and mature delivery."
    static let plain = "Adult male, mature delivery."

    /// Every voice kind, with and without accent text, across every tone: the cloned-delivery notice
    /// only for a recorded voice given a tone, the accent notice only for a designed voice whose
    /// description asks for one, never both, never duplicated, and in a stable order.
    @Test func warningsForEveryKindDescriptionAndTone() {
        for kind in VoiceKind.allCases {
            for description in [nil, "", Self.plain, Self.accented, "  \(Self.accented)  "] as [String?] {
                for tone in [String?]([nil]) + SpeechTone.allCases.map { Optional($0.rawValue) } {
                    let configuration = QwenVoiceConfiguration(kind: kind, description: description, language: "English")
                    let request = SpeechRequest(voice: "v", text: "Hello.", tone: tone)
                    var expected: [String] = []
                    if kind == .cloned, let tone, tone != "natural" { expected.append(QwenCapabilities.cloneDeliveryNotice) }
                    if kind == .designed, description?.contains("accent") == true { expected.append(QwenCapabilities.designAccentNotice) }
                    let warnings = QwenCapabilities.warnings(configuration: configuration, request: request)
                    #expect(warnings == expected, "\(kind) \(description.debugDescription) \(tone ?? "nil")")
                    #expect(Set(warnings).count == warnings.count)
                    #expect(QwenCapabilities.warnings(configuration: configuration, request: request) == warnings)
                }
            }
        }
    }

    /// A built-in speaker never carries the accent notice, even if a description lingers on it from
    /// an earlier kind; a recorded voice's accent comes from its recording, so it never does either.
    @Test func onlyDesignedVoicesAreJudgedOnTheirDescription() throws {
        let request = SpeechRequest(voice: "v", text: "Hello.")
        let preset = try QwenVoiceConfiguration(kind: .preset, speaker: "aiden", description: Self.accented).validated()
        #expect(QwenCapabilities.warnings(configuration: preset, request: request).isEmpty)
        #expect(QwenCapabilities.warnings(configuration: QwenVoiceConfiguration(kind: .cloned, description: Self.accented), request: request).isEmpty)
        // A designed voice saved through validation (trimmed) still warns.
        let designed = try QwenVoiceConfiguration(kind: .designed, description: "\n  \(Self.accented)\t").validated()
        #expect(QwenCapabilities.warnings(configuration: designed, request: request) == [QwenCapabilities.designAccentNotice])
        // An invalid tone in an unvalidated request is treated as natural, not as a tone.
        let unknown = SpeechRequest(voice: "v", text: "Hello.", tone: "invented")
        #expect(QwenCapabilities.warnings(configuration: QwenVoiceConfiguration(kind: .cloned), request: unknown).isEmpty)
    }

    /// The warning travels with the job: it survives the receipt's JSON round trip intact.
    @Test func accentNoticeSurvivesTheReceiptRoundTrip() throws {
        let configuration = QwenVoiceConfiguration(kind: .designed, description: Self.accented, language: "English")
        let request = SpeechRequest(voice: "v", text: "Hello.", tone: "warm")
        var job = SpeechJob(request: request, voiceName: "Arvind")
        job.voiceConfiguration = configuration
        job.warnings = QwenCapabilities.warnings(configuration: configuration, request: request)
        let restored = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job))
        #expect(restored.warnings == [QwenCapabilities.designAccentNotice])
        #expect(restored.voiceConfiguration?.description == Self.accented)
    }

    // MARK: Sampling settings

    /// Property: whatever the kind, the settings sit where the sampler treats them as intended —
    /// a positive, finite temperature (zero or below means greedy decoding), a top-p in (0, 1]
    /// (1 means no nucleus cut; 0 or below silently disables it), and a top-k that keeps at least
    /// one token and is below the 3,072-entry codec vocabulary (at or above it disables the cut).
    /// Only designed voices read the whole text first; the Float conversion keeps the value.
    @Test func generationSettingsStayInsideTheSamplersRanges() {
        for kind in VoiceKind.allCases {
            let settings = QwenGeneration.settings(for: kind)
            #expect(settings.temperature.isFinite && settings.temperature > 0 && settings.temperature <= 2, "\(kind)")
            #expect(settings.topP.isFinite && settings.topP > 0 && settings.topP <= 1, "\(kind)")
            #expect((1..<3_072).contains(settings.topK), "\(kind)")
            #expect(settings.wholeTextFirst == (kind == .designed), "\(kind)")
            #expect(abs(Double(Float(settings.temperature)) - settings.temperature) < 1e-6)
            #expect(abs(Double(Float(settings.topP)) - settings.topP) < 1e-6)
            #expect(QwenGeneration.settings(for: kind) == settings, "\(kind) not deterministic")
        }
        // Designed voices sample more widely than recorded and built-in voices, which share settings.
        let designed = QwenGeneration.settings(for: .designed), cloned = QwenGeneration.settings(for: .cloned)
        #expect(designed.temperature > cloned.temperature && designed.topP > cloned.topP)
        #expect(QwenGeneration.settings(for: .preset) == cloned)
    }

    @Test func generationEqualityComparesEveryField() {
        let base = QwenGeneration(temperature: 0.9, topP: 1, topK: 50, wholeTextFirst: true)
        var changed = base; changed.temperature = 0.8; #expect(changed != base)
        changed = base; changed.topP = 0.95; #expect(changed != base)
        changed = base; changed.topK = 40; #expect(changed != base)
        changed = base; changed.wholeTextFirst = false; #expect(changed != base)
    }

    // MARK: Tone cue grammar

    /// Every tone's cue, word for word. The "an" tones are listed by hand rather than derived, and
    /// the case count is pinned: a new tone must have its article checked by a person (an
    /// "honest" or "unique" tone would defeat a vowel-letter rule).
    @Test func everyToneCueHasTheRightArticleAndShape() {
        let anTones: Set<SpeechTone> = [.optimistic, .excited, .empathetic, .apologetic, .angry, .urgent]
        #expect(SpeechTone.allCases.count == 33, "a tone was added or removed: check its article, then update this count")
        for tone in SpeechTone.allCases where tone != .natural {
            let article = anTones.contains(tone) ? "an" : "a"
            #expect(tone.cue == "Speak with \(article) \(tone.rawValue) delivery. \(tone.detail)", "\(tone)")
            #expect(tone.rawValue == tone.rawValue.lowercased(), "\(tone) must be lowercase for the article rule")
            let words = tone.cue.split(separator: " ", omittingEmptySubsequences: false)
            #expect(!words.contains(""), "\(tone) has a doubled space")
            #expect(words.prefix(4) == ["Speak", "with", Substring(article), Substring(tone.rawValue)], "\(tone)")
            #expect(zip(words, words.dropFirst()).allSatisfy { !(["a", "an"].contains($0) && ["a", "an"].contains($1)) }, "\(tone)")
            #expect(tone.cue.hasSuffix("."), "\(tone)")
            #expect(!tone.cue.contains("[") && !tone.cue.contains("<|"), "\(tone)")
        }
        #expect(SpeechTone.natural.cue == "")
    }
}

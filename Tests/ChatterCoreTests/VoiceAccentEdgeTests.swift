import Foundation
import Testing
@testable import ChatterCore

/// Edge cases, seeded properties and budgets for accent and gender detection and for choosing a
/// macOS voice. Every generator is seeded, so a failure names its seed and input.
struct VoiceAccentEdgeTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    static func accent(_ id: String) -> VoiceAccent { VoiceAccents.catalog.first { $0.id == id }! }

    // MARK: Which accent a description asks for

    /// Case, punctuation, hyphens, quotes and non-word symbols around a keyword. A letter or digit
    /// on either side means the keyword is part of another word.
    @Test(arguments: [
        ("INDIAN ACCENT", "indian"),
        ("iNdIaN aCcEnT", "indian"),
        ("Indian-accented English", "indian"),
        ("“Indian” accent", "indian"),
        ("(Irish) accent", "irish"),
        ("Accent: Scottish.", "scottish"),
        ("A Scots accent", "scottish"),
        ("Accent from Edinburgh, Scotland", "scottish"),
        ("Northern Irish accent", "irish"),
        ("A U.K. accent", "british"),
        ("UK accent, crisp", "british"),
        ("A cockney accent", "british"),
        ("An accent from the U.S.", "american"),
        ("Speaks American English", "american"),     // a named variety needs no "accent"
        ("Speaks south african english", "south-african"),
        ("Cape Town accent", "south-african"),
        ("Johannesburg accent", "south-african"),
        ("An Aussie accent", "australian"),
        ("🇮🇳Indian accent", "indian"),              // emoji are not word characters
        ("Hindi-speaker's accent", "indian"),
        ("Bengaluru\naccent", "indian"),
        ("Indian\u{A0}accent", "indian"),
        ("A Tamil dialect", "indian"),
        ("received pronunciation accent", "british"),
    ])
    func accentsAreFoundThroughCaseAndPunctuation(description: String, accent: String) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
    }

    @Test(arguments: [
        "",
        "   ",
        "accent",                                 // an accent, but no catalog one
        "Indian",                                 // a catalog word, but no accent asked for
        "Ukrainian accent",                       // "uk" inside a word
        "Indianapolis accent",
        "Indiané accent",                         // a non-English letter continues the word
        "印度Indian accent",                       // so does an ideograph
        "Indian2 accent",                         // and a digit
        "Indian_accent",                          // "_" is a word character for the accent check
        "Scotlandish accent",
        "Londonderry accent",
        "Cape  Town accent",                      // a multi-word keyword needs its single space
        "Indian-English",                         // a variety is named with a space
        "An Indian Englishman",
        "A French accent, Parisian",
    ])
    func noCatalogAccentForNearMisses(description: String) {
        #expect(VoiceAccents.requested(in: description) == nil, "\(description.debugDescription)")
    }

    /// Several accents named: the catalog order decides, not the order in the text. Scottish and
    /// Irish come before British so their place names win.
    @Test func whenSeveralAccentsAreNamedTheCatalogOrderDecides() {
        #expect(VoiceAccents.requested(in: "A London accent with a hint of Scottish")?.id == "scottish")
        #expect(VoiceAccents.requested(in: "A Scottish accent with a hint of London")?.id == "scottish")
        #expect(VoiceAccents.requested(in: "A British or Australian accent")?.id == "british")
        #expect(VoiceAccents.requested(in: "Australian accent, raised in Mumbai")?.id == "indian")
        #expect(VoiceAccents.requested(in: "An Irish accent from Dublin, schooled in England")?.id == "irish")
        #expect(VoiceAccents.requested(in: "American accent, born in Glasgow")?.id == "scottish")
    }

    /// The catalog itself: unique IDs and names, lowercased keywords, and every accent findable by
    /// each of its keywords and by its variety name.
    @Test func everyCatalogKeywordAndNameFindsItsAccent() {
        #expect(Set(VoiceAccents.catalog.map(\.id)).count == VoiceAccents.catalog.count)
        #expect(Set(VoiceAccents.catalog.map(\.name)).count == VoiceAccents.catalog.count)
        for (index, accent) in VoiceAccents.catalog.enumerated() {
            #expect(!accent.languages.isEmpty && accent.languages.allSatisfy { $0.hasPrefix("en-") }, "\(accent.id)")
            #expect(QwenCapabilities.describesAccent("Speaks \(accent.name.uppercased()) all day"), "\(accent.name)")
            #expect(VoiceAccents.requested(in: "Speaks \(accent.name)")?.id == accent.id, "\(accent.name)")
            for keyword in accent.keywords {
                #expect(keyword == keyword.lowercased(), "\(keyword)")
                // An earlier accent may claim the keyword (none does today); never a later one.
                let found = VoiceAccents.requested(in: "a \(keyword) accent")
                let foundIndex = found.flatMap { f in VoiceAccents.catalog.firstIndex { $0.id == f.id } }
                #expect(found?.id == accent.id, "\(keyword) found \(found?.id ?? "nothing")")
                #expect((foundIndex ?? .max) <= index)
            }
        }
    }

    /// A description that asks for no accent, or negates one, is not understood as such: the
    /// keyword still selects the accent. The notice side of this is deliberate (see
    /// DesignedVoiceEdgeTests); offering the negated accent's macOS voices is not.
    @Test func negatedAccentsAreNotUnderstood() {
        withKnownIssue("VoiceAccents.requested ignores negation; the first catalog keyword wins") {
            #expect(VoiceAccents.requested(in: "Not Indian: a neutral American accent")?.id == "american")
            #expect(VoiceAccents.requested(in: "A Londoner with no accent at all") == nil)
        }
    }

    /// Place names that contain a catalog keyword but name a different accent are ignored, with
    /// their words joined by spaces or hyphens; the rest of the description still counts.
    @Test(arguments: [
        ("A West Indian accent", nil),               // Caribbean, not Indian English
        ("A West-Indian accent", nil),
        ("A New England accent", nil),               // American, not British
        ("A South American accent", nil),            // Spanish-influenced, not en-US
        ("A Latin American accent", nil),
        ("A Central American accent", nil),
        ("A Native American accent", nil),
        ("An American Indian accent", nil),
        ("A British Columbia accent", nil),          // Canadian
        ("An Irish-American accent", nil),
        ("An Ulster Scots accent", nil),
        ("An accent from the Indian Ocean islands", nil),
        ("A New England accent, raised in Mumbai", "indian"),
        ("A West Indian accent with London vowels", "british"),
        ("A New South Wales accent", "australian"),
        ("Anglo-Indian accent", "indian"),           // an Indian English variety
        ("North American accent", "american"),
        ("New Delhi accent", "indian"),
    ] as [(String, String?)])
    func misleadingPlaceNamesAreIgnored(description: String, accent: String?) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
    }

    /// A named variety counts as its adjective; "an English accent" means British but never
    /// outranks a named variety or another accent's keyword.
    @Test(arguments: [
        ("An English accent", "british"),
        ("With an English accent", "british"),
        ("A soft, educated English accent", nil),   // only "an English accent": an adjective there could be a variety
        ("An American English accent", "american"),
        ("An Australian English accent", "australian"),
        ("A South African English accent", "south-african"),
        ("Speaks American English with an Indian accent", "indian"),
        ("Indian English", "indian"),
        ("Speaks English with a Dublin accent", "irish"),
        ("Speaks English fluently", nil),            // no accent asked for
    ] as [(String, String?)])
    func varietiesCountAsTheirAdjective(description: String, accent: String?) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
    }

    // MARK: Gender

    @Test(arguments: [
        ("MALE narrator", VoiceGender.male),
        ("Female.", .female),
        ("He's warm and wry", .male),
        ("A woman's voice", .female),
        ("Women's choir soloist", .female),
        ("Bass-baritone, slow", .male),
        ("A contralto? no, an alto", .female),
        ("male_voice", .male),                   // "_" separates words here
        ("male2", .male),                        // so does a digit
        ("A grandmother reading", .female),
        ("Grandfather, gravelly", .male),
        ("This voice is shepherd-like and human", nil), // "his", "he", "man" only inside words
        ("Hermione, a Mandarin speaker", nil),
        ("male/female duet", nil),
        ("Not a man, a woman", nil),             // both named: no preference rather than a guess
        ("Girls and boys", nil),                 // plurals other than men/women are not words it knows
        ("homme, femme", nil),
        ("", nil),
        ("   \n\t", nil),
        ("womané", nil),                         // a non-English letter continues the word
        ("ÉLÉGANT GENTLEMAN", .male),
    ] as [(String, VoiceGender?)])
    func genderEdgeCases(description: String, gender: VoiceGender?) {
        #expect(VoiceGender.requested(in: description) == gender, "\(description.debugDescription)")
    }

    // MARK: Seeded properties

    static let pieces = ["warm", " ", ", ", ".", "-", "\n", "_", "2", "é", "中文", "😀", "(", ")", "’", "\u{A0}",
                         "voice", "accent", "dialect", "accentuated", "Indian", "indianapolis", "Scottish", "Glasgow",
                         "Irish", "British", "London", "UK", "u.k.", "Australian", "Sydney", "south african", "cape town",
                         "American", "u.s.", "English", "Indian English", "received pronunciation",
                         "male", "female", "man", "woman", "she", "he", "his", "this", "her", "shepherd", "baritone", "alto"]

    static func description(_ rng: inout Seeded) -> String {
        (0..<Int.random(in: 0...24, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    static func index(_ accent: VoiceAccent?) -> Int? { accent.flatMap { a in VoiceAccents.catalog.firstIndex { $0.id == a.id } } }

    /// Detection is deterministic and case-insensitive; an accent found implies an accent request;
    /// adding "accent" never changes which accent; and joining two accent descriptions picks the
    /// earlier catalog accent of the two.
    @Test func accentDetectionProperties() {
        for seed in UInt64(1)...1_500 {
            var rng = Seeded(state: seed)
            let a = Self.description(&rng), b = Self.description(&rng)
            let found = VoiceAccents.requested(in: a)
            #expect(VoiceAccents.requested(in: a) == found, "seed \(seed) not deterministic")
            #expect(VoiceAccents.requested(in: a.uppercased()) == found, "seed \(seed): \(a.debugDescription)")
            #expect(VoiceAccents.requested(in: a.lowercased()) == found, "seed \(seed): \(a.debugDescription)")
            if found != nil { #expect(QwenCapabilities.describesAccent(a), "seed \(seed): \(a.debugDescription)") }
            let asked = VoiceAccents.requested(in: a + " accent")
            if let found { #expect(asked == found, "seed \(seed): \(a.debugDescription)") }
            // Each part keeps its own trailing "accent": "English accent" is a phrase, and a place
            // name could otherwise form across the join ("West" + "Indian").
            let both = Self.index(VoiceAccents.requested(in: a + " accent " + b + " accent"))
            let expected = [Self.index(asked), Self.index(VoiceAccents.requested(in: b + " accent"))].compactMap { $0 }.min()
            #expect(both == expected, "seed \(seed): \(a.debugDescription) + \(b.debugDescription)")
        }
    }

    /// Gender is a bag of words: deterministic, case-insensitive, unchanged by repeating the
    /// description, and a join of two descriptions agrees with them where they agree.
    @Test func genderDetectionProperties() {
        for seed in UInt64(1)...1_500 {
            var rng = Seeded(state: seed)
            let a = Self.description(&rng), b = Self.description(&rng)
            let gender = VoiceGender.requested(in: a)
            #expect(VoiceGender.requested(in: a.uppercased()) == gender, "seed \(seed): \(a.debugDescription)")
            #expect(VoiceGender.requested(in: a + " " + a) == gender, "seed \(seed): \(a.debugDescription)")
            let words = a.split(separator: " ").shuffled(using: &rng).joined(separator: " ")
            #expect(VoiceGender.requested(in: words) == gender, "seed \(seed): \(a.debugDescription) vs \(words.debugDescription)")
            if gender != nil, gender == VoiceGender.requested(in: b) {
                #expect(VoiceGender.requested(in: a + " " + b) == gender, "seed \(seed)")
            }
            if let gender {
                // Naming the other gender as well always cancels the preference.
                let other = gender == .male ? "woman" : "man"
                #expect(VoiceGender.requested(in: a + " " + other) == nil, "seed \(seed): \(a.debugDescription)")
            }
        }
    }

    // MARK: Budget

    /// Detection runs on every keystroke of an uncapped TextEditor: a megabyte of near misses, or an
    /// accent named only at the very end, stays well inside a second per call.
    @Test func detectionStaysFastOnVeryLongDescriptions() {
        let nearMisses = String(repeating: "Indianapolis xindian Scotlandish Ukrainian he’s-not ", count: 20_000) + "accent" // ~1 MB
        let late = String(repeating: "warm mature voice ", count: 55_000) + "with a slight Irish accent"
        let clock = ContinuousClock()
        var accents: [String?] = [], genders: [VoiceGender?] = []
        let elapsed = clock.measure {
            for _ in 0..<2 {
                accents.append(VoiceAccents.requested(in: nearMisses)?.id); accents.append(VoiceAccents.requested(in: late)?.id)
                genders.append(VoiceGender.requested(in: late))
            }
        }
        #expect(accents == [nil, "irish", nil, "irish"])
        #expect(genders == [nil, nil])
        #expect(elapsed < .seconds(5), "four accent scans and two gender scans of ~1 MB took \(elapsed)")
        let saved = String(repeating: "warm mature ", count: 160) + "Indian accent"
        let small = clock.measure { for _ in 0..<1_000 { _ = VoiceAccents.requested(in: saved); _ = VoiceGender.requested(in: saved) } }
        #expect(small < .seconds(2), "1,000 scans of 2 KB took \(small)")
    }

    /// Detection is called from views and from a detached task: shared regexes stay correct under
    /// parallel use.
    @Test func detectionIsConsistentUnderConcurrency() async {
        let inputs = ["Indian accent", "Scottish accent from Glasgow", "a London dialect", "Speaks Irish English", "plain voice"]
        let expected = inputs.map { VoiceAccents.requested(in: $0)?.id }
        let results = await withTaskGroup(of: [String?].self) { group in
            for _ in 0..<16 { group.addTask { (0..<200).flatMap { _ in inputs.map { VoiceAccents.requested(in: $0)?.id } } } }
            return await group.reduce(into: [[String?]]()) { $0.append($1) }
        }
        #expect(expected == ["indian", "scottish", "british", "irish", nil])
        for result in results { #expect(result == Array((0..<200).flatMap { _ in expected })) }
    }

    // MARK: Choosing a macOS voice

    static func voice(_ id: String, _ name: String = "V", _ language: String, _ gender: VoiceGender? = nil, quality: Int = 0, novelty: Bool = false) -> SystemVoiceOption {
        SystemVoiceOption(id: id, name: name, language: language, gender: gender, quality: quality, isNovelty: novelty)
    }

    /// Locales match by case-insensitive prefix; a bare "en" or another language does not.
    @Test func localesMatchByPrefixIgnoringCase() {
        let voices = [
            Self.voice("a", "A", "en-IN"), Self.voice("b", "B", "EN-in"), Self.voice("c", "C", "en-IN-x-private"),
            Self.voice("d", "D", "en"), Self.voice("e", "E", "hi-IN"), Self.voice("f", "F", "in-EN"), Self.voice("g", "G", "en-US"),
        ]
        #expect(SystemVoiceOption.candidates(for: Self.accent("indian"), gender: nil, among: voices).map(\.id) == ["a", "b", "c"])
        #expect(SystemVoiceOption.candidates(for: Self.accent("american"), gender: nil, among: voices).map(\.id) == ["g"])
    }

    /// Scottish voices start with en-GB but belong to Scotland; Welsh and other en-GB voices stay
    /// British; the Irish locale is not British; Scotland's alternative locale is Scottish.
    @Test func scottishBritishAndIrishLocalesStaySeparate() {
        let voices = [
            Self.voice("gb", "Daniel", "en-GB"), Self.voice("sct", "Fiona", "en-GB-u-sd-gbsct"), Self.voice("SCT", "Fia", "EN-GB-U-SD-GBSCT"),
            Self.voice("wls", "Gwen", "en-GB-u-sd-gbwls"), Self.voice("ie", "Moira", "en-IE"), Self.voice("alt", "Iona", "en-scotland"),
        ]
        #expect(SystemVoiceOption.candidates(for: Self.accent("british"), gender: nil, among: voices).map(\.id) == ["gb", "wls"])
        #expect(SystemVoiceOption.candidates(for: Self.accent("scottish"), gender: nil, among: voices).map(\.id) == ["SCT", "sct", "alt"])
        #expect(SystemVoiceOption.candidates(for: Self.accent("irish"), gender: nil, among: voices).map(\.id) == ["ie"])
    }

    /// Robotic and low-storage voices are filtered in any letter case; a name merely containing
    /// those words is not.
    @Test func eloquenceAndSuperCompactAreFilteredInAnyCase() {
        let voices = [
            Self.voice("com.apple.Eloquence.en-US.Flo", "Flo", "en-US"), Self.voice("com.apple.voice.Super-Compact.en-US.Sam", "Sam", "en-US"),
            Self.voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US"),
            Self.voice("com.apple.speech.synthesis.voice.Bahh", "Bahh", "en-US", novelty: true),
            Self.voice("com.example.Eloquence", "Eloquence", "en-US"),
        ]
        #expect(SystemVoiceOption.candidates(for: Self.accent("american"), gender: nil, among: voices).map(\.name) == ["Eloquence", "Samantha"])
    }

    /// A voice AppKit lists twice appears once: the first eligible listing of an ID is kept, and
    /// an ineligible listing does not hide a later eligible one.
    @Test func theFirstEligibleListingOfAnIDIsKept() {
        let first = Self.voice("x", "First", "en-IN", quality: 0), second = Self.voice("x", "Second", "en-IN", quality: 2)
        #expect(SystemVoiceOption.candidates(for: Self.accent("indian"), gender: nil, among: [first, second]) == [first])
        let novelty = Self.voice("y", "Novelty", "en-IN", novelty: true), real = Self.voice("y", "Real", "en-IN")
        #expect(SystemVoiceOption.candidates(for: Self.accent("indian"), gender: nil, among: [novelty, real]) == [real])
        let otherLocale = Self.voice("z", "Elsewhere", "en-US")
        #expect(SystemVoiceOption.candidates(for: Self.accent("indian"), gender: nil, among: [otherLocale, Self.voice("z", "Here", "en-IN")]).map(\.name) == ["Here"])
    }

    /// Ties break by name, then by ID, so the picker order is stable.
    @Test func tiesBreakByNameThenID() {
        let voices = [Self.voice("b", "Aman", "en-IN", .male, quality: 1), Self.voice("a", "Aman", "en-IN", .male, quality: 1),
                      Self.voice("c", "Aarav", "en-IN", .male, quality: 1), Self.voice("d", "Zed", "en-IN", .male, quality: 2)]
        #expect(SystemVoiceOption.candidates(for: Self.accent("indian"), gender: .male, among: voices).map(\.id) == ["d", "c", "a", "b"])
    }

    /// Gender outranks quality: a default-quality voice of the requested gender comes before a
    /// premium voice of no stated gender, which comes before a premium voice of the other one.
    @Test func genderOutranksQuality() {
        let voices = [Self.voice("f", "F", "en-AU", .female, quality: 2), Self.voice("n", "N", "en-AU", nil, quality: 2),
                      Self.voice("m", "M", "en-AU", .male, quality: 0)]
        #expect(SystemVoiceOption.candidates(for: Self.accent("australian"), gender: .male, among: voices).map(\.id) == ["m", "n", "f"])
        #expect(SystemVoiceOption.candidates(for: Self.accent("australian"), gender: .female, among: voices).map(\.id) == ["f", "n", "m"])
        #expect(SystemVoiceOption.candidates(for: Self.accent("australian"), gender: nil, among: voices).map(\.id) == ["f", "n", "m"])
    }

    static let languages = ["en-IN", "en-in", "EN-IN", "en-IN-x", "en-GB", "en-GB-u-sd-gbsct", "en-GB-u-sd-gbwls", "en-scotland", "en-IE",
                            "en-AU", "en-ZA", "en-US", "en", "fr-FR", "in-EN", "en_IN", ""]
    static let names = ["Aman", "Tara", "Rishi", "Daniel", "Fiona", "Moira", "aman", "Émile", ""]

    static func voices(_ rng: inout Seeded) -> [SystemVoiceOption] {
        (0..<Int.random(in: 0...25, using: &rng)).map { i in
            let tag = ["voice.compact", "voice.enhanced", "voice.premium", "eloquence", "voice.super-compact", "speech.synthesis.voice"].randomElement(using: &rng)!
            return SystemVoiceOption(id: "com.apple.\(tag).v\(i)", name: names.randomElement(using: &rng)!, language: languages.randomElement(using: &rng)!,
                                     gender: [VoiceGender.male, .female, nil].randomElement(using: &rng)!, quality: Int.random(in: 0...2, using: &rng),
                                     isNovelty: Int.random(in: 0..<5, using: &rng) == 0)
        }
    }

    /// For every accent and gender over generated voice lists: only eligible voices of the
    /// accent's locales, each once, all of them, in rank order; unchanged by shuffling the input
    /// and by choosing again from the result.
    @Test func candidateProperties() {
        for seed in UInt64(1)...400 {
            var rng = Seeded(state: seed)
            let voices = Self.voices(&rng)
            for accent in VoiceAccents.catalog {
                for gender in [VoiceGender.male, .female, nil] {
                    let chosen = SystemVoiceOption.candidates(for: accent, gender: gender, among: voices)
                    func eligible(_ v: SystemVoiceOption) -> Bool {
                        let id = v.id.lowercased(), language = v.language.lowercased()
                        return !v.isNovelty && !id.contains(".eloquence.") && !id.contains("super-compact")
                            && !id.hasPrefix("com.apple.speech.synthesis.voice.")
                            && accent.languages.contains { language.hasPrefix($0.lowercased()) }
                            && !(accent.id == "british" && language.contains("sct"))
                    }
                    let context = "seed \(seed) \(accent.id) \(String(describing: gender))"
                    #expect(Set(chosen.map(\.id)) == Set(voices.filter(eligible).map(\.id)), "\(context)")
                    #expect(Set(chosen.map(\.id)).count == chosen.count, "\(context)")
                    func rank(_ v: SystemVoiceOption) -> Int { gender == nil || v.gender == gender ? 0 : v.gender == nil ? 1 : 2 }
                    for (x, y) in zip(chosen, chosen.dropFirst()) {
                        #expect((rank(x), -x.quality, x.name, x.id) <= (rank(y), -y.quality, y.name, y.id), "\(context)")
                    }
                    #expect(SystemVoiceOption.candidates(for: accent, gender: gender, among: voices.shuffled(using: &rng)) == chosen, "\(context)")
                    #expect(SystemVoiceOption.candidates(for: accent, gender: gender, among: chosen) == chosen, "\(context)")
                    #expect(SystemVoiceOption.candidates(for: accent, gender: gender, among: voices + voices) == chosen, "\(context)")
                }
            }
        }
    }

    /// Choosing among many listings (every voice listed several times) stays fast.
    @Test func candidatesScaleToLongVoiceLists() {
        let voices = (0..<20_000).map { i in
            Self.voice("v\(i % 5_000)", "Name\(i % 97)", ["en-IN", "en-GB", "en-US"][i % 5_000 % 3], [.male, .female, nil][i % 3], quality: i % 3)
        }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = SystemVoiceOption.candidates(for: Self.accent("indian"), gender: .female, among: voices).count }
        #expect(count == 1_667) // v0, v3, … v4998: the en-IN IDs, each once
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    // MARK: Picker titles

    @Test(arguments: [(0, "Rishi"), (1, "Rishi (enhanced)"), (2, "Rishi (premium)"), (3, "Rishi"), (-1, "Rishi")])
    func titlesOnlyNameKnownQualities(quality: Int, title: String) {
        #expect(Self.voice("r", "Rishi", "en-IN", quality: quality).title == title)
    }

    @Test func titlesKeepTheNameVerbatim() {
        #expect(Self.voice("e", "", "en-IN", quality: 2).title == " (premium)")
        #expect(Self.voice("e", "Amélie (Canada)", "fr-CA", quality: 1).title == "Amélie (Canada) (enhanced)")
    }

    // MARK: The receipt warning

    /// A named variety or a dialect warns a designed voice even without the word "accent"; a
    /// recorded voice never gets the design notice.
    @Test func varietiesAndDialectsWarnDesignedVoicesOnly() {
        let request = SpeechRequest(voice: "Arvind", text: "Hello.")
        for description in ["Speaks Indian English, warm", "A Yorkshire dialect", "regional DIALECTS", "SOUTH AFRICAN ENGLISH, calm"] {
            let designed = QwenVoiceConfiguration(kind: .designed, description: description, language: "English")
            #expect(QwenCapabilities.warnings(configuration: designed, request: request) == [QwenCapabilities.designAccentNotice], "\(description)")
            let cloned = QwenVoiceConfiguration(kind: .cloned, description: description, language: "English")
            #expect(QwenCapabilities.warnings(configuration: cloned, request: request).isEmpty, "\(description)")
        }
        for description in ["dialectal shading", "Indian-English", "English, clearly", "dialectic tone"] {
            #expect(!QwenCapabilities.describesAccent(description), "\(description)")
        }
    }
}

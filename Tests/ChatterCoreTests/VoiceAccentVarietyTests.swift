import Foundation
import Testing
@testable import ChatterCore

/// How ignoring misleading place names and reducing "<Adjective> English" to its adjective
/// combine with the keywords, including the British phrase "an english accent". Extends
/// `VoiceAccentEdgeTests`.
extension VoiceAccentEdgeTests {
    /// Behaviour the two rewrites get right: a misleading place name beside a real accent, a
    /// variety at either end of the text, whitespace other than one space, and phrases that
    /// already contain "English".
    @Test(arguments: [
        ("An Indian accent, not West Indian", "indian"),
        ("A New England accent with British vowels", "british"),
        ("A british accent from british columbia", "british"),
        ("Indian accent from the Indian Ocean coast", "indian"),
        ("An Ulster Scots-Irish accent", "irish"),          // "Ulster Scots" goes, "Irish" stays
        ("WEST INDIAN ACCENT", nil),
        ("A West\nIndian accent", nil),                      // words joined across a line break
        ("West\u{A0}Indian accent", nil),
        ("New  England accent", nil),
        ("new-england accent", nil),
        ("A Native-American accent", nil),
        ("English English accent", nil),                    // only "an English accent" means British
        ("british english accent", "british"),
        ("Received Pronunciation English accent", "british"),
        ("A Welsh English accent", nil),                    // like "a Welsh accent": no catalog accent
        ("A Scots English accent", "scottish"),
        ("South African English", "south-african"),          // the variety keeps its two words
        ("American English, warm", "american"),              // a variety at the start
        ("warm, AMERICAN ENGLISH", "american"),              // and at the end
        ("An accent: american english", "american"),
        ("American\u{A0}English accent", "american"),
        ("A NEW SOUTH WALES accent", "australian"),
        ("A Glasgow English accent", "scottish"),            // an earlier accent's place still wins
        ("A Dublin English accent", "irish"),
    ] as [(String, String?)])
    func placeNamesAndVarietiesCombine(description: String, accent: String?) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
    }

    /// "English accent" means British only as "an English accent": a variety outside the catalog,
    /// or a later accent's place, never becomes British.
    @Test(arguments: [
        ("A Canadian English accent", nil),
        ("A New Zealand English accent", nil),
        ("A Jamaican English accent", nil),
        ("A West Indian English accent", nil),               // "West Indian" is blanked, "English accent" is left
        ("A South American English accent", nil),
        ("A British Columbia English accent", nil),
        ("A New South Wales English accent", "australian"),
        ("A Sydney English accent", "australian"),
        ("A Cape Town English accent", "south-african"),
    ] as [(String, String?)])
    func otherVarietiesOfEnglishAreNotBritish(description: String, accent: String?) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
    }

    /// A hyphenated variety counts as its adjective too.
    @Test(arguments: [
        ("An American-English accent", "american"),
        ("An Australian-English accent", "australian"),
        ("A South African-English accent", "south-african"),
    ])
    func hyphenatedVarietiesAreNotBritish(description: String, accent: String) {
        #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
        #expect(VoiceAccents.requested(in: "An Indian-English accent")?.id == "indian")
    }

    /// Typographic dashes join place names as ASCII hyphens do.
    @Test(arguments: ["A West\u{2013}Indian accent", "An Irish\u{2011}American accent", "A New\u{2010}England accent"])
    func typographicDashesJoinPlaceNames(description: String) {
        #expect(VoiceAccents.requested(in: description) == nil, "\(description.debugDescription)")
    }

    /// "Indian-accented" finds Indian; "English-accented" and "English accents" should find British.
    @Test(arguments: ["An English-accented narrator", "A mix of English accents"])
    func inflectedEnglishAccentIsBritish(description: String) {
        withKnownIssue("the keyword is the literal phrase \"english accent\", so the following letters end the match") {
            #expect(VoiceAccents.requested(in: description)?.id == "british", "\(description.debugDescription)")
        }
    }

    static let misleadingPlaces = ["west indian", "west indians", "american indian", "indian ocean", "native american", "central american",
                                   "south american", "latin american", "new england", "british columbia", "irish american", "ulster scots"]

    /// Seeded over every misleading place name, in any case and joined by any mix of spaces,
    /// hyphens, tabs, line breaks or no-break spaces: alone it asks for no catalog accent, and
    /// placed before any keyword's description it never changes that description's accent.
    @Test func misleadingPlaceNamesAreTransparent() {
        let joins = [" ", "-", "  ", "\t", "\n", "\u{A0}", " - ", "--"]
        let keywords = VoiceAccents.catalog.flatMap(\.keywords)
        for seed in UInt64(1)...300 {
            var rng = Seeded(state: seed)
            let place = Self.misleadingPlaces.randomElement(using: &rng)!
            let words = place.split(separator: " ").map { word in
                String(word).map { Bool.random(using: &rng) ? $0.uppercased() : String($0) }.joined()
            }
            let joined = words.joined(separator: joins.randomElement(using: &rng)!)
            #expect(VoiceAccents.requested(in: "A \(joined) accent") == nil, "seed \(seed): \(joined.debugDescription)")
            let keyword = keywords.randomElement(using: &rng)!
            let plain = "a \(keyword) accent"
            #expect(VoiceAccents.requested(in: "A \(joined) accent, \(plain)") == VoiceAccents.requested(in: plain),
                    "seed \(seed): \(joined.debugDescription) + \(keyword)")
        }
    }

    /// Every catalog variety means the same as its adjective, alone or before "accent", and
    /// "English accent" after a catalog variety never overrides it.
    @Test func catalogVarietiesMeanTheirAdjective() {
        for accent in VoiceAccents.catalog {
            let adjective = String(accent.name.dropLast(" English".count))
            for text in ["\(accent.name)", "\(accent.name) accent", "\(adjective) accent", "\(accent.name.lowercased()) accent",
                         "\(adjective)  English accent", "\(adjective)\nEnglish accent", "with an \(accent.name) accent."] {
                #expect(VoiceAccents.requested(in: text)?.id == accent.id, "\(text.debugDescription)")
            }
        }
    }

    /// Without the word "accent", a variety split by a line break or two spaces is not noticed:
    /// the variety names that make it an accent request need exactly one space.
    @Test(arguments: [("Speaks Indian\nEnglish", "indian"), ("Speaks Irish  English", "irish"), ("Speaks American\u{A0}English", "american")])
    func varietiesSplitByOtherWhitespaceAreAccentRequests(description: String, accent: String) {
        withKnownIssue("namesVariety matches catalog names with a literal space while the variety regex accepts any whitespace") {
            #expect(VoiceAccents.requested(in: description)?.id == accent, "\(description.debugDescription)")
        }
    }

    // MARK: MacinTalk voices

    /// MacinTalk voices (Fred, Albert, Ralph) are robotic even when AVFoundation doesn't call them
    /// novelty voices; their identifier prefix is matched in any case, and only as a prefix.
    @Test func macinTalkVoicesAreExcludedInAnyCase() {
        let voices = [
            Self.voice("com.apple.speech.synthesis.voice.Fred", "Fred", "en-US"),
            Self.voice("COM.APPLE.SPEECH.SYNTHESIS.VOICE.Albert", "Albert", "en-US"),
            Self.voice("Com.Apple.Speech.Synthesis.Voice.Ralph", "Ralph", "en-US", quality: 2),
            Self.voice("com.example.com.apple.speech.synthesis.voice.Kept", "Kept", "en-US"),
            Self.voice("com.apple.speech.synthesis.voicekathy", "Kathy", "en-US"),   // not the MacinTalk prefix
            Self.voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US"),
        ]
        #expect(SystemVoiceOption.candidates(for: Self.accent("american"), gender: nil, among: voices).map(\.name) == ["Kathy", "Kept", "Samantha"])
        // A MacinTalk listing does not hide a later eligible voice of the same name.
        #expect(SystemVoiceOption.candidates(for: Self.accent("american"), gender: nil, among: [voices[0], Self.voice("fred", "Fred", "en-US")]).map(\.id) == ["fred"])
    }
}

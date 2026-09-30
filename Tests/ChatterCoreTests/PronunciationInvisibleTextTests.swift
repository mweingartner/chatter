import Foundation
import Testing
@testable import ChatterCore

/// Invisible characters inside legitimate text: what cleaning keeps (joiners that Persian, Indic and emoji
/// spellings need) and what it drops (variation selectors, Hangul fillers, the grapheme joiner), and how
/// the "already has a pronunciation" lookup and the CSV header check see the same cleaned text as
/// `upsert`. Random cases are seeded, and a failure names its seed.
@Suite("Pronunciation invisible text")
struct PronunciationInvisibleTextTests {
    typealias C = PronunciationCleaningTests
    typealias E = PronunciationEdgeTests

    static func scalars(_ value: String) -> [UInt32] { value.unicodeScalars.map(\.value) }

    // MARK: Legitimate text

    /// Joiners inside a word stay, so Persian, Devanagari and emoji ZWJ sequences keep their meaning.
    @Test func joinersInsideRealSpellingsStay() {
        let persian = "می\u{200C}خواهم"   // "I want": the ZWNJ keeps the prefix unjoined
        #expect(PronunciationList.cleaned(persian) == persian)
        #expect(PronunciationList.cleaned("  \u{200C}" + persian + "\u{200C} \u{200D}") == persian)
        let halfForm = "क्\u{200D}ष"   // ZWJ requests the half form of क
        #expect(PronunciationList.cleaned(halfForm) == halfForm)
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(PronunciationList.cleaned(family) == family && PronunciationList.cleaned(family).count == 1)
        // A joiner surrounded by spaces inside a field is inside, so it stays (nothing trims the middle).
        #expect(Self.scalars(PronunciationList.cleaned("a \u{200D} b")) == [0x61, 0x20, 0x200D, 0x20, 0x62])
    }

    /// A ZWJ sequence cut at a field's edge loses only the dangling joiner, however it is mixed with spaces.
    @Test(arguments: [
        ("SQL👨\u{200D}", "SQL👨"),
        ("\u{200D}👩 SQL", "👩 SQL"),
        ("SQL \u{200D}", "SQL"),
        ("SQL\u{200D} \u{200C}\t\u{200D}", "SQL"),
        ("\u{200C} \u{200D}\u{3000}SQL", "SQL"),
        ("👨\u{200D}\u{FE0F}", "👨"),          // a variation selector after the joiner goes first, then the joiner is at the edge
        ("\u{FE0F}\u{200D}👩", "👩"),
        ("\u{200D}\u{200B}\u{200D}SQL", "SQL"),  // a removed character between two edge joiners doesn't shield the inner one
    ])
    func danglingJoinersAtTheEdgesGo(raw: String, expected: String) {
        #expect(PronunciationList.cleaned(raw) == expected, "\(raw.debugDescription)")
    }

    /// Variation selectors go: emoji keep their picture (one character), ideographs keep their base.
    @Test func variationSelectorsGoWithoutBreakingCharacters() {
        #expect(Self.scalars(PronunciationList.cleaned("I ❤\u{FE0F} NY")) == Self.scalars("I ❤ NY"))
        let keycap = PronunciationList.cleaned("1\u{FE0F}\u{20E3}")
        #expect(Self.scalars(keycap) == [0x31, 0x20E3] && keycap.count == 1)
        let rainbow = PronunciationList.cleaned("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}")   // the flag keeps its joiner
        #expect(Self.scalars(rainbow) == [0x1F3F3, 0x200D, 0x1F308] && rainbow.count == 1)
        #expect(PronunciationList.cleaned("葛\u{E0100}飾") == "葛飾")                     // ideographic variation selector
        #expect(PronunciationList.cleaned("\u{E01EF}漢\u{FE00}字\u{E0100}") == "漢字")
        #expect(PronunciationList.cleaned("ᠠ\u{180B}ᠡ\u{180F}") == "ᠠᠡ")               // Mongolian free variation selectors
        #expect(PronunciationList.cleaned("S\u{034F}QL") == "SQL")                        // combining grapheme joiner
    }

    /// Hangul fillers are letters by category, so before they were removed they could hide inside a word or
    /// stand in for the "at least one letter" a field needs. Removed, they do neither.
    @Test func hangulFillersAreNotLetters() throws {
        for filler: Unicode.Scalar in ["\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}"] {
            #expect(Character(filler).isLetter)   // why they must be removed, not merely filtered as non-letters
            #expect(PronunciationList.cleaned("한\(filler)국") == "한국", "\(C.hex(filler))")
            #expect(PronunciationList.cleaned(" \(filler) SQL \(filler) ") == "SQL", "\(C.hex(filler))")
            do { _ = try PronunciationList.validated(Pronunciation(written: "\(filler)\(filler)", sayAs: "x", matchCase: false)); Issue.record("accepted \(C.hex(filler))") }
            catch { #expect(error.localizedDescription == "Written needs at least one letter or number.") }
            do { _ = try PronunciationList.validated(Pronunciation(written: "SQL", sayAs: " \(filler) ", matchCase: false)); Issue.record("accepted \(C.hex(filler))") }
            catch { #expect(error.localizedDescription == "Say it as needs at least one letter or number.") }
        }
        // A choseong filler before a vowel jamo leaves the vowel.
        #expect(Self.scalars(PronunciationList.cleaned("\u{115F}\u{1161}")) == [0x1161])
        var list = PronunciationList()
        #expect(throws: ChatterError.self) { try list.importCSV("SQL,\u{3164}\n") }
        #expect(list.isEmpty)
    }

    /// Spellings that differ only in a kept joiner are different entries; ones that differ only in a removed
    /// character are the same entry.
    @Test func joinerSpellingsAreDistinctEntriesAndSelectorSpellingsAreNot() throws {
        var list = PronunciationList()
        try list.upsert(Pronunciation(written: "می\u{200C}خواهم", sayAs: "mi-khaa-ham", matchCase: false))
        try list.upsert(Pronunciation(written: "میخواهم", sayAs: "mikhaaham", matchCase: false))
        #expect(list.entries.count == 2)
        try list.upsert(Pronunciation(written: "葛飾", sayAs: "katsushika", matchCase: false))
        do { try list.upsert(Pronunciation(written: "葛\u{E0100}飾", sayAs: "kazushika", matchCase: false)); Issue.record("added an IVS look-alike") }
        catch { #expect(error.localizedDescription == "“葛飾” already has a pronunciation. Edit that entry instead.") }
        #expect(list.entries.count == 3)
    }

    // MARK: The "already has a pronunciation" lookup

    /// Fillers, variation selectors and the grapheme joiner, anywhere in what was typed, find the entry the
    /// save clashed with, exactly as upsert refuses it.
    @Test(arguments: ["S\u{3164}QL", "SQL\u{115F}", "\u{FFA0}SQL", "\u{1160}S\u{1160}Q\u{1160}L", "S\u{FE0F}QL", "SQL\u{E0100}",
                      "S\u{034F}QL", "\u{200D}SQL\u{200C}", " \u{3164} SQL\u{FE0F} ", "\u{E0001}SQL\u{E007F}"])
    func lookAlikesFindTheClashingEntry(typed: String) throws {
        var list = PronunciationList()
        let sql = try list.upsert(Pronunciation(written: "SQL", sayAs: "sequel", matchCase: true))
        do { try list.upsert(Pronunciation(written: typed, sayAs: "squeal", matchCase: true)); Issue.record("added \(typed.debugDescription)") }
        catch { #expect(error.localizedDescription == "“SQL” already has a pronunciation. Edit that entry instead.") }
        #expect(list.entry(covering: typed, matchCase: true)?.id == sql.id, "\(typed.debugDescription)")
        #expect(list.entry(covering: typed, matchCase: false)?.id == sql.id, "\(typed.debugDescription)")
        #expect(list.entry(covering: typed, matchCase: true, excluding: sql.id) == nil)
        // Editing the entry itself to a look-alike is allowed and stores the clean spelling.
        #expect(try list.upsert(Pronunciation(id: sql.id, written: typed, sayAs: "squeal", matchCase: true)).written == "SQL")
    }

    @Test func theLookupFindsNothingForInvisibleOrDifferentText() throws {
        let list = try PronunciationTests.list([("SQL", "sequel", true), ("葛飾", "katsushika", false), ("می\u{200C}خواهم", "mi-khaa-ham", false)])
        for typed in ["", " ", "\u{3164}", "\u{FE0F}\u{200D}", "S\u{200C}QL", "SQ\u{200D}L", "Sql\u{E0100}", "میخواهم"] {
            #expect(list.entry(covering: typed, matchCase: true) == nil, "\(typed.debugDescription)")
        }
        #expect(list.entry(covering: "葛\u{E0100}飾", matchCase: true)?.written == "葛飾")
        #expect(list.entry(covering: "\u{200C}می\u{200C}خواهم\u{200D}", matchCase: false)?.written == "می\u{200C}خواهم")
        #expect(list.entry(covering: "sql\u{3164}", matchCase: false)?.written == "SQL")
    }

    /// Property: for any typed spelling that validates, the lookup finds an entry exactly when upsert refuses
    /// the save as a clash, and the entry it finds is the one the refusal names. Editing an entry (`excluding`
    /// its id) agrees the same way.
    @Test("The lookup agrees with upsert", arguments: 0..<4)
    func lookupAgreesWithUpsert(chunk: Int) throws {
        let base = try PronunciationTests.list([("SQL", "sequel", true), ("sql", "s-q-l", true), ("Kubernetes", "koo-ber-NET-eez", false),
                                                ("葛飾", "katsushika", false), ("می\u{200C}خواهم", "mi-khaa-ham", false), ("IT", "eye-tee", true)])
        let spellings = ["SQL", "sql", "Sql", "Kubernetes", "KUBERNETES", "葛飾", "می\u{200C}خواهم", "میخواهم", "IT", "it", "Swift"]
        var clashes = 0
        for seed in UInt64(20_000 + chunk * 250)..<UInt64(20_000 + chunk * 250 + 250) {
            var rng = E.Seeded(state: seed)
            let typed = C.sprinkled(spellings.randomElement(using: &rng)!, Int.random(in: 0...4, using: &rng), &rng)
                + (Bool.random(using: &rng) ? " " : "")
            let matchCase = Bool.random(using: &rng)
            let excluded: UUID? = Bool.random(using: &rng) ? base.entries.randomElement(using: &rng)!.id : nil
            guard (try? PronunciationList.validated(Pronunciation(written: typed, sayAs: "x", matchCase: matchCase))) != nil else { continue }
            var copy = base
            let found = base.entry(covering: typed, matchCase: matchCase, excluding: excluded)
            do {
                try copy.upsert(Pronunciation(id: excluded ?? UUID(), written: typed, sayAs: "x", matchCase: matchCase))
                #expect(found == nil, "seed \(seed): \(typed.debugDescription) saved, but the lookup found \(found?.written ?? "")")
            } catch {
                clashes += 1
                #expect(found.map { "“\($0.written)” already has a pronunciation. Edit that entry instead." } == error.localizedDescription,
                        "seed \(seed): \(typed.debugDescription): \(error.localizedDescription)")
            }
        }
        #expect(clashes > 50)   // the generator must actually produce clashes
    }

    // MARK: The CSV header

    @Test(arguments: [["written\u{3164}", "say it as\u{115F}"], ["\u{FFA0}Written", "Say\u{1160} it as"], ["writ\u{FE0F}ten", "say_it_as\u{E0100}"],
                      ["w\u{034F}ritten", "\u{3164}\u{3164}say it as"], [" \u{200D}written ", "\u{200C}say it as\u{200D}"]])
    func headersWithFillersAndSelectorsAreSkipped(header: [String]) throws {
        #expect(PronunciationList.isHeader(header), "\(header)")
        #expect(PronunciationList.isHeader(header + ["match_case\u{3164}"]))
        var list = PronunciationList()
        let file = header.map { "\"\($0)\"" }.joined(separator: ",") + ",match_case\nSQL,sequel,true\n"
        #expect(try list.importCSV(file) == .init(added: 1, updated: 0))
        #expect(list.entries.map(\.written) == ["SQL"])
    }

    /// Every removable scalar, anywhere in either header cell, leaves the header recognized; one kept
    /// (visible) letter added to either cell makes it data instead.
    @Test func everyRemovableScalarLeavesTheHeaderRecognized() {
        var failures: [String] = []
        for scalar in C.removable {
            let s = String(scalar)
            if !PronunciationList.isHeader([s + "writ" + s + "ten" + s, "say" + s + " it as" + s]) { failures.append(C.hex(scalar)) }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20))")
        #expect(C.removable.count > 4_000)   // includes the reserved default-ignorable blocks
        #expect(!PronunciationList.isHeader(["written\u{3164}x", "say it as"]))
        #expect(!PronunciationList.isHeader(["written", "say it as\u{AC00}"]))   // 가 is a real syllable, not a filler
        #expect(!PronunciationList.isHeader(["\u{3164}", "say it as"]))
        #expect(!PronunciationList.isHeader(["SQL", "written"]))
    }

    /// A first row whose "written" cell is only a filler is not a header: it is read as data and refused,
    /// and nothing is imported.
    @Test func aFillerOnlyFirstRowIsDataAndFails() throws {
        var list = PronunciationList()
        do { _ = try list.importCSV("\u{3164},say it as\nSQL,sequel\n"); Issue.record("imported a filler-only word") }
        catch { #expect(error.localizedDescription == "Row 1: Written needs at least one letter or number.") }
        #expect(list.isEmpty)
    }
}

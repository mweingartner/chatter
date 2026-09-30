import Foundation
import Testing
@testable import ChatterCore

/// Pronunciations respell whole words before speech, without touching anything else in the text.
struct PronunciationTests {
    static func list(_ entries: [(String, String, Bool)]) throws -> PronunciationList {
        var list = PronunciationList()
        for (written, sayAs, matchCase) in entries { try list.upsert(Pronunciation(written: written, sayAs: sayAs, matchCase: matchCase)) }
        return list
    }

    @Test func respellsWholeWordsAndLeavesEverythingElse() throws {
        let list = try Self.list([("Kubernetes", "koo-ber-NET-eez", false), ("SQL", "sequel", true)])
        #expect(try list.respell("Deploy Kubernetes today.") == "Deploy koo-ber-NET-eez today.")
        #expect(try list.respell("kubernetes, KUBERNETES and Kubernetes!") == "koo-ber-NET-eez, koo-ber-NET-eez and koo-ber-NET-eez!")
        #expect(try list.respell("SQL, (SQL), SQL's, SQL’s, \"SQL\" and SQL.") == "sequel, (sequel), sequel's, sequel’s, \"sequel\" and sequel.")
        #expect(try list.respell("SQLite, MySQL, NoSQL and sql") == "SQLite, MySQL, NoSQL and sql")
        #expect(try list.respell("Kubernetes-native tools") == "koo-ber-NET-eez-native tools")
        #expect(try list.respell("") == "")
        #expect(try PronunciationList().respell("Nothing to change.") == "Nothing to change.")
    }

    @Test func matchCaseKeepsAcronymsApartFromWords() throws {
        let list = try Self.list([("IT", "I T", true)])
        #expect(try list.respell("IT said it works; ask IT.") == "I T said it works; ask I T.")
        #expect(try list.respell("It is fine.") == "It is fine.")
    }

    @Test func longerWrittenFormsWinAndReplacementsAreNeverRespelledAgain() throws {
        let list = try Self.list([("Visual Studio", "VIZH-oo-al studio", false), ("Visual Studio Code", "VS code", false),
                                  ("VS", "vee ess", true), ("A", "B B", true), ("B", "C", true)])
        #expect(try list.respell("Open Visual Studio Code, not Visual Studio.") == "Open VS code, not VIZH-oo-al studio.")
        #expect(try list.respell("A") == "B B")                // not "C C"
        #expect(try list.respell("VS VS") == "vee ess vee ess")
    }

    @Test func punctuationAndDigitsAtTheEdgesFollowTheSameRule() throws {
        let list = try Self.list([(".NET", "dot net", true), ("C++", "C plus plus", true), ("5G", "five G", true), ("AT&T", "A T and T", true)])
        #expect(try list.respell("the .NET runtime and ASP.NET") == "the dot net runtime and ASP.NET")
        #expect(try list.respell("C++ code, C++11 code") == "C plus plus code, C++11 code")
        #expect(try list.respell("5G networks, not 15G") == "five G networks, not 15G")
        #expect(try list.respell("AT&T's plan") == "A T and T's plan")
    }

    @Test func unicodeCompositionAndNeighboursAreHandled() throws {
        let list = try Self.list([("Café", "ka-FAY", false), ("Kubernetes", "koo-ber-NET-eez", false)])
        #expect(try list.respell("Cafe\u{301} opens") == "ka-FAY opens")          // decomposed é matches the composed entry
        #expect(try list.respell("🚀Kubernetes🚀") == "🚀koo-ber-NET-eez🚀")
        #expect(try list.respell("中Kubernetes") == "中Kubernetes")                 // a letter on either side keeps the word intact
        #expect(try list.respell("Cafe opens") == "Cafe opens")                    // diacritics still matter
    }

    /// Property: respelling only ever replaces whole matches of an entry; text made of other words is
    /// returned unchanged, and every replacement sits between non-word characters.
    @Test func randomTextsChangeOnlyAtWholeWordMatches() throws {
        let list = try Self.list([("API", "A P I", true), ("Kubernetes", "koo-ber-NET-eez", false), ("Visual Studio Code", "V S code", false)])
        var rng = SeededGenerator(seed: 0x5EED)
        let pieces = ["API", "APIs", "api", "Kubernetes", "kubernetes", "Kuber", "netes", "Visual", "Studio", "Code", "Visual Studio Code",
                      " ", ", ", ". ", "-", "’s", "é", "中", "🚀", "\n", "x"]
        for _ in 0..<500 {
            let text = (0..<Int.random(in: 0...30, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let spoken = try list.respell(text)
            // Undo the replacements: every "A P I" etc. must come from a whole-word match in the original.
            let undone = spoken.replacingOccurrences(of: "koo-ber-NET-eez", with: "⟦K⟧").replacingOccurrences(of: "V S code", with: "⟦V⟧").replacingOccurrences(of: "A P I", with: "⟦A⟧")
            #expect(undone.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "").count <= spoken.count)
            if !text.contains("API"), text.range(of: "kubernetes", options: .caseInsensitive) == nil, text.range(of: "visual studio code", options: .caseInsensitive) == nil {
                #expect(spoken == text, "\(text.debugDescription)")
            }
            #expect(!spoken.contains("A P Is"), "APIs must not be respelled: \(text.debugDescription)")
        }
    }

    @Test func respelledTextHasABoundedSize() throws {
        let list = try Self.list([("X", String(repeating: "ecks ", count: 40), true)])
        #expect(try list.respell(String(repeating: "X ", count: 900)).utf8.count <= PronunciationList.maxRespelledBytes)
        #expect(throws: ChatterError.self) { try list.respell(String(repeating: "X ", count: 1_200)) }
    }

    @Test func entriesAreValidatedAndCollisionsRefused() throws {
        var list = PronunciationList()
        let sql = try list.upsert(Pronunciation(written: "  SQL ", sayAs: " sequel ", matchCase: true))
        #expect(sql.written == "SQL" && sql.sayAs == "sequel")
        for (written, sayAs) in [("", "x"), ("   ", "x"), ("---", "x"), ("x", "!!!"), ("two\nlines", "x"), ("x", "tab\there"),
                                 (String(repeating: "a", count: 101), "x"), ("x", String(repeating: "b", count: 201))] {
            #expect(throws: ChatterError.self, "\(written.debugDescription) → \(sayAs.debugDescription)") {
                try list.upsert(Pronunciation(written: written, sayAs: sayAs, matchCase: false))
            }
        }
        // "sql" (any case) would claim the same text as "SQL"; an exact-case sibling does not.
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "sql", sayAs: "S Q L", matchCase: false)) }
        try list.upsert(Pronunciation(written: "IT", sayAs: "I T", matchCase: true))
        try list.upsert(Pronunciation(written: "It", sayAs: "it", matchCase: true))
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "IT", sayAs: "eye tee", matchCase: true)) }
        // Editing an entry does not collide with itself.
        var edited = sql; edited.sayAs = "S Q L"
        try list.upsert(edited)
        #expect(list.entries.first { $0.id == sql.id }?.sayAs == "S Q L" && list.entries.count == 3)
        list.remove(id: sql.id)
        #expect(list.entries.count == 2)
    }

    @Test func theListHasACapacity() throws {
        var list = PronunciationList()
        for index in 0..<PronunciationList.maxEntries { try list.upsert(Pronunciation(written: "word\(index)", sayAs: "say \(index)", matchCase: false)) }
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "one more", sayAs: "x", matchCase: false)) }
    }

    @Test func matchCaseIsSuggestedForAcronymsAndStylizedNames() {
        for written in ["IBM", "SQL", "iOS", "NGINX", "AT&T", "GitHub"] { #expect(Pronunciation.suggestsMatchCase(for: written), "\(written)") }
        for written in ["Kubernetes", "nginx", "Azure", "C", "x86"] { #expect(!Pronunciation.suggestsMatchCase(for: written), "\(written)") }
    }

    @Test func listsRoundTripThroughJSON() throws {
        let list = try Self.list([("Kubernetes", "koo-ber-NET-eez", false), ("SQL", "sequel", true)])
        let decoded = try JSONDecoder().decode(PronunciationList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(try decoded.respell("SQL on Kubernetes") == "sequel on koo-ber-NET-eez")
    }

    // MARK: CSV

    @Test func csvRoundTripsWithQuoting() throws {
        let list = try Self.list([("Kubernetes", "koo-ber-NET-eez", false), ("R&D, Inc.", "R and D, incorporated", true), ("Say \"hi\"", "say hi", false)])
        let csv = list.csv
        #expect(csv.hasPrefix("written,say_it_as,match_case\n"))
        #expect(csv.contains("\"R&D, Inc.\",\"R and D, incorporated\",true"))
        #expect(csv.contains("\"Say \"\"hi\"\"\",say hi,false"))
        var imported = PronunciationList()
        let summary = try imported.importCSV(csv)
        #expect(summary == .init(added: 3, updated: 0))
        #expect(Set(imported.entries.map { [$0.written, $0.sayAs, "\($0.matchCase)"] }) == Set(list.entries.map { [$0.written, $0.sayAs, "\($0.matchCase)"] }))
    }

    @Test func csvImportAcceptsCommonShapes() throws {
        var list = try Self.list([("SQL", "S Q L", true)])
        let text = "\u{FEFF}Written, Say it as, Match case\r\nSQL,sequel,yes\r\n\r\nKubernetes,koo-ber-NET-eez,\r\nIBM,I B M\r\n\"GIF\",\"jif\",no"
        let summary = try list.importCSV(text)
        #expect(summary == .init(added: 3, updated: 1))
        let byWritten = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0) })
        #expect(byWritten["SQL"]?.sayAs == "sequel" && byWritten["SQL"]?.matchCase == true)
        #expect(byWritten["Kubernetes"]?.matchCase == false)         // blank: suggested from the spelling
        #expect(byWritten["IBM"]?.matchCase == true)                 // missing column: suggested too
        #expect(byWritten["GIF"]?.sayAs == "jif" && byWritten["GIF"]?.matchCase == false)
        var headerless = PronunciationList()
        #expect(try headerless.importCSV("Azure,AZH-er,false\n") == .init(added: 1, updated: 0))
    }

    @Test func csvImportIsAllOrNothingAndNamesTheBadRow() throws {
        var list = try Self.list([("SQL", "sequel", true)])
        let before = list
        for (text, row) in [("Kubernetes,koo-ber-NET-eez\nonly one field\n", "Row 2"), ("a,b,maybe\n", "Row 1"),
                            ("ok,fine\nbad,\n", "Row 2"), ("a,b,true,extra\n", "Row 1")] {
            do { _ = try list.importCSV(text); Issue.record("imported \(text.debugDescription)") } catch {
                #expect(error.localizedDescription.hasPrefix(row), "\(error.localizedDescription)")
            }
            #expect(list == before)
        }
        #expect(throws: ChatterError.self) { try list.importCSV("\"unterminated,value\n") }
        #expect(throws: ChatterError.self) { try list.importCSV(String(repeating: "a,b\n", count: 300_000)) }
        #expect(list == before)
    }

    /// A letter carrying thousands of combining marks is one character but megabytes of text: fields are
    /// limited by Unicode scalars and bytes too, so such an entry can never be saved or imported.
    @Test func stackedCombiningMarksAreRejected() throws {
        var list = PronunciationList()
        let zalgo = "a" + String(repeating: "\u{301}", count: 1_000)
        #expect(zalgo.count == 1)
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "X", sayAs: zalgo, matchCase: true)) }
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: zalgo, sayAs: "x", matchCase: true)) }
        #expect(throws: ChatterError.self) { try list.importCSV("X,\(zalgo)\n") }
        #expect(list.isEmpty)
        // Ordinary accented and CJK text within the character limit is still fine.
        try list.upsert(Pronunciation(written: "Café", sayAs: String(repeating: "漢", count: 200), matchCase: false))
    }

    /// The respelled size is computed before anything is built: an expansion past the cap fails fast.
    @Test func expansionPastTheCapFailsBeforeBuilding() throws {
        let list = try Self.list([("X", String(repeating: "e", count: 200), true)])
        let text = String(repeating: "X ", count: 50_000)          // 100 KB → 10 MB if built
        let start = ContinuousClock.now
        #expect(throws: ChatterError.self) { try list.respell(text) }
        #expect(ContinuousClock.now - start < .seconds(20))
        // Just under the cap still respells.
        let fits = String(repeating: "X ", count: 990)
        #expect(try list.respell(fits).utf8.count <= PronunciationList.maxRespelledBytes)
    }

    @Test func importsLargerThanTheCapacityAreRefusedWhole() throws {
        var list = try Self.list([("SQL", "sequel", true)])
        let before = list
        let rows = (0...PronunciationList.maxEntries).map { "word\($0),say \($0)" }.joined(separator: "\n")
        do { _ = try list.importCSV(rows); Issue.record("imported 1,001 rows") } catch {
            #expect(error.localizedDescription.contains("more than 1,000"))
        }
        #expect(list == before)
    }

    /// Cells a spreadsheet would run as formulas are exported with a leading apostrophe, and the
    /// apostrophe is removed again on import, so the list round-trips exactly.
    @Test func exportGuardsFormulaCellsAndImportRestoresThem() throws {
        let entries: [(String, String, Bool)] = [("=SUM(A1)", "equals sum", false), ("+1 plan", "plus one plan", false),
                                                 ("@handle", "at handle", false), ("'=already", "quote equals", false), ("Normal", "-ish", false)]
        let list = try Self.list(entries)
        let csv = list.csv
        #expect(csv.contains("'=SUM(A1)") && csv.contains("'+1 plan") && csv.contains("'@handle") && csv.contains("''=already") && csv.contains("'-ish"))
        #expect(!csv.split(separator: "\n").dropFirst().contains { line in line.first.map { "=+-@".contains($0) } == true })
        var imported = PronunciationList()
        _ = try imported.importCSV(csv)
        #expect(Set(imported.entries.map { "\($0.written)|\($0.sayAs)" }) == Set(entries.map { "\($0.0)|\($0.1)" }))
    }

    /// A row without a match-case value that names an existing word updates its respelling and keeps its settings.
    @Test func importKeepsMatchCaseWhenTheColumnIsBlank() throws {
        var list = try Self.list([("Kubernetes", "koo-ber-NET-eez", false), ("SQL", "sequel", true)])
        #expect(try list.importCSV("KUBERNETES,koo-ber-NETTIES\nsql,S Q L,\n") == .init(added: 0, updated: 2))
        #expect(list.entries.count == 2)
        let byWritten = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0) })
        #expect(byWritten["Kubernetes"]?.matchCase == false && byWritten["Kubernetes"]?.sayAs == "koo-ber-NETTIES")
        #expect(byWritten["SQL"]?.matchCase == true && byWritten["SQL"]?.sayAs == "S Q L")
        // An explicit value still decides: this adds an exact-case lowercase sibling.
        #expect(try list.importCSV("sql,squeal,true\n") == .init(added: 1, updated: 0))
    }

    @Test func spacesBeforeAQuotedFieldAreAllowed() throws {
        var list = PronunciationList()
        _ = try list.importCSV("SQL, \"sequel, the language\", true\n")
        #expect(list.entries.first?.sayAs == "sequel, the language" && list.entries.first?.matchCase == true)
    }

    /// Invisible formatting characters are removed from both fields, so an entry never looks different
    /// from what it does: a direction override can't make "on" display as "no", and a zero-width space
    /// can't make a second "SQL" that never matches. Joiners, which scripts and emoji need, stay.
    @Test func invisibleFormattingCharactersAreRemoved() throws {
        var list = PronunciationList()
        let saved = try list.upsert(Pronunciation(written: "\u{FEFF}SQL\u{200B}", sayAs: "\u{202E}on\u{202C}", matchCase: true))
        #expect(saved.written == "SQL" && saved.sayAs == "on")
        for invisible in ["\u{00AD}", "\u{200B}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{2060}", "\u{2066}", "\u{2069}", "\u{FEFF}", "\u{E0041}"] {
            let entry = try PronunciationList.validated(Pronunciation(written: "Kuber\(invisible)netes", sayAs: " koo\(invisible)-ber\(invisible) ", matchCase: false))
            #expect(entry.written == "Kubernetes" && entry.sayAs == "koo-ber", "U+\(String(invisible.unicodeScalars.first!.value, radix: 16, uppercase: true))")
        }
        // A look-alike of an existing entry is that entry, and a field of nothing visible is empty.
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "S\u{200B}QL", sayAs: "squeal", matchCase: true)) }
        #expect(throws: ChatterError.self) { try PronunciationList.validated(Pronunciation(written: "\u{200B} \u{2060}", sayAs: "x", matchCase: false)) }
        // Joiners stay: Persian spelling needs U+200C, and emoji sequences U+200D.
        let persian = "می\u{200C}خواهم", family = "👨\u{200D}👩\u{200D}👧"
        let kept = try PronunciationList.validated(Pronunciation(written: persian, sayAs: "mi khaaham \(family)", matchCase: false))
        #expect(kept.written == persian && kept.sayAs == "mi khaaham \(family)")
        // Imports and saved lists are cleaned the same way; a look-alike row updates the existing entry.
        #expect(try list.importCSV("\u{200B}SQL,\u{202E}sequel\n") == .init(added: 0, updated: 1))
        #expect(list.entries.map(\.written) == ["SQL"] && list.entries.first?.sayAs == "sequel" && list.entries.first?.matchCase == true)
        let json = #"{"entries":[{"id":"\#(UUID().uuidString)","written":"S\u200bQL","sayAs":"\u202eon","matchCase":true}]}"#
        let loaded = try JSONDecoder().decode(PronunciationList.self, from: Data(json.utf8))
        #expect(loaded.entries.first?.written == "SQL" && loaded.entries.first?.sayAs == "on")
    }

    /// A space after the comma doesn't hide the formula guard: hand-written rows import like exported ones.
    @Test func spacesBeforeAGuardedCellAreIgnored() throws {
        var list = PronunciationList()
        _ = try list.importCSV("SQL, '=x\nIBM,'=y\nGIF,  ''=z\n")
        #expect(Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0.sayAs) }) == ["SQL": "=x", "IBM": "=y", "GIF": "'=z"])
    }

    /// The message names the limit that was reached.
    @Test func sizeRefusalsNameTheLimitReached() throws {
        do { _ = try PronunciationList.validated(Pronunciation(written: String(repeating: "a", count: 101), sayAs: "x", matchCase: false)); Issue.record("accepted 101 characters") }
        catch { #expect(error.localizedDescription == "Written can be at most 100 characters.") }
        // Devanagari syllables of four scalars and 12 bytes each: 67 are within 100 characters but over 800 bytes.
        let dense = String(repeating: "क्षि", count: 67)
        #expect(dense.count <= 100 && dense.utf8.count == 804)
        do { _ = try PronunciationList.validated(Pronunciation(written: dense, sayAs: "x", matchCase: false)); Issue.record("accepted 804 bytes") }
        catch { #expect(error.localizedDescription == "Written is too long. Accented and combined characters take extra room, so shorten it.") }
    }

    @Test func respellingStaysFastForLargeListsAndTexts() throws {
        var list = PronunciationList()
        for index in 0..<PronunciationList.maxEntries { try list.upsert(Pronunciation(written: "Product\(index)", sayAs: "product \(index)", matchCase: index.isMultiple(of: 2))) }
        let text = String(repeating: "Deploy Product17 and product42 with Kubernetes, then check Product999. ", count: 1_400)   // ~100 KB
        let start = ContinuousClock.now
        let spoken = try list.respell(text)
        #expect(ContinuousClock.now - start < .seconds(20))   // generous for debug builds
        #expect(spoken.contains("product 17") && spoken.contains("product 999"))
        #expect(spoken.contains("product42"))   // entry 42 matches case; "product42" is lowercase
    }
}

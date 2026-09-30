import Foundation
import Testing
@testable import ChatterCore

/// Exact limits and CSV rules: field sizes by character, Unicode scalar and byte; the respelled-size
/// cap; the import row cap; the spreadsheet formula guard; rows without a match-case value; and the
/// parser's handling of spaces and quotes. Random cases are seeded, and a failure names its seed.
@Suite("Pronunciation boundaries")
struct PronunciationBoundaryTests {
    typealias T = PronunciationTests
    typealias E = PronunciationEdgeTests

    static func triples(_ list: PronunciationList) -> [[String]] {
        list.entries.map { [$0.written, $0.sayAs, "\($0.matchCase)"] }.sorted { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") }
    }

    // MARK: Field limits

    /// One character made of `marks + 1` scalars: a letter carrying combining acute accents (2 bytes each).
    static func stacked(_ marks: Int) -> String { "e" + String(repeating: "\u{301}", count: marks) }
    /// One 8-byte letter in 2 scalars: a supplementary-plane ideograph carrying a supplementary combining mark.
    static let wide = "\u{20000}\u{1D167}"
    /// One 9-byte character in 5 scalars: a letter carrying four accents.
    static let wider = "e\u{301}\u{301}\u{301}\u{301}"

    @Test(arguments: [("Written", PronunciationList.maxWrittenLength), ("Say it as", PronunciationList.maxSayAsLength)])
    func fieldsAreLimitedByScalarsExactly(field: String, limit: Int) throws {
        func entry(_ value: String) -> Pronunciation {
            field == "Written" ? Pronunciation(written: value, sayAs: "x", matchCase: false) : Pronunciation(written: "x", sayAs: value, matchCase: false)
        }
        // `limit` characters of four scalars each: exactly limit * 4 scalars, under the byte limit.
        let atLimit = String(repeating: Self.stacked(3), count: limit)
        #expect(atLimit.count == limit && atLimit.unicodeScalars.count == limit * 4 && atLimit.utf8.count < limit * 8)
        let accepted = try PronunciationList.validated(entry(atLimit))
        #expect((field == "Written" ? accepted.written : accepted.sayAs) == atLimit)
        // One more mark on the last character: still `limit` characters, one scalar too many.
        let over = atLimit + "\u{301}"
        #expect(over.count == limit && over.unicodeScalars.count == limit * 4 + 1)
        do { _ = try PronunciationList.validated(entry(over)); Issue.record("accepted \(limit * 4 + 1) scalars") } catch {
            #expect(error.localizedDescription == "\(field) is too long. Accented and combined characters take extra room, so shorten it.")
        }
        var list = PronunciationList()
        #expect(throws: ChatterError.self) { try list.upsert(entry(over)) }
        #expect(list.isEmpty)
    }

    @Test(arguments: [("Written", PronunciationList.maxWrittenLength), ("Say it as", PronunciationList.maxSayAsLength)])
    func fieldsAreLimitedByBytesExactly(field: String, limit: Int) throws {
        func entry(_ value: String) -> Pronunciation {
            field == "Written" ? Pronunciation(written: value, sayAs: "x", matchCase: false) : Pronunciation(written: "x", sayAs: value, matchCase: false)
        }
        #expect(Self.wide.count == 1 && Self.wide.utf8.count == 8 && Self.wider.count == 1 && Self.wider.utf8.count == 9)
        let atLimit = String(repeating: Self.wide, count: limit)
        #expect(atLimit.count == limit && atLimit.unicodeScalars.count == limit * 2 && atLimit.utf8.count == limit * 8)
        _ = try PronunciationList.validated(entry(atLimit))
        // Same number of characters and well under the scalar limit, one byte over.
        let over = String(repeating: Self.wide, count: limit - 1) + Self.wider
        #expect(over.count == limit && over.unicodeScalars.count < limit * 4 && over.utf8.count == limit * 8 + 1)
        do { _ = try PronunciationList.validated(entry(over)); Issue.record("accepted \(limit * 8 + 1) bytes") } catch {
            #expect(error.localizedDescription == "\(field) is too long. Accented and combined characters take extra room, so shorten it.")
        }
        // Limits apply after trimming: surrounding spaces never count.
        _ = try PronunciationList.validated(entry("  " + atLimit + " \t"))
    }

    @Test func eachLimitIsIndependent() throws {
        // A ZWJ family emoji is one character of 7 scalars: 99 of them plus a letter are 100 characters but 694 scalars.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.count == 1 && family.unicodeScalars.count == 7)
        let emojiHeavy = "a" + String(repeating: family, count: 99)
        #expect(emojiHeavy.count == 100)
        #expect(throws: ChatterError.self) { try PronunciationList.validated(Pronunciation(written: emojiHeavy, sayAs: "x", matchCase: false)) }
        // "Say it as" allows twice as much: 400 scalars fit, 806 do not.
        _ = try PronunciationList.validated(Pronunciation(written: "x", sayAs: "a" + String(repeating: family, count: 57), matchCase: false))   // 400 scalars
        #expect(throws: ChatterError.self) {
            try PronunciationList.validated(Pronunciation(written: "x", sayAs: "a" + String(repeating: family, count: 115), matchCase: false))  // 806 scalars
        }
        // A CSV row over a limit is named and nothing is imported.
        var list = try T.list([("SQL", "sequel", true)])
        let before = list
        do { _ = try list.importCSV("ok,fine\nx,\(String(repeating: Self.wide, count: 199) + Self.wider)\n"); Issue.record("imported") } catch {
            #expect(error.localizedDescription.hasPrefix("Row 2:"), "\(error.localizedDescription)")
        }
        #expect(list == before)
    }

    // MARK: Respelled size

    static let sayAsPieces = ["é", "e\u{301}", "中文", "🚀x", "👍🏽a", "Straße", "ǅ", "\u{301}a", Self.wide, "x", " ", "-", "SQL", "ﬁ", "İ"]

    /// Entries with multibyte respellings (composed, decomposed, emoji, supplementary planes), some long.
    static func sizedList(_ rng: inout E.Seeded) -> PronunciationList {
        var list = PronunciationList()
        for _ in 0..<Int.random(in: 1...12, using: &rng) {
            let written = Bool.random(using: &rng) ? E.writtenPool.randomElement(using: &rng)!
                : (0..<Int.random(in: 1...3, using: &rng)).map { _ in E.textPieces.randomElement(using: &rng)! }.joined()
            let sayAs = Int.random(in: 0..<8, using: &rng) == 0 ? String(repeating: "中", count: 200)
                : (0..<Int.random(in: 1...20, using: &rng)).map { _ in sayAsPieces.randomElement(using: &rng)! }.joined()
            _ = try? list.upsert(Pronunciation(written: written, sayAs: sayAs, matchCase: Bool.random(using: &rng)))
        }
        return list
    }

    /// Property: the size computed before building equals the size of what is built. Random texts (mixed
    /// scripts, combining marks, emoji, CR, LF and CRLF) are repeated and padded so the respelled result
    /// lands one byte under, exactly on, and one byte over the cap: under and on are respelled like the
    /// reference, over is refused, and a text nothing respells is returned whatever its size.
    @Test("The respelled-size check is exact for random lists and texts", arguments: 0..<8)
    func respelledSizeCheckIsExact(chunk: Int) throws {
        let limit = PronunciationList.maxRespelledBytes
        for seed in UInt64(5_000 + chunk * 6)..<UInt64(5_000 + chunk * 6 + 6) {
            var rng = E.Seeded(state: seed)
            let list = Self.sizedList(&rng)
            let breaks = ["\r\n", "\r", "\n", " "]
            let base = E.randomText(&rng) + breaks.randomElement(using: &rng)! + E.randomText(&rng) + " SQL café 中文"
            let (spokenBase, matches) = E.referenceWithMatches(list.entries, base)
            // Line breaks keep copies independent (see "Respelling distributes over line breaks"), so copies of the
            // text become copies of its respelling, with many replacements of every size.
            let copies = Bool.random(using: &rng) ? 1 : max(1, min(3_000, (limit / 2) / (spokenBase.utf8.count + 1)))
            let body = Array(repeating: base, count: copies).joined(separator: "\n")
            let spokenBody = Array(repeating: spokenBase, count: copies).joined(separator: "\n")
            for delta in -1...1 {
                let padding = String(repeating: " ", count: limit + delta - spokenBody.utf8.count - 1)
                let text = body + "\n" + padding, expected = spokenBody + "\n" + padding
                let context = "seed \(seed) delta \(delta) copies \(copies): \(base.debugDescription) with [\(E.describe(list))]"
                if matches == 0 {
                    #expect(try list.respell(text) == text, "\(context)")
                } else if delta <= 0 {
                    let spoken = try list.respell(text)
                    #expect(spoken.utf8.count == limit + delta, "\(context)")
                    #expect(Array(spoken.unicodeScalars) == Array(expected.unicodeScalars), "\(context)")
                } else {
                    #expect(throws: ChatterError.self, "\(context)") { try list.respell(text) }
                }
            }
        }
    }

    /// Replacements that shrink the text are subtracted exactly too: a text over the cap is accepted
    /// once respelling brings it to the cap, and refused one byte above.
    @Test func shrinkingReplacementsAreCountedExactly() throws {
        let limit = PronunciationList.maxRespelledBytes
        let list = try T.list([("Kubernetes", "k8s", false)])   // 10 bytes become 3
        let words = Array(repeating: "Kubernetes", count: 1_000).joined(separator: " ")
        let respelledWords = 1_000 * 3 + 999
        for (delta, fits) in [(0, true), (1, false)] {
            let text = words + " " + String(repeating: "z", count: limit + delta - respelledWords - 1)
            #expect(text.utf8.count > limit)
            if fits { #expect(try list.respell(text).utf8.count == limit) } else { #expect(throws: ChatterError.self) { try list.respell(text) } }
        }
        // The cap's message tells the caller what to do.
        do { _ = try list.respell(words + " " + String(repeating: "z", count: limit)); Issue.record("accepted") } catch {
            #expect(error.localizedDescription.contains("200,000 bytes") && error.localizedDescription.contains("Split it"))
        }
    }

    /// Jobs respell a value copy of the list off the main actor, several at once: concurrent respells of one
    /// list agree with a serial respell, and a refusal is the same refusal in every task.
    @Test func concurrentRespellsOfOneListAgree() async throws {
        var rng = E.Seeded(state: 0xC0C0)
        let list = Self.sizedList(&rng)
        let texts = (0..<32).map { _ in String(repeating: E.randomText(&rng) + " SQL café\n", count: 200) }
        let serial = texts.map { try? list.respell($0) }
        let concurrent = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, try? await Task.detached(priority: .userInitiated) { try list.respell(text) }.value) }
            }
            var results = [String?](repeating: nil, count: texts.count)
            for await (index, spoken) in group { results[index] = spoken }
            return results
        }
        #expect(concurrent == serial, "[\(E.describe(list))]")
        let huge = try T.list([("X", String(repeating: "y", count: 200), true)])
        let refusals = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { (try? huge.respell(String(repeating: "X ", count: 5_000))) == nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(refusals == 8)
    }

    // MARK: Saved list

    /// A saved file is held to the same scalar and byte limits as typed entries.
    @Test func decodingAppliesScalarAndByteLimits() throws {
        func decode(_ written: String, _ sayAs: String) throws -> PronunciationList {
            try JSONDecoder().decode(PronunciationList.self, from: E.json([E.object(written, sayAs)]))
        }
        _ = try decode(String(repeating: Self.stacked(3), count: 100), String(repeating: Self.wide, count: 200))
        for (written, sayAs) in [(String(repeating: Self.stacked(3), count: 100) + "\u{301}", "x"), ("x", String(repeating: Self.stacked(3), count: 200) + "\u{301}"),
                                 (String(repeating: Self.wide, count: 99) + Self.wider, "x"), ("x", String(repeating: Self.wide, count: 199) + Self.wider),
                                 ("x", "a" + String(repeating: "\u{301}", count: 10_000))] {
            #expect(throws: DecodingError.self) { try decode(written, sayAs) }
        }
    }

    // MARK: Import row cap

    static func rows(_ count: Int, prefix: String = "word") -> String {
        (0..<count).map { "\(prefix)\($0),say \($0)" }.joined(separator: "\n")
    }

    @Test(arguments: [false, true])
    func importAcceptsExactlyAThousandRows(header: Bool) throws {
        var list = PronunciationList()
        let text = (header ? "written,say_it_as,match_case\n" : "") + Self.rows(PronunciationList.maxEntries)
        #expect(try list.importCSV(text) == .init(added: PronunciationList.maxEntries, updated: 0))
        #expect(list.entries.count == PronunciationList.maxEntries)
        // Blank lines and CRLF endings are not rows.
        var spaced = PronunciationList()
        let crlf = "\r\n\r\n" + (header ? "Written, Say it as\r\n\r\n" : "") + Self.rows(PronunciationList.maxEntries).replacingOccurrences(of: "\n", with: "\r\n\r\n  \r\n") + "\r\n\r\n"
        #expect(try spaced.importCSV(crlf) == .init(added: PronunciationList.maxEntries, updated: 0))
    }

    @Test(arguments: [false, true])
    func importRefusesAThousandAndOneRowsWhole(header: Bool) throws {
        var list = try T.list([("SQL", "sequel", true)])
        let before = list
        for body in [Self.rows(PronunciationList.maxEntries + 1),
                     // Every row updates the same entry, and the first row is invalid: the cap is still checked first.
                     "bad row\n" + Array(repeating: "SQL,S Q L", count: PronunciationList.maxEntries).joined(separator: "\n")] {
            let text = (header ? "written,say_it_as\n" : "") + body
            do { _ = try list.importCSV(text); Issue.record("imported 1,001 rows") } catch {
                #expect(error.localizedDescription == "That file lists more than 1,000 pronunciations, and Chatter keeps up to 1,000. Split it or remove some.")
            }
            #expect(list == before)
        }
    }

    @Test func refusingTooManyRowsIsQuick() throws {
        // 1,001 long rows, refused before any of them is validated or merged.
        let row = String(repeating: "a", count: 100) + "," + String(repeating: "b", count: 200)
        let text = Array(repeating: row, count: 1_001).joined(separator: "\n")
        var list = PronunciationList()
        let start = ContinuousClock.now
        #expect(throws: ChatterError.self) { try list.importCSV(text) }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(list.isEmpty)
    }

    // MARK: Formula guard

    @Test func formulaGuardHelpers() {
        for cell in ["=x", "+1", "-1", "@a", "\tx", "\rx", "'=x", "'''@x", "''-"] { #expect(PronunciationList.needsFormulaGuard(cell), "\(cell.debugDescription)") }
        for cell in ["", "'", "'''", "x=", " =x", "'x", "'' +", "\u{FF1D}x", "\"=x"] { #expect(!PronunciationList.needsFormulaGuard(cell), "\(cell.debugDescription)") }
        // Exactly one apostrophe is removed, and only in front of a cell the export would have guarded.
        let cases: [(String, String)] = [("'=x", "=x"), ("''=x", "'=x"), ("'''-x", "''-x"), ("'x", "'x"), ("''x", "''x"), ("'", "'"), ("''", "''"),
                                         ("=x", "=x"), ("x'", "x'"), (" '=x", " '=x"), ("'@", "@")]
        for (cell, expected) in cases { #expect(PronunciationList.unguarded(cell) == expected, "\(cell.debugDescription)") }
    }

    /// Property: values beginning with any number of apostrophes and a formula character survive export and
    /// import exactly, no exported cell starts with a formula character, and each cell unguards to its value.
    @Test("The formula guard round-trips", arguments: 0..<4)
    func formulaGuardRoundTrips(chunk: Int) throws {
        let starts = ["=", "+", "-", "@"]
        let pieces = ["'", "''", "=", "+", "-", "@", "a", "Z", "7", " ", ",", "\"", "é", "SUM(A1)", "'x", "\u{FF1D}", "中"]
        for seed in UInt64(6_000 + chunk * 50)..<UInt64(6_000 + chunk * 50 + 50) {
            var rng = E.Seeded(state: seed)
            func value() -> String {
                let lead = Bool.random(using: &rng)
                    ? String(repeating: "'", count: Int.random(in: 0...3, using: &rng)) + starts.randomElement(using: &rng)! : ""
                return lead + (0..<Int.random(in: 1...5, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            }
            var list = PronunciationList()
            for _ in 0..<Int.random(in: 1...15, using: &rng) {
                _ = try? list.upsert(Pronunciation(written: value(), sayAs: value(), matchCase: Bool.random(using: &rng)))
            }
            let csv = list.csv
            let parsed = try PronunciationList.parseCSV(csv).dropFirst()
            #expect(parsed.count == list.entries.count, "seed \(seed)")
            for (cells, entry) in zip(parsed, list.sorted) {
                for (cell, stored) in zip(cells.prefix(2), [entry.written, entry.sayAs]) {
                    #expect(cell.unicodeScalars.first.map { !PronunciationList.formulaStarts.contains($0) } == true, "seed \(seed): \(cell.debugDescription)")
                    #expect(PronunciationList.unguarded(cell) == stored, "seed \(seed): \(cell.debugDescription) for \(stored.debugDescription)")
                }
            }
            var imported = PronunciationList()
            do {
                #expect(try imported.importCSV(csv) == .init(added: list.entries.count, updated: 0), "seed \(seed)")
                #expect(Self.triples(imported) == Self.triples(list), "seed \(seed): \(csv.debugDescription)")
                // Exporting the import gives the same file.
                #expect(imported.csv == csv, "seed \(seed)")
            } catch {
                Issue.record("seed \(seed): \(error.localizedDescription) importing \(csv.debugDescription)")
            }
        }
    }

    @Test func valuesStartingWithSeveralApostrophes() throws {
        let values = ["'''=x", "''+1 plan", "'-", "'''x", "''a", "'@'b", "x'''", "'", "' =x"]
        var list = PronunciationList()
        for (index, value) in values.enumerated() {
            let sayAs = value.contains(where: { $0.isLetter || $0.isNumber }) ? value : value + "1"
            try list.upsert(Pronunciation(written: "w\(index)", sayAs: sayAs, matchCase: false))
        }
        let csv = list.csv
        #expect(csv.contains("w0,''''=x,false") && csv.contains("w1,'''+1 plan,false") && csv.contains("w3,'''x,false") && csv.contains("w8,' =x,false"))
        var imported = PronunciationList()
        _ = try imported.importCSV(csv)
        #expect(Self.triples(imported) == Self.triples(list))
    }

    // MARK: Rows without a match-case value

    @Test func blankMatchCaseNamingAThirdCapitalizationOfTwoSiblings() throws {
        // "it" is covered by neither exact-case entry and is not a unique case-insensitive match, so it is a new
        // case-insensitive entry, which would claim both siblings' text: refused, and nothing changes.
        var list = try T.list([("IT", "I T", true), ("It", "it", true)])
        let before = list
        for row in ["it,eye tee\n", "iT,eye tee,\n", " it ,eye tee, \n"] {
            do { _ = try list.importCSV(row); Issue.record("imported \(row.debugDescription)") } catch {
                #expect(error.localizedDescription.hasPrefix("Row 1:") && error.localizedDescription.contains("already has a pronunciation"), "\(error.localizedDescription)")
            }
            #expect(list == before)
        }
        // The exact spelling of either sibling updates just that one.
        #expect(try list.importCSV("It,itt\n") == .init(added: 0, updated: 1))
        #expect(list.entries.map(\.sayAs) == ["I T", "itt"] && list.entries.allSatisfy(\.matchCase))
        // A third spelling that is suggested to match case is an exact-case sibling of its own.
        var sql = try T.list([("SQL", "sequel", true), ("Sql", "squeal", true)])
        #expect(try sql.importCSV("SQl,S Q L\n") == .init(added: 1, updated: 0))
        #expect(sql.entries.map(\.written) == ["SQL", "Sql", "SQl"] && sql.entries.allSatisfy(\.matchCase))
    }

    @Test func blankMatchCaseForAnExactCaseEntryInAnotherCapitalization() throws {
        var list = try T.list([("IT", "I T", true), ("Kubernetes", "k", false)])
        let ids = list.entries.map(\.id)
        // Blank: updates the only entry with that spelling in any case, keeping its spelling and match case.
        #expect(try list.importCSV("it,eye tee,\n") == .init(added: 0, updated: 1))
        #expect(list.entries[0].id == ids[0] && list.entries[0].written == "IT" && list.entries[0].matchCase && list.entries[0].sayAs == "eye tee")
        // Explicit true adds an exact-case sibling. Explicit false would then claim both siblings' text: refused.
        #expect(try list.importCSV("it,it,true\n") == .init(added: 1, updated: 0))
        var copy = list
        #expect(throws: ChatterError.self) { try copy.importCSV("It,x,false\n") }
        #expect(copy == list)
        // With one exact-case entry, explicit false replaces it in place.
        var single = try T.list([("IT", "I T", true)])
        let id = single.entries[0].id
        #expect(try single.importCSV("it,eye tee,false\n") == .init(added: 0, updated: 1))
        #expect(single.entries == [Pronunciation(id: id, written: "it", sayAs: "eye tee", matchCase: false)])
    }

    @Test func blankMatchCaseForNewWordsUsesTheSuggestion() throws {
        var list = try T.list([("SQL", "sequel", true)])
        #expect(try list.importCSV("NGINX,engine x,\nnginx2,engine two\nGitHub,git hub, \n") == .init(added: 3, updated: 0))
        let byWritten = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0.matchCase) })
        #expect(byWritten == ["SQL": true, "NGINX": true, "nginx2": false, "GitHub": true])
    }

    @Test func blankMatchCaseMatchesCompositionAndTrimming() throws {
        var list = try T.list([("Café", "ka-FAY", false)])
        let id = list.entries[0].id
        #expect(try list.importCSV("Cafe\u{301},first\n  CAFE\u{301}  ,second,\n") == .init(added: 0, updated: 2))
        #expect(list.entries == [Pronunciation(id: id, written: "Café", sayAs: "second", matchCase: false)])
        // The update is validated like any other: an invalid respelling names the row and changes nothing.
        let before = list
        #expect(throws: ChatterError.self) { try list.importCSV("café,ok\ncafé,!!!\n") }
        #expect(list == before)
    }

    @Test func entryToUpdatePrefersTheExactSpelling() throws {
        let list = try T.list([("IT", "a", true), ("It", "b", true), ("Kubernetes", "c", false)])
        #expect(PronunciationList.entryToUpdate(for: "It", in: list)?.sayAs == "b")
        #expect(PronunciationList.entryToUpdate(for: " IT\t", in: list)?.sayAs == "a")
        #expect(PronunciationList.entryToUpdate(for: "it", in: list) == nil)            // two candidates: none is chosen
        #expect(PronunciationList.entryToUpdate(for: "KUBERNETES", in: list)?.sayAs == "c")
        #expect(PronunciationList.entryToUpdate(for: "Kube", in: list) == nil)
        #expect(PronunciationList.entryToUpdate(for: "", in: list) == nil)
        #expect(PronunciationList.entryToUpdate(for: "IT", in: PronunciationList()) == nil)
    }

    @Test func duplicateRowsInOneFile() throws {
        // Later rows update what earlier rows added; blank rows keep the spelling and match case the first row set.
        var list = PronunciationList()
        #expect(try list.importCSV("Foo,a\nFOO,b\nfoo,c,\nIBM,x\nibm,y\n") == .init(added: 2, updated: 3))
        #expect(Self.triples(list) == [["Foo", "c", "false"], ["IBM", "y", "true"]])
        // Explicit, then blank in another capitalization: the blank row updates the entry just added.
        var mixed = PronunciationList()
        #expect(try mixed.importCSV("sql,a,true\nSQL,b\n") == .init(added: 1, updated: 1))
        #expect(Self.triples(mixed) == [["sql", "b", "true"]])
        // Two explicit exact-case spellings are two entries; explicit case-insensitive then exact-case replaces.
        var siblings = PronunciationList()
        #expect(try siblings.importCSV("sql,a,true\nSQL,b,true\n") == .init(added: 2, updated: 0))
        var replaced = PronunciationList()
        #expect(try replaced.importCSV("sql,a,false\nSQL,b,true\n") == .init(added: 1, updated: 1))
        #expect(Self.triples(replaced) == [["SQL", "b", "true"]])
    }

    @Test(arguments: ["written,say_it_as,match_case\n", "\u{FEFF}Written, Say it as\r\n\r\n", "written,say_it_as\n\n  \n\r\n", "\n\n", "", "\u{FEFF}"])
    func headerOnlyAndEmptyFilesChangeNothing(text: String) throws {
        var list = try T.list([("SQL", "sequel", true)])
        let before = list
        #expect(try list.importCSV(text) == .init(added: 0, updated: 0))
        #expect(list == before)
    }

    @Test func exportOfAnEmptyListIsJustTheHeader() throws {
        #expect(PronunciationList().csv == "written,say_it_as,match_case\n")
        var list = PronunciationList()
        #expect(try list.importCSV(PronunciationList().csv) == .init(added: 0, updated: 0))
    }

    // MARK: Parsing

    @Test func spacesBeforeAnOpeningQuote() throws {
        let parse = PronunciationList.parseCSV
        #expect(try parse("  \"a, b\" , \"c\"\n") == [["a, b ", "c"]])            // text after the closing quote is kept
        #expect(try parse("\t \"a,b\",x") == [["a,b", "x"]])
        #expect(try parse("x,y\r\n  \"q,r\",s") == [["x", "y"], ["q,r", "s"]])     // at the start of a later row too
        #expect(try parse(" \"\"\"a\"\"\"") == [["\"a\""]])
        #expect(try parse("a,  b") == [["a", "  b"]])                               // spaces without a quote stay
        #expect(try parse("\u{00A0}\"a,b\"") == [["\u{00A0}\"a", "b\""]])           // only spaces and tabs open a quote
        #expect(try parse("  \"\",x") == [["", "x"]])
        var list = PronunciationList()
        #expect(try list.importCSV("  \"SQL, the language\"  ,  \"sequel, ok\"  ,  true  \n") == .init(added: 1, updated: 0))
        #expect(list.entries.first.map { [$0.written, $0.sayAs, "\($0.matchCase)"] } == ["SQL, the language", "sequel, ok", "true"])
        #expect(throws: ChatterError.self) { try parse("  \"unterminated, x\n") }
    }

    @Test func quotesAfterTheStartOfAFieldAreLiteral() throws {
        let parse = PronunciationList.parseCSV
        #expect(try parse("ab\"c,d") == [["ab\"c", "d"]])
        #expect(try parse("a \"b, c\" d\n") == [["a \"b", " c\" d"]])
        #expect(try parse("\"ab\"cd,e") == [["abcd", "e"]])                         // after a closing quote, text continues the field
        #expect(try parse("\"a\" \"b\"") == [["a \"b\""]])
        #expect(try parse("x,y\"\n\"z\",w") == [["x", "y\""], ["z", "w"]])
        var list = PronunciationList()
        #expect(try list.importCSV("O\"Reilly,oh RYE-lee\n") == .init(added: 1, updated: 0))
        #expect(list.entries.first?.written == "O\"Reilly")
        #expect(try list.respell("O\"Reilly books") == "oh RYE-lee books")
    }

    static let csvAlphabet: [Unicode.Scalar] = ["a", "B", ",", "\"", "\r", "\n", " ", "\t", "\u{FEFF}", "é", "\u{301}", "'", "="]

    /// Property: parsing never traps, is deterministic, throws only for a file that ends inside quotes, and
    /// never returns a blank single-field row.
    @Test func parserFuzzNeverTraps() throws {
        var rng = E.Seeded(state: 0xC5F)
        for iteration in 0..<3_000 {
            var text = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...40, using: &rng) { text.append(Self.csvAlphabet.randomElement(using: &rng)!) }
            let input = String(text)
            do {
                let rows = try PronunciationList.parseCSV(input)
                #expect(try PronunciationList.parseCSV(input) == rows, "\(iteration): \(input.debugDescription)")
                #expect(!rows.contains { $0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty }, "\(iteration): \(input.debugDescription)")
            } catch {
                // Only an unclosed quote is an error: the same file without quotes always parses.
                // (By scalar: a quote carrying a combining mark is one Character but still a quote in the file.)
                #expect(input.unicodeScalars.contains("\""), "\(iteration): \(input.debugDescription)")
                var unquoted = String.UnicodeScalarView(); unquoted.append(contentsOf: input.unicodeScalars.filter { $0 != "\"" })
                #expect(throws: Never.self) { try PronunciationList.parseCSV(String(unquoted)) }
            }
            var list = PronunciationList()
            _ = try? list.importCSV(input)   // never traps, whatever it decides
        }
    }

    /// Metamorphic: rows written with RFC 4180 quoting parse back to the same rows whichever line ending
    /// separates them (LF, CRLF or CR), with or without a byte-order mark and blank lines between rows.
    @Test func quotedRowsParseTheSameWithAnyLineEnding() throws {
        var rng = E.Seeded(state: 0x0D0A)
        let cellPieces = ["a", "B", ",", "\"", "\r\n", "\n", "\r", " ", "é", "e\u{301}", ",\u{301}", "'", "=", "中", "🚀"]
        for iteration in 0..<500 {
            let rows: [[String]] = (0..<Int.random(in: 1...6, using: &rng)).map { _ in
                (0..<Int.random(in: 2...3, using: &rng)).map { _ in "x" + (0..<Int.random(in: 0...4, using: &rng)).map { _ in cellPieces.randomElement(using: &rng)! }.joined() }
            }
            func quote(_ cell: String) -> String { "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\"" }
            for ending in ["\n", "\r\n", "\r", "\r\n\r\n", "\n  \n"] {
                let text = (Bool.random(using: &rng) ? "\u{FEFF}" : "") + rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: ending) + ending
                #expect(try PronunciationList.parseCSV(text) == rows, "\(iteration) \(ending.debugDescription): \(text.debugDescription)")
            }
        }
    }
}

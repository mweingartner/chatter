import Foundation
import Testing
@testable import ChatterCore

/// Respelling edge cases, proof that the leading-word pre-filter never changes a result, and the
/// CSV/JSON boundaries. Random cases use a seeded generator: a failure names its seed and inputs so it
/// replays exactly, and a replayed failure becomes a pinned case below.
@Suite("Pronunciation edge cases")
struct PronunciationEdgeTests {
    typealias T = PronunciationTests

    /// Seeded SplitMix64 so failures replay.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Reference implementation

    /// The respelling rules written the slow, obvious way, with no pre-filter: entries in priority order
    /// (longest first, exact-case first, then by spelling), each tried with an anchored search at every
    /// character boundary; a whole-word match that overlaps nothing claimed is kept.
    static func reference(_ entries: [Pronunciation], _ text: String) -> String { referenceWithMatches(entries, text).text }

    /// The reference result and how many matches it replaced (the size cap only applies when there is one).
    static func referenceWithMatches(_ entries: [Pronunciation], _ text: String) -> (text: String, matches: Int) {
        let ordered = entries.sorted { a, b in
            if a.written.count != b.written.count { return a.written.count > b.written.count }
            if a.matchCase != b.matchCase { return a.matchCase }
            return a.written < b.written
        }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var claimed = Set<Int>()
        var picks: [(start: Int, range: Range<String.Index>, sayAs: String)] = []
        for entry in ordered {
            let options: String.CompareOptions = entry.matchCase ? [.anchored] : [.anchored, .caseInsensitive]
            for start in text.indices {
                guard let r = text.range(of: entry.written, options: options, range: start..<text.endIndex), !r.isEmpty else { continue }
                if r.lowerBound > text.startIndex, isWord(text[text.index(before: r.lowerBound)]) { continue }
                if r.upperBound < text.endIndex, isWord(text[r.upperBound]) { continue }
                let span = r.lowerBound.utf16Offset(in: text)..<r.upperBound.utf16Offset(in: text)
                if span.contains(where: claimed.contains) { continue }
                claimed.formUnion(span)
                picks.append((span.lowerBound, r, entry.sayAs))
            }
        }
        var out = "", cursor = text.startIndex
        for pick in picks.sorted(by: { $0.start < $1.start }) {
            out += text[cursor..<pick.range.lowerBound]; out += pick.sayAs; cursor = pick.range.upperBound
        }
        return (out + text[cursor...], picks.count)
    }

    /// Text fragments chosen to collide with the entries below: case variants, case-folding pairs
    /// (ß/ss, ſ/s, ﬁ/fi, Kelvin sign), composed and decomposed accents, bare combining marks, a
    /// grapheme-prepending mark, joiners, emoji with modifiers, flags, CJK, digits and punctuation.
    static let textPieces = ["SQL", "sql", "Sql", "ſql", "NET", ".NET", "net", "ASP", "Straße", "STRASSE", "strasse", "ﬁle", "file", "FILE",
                             "Café", "Cafe\u{301}", "CAFÉ", "cafe", "IT", "It", "it", "A", "a", "B", "b", "C", "5G", "15G", "C++", "AT&T",
                             "x86-64", "中文", "中", "Kubernetes", "\u{212A}ubernetes", "İ", "ı", "ß", "ss", "SS", "ẞ", "ﬆ", "st", "ǅ",
                             " ", " ", " ", " ", ", ", ". ", "-", "&", "+", "'", "’s", "(", ")", "\"", "\n", "\t", "🚀", "👍🏽", "🇺🇸",
                             "\u{301}", "\u{200D}", "\u{0600}", "é", "e", "1", "2", "_", "/", "\u{00A0}"]
    static let writtenPool = ["SQL", "sql", ".NET", "NET", "net", "ASP.NET", "strasse", "Straße", "STRASSE", "file", "ﬁle", "Café",
                              "Cafe\u{301}", "cafe", "IT", "It", "it", "A", "a", "A B", "B C", "a-b", "b-c", "5G", "C++", "AT&T", "x86-64",
                              "中文", "Kubernetes", "ss", "ß", "st", "SQL SQL", "SQL.NET", "e\u{301}", "1", "12", "A.B", "&T", "T", "(SQL)",
                              "'s", "st.", "C", "İ", "ı", "ǅ"]

    static func randomText(_ rng: inout Seeded, maxPieces: Int = 24) -> String {
        (0..<Int.random(in: 0...maxPieces, using: &rng)).map { _ in textPieces.randomElement(using: &rng)! }.joined()
    }

    /// A list of up to `count` entries: mostly from the pool, some glued from random fragments. Entries
    /// the list refuses (invalid or colliding) are simply left out.
    static func randomList(_ rng: inout Seeded, count: Int) -> PronunciationList {
        var list = PronunciationList()
        for index in 0..<Int.random(in: 1...count, using: &rng) {
            let written = Bool.random(using: &rng) ? writtenPool.randomElement(using: &rng)!
                : (0..<Int.random(in: 1...3, using: &rng)).map { _ in textPieces.randomElement(using: &rng)! }.joined()
            let sayAs = ["<\(index)>", "say \(index)", "SQL", "Straße", "A B"].randomElement(using: &rng)!
            _ = try? list.upsert(Pronunciation(written: written, sayAs: sayAs, matchCase: Bool.random(using: &rng)))
        }
        return list
    }

    static func describe(_ list: PronunciationList) -> String {
        list.entries.map { "\($0.written.debugDescription)\($0.matchCase ? "(case)" : "")→\($0.sayAs.debugDescription)" }.joined(separator: ", ")
    }

    // MARK: Pre-filter soundness (property / oracle)

    /// Property: respell equals the reference (which has no pre-filter) for every generated list and text,
    /// scalar for scalar, never traps, and is deterministic. Eight chunks of 40 seeds run in parallel.
    @Test("Respelling matches the no-pre-filter reference for random lists and texts", arguments: 0..<8)
    func matchesReference(chunk: Int) throws {
        for seed in UInt64(chunk * 40)..<UInt64(chunk * 40 + 40) {
            var rng = Seeded(state: seed)
            let list = Self.randomList(&rng, count: 12)
            for _ in 0..<12 {
                let text = Self.randomText(&rng)
                let spoken = try list.respell(text)
                let expected = Self.reference(list.entries, text)
                #expect(Array(spoken.unicodeScalars) == Array(expected.unicodeScalars),
                        "seed \(seed): \(text.debugDescription) with [\(Self.describe(list))] → \(spoken.debugDescription), reference \(expected.debugDescription)")
                #expect(try list.respell(text) == spoken, "seed \(seed): not deterministic")
                if !text.contains(where: { $0.isLetter || $0.isNumber }) { #expect(spoken == text, "seed \(seed): letterless text changed") }
            }
        }
    }

    /// Pinned from the property above: a case-insensitive entry whose ASCII spelling the text holds only
    /// in case-folded form (ß = ss, ſ = s, ﬁ = fi, ﬆ = st). The search matches these, so the pre-filter must
    /// not skip them, and whether they are respelled must not depend on other words in the text.
    @Test func caseFoldedSpellingsAreNotSkippedByThePreFilter() throws {
        let list = try T.list([("strasse", "SHTRAH-seh", false), ("SQL", "sequel", false), ("file", "fyle", false), ("st", "street", false)])
        for text in ["Straße", "ſql", "ﬁle", "ﬆ", "Main STRASSE and Straße", "Straße\nstrasse", "the ﬁle, the file"] {
            #expect(try list.respell(text) == Self.reference(list.entries, text), "\(text.debugDescription)")
        }
        #expect(try list.respell("Straße") == "SHTRAH-seh")
        #expect(try list.respell("ſql and ﬁle") == "sequel and fyle")
        // Exact-case entries never fold, with or without the pre-filter.
        let exact = try T.list([("strasse", "x", true), ("SQL", "y", true)])
        #expect(try exact.respell("Straße ſql SQL") == "Straße ſql y")
    }

    /// Metamorphic: no written form spans a line break (entries are single lines) and a line break is not a
    /// letter, so respelling two texts joined by one equals joining their respellings. This also proves the
    /// pre-filter is local: words elsewhere in the text never change what a line becomes.
    @Test("Respelling distributes over line breaks", arguments: 0..<4)
    func distributesOverLineBreaks(chunk: Int) throws {
        for seed in UInt64(1_000 + chunk * 50)..<UInt64(1_000 + chunk * 50 + 50) {
            var rng = Seeded(state: seed)
            let list = Self.randomList(&rng, count: 10)
            for _ in 0..<10 {
                let a = Self.randomText(&rng, maxPieces: 12), b = Self.randomText(&rng, maxPieces: 12)
                let joined = try list.respell(a + "\n" + b), separate = try list.respell(a) + "\n" + list.respell(b)
                #expect(Array(joined.unicodeScalars) == Array(separate.unicodeScalars),
                        "seed \(seed): \(a.debugDescription) | \(b.debugDescription) with [\(Self.describe(list))]")
            }
        }
    }

    /// Metamorphic: the result depends only on the entries, not the order they were added, and a
    /// composed text and its decomposed form are respelled to canonically equal results.
    @Test("Respelling ignores insertion order and Unicode composition", arguments: 0..<4)
    func orderAndCompositionInvariant(chunk: Int) throws {
        for seed in UInt64(2_000 + chunk * 50)..<UInt64(2_000 + chunk * 50 + 50) {
            var rng = Seeded(state: seed)
            let list = Self.randomList(&rng, count: 10)
            var shuffled = PronunciationList()
            for entry in list.entries.shuffled(using: &rng) { try shuffled.upsert(entry) }
            for _ in 0..<10 {
                let text = Self.randomText(&rng)
                let spoken = try list.respell(text)
                #expect(try shuffled.respell(text) == spoken, "seed \(seed): order changed \(text.debugDescription)")
                let composed = try list.respell(text.precomposedStringWithCanonicalMapping)
                let decomposed = try list.respell(text.decomposedStringWithCanonicalMapping)
                #expect(composed == decomposed, "seed \(seed): composition changed \(text.debugDescription) with [\(Self.describe(list))]")
            }
        }
    }

    /// Metamorphic: a case-insensitive entry means the same whatever capitalization it was typed in.
    @Test func caseInsensitiveEntriesIgnoreTheirOwnCapitalization() throws {
        var rng = Seeded(state: 77)
        for _ in 0..<200 {
            let text = Self.randomText(&rng)
            for written in ["kubernetes", "sql", "a b", "x86-64", "at&t"] {
                let lower = try T.list([(written, "<w>", false)]), upper = try T.list([(written.uppercased(), "<w>", false)])
                #expect(try lower.respell(text) == upper.respell(text), "\(written): \(text.debugDescription)")
            }
        }
    }

    @Test func leadingWordsAndTextWords() {
        #expect(PronunciationList.leadingWord(of: ".NET") == nil)
        #expect(PronunciationList.leadingWord(of: "AT&T") == "AT")
        #expect(PronunciationList.leadingWord(of: "x86-64") == "x86")
        #expect(PronunciationList.leadingWord(of: "Visual Studio Code") == "Visual")
        #expect(PronunciationList.leadingWord(of: "Cafe\u{301} au lait") == "Cafe\u{301}")
        #expect(PronunciationList.leadingWord(of: "中文 name") == "中文")
        let words = PronunciationList.lowercasedWords(in: "Deploy K8s, AT&T's .NET-ready SQL!")
        #expect(words.isSuperset(of: ["deploy", "k8s", "at", "t", "s", "net", "ready", "sql"]))
        #expect(!words.contains("") && !words.contains("at&t"))
        #expect(PronunciationList.lowercasedWords(in: "").isEmpty && PronunciationList.lowercasedWords(in: ".,-🚀 ").isEmpty)
    }

    // MARK: Respelling rules, example by example

    @Test func adjacentAndRepeatedOccurrences() throws {
        let list = try T.list([("SQL", "sequel", true), ("na na", "N", false)])
        #expect(try list.respell("SQL SQL,SQL-SQL/SQL") == "sequel sequel,sequel-sequel/sequel")
        #expect(try list.respell("SQLSQL SQL1 1SQL _SQL_") == "SQLSQL SQL1 1SQL _sequel_")   // "_" is punctuation, not a letter
        // A written form that overlaps itself: matches never overlap, leftmost first.
        #expect(try list.respell("na na na") == "N na")
        #expect(try list.respell("na na na na") == "N N")
        #expect(try list.respell("nana na na") == "nana N")
    }

    @Test func prefixesSuffixesAndOverlapsResolveByLength() throws {
        let list = try T.list([("Visual", "V", false), ("Visual Studio", "VS", false), ("Studio Code", "SC", false), ("Studio", "S", false), ("Code", "C", false)])
        #expect(try list.respell("Visual Studio and Visual and Studio") == "VS and V and S")
        #expect(try list.respell("Visual Studio Code") == "VS C")          // 13 characters beat 11; "Code" still stands alone
        #expect(try list.respell("Studio Code Visual") == "SC V")
        #expect(try list.respell("VisualStudio Code") == "VisualStudio C")
    }

    @Test func sameLengthTiesAreIndependentOfInsertionOrder() throws {
        let forward = try T.list([("ab cd", "X", false), ("cd ef", "Y", false)])
        let backward = try T.list([("cd ef", "Y", false), ("ab cd", "X", false)])
        #expect(try forward.respell("ab cd ef") == "X ef")                 // alphabetical first
        #expect(try backward.respell("ab cd ef") == "X ef")
        // Among equal lengths, an exact-case entry outranks a case-insensitive one even when it sorts later.
        for entries in [[("a-b", "P", false), ("b-c", "Q", true)], [("b-c", "Q", true), ("a-b", "P", false)]] {
            #expect(try T.list(entries).respell("a-b-c") == "a-Q")
            #expect(try T.list(entries).respell("a-B-c") == "P-c")         // "B-c" is not the exact case, so "a-b" is free
        }
    }

    @Test func exactCaseAndCaseInsensitiveSiblings() throws {
        let list = try T.list([("US", "U S", true), ("us", "uhs", true), ("IT", "I T", true), ("it's", "it is", false)])
        #expect(try list.respell("US and us and Us") == "U S and uhs and Us")
        // A longer case-insensitive entry wins over a shorter exact-case one it contains, in every case.
        #expect(try list.respell("IT's fine, it's fine, IT'S fine; IT is") == "it is fine, it is fine, it is fine; I T is")
        // An entry that ignores case would claim both exact-case spellings, so it is refused either way round.
        var edited = list
        #expect(throws: ChatterError.self) { try edited.upsert(Pronunciation(written: "US", sayAs: "x", matchCase: false)) }
        #expect(throws: ChatterError.self) { try edited.upsert(Pronunciation(written: "It's", sayAs: "x", matchCase: true)) }
        #expect(edited == list)
        #expect(throws: ChatterError.self) { try T.list([("Apple", "the company", true), ("apple", "the fruit", false)]) }
    }

    @Test func punctuationLedAndDigitForms() throws {
        let list = try T.list([(".NET", "dot net", true), ("NET", "net", true), ("911", "nine one one", false), ("C++", "C plus plus", true)])
        #expect(try list.respell(".NET (.NET) ..NET .NETs") == "dot net (dot net) .dot net .NETs")
        #expect(try list.respell("ASP.NET") == "ASP.net")                    // ".NET" needs a non-letter before the dot; "NET" does not
        #expect(try list.respell("911. 9111 A911 911½") == "nine one one. 9111 A911 911½")   // "½" is a number
        #expect(try list.respell("C++ C+++ C++C") == "C plus plus C plus plus+ C++C")
    }

    @Test func unicodeNeighboursNeverTrapOrSplitAGrapheme() throws {
        let list = try T.list([("SQL", "sequel", true), ("Café", "ka-FAY", false), ("ष", "sha", true)])
        #expect(try list.respell("CAFÉ cafe\u{301} CAFE\u{301}") == "ka-FAY ka-FAY ka-FAY")
        #expect(try list.respell("SQL\u{301} SQL\u{200D} SQL\u{0903}") == "SQL\u{301} SQL\u{200D} SQL\u{0903}")   // marks join the last letter
        #expect(try list.respell("\u{0600}SQL \u{0D4E}SQL") == "\u{0600}SQL \u{0D4E}SQL")                     // prepended marks join the first
        #expect(try list.respell("👍🏽SQL🇺🇸 SQL\u{FE0F}") == "👍🏽sequel🇺🇸 SQL\u{FE0F}")
        #expect(try list.respell("क्ष ष") == "क्ष sha")                                                       // conjunct is one letter
        #expect(try list.respell("\u{FEFF}SQL\u{200B}") == "\u{FEFF}sequel\u{200B}")
    }

    @Test func respelledSizeLimitIsExact() throws {
        let limit = PronunciationList.maxRespelledBytes
        let list = try T.list([("X", String(repeating: "y", count: 200), true)])
        // n replacements of "X" (1 byte → 200 bytes) plus padding to land exactly on the limit.
        let n = limit / 201, padding = limit - 201 * n + 1
        let text = Array(repeating: "X", count: n).joined(separator: " ") + String(repeating: " ", count: padding)
        #expect(text.utf8.count + n * 199 == limit)
        #expect(try list.respell(text).utf8.count == limit)
        #expect(throws: ChatterError.self) { try list.respell(text + " ") }
        // Text over the limit that nothing respells is passed through; the request limit applies elsewhere.
        let long = String(repeating: "z ", count: limit)
        #expect(try list.respell(long) == long)
        // A respelling that shrinks the text still has to fit.
        let shrink = try T.list([("long", "s", true)])
        #expect(throws: ChatterError.self) { try shrink.respell(String(repeating: "long ", count: 150_000)) }
    }

    // MARK: Editing

    @Test func validationBoundaries() throws {
        var list = PronunciationList()
        try list.upsert(Pronunciation(written: String(repeating: "a", count: 100), sayAs: String(repeating: "b", count: 200), matchCase: false))
        // Limits count characters, so 100 decomposed letters are still 100.
        try list.upsert(Pronunciation(written: String(repeating: "e\u{301}", count: 100), sayAs: "x", matchCase: false))
        let trimmed = try list.upsert(Pronunciation(written: "\t\u{00A0}SQL \t", sayAs: "  sequel\u{00A0}", matchCase: true))
        #expect(trimmed.written == "SQL" && trimmed.sayAs == "sequel")
        for (written, sayAs) in [("a\u{2028}b", "x"), ("a\u{2029}b", "x"), ("a\u{85}b", "x"), ("a\rb", "x"), ("x", "a\u{0}b"), ("x", "a\u{7F}b"),
                                 ("🚀", "x"), ("\u{301}", "x"), ("x", "—")] {
            #expect(throws: ChatterError.self, "\(written.debugDescription) → \(sayAs.debugDescription)") {
                try list.upsert(Pronunciation(written: written, sayAs: sayAs, matchCase: false))
            }
        }
        #expect(list.entries.count == 3)
    }

    @Test func collisionsFollowCaseAndComposition() throws {
        var list = try T.list([("Café", "ka-FAY", true)])
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "Cafe\u{301}", sayAs: "x", matchCase: true)) }   // same text, decomposed
        #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: "CAFÉ", sayAs: "x", matchCase: false)) }
        try list.upsert(Pronunciation(written: "CAFÉ", sayAs: "x", matchCase: true))
        // Renaming an entry onto another's spelling is refused and leaves the list as it was.
        var renamed = list.entries[1]; renamed.written = "Café"
        let before = list
        #expect(throws: ChatterError.self) { try list.upsert(renamed) }
        #expect(list == before)
        list.remove(id: UUID())
        #expect(list == before)
    }

    @Test func aFullListStillAcceptsEdits() throws {
        var list = PronunciationList()
        for index in 0..<PronunciationList.maxEntries { try list.upsert(Pronunciation(written: "w\(index)", sayAs: "s", matchCase: false)) }
        var edited = list.entries[500]; edited.sayAs = "changed"; edited.written = "renamed"
        try list.upsert(edited)
        #expect(list.entries.count == PronunciationList.maxEntries && list.entries[500].written == "renamed")
        list.remove(id: edited.id)
        try list.upsert(Pronunciation(written: "fits again", sayAs: "s", matchCase: false))
        #expect(list.entries.count == PronunciationList.maxEntries)
    }

    // MARK: JSON

    static func json(_ entries: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["entries": entries]) }
    static func object(_ written: String, _ sayAs: String = "x", matchCase: Bool = false, id: UUID = UUID()) -> [String: Any] {
        ["id": id.uuidString, "written": written, "sayAs": sayAs, "matchCase": matchCase]
    }

    @Test func decodingRejectsInvalidAndCollidingEntries() throws {
        let id = UUID()
        let bad: [(String, [[String: Any]])] = [
            ("empty written", [Self.object("")]), ("no letters", [Self.object("x", "!!!")]), ("too long", [Self.object(String(repeating: "a", count: 101))]),
            ("two lines", [Self.object("a\nb")]), ("duplicate", [Self.object("SQL"), Self.object("SQL")]),
            ("case duplicate", [Self.object("SQL", matchCase: true), Self.object("sql")]),
            ("composition duplicate", [Self.object("Café", matchCase: true), Self.object("Cafe\u{301}", matchCase: true)]),
            ("too many", (0...PronunciationList.maxEntries).map { Self.object("w\($0)") }),
            ("duplicate id", [Self.object("SQL", id: id), Self.object("Kubernetes", id: id)]),
        ]
        for (name, entries) in bad {
            #expect(throws: DecodingError.self, "\(name)") { try JSONDecoder().decode(PronunciationList.self, from: Self.json(entries)) }
        }
        do {
            _ = try JSONDecoder().decode(PronunciationList.self, from: Self.json([Self.object("ok"), Self.object("  ")]))
            Issue.record("decoded a blank entry")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("Written needs at least one letter or number"))
        }
        for data in [Data("{}".utf8), Data(#"{"entries": {}}"#.utf8), Data(#"{"entries": [{"id": "nope", "written": "a", "sayAs": "b", "matchCase": false}]}"#.utf8),
                     Data(#"{"entries": [{"written": "a", "sayAs": "b", "matchCase": false}]}"#.utf8)] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(PronunciationList.self, from: data) }
        }
    }

    @Test func decodingKeepsOrderIdsAndTrims() throws {
        let ids = [UUID(), UUID(), UUID()]
        let data = try Self.json([Self.object(" SQL ", "sequel", matchCase: true, id: ids[0]), Self.object("IT", "I T", matchCase: true, id: ids[1]),
                                  Self.object("It", "it", matchCase: true, id: ids[2])])
        let list = try JSONDecoder().decode(PronunciationList.self, from: data)
        #expect(list.entries.map(\.id) == ids && list.entries.map(\.written) == ["SQL", "IT", "It"])
        #expect(try JSONDecoder().decode(PronunciationList.self, from: Self.json([])).isEmpty)
        let full = try JSONDecoder().decode(PronunciationList.self, from: Self.json((0..<PronunciationList.maxEntries).map { Self.object("w\($0)") }))
        #expect(full.entries.count == PronunciationList.maxEntries)
    }

    @Test func previewJobsKeepTheirNoRespellFlag() throws {
        var job = SpeechJob(request: SpeechRequest(voice: "v", text: "SQL"), voiceName: "v")
        let plain = try JSONEncoder().encode(job)
        #expect(!String(decoding: plain, as: UTF8.self).contains("respell"))
        #expect(try JSONDecoder().decode(SpeechJob.self, from: plain).respell == nil)
        job.respell = false
        #expect(try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job)).respell == false)
    }

    // MARK: CSV

    @Test func csvParserHandlesQuotingAndLineEndings() throws {
        let parse = PronunciationList.parseCSV
        #expect(try parse("\"a,b\",\"c\nd\",e\n") == [["a,b", "c\nd", "e"]])                  // quotes span commas and line breaks
        #expect(try parse("\"say \"\"hi\"\"\",\"\"\"\"\n") == [["say \"hi\"", "\""]])        // doubled quotes
        #expect(try parse("a,b\rc,d\re,f") == [["a", "b"], ["c", "d"], ["e", "f"]])           // CR only, no final newline
        #expect(try parse("a,b\r\nc,d\ne,f\r") == [["a", "b"], ["c", "d"], ["e", "f"]])       // mixed endings
        #expect(try parse("a,b,\n") == [["a", "b", ""]])                                       // trailing comma is an empty field
        #expect(try parse("\n\r\n  \n\u{FEFF}") == [["\u{FEFF}"]])                             // blank rows skipped; only a leading BOM is removed
        #expect(try parse("\u{FEFF}a,b") == [["a", "b"]])
        #expect(try parse("O\"Reilly,oh\n") == [["O\"Reilly", "oh"]])                          // a quote mid-field is literal
        #expect(try parse("") == [] && parse("\u{FEFF}") == [])
        #expect(try parse(",\n") == [["", ""]])
        #expect(throws: ChatterError.self) { try parse("a,\"b\n") }
        #expect(throws: ChatterError.self) { try parse("\"a\"\"") }
    }

    @Test(arguments: ["written,say_it_as", "WRITTEN,SAY_IT_AS,MATCH_CASE", " Written , Say it as , Match case ", "\"Written\",\"Say-It-As\"", "written,sayItAs,anything"])
    func csvHeaderVariantsAreSkipped(header: String) throws {
        var list = PronunciationList()
        #expect(try list.importCSV(header + "\nSQL,sequel,true\n") == .init(added: 1, updated: 0))
        #expect(list.entries.map(\.written) == ["SQL"])
        var headerOnly = PronunciationList()
        #expect(try headerOnly.importCSV(header) == .init(added: 0, updated: 0) && headerOnly.isEmpty)
    }

    @Test func csvMatchCaseValuesAndSuggestions() throws {
        var list = PronunciationList()
        let summary = try list.importCSV("a1,x,TRUE\na2,x, Yes \na3,x,1\na4,x,No\na5,x,0\na6,x,false\nIBM,x,\niOS,x\nKubernetes,x, \n")
        #expect(summary == .init(added: 9, updated: 0))
        let matchCase = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0.matchCase) })
        #expect(matchCase == ["a1": true, "a2": true, "a3": true, "a4": false, "a5": false, "a6": false, "IBM": true, "iOS": true, "Kubernetes": false])
        for value in ["y", "n", "2", "maybe", "truee"] {
            var copy = list
            #expect(throws: ChatterError.self, "\(value)") { try copy.importCSV("z,x,\(value)\n") }
            #expect(copy == list)
        }
    }

    @Test func csvRowsAreCountedAfterTheHeaderAndBlankLines() throws {
        var list = PronunciationList()
        for (text, row) in [("written,say_it_as\nok,fine\n,\n", "Row 2"), ("\n\nok,fine\n\nbad\n", "Row 2"), ("a,b\na,\n", "Row 2"),
                            ("x,\"two\nlines\"\n", "Row 1"), ("\(String(repeating: "w", count: 101)),x\n", "Row 1"), ("a,b,true,\n", "Row 1")] {
            do { _ = try list.importCSV(text); Issue.record("imported \(text.debugDescription)") } catch {
                #expect(error.localizedDescription.hasPrefix(row + ":"), "\(text.debugDescription): \(error.localizedDescription)")
            }
            #expect(list.isEmpty)
        }
    }

    @Test func csvImportUpdatesAndReplacesMatchCase() throws {
        var list = try T.list([("SQL", "S Q L", true), ("Kubernetes", "k", false)])
        let sqlID = list.entries[0].id
        #expect(try list.importCSV("sql,sequel,false\nKUBERNETES,koo-ber-NET-eez\nnew,one\nnew,two\n") == .init(added: 1, updated: 3))
        let sql = try #require(list.entries.first { $0.id == sqlID })
        #expect(sql.written == "sql" && sql.sayAs == "sequel" && !sql.matchCase)
        #expect(list.entries.count == 3 && list.entries.first { $0.written == "new" }?.sayAs == "two")
        // A row that would claim the text of two exact-case entries at once is refused, not merged.
        var siblings = try T.list([("IT", "I T", true), ("It", "it", true)])
        let before = siblings
        #expect(throws: ChatterError.self) { try siblings.importCSV("it,eye tee,false\n") }
        #expect(siblings == before)
    }

    @Test func csvImportRespectsCapacityCountingUpdates() throws {
        var list = PronunciationList()
        for index in 0..<(PronunciationList.maxEntries - 1) { try list.upsert(Pronunciation(written: "w\(index)", sayAs: "s", matchCase: false)) }
        // One new entry plus updates fits; the same new entry twice is an add and an update.
        var fits = list
        #expect(try fits.importCSV("W5,five\nnew,a\nnew,b\nw998,last\n") == .init(added: 1, updated: 3))
        #expect(fits.entries.count == PronunciationList.maxEntries)
        // A full list takes updates to every entry in one import.
        let everything = fits.entries.map { "\($0.written),updated" }.joined(separator: "\n")
        var full = fits
        #expect(try full.importCSV(everything) == .init(added: 0, updated: PronunciationList.maxEntries))
        #expect(full.entries.allSatisfy { $0.sayAs == "updated" })
        // A second new entry does not fit: the import names that row and changes nothing.
        var over = list
        do { _ = try over.importCSV("w1,x\nnew1,a\nw2,y\nnew2,b\n"); Issue.record("imported past capacity") } catch {
            #expect(error.localizedDescription.hasPrefix("Row 4:"), "\(error.localizedDescription)")
        }
        #expect(over == list)
    }

    @Test func csvSizeLimitIsInclusive() throws {
        let row = "SQL,sequel\n"
        var list = PronunciationList()
        let exact = row + String(repeating: "\n", count: 1_000_000 - row.utf8.count)
        #expect(try list.importCSV(exact) == .init(added: 1, updated: 0))
        var over = PronunciationList()
        #expect(throws: ChatterError.self) { try over.importCSV(exact + "\n") }
        #expect(over.isEmpty)
        // A very long field inside the limit is parsed and then refused by name, quickly.
        let start = ContinuousClock.now
        #expect(throws: ChatterError.self) { try over.importCSV("\"" + String(repeating: "a, ", count: 300_000) + "\",x\n") }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    /// Property: any list survives export and re-import, including values with commas, quotes, and
    /// combining marks that attach to a comma or quote (one Character in Swift, two scalars in the file).
    @Test("CSV export re-imports to the same list", arguments: 0..<4)
    func csvRoundTrips(chunk: Int) throws {
        let pieces = ["a", "B", "Straße", "é", "e\u{301}", ",", "\"", ",\u{301}", "\"\u{301}", " ", "'", "中", "🚀", "=", ";", "1", "\u{FEFF}"]
        for seed in UInt64(3_000 + chunk * 50)..<UInt64(3_000 + chunk * 50 + 50) {
            var rng = Seeded(state: seed)
            var list = PronunciationList()
            for _ in 0..<Int.random(in: 1...20, using: &rng) {
                func value() -> String { (0..<Int.random(in: 1...6, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined() }
                _ = try? list.upsert(Pronunciation(written: value(), sayAs: value(), matchCase: Bool.random(using: &rng)))
            }
            let csv = list.csv
            func rows(_ l: PronunciationList) -> [[String]] {
                l.entries.map { [$0.written, $0.sayAs, "\($0.matchCase)"] }.sorted { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") }
            }
            var imported = PronunciationList()
            do {
                #expect(try imported.importCSV(csv) == .init(added: list.entries.count, updated: 0), "seed \(seed)")
                #expect(rows(imported) == rows(list), "seed \(seed): \(csv.debugDescription)")
                var same = list
                #expect(try same.importCSV(csv) == .init(added: 0, updated: list.entries.count) && same == list, "seed \(seed)")
            } catch {
                Issue.record("seed \(seed): \(error.localizedDescription) importing \(csv.debugDescription)")
            }
        }
    }

    /// Pinned from the round-trip property: a comma or quote carrying a combining mark must still be quoted.
    @Test func csvQuotesCommasAndQuotesThatCarryMarks() throws {
        let list = try T.list([("a,\u{301}b", "x", false), ("\"\u{301}q", "say \"\u{301}", false)])
        let csv = list.csv
        #expect(csv.contains("\"a,\u{301}b\",x,false"))
        #expect(csv.contains("\"\"\"\u{301}q\",\"say \"\"\u{301}\",false"))
        var imported = PronunciationList()
        #expect(try imported.importCSV(csv) == .init(added: 2, updated: 0))
        #expect(Set(imported.entries.map(\.written)) == ["a,\u{301}b", "\"\u{301}q"])
    }

    // MARK: Performance

    /// With written forms that start with punctuation or non-ASCII letters, the pre-filter cannot skip
    /// anything, so every entry searches the whole text. This is the slowest a full list gets.
    @Test func respellingAFullListWithoutThePreFilterStaysBounded() throws {
        var list = PronunciationList()
        for index in 0..<PronunciationList.maxEntries {
            try list.upsert(Pronunciation(written: index.isMultiple(of: 2) ? "Café\(index)" : ".net\(index)", sayAs: "x \(index)", matchCase: index.isMultiple(of: 3)))
        }
        let text = String(repeating: "Straße Café au lait, .NET runtimes, Café990 and café992 again. ", count: 1_600)   // ~100 KB
        let start = ContinuousClock.now
        let spoken = try list.respell(text)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(30), "\(elapsed)")
        #expect(spoken.contains("x 990") && spoken.contains("x 992") && !spoken.contains("café992"))
    }

    @Test func nearMissesDoNotBlowUp() throws {
        // Every position is a near miss (a letter follows), so the search advances one character at a time.
        let list = try T.list([(".x", "dot ex", false), ("a a", "A", false)])
        let start = ContinuousClock.now
        #expect(try list.respell(String(repeating: ".xx", count: 30_000)) == String(repeating: ".xx", count: 30_000))
        let spaced = String(repeating: "a ", count: 50_000)
        #expect(try list.respell(spaced) == String(repeating: "A ", count: 25_000))
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func importingAndDecodingAFullListIsQuick() throws {
        let csv = "written,say_it_as,match_case\n" + (0..<PronunciationList.maxEntries).map { "Word\($0),say \($0),\($0.isMultiple(of: 2))" }.joined(separator: "\n")
        var list = PronunciationList()
        let start = ContinuousClock.now
        #expect(try list.importCSV(csv) == .init(added: PronunciationList.maxEntries, updated: 0))
        let decoded = try JSONDecoder().decode(PronunciationList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(ContinuousClock.now - start < .seconds(20))
    }
}

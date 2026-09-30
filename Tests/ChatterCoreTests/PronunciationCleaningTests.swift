import Foundation
import Testing
@testable import ChatterCore

/// How fields are cleaned before they are stored: every invisible character (general category Cf, or a
/// default-ignorable code point) goes except the joiners U+200C and U+200D, then surrounding spaces and
/// edge joiners. Checked over the whole Unicode
/// range, as properties of random fields (seeded, so a failure names its seed), and where cleaning meets
/// the loader, the importer, the formula guard and the "already has a pronunciation" lookup.
@Suite("Pronunciation cleaning")
struct PronunciationCleaningTests {
    typealias E = PronunciationEdgeTests
    typealias B = PronunciationBoundaryTests

    static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    static func isRemovable(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.properties.generalCategory == .format || scalar.properties.isDefaultIgnorableCodePoint) && !joiners.contains(scalar)
    }

    /// Every Cf or default-ignorable scalar other than the joiners, found by scanning the whole code space.
    static let removable: [Unicode.Scalar] = (0...0x10FFFF).compactMap { Unicode.Scalar($0) }.filter(isRemovable)

    static func hex(_ scalar: Unicode.Scalar) -> String { "U+" + String(scalar.value, radix: 16, uppercase: true) }

    // MARK: Whole-range scan

    /// Each plane is scanned separately (in parallel): between two letters, a scalar is removed exactly when
    /// it is invisible (format or default-ignorable) other than the joiners, and every other scalar is kept.
    @Test("Only invisible characters other than the joiners are removed", arguments: 0..<17)
    func onlyFormatCharactersAreRemoved(plane: Int) {
        var failures: [String] = []
        for value in UInt32(plane << 16)...UInt32((plane << 16) | 0xFFFF) {
            guard let scalar = Unicode.Scalar(value) else { continue }   // surrogates
            var input = String.UnicodeScalarView(); input.append("a"); input.append(scalar); input.append("b")
            let expected: [Unicode.Scalar] = Self.isRemovable(scalar) ? ["a", "b"] : ["a", scalar, "b"]
            if Array(PronunciationList.cleaned(String(input)).unicodeScalars) != expected { failures.append(Self.hex(scalar)) }
        }
        #expect(failures.isEmpty, "plane \(plane): \(failures.prefix(20))")
    }

    /// The scan finds the characters the fix names, and the joiners are format characters that are kept.
    @Test func theScanCoversTheNamedCharacters() {
        let named: [Unicode.Scalar] = ["\u{00AD}", "\u{061C}", "\u{180E}", "\u{200B}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202E}",
                                       "\u{2060}", "\u{2066}", "\u{2069}", "\u{FEFF}", "\u{FFF9}", "\u{E0001}", "\u{E0041}", "\u{E007F}",
                                       "\u{034F}", "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}", "\u{FE0F}", "\u{E0100}"]
        for scalar in named { #expect(Self.removable.contains(scalar), "\(Self.hex(scalar))") }
        for joiner in Self.joiners {
            #expect(joiner.properties.generalCategory == .format)
            #expect(PronunciationList.cleaned("a\(joiner)b") == "a\(joiner)b")
        }
        #expect(Self.removable.count >= 150)   // Unicode 15/16 have about 170 Cf scalars
        // All of them at once, around and inside a word, leave just the word.
        let all = String(String.UnicodeScalarView(Self.removable))
        #expect(PronunciationList.cleaned(all + " Kuber" + all + "netes " + all) == "Kubernetes")
        #expect(PronunciationList.cleaned(all).isEmpty)
    }

    /// Spaces are trimmed after the removal, so format characters can't shield them; space-like scalars that
    /// are not format characters (and not `.whitespaces`) are left alone.
    @Test func trimmingHappensAfterRemoval() {
        #expect(PronunciationList.cleaned("\u{200B} SQL \u{FEFF}") == "SQL")
        #expect(PronunciationList.cleaned(" \u{2060} \u{3000}SQL\u{00A0}\u{2003}\t\u{202C}") == "SQL")
        #expect(PronunciationList.cleaned("S Q\u{200B} L") == "S Q L")          // inner spaces stay
        #expect(PronunciationList.cleaned("\u{200D}SQL\u{200C}") == "SQL")                // joiners at the edges join nothing
        #expect(PronunciationList.cleaned(" \u{200D} می\u{200C}خواهم \u{200C}") == "می\u{200C}خواهم")
        #expect(PronunciationList.cleaned("\u{3164}").isEmpty && PronunciationList.cleaned("the\u{3164}") == "the")
        #expect(PronunciationList.cleaned("") == "")
        #expect(PronunciationList.cleaned("   ") == "")
        // Removing a format character between a letter and its accent reunites them into one character.
        #expect(PronunciationList.cleaned("e\u{200B}\u{301}") == "e\u{301}")
        #expect(PronunciationList.cleaned("e\u{200B}\u{301}").count == 1)
    }

    // MARK: Properties

    static let pieces: [String] = ["a", "Z", "7", "é", "e\u{301}", "中", "क्षि", "'", "=", "-", ",", "\"", " ", "  ", "\t", "\u{00A0}", "\u{3000}",
                                   "\u{2003}", "\u{200C}", "\u{200D}", "👨\u{200D}👩", "\u{301}", "\u{FE0F}", "\u{3164}"]

    static func randomField(_ rng: inout E.Seeded) -> String {
        (0..<Int.random(in: 0...12, using: &rng)).map { _ in
            Int.random(in: 0..<3, using: &rng) == 0 ? String(removable.randomElement(using: &rng)!) : pieces.randomElement(using: &rng)!
        }.joined()
    }

    /// Inserts `count` random format characters at random scalar positions.
    static func sprinkled(_ value: String, _ count: Int, _ rng: inout E.Seeded) -> String {
        var scalars = Array(value.unicodeScalars)
        for _ in 0..<count { scalars.insert(removable.randomElement(using: &rng)!, at: Int.random(in: 0...scalars.count, using: &rng)) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func hasOnlyAllowedFormatting(_ value: String) -> Bool { !value.unicodeScalars.contains(where: isRemovable) }

    static func hasNoEdgeWhitespace(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return true }
        return !PronunciationList.fieldEdges.contains(first) && !PronunciationList.fieldEdges.contains(last)
    }

    /// cleaned() is idempotent and leaves no removable format character or edge space; sprinkling format
    /// characters anywhere, or padding with spaces, never changes the result (metamorphic relations).
    @Test("Cleaning is idempotent and ignores sprinkled format characters", arguments: 0..<4)
    func cleaningProperties(chunk: Int) {
        for seed in UInt64(9_000 + chunk * 250)..<UInt64(9_000 + chunk * 250 + 250) {
            var rng = E.Seeded(state: seed)
            let raw = Self.randomField(&rng)
            let once = PronunciationList.cleaned(raw)
            #expect(PronunciationList.cleaned(once) == once, "seed \(seed): \(raw.debugDescription)")
            #expect(Self.hasOnlyAllowedFormatting(once) && Self.hasNoEdgeWhitespace(once), "seed \(seed): \(raw.debugDescription) → \(once.debugDescription)")
            let noisy = Self.sprinkled(raw, Int.random(in: 1...6, using: &rng), &rng)
            #expect(PronunciationList.cleaned(noisy) == once, "seed \(seed): \(noisy.debugDescription)")
            #expect(PronunciationList.cleaned(" \t" + raw + "\u{3000} ") == once, "seed \(seed): \(raw.debugDescription)")
            // Nothing but the removable scalars and edge spaces ever goes: the joiners and all else stay in order.
            let kept = raw.unicodeScalars.filter { !Self.isRemovable($0) }
            #expect(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: PronunciationList.fieldEdges) == once, "seed \(seed)")
        }
    }

    /// Whatever validated() returns has no removable format character and no edge space in either field,
    /// and validating it again changes nothing.
    @Test("Validated fields are clean", arguments: 0..<4)
    func validatedFieldsAreClean(chunk: Int) throws {
        var accepted = 0
        for seed in UInt64(10_000 + chunk * 250)..<UInt64(10_000 + chunk * 250 + 250) {
            var rng = E.Seeded(state: seed)
            let entry = Pronunciation(written: Self.randomField(&rng), sayAs: Self.randomField(&rng), matchCase: Bool.random(using: &rng))
            guard let valid = try? PronunciationList.validated(entry) else { continue }
            accepted += 1
            for field in [valid.written, valid.sayAs] {
                #expect(Self.hasOnlyAllowedFormatting(field) && Self.hasNoEdgeWhitespace(field), "seed \(seed): \(field.debugDescription)")
                #expect(field.contains(where: { $0.isLetter || $0.isNumber }), "seed \(seed)")
            }
            #expect(try PronunciationList.validated(valid) == valid, "seed \(seed)")
            #expect(valid.id == entry.id && valid.matchCase == entry.matchCase)
        }
        #expect(accepted > 50)   // the generator must actually exercise accepted entries
    }

    /// Limits apply to the cleaned field: invisible padding never pushes a field over them.
    @Test func limitsCountTheCleanedField() throws {
        let hundred = String(repeating: "a\u{200B}", count: PronunciationList.maxWrittenLength)
        #expect(hundred.unicodeScalars.count == 200)
        #expect(try PronunciationList.validated(Pronunciation(written: hundred, sayAs: "x", matchCase: false)).written.count == 100)
        // 400 accented letters' worth of scalars plus 5,000 tag characters is still within the scalar cap once cleaned.
        let padded = String(repeating: "\u{E0041}", count: 5_000) + String(repeating: B.stacked(3), count: 100)
        #expect(try PronunciationList.validated(Pronunciation(written: padded, sayAs: "x", matchCase: false)).written.unicodeScalars.count == 400)
        do { _ = try PronunciationList.validated(Pronunciation(written: hundred + "a", sayAs: "x", matchCase: false)); Issue.record("accepted 101 characters") }
        catch { #expect(error.localizedDescription == "Written can be at most 100 characters.") }
        do { _ = try PronunciationList.validated(Pronunciation(written: "x", sayAs: String(repeating: "b\u{FEFF}", count: 201), matchCase: false)); Issue.record("accepted 201") }
        catch { #expect(error.localizedDescription == "Say it as can be at most 200 characters.") }
        // A field of only format characters and spaces is empty once cleaned.
        do { _ = try PronunciationList.validated(Pronunciation(written: "SQL", sayAs: "\u{202E} \u{200B}\u{E0020}", matchCase: false)); Issue.record("accepted invisible") }
        catch { #expect(error.localizedDescription == "Say it as needs at least one letter or number.") }
    }

    // MARK: Look-alikes that clean to the same entry

    /// A saved list whose entries differ only by format characters cleans to two claims on the same text, so
    /// the loader refuses the file (the app sets it aside) rather than silently dropping one of them.
    @Test func aSavedListWhoseEntriesCleanToTheSameTextIsRefused() throws {
        func load(_ entries: [[String: Any]]) throws -> PronunciationList { try JSONDecoder().decode(PronunciationList.self, from: E.json(entries)) }
        let clashes: [[[String: Any]]] = [
            [E.object("SQL", "sequel", matchCase: true), E.object("S\u{200B}QL", "squeal", matchCase: true)],
            [E.object("\u{FEFF}SQL", "sequel", matchCase: true), E.object("SQL\u{2060}", "squeal", matchCase: true)],
            [E.object("SQL", "sequel", matchCase: true), E.object("s\u{00AD}ql", "squeal", matchCase: false)],   // case-insensitive entry claims it too
        ]
        for entries in clashes {
            do { _ = try load(entries); Issue.record("loaded \(entries)") }
            catch let DecodingError.dataCorrupted(context) {
                #expect(context.debugDescription.hasSuffix("“SQL” already has a pronunciation. Edit that entry instead."), "\(context.debugDescription)")
            }
        }
        // Differing in visible capitalization with both matching case is still two entries, each cleaned.
        let apart = try load([E.object("S\u{200B}QL", "sequel", matchCase: true), E.object("S\u{200B}Ql", "squeal", matchCase: true)])
        #expect(apart.entries.map(\.written) == ["SQL", "SQl"])
        // Saving the cleaned list and loading it again gives the same list.
        #expect(try JSONDecoder().decode(PronunciationList.self, from: JSONEncoder().encode(apart)) == apart)
    }

    /// In one import, a look-alike row names the same entry as the row before it: the later row wins.
    @Test func importRowsThatCleanToTheSameWordUpdateOneEntry() throws {
        var list = PronunciationList()
        #expect(try list.importCSV("S\u{200B}QL,a,true\nSQL,b,true\n\u{2060}sql\u{FEFF},c\n") == .init(added: 1, updated: 2))
        #expect(list.entries.count == 1)
        #expect(list.entries.first.map { [$0.written, $0.sayAs, "\($0.matchCase)"] } == ["SQL", "c", "true"])
    }

    /// The panel's "Edit …" link finds the entry a pasted look-alike clashes with, as upsert does.
    @Test func theClashingEntryIsFoundForALookAlike() throws {
        var list = PronunciationList()
        let sql = try list.upsert(Pronunciation(written: "SQL", sayAs: "sequel", matchCase: true))
        for typed in ["S\u{200B}QL", " \u{FEFF}SQL\u{202C} ", "SQL\u{E0041}"] {
            #expect(throws: ChatterError.self) { try list.upsert(Pronunciation(written: typed, sayAs: "squeal", matchCase: true)) }
            #expect(list.entry(covering: typed, matchCase: true)?.id == sql.id, "\(typed.debugDescription)")
            #expect(list.entry(covering: typed, matchCase: true, excluding: sql.id) == nil)
        }
        #expect(list.entry(covering: "S\u{200B}Ql", matchCase: true) == nil)
        #expect(list.entry(covering: "s\u{200B}ql", matchCase: false)?.id == sql.id)
    }

    /// The header is recognized after the same cleaning as the data: a prepended format character (seed
    /// 11196 found U+0890 and U+08E2) merges with the next letter into one non-letter character, which
    /// hid the header, so a two-column file imported "written" as a word.
    @Test(arguments: ["s\u{0890}ay_it_as", "\u{0600}say it as", "Say\u{08E2} it as", "\u{202E}say_it_as\u{202C}", "say\u{E0041}_it_as"])
    func headersWithFormatCharactersAreSkipped(sayAsHeader: String) throws {
        #expect(PronunciationList.isHeader(["w\u{0891}ritten", sayAsHeader]))
        var list = PronunciationList()
        #expect(try list.importCSV("w\u{0891}ritten,\(sayAsHeader)\nSQL,sequel\n") == .init(added: 1, updated: 0))
        #expect(list.entries.map(\.written) == ["SQL"])
    }

    // MARK: Formula guard after cleaning

    @Test func formatCharactersNeverHideTheFormulaGuard() throws {
        var list = PronunciationList()
        _ = try list.importCSV("w1,\u{200B}'=x\nw2,'\u{200B}=y\nw3,\u{202E}'@z\u{202C}\nw4,''\u{FEFF}=q\nw5, \u{2060} '-1 a\nw6,\u{200D}'=j\n\u{200B}'=w7,x\n")
        let sayAs = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.written, $0.sayAs) })
        #expect(sayAs == ["w1": "=x", "w2": "=y", "w3": "@z", "w4": "'=q", "w5": "-1 a", "w6": "=j", "=w7": "x"])
        // Exported again, each guarded value is guarded once, and re-importing gives the same list.
        var again = PronunciationList()
        _ = try again.importCSV(list.csv)
        #expect(B.triples(again) == B.triples(list))
    }

    /// Property: an exported file with format characters sprinkled anywhere in its cells and spaces around
    /// them (as a hand edit or another app might leave it) imports to the same list.
    @Test("The formula guard round-trips through sprinkled format characters", arguments: 0..<4)
    func guardRoundTripsThroughCleaning(chunk: Int) throws {
        let starts = ["=", "+", "-", "@"]
        let pieces = ["'", "''", "=", "+", "-", "@", "a", "Z", "7", " ", ",", "\"", "é", "SUM(A1)", "'x", "中", "\u{200D}"]
        for seed in UInt64(11_000 + chunk * 50)..<UInt64(11_000 + chunk * 50 + 50) {
            var rng = E.Seeded(state: seed)
            func value() -> String {
                let lead = Bool.random(using: &rng) ? String(repeating: "'", count: Int.random(in: 0...3, using: &rng)) + starts.randomElement(using: &rng)! : ""
                return lead + (0..<Int.random(in: 1...5, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            }
            var list = PronunciationList()
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                _ = try? list.upsert(Pronunciation(written: value(), sayAs: value(), matchCase: Bool.random(using: &rng)))
            }
            let noisy = try PronunciationList.parseCSV(list.csv).map { cells in
                cells.enumerated().map { index, cell -> String in
                    let messy = index < 2 ? String(repeating: " ", count: Int.random(in: 0...2, using: &rng)) + Self.sprinkled(cell, Int.random(in: 0...3, using: &rng), &rng) + " " : cell
                    return "\"" + messy.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
                }.joined(separator: ",")
            }.joined(separator: "\r\n")
            var imported = PronunciationList()
            do {
                #expect(try imported.importCSV(noisy) == .init(added: list.entries.count, updated: 0), "seed \(seed)")
                #expect(B.triples(imported) == B.triples(list), "seed \(seed): \(noisy.debugDescription)")
                #expect(imported.csv == list.csv, "seed \(seed)")
            } catch {
                Issue.record("seed \(seed): \(error.localizedDescription) importing \(noisy.debugDescription)")
            }
        }
    }

    // MARK: Non-functional

    /// Cleaning a field is linear: a megabyte of mixed text with format characters is quick.
    @Test func cleaningLargeInputIsQuick() {
        let chunk = "Kuber\u{200B}netes \u{202E}SQL\u{202C} \u{200D}"
        let large = String(repeating: chunk, count: 40_000)   // about 1 MB
        let start = ContinuousClock.now
        let result = PronunciationList.cleaned(large)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result.unicodeScalars.count == large.unicodeScalars.count - 40_000 * 3 - 2)   // three removed per chunk, then the trailing space and joiner
        #expect(PronunciationList.cleaned(large + " ") == result)
    }
}

import Foundation
import Testing
@testable import ChatterCore

/// Seeded properties and fuzzing for expression notes: placing notes never changes a word, whatever the
/// Unicode; a model's reply is checked however hostile it is; the review keeps what it had when a window
/// fails, runs long or answers out of range; pronunciations never touch a placed note; and suggestions
/// are always entries the panel would accept. Every generator is seeded, so a failure names its seed.
struct ExpressionPropertyTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    /// Text pieces that stress sentence starts: combining marks, CRLF, lone CR, emoji sequences, RTL text
    /// and marks, Python-only whitespace, full-width punctuation, parentheses that are and are not notes.
    static let unicodePieces = [
        "Hello", " world", ". ", "! ", "? ", "\n", "\r\n", "\r", "  ", "\t", "é", "e\u{301}", "\u{301}", "中文", "。", "！", "？ ",
        "😀", "👩‍👩‍👧", "🇨🇦", "שלום", "\u{200F}", "مرحبا", "\u{202E}", "\u{3000}", "\u{85}", "\u{2028}", "\u{1C}", "\u{A0}",
        "(aside) ", "(2019) ", "[whisper] ", "(", ")", "[", "]", "4.2", "…", "'", "x", "Ω", "\u{0600}",
    ]

    static func text(_ rng: inout Seeded, pieces: [String] = unicodePieces, upTo count: Int = 40) -> String {
        (0..<Int.random(in: 0...count, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    static func plan(for text: String, _ rng: inout Seeded) -> ExpressionPlan {
        let count = Sentences.split(text).count
        return ExpressionPlan(notes: (0..<count + 2).compactMap {
            Int.random(in: 0..<3, using: &rng) == 0 ? nil : .init(sentence: $0, note: ExpressionNote.allCases.randomElement(using: &rng)!)
        })
    }

    static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    /// Scalar offset of a string index (annotate's ranges are scalar-aligned).
    static func offset(_ index: String.Index, in text: String) -> Int {
        text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    /// The text with each reported note and the one space after it removed, by scalar.
    static func strip(_ noted: String, _ ranges: [Range<String.Index>]) -> [Unicode.Scalar] {
        var result = scalars(noted)
        for range in ranges.reversed() {
            let lower = offset(range.lowerBound, in: noted), upper = offset(range.upperBound, in: noted)
            result.removeSubrange(lower..<(upper + 1))
        }
        return result
    }

    // MARK: Placing notes never changes a word

    /// Property: for arbitrary Unicode, annotate only inserts "(note) " at sentence starts. Compared by
    /// scalar, not by String equality, so canonical equivalence cannot hide a change.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func annotatingOnlyInsertsCatalogNotesForAnyUnicode(seed: UInt64) {
        var rng = Seeded(state: seed)
        for _ in 0..<250 {
            let text = Self.text(&rng)
            let plan = Self.plan(for: text, &rng)
            let (noted, ranges) = plan.annotate(text)
            let context = "seed \(seed): \(text.debugDescription) → \(noted.debugDescription)"
            #expect(Self.strip(noted, ranges) == Self.scalars(text), "\(context)")
            #expect(ranges.count <= plan.notes.count, "\(context)")
            let notedScalars = Self.scalars(noted)
            for range in ranges {
                let marker = String(noted[range])
                #expect(ExpressionNote.allCases.contains { $0.marker == marker }, "\(context)")
                #expect(notedScalars[Self.offset(range.upperBound, in: noted)] == " ", "\(context)")
            }
            // Ranges are in order and never overlap.
            #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound < $1.lowerBound }, "\(context)")
        }
    }

    /// Metamorphic: annotating keeps the sentence count and each sentence's words, every placed note opens
    /// its sentence as a leading note, and annotating the result again with the same plan changes nothing.
    @Test(arguments: [11, 12, 13, 14] as [UInt64])
    func annotatedSentencesAlignAndReannotatingIsIdempotent(seed: UInt64) throws {
        var rng = Seeded(state: seed)
        for _ in 0..<250 {
            let text = Self.text(&rng)
            let plan = Self.plan(for: text, &rng)
            let (noted, ranges) = plan.annotate(text)
            let context = "seed \(seed): \(text.debugDescription)"
            let before = Sentences.split(Self.scalars(text)), after = Sentences.split(Self.scalars(noted))
            try #require(before.count == after.count, "\(context)")
            let placedMarkers = Set(ranges.map { Self.offset($0.lowerBound, in: noted) })
            var cursor = 0, placed = 0
            for (index, (original, annotated)) in zip(before, after).enumerated() {
                let parts = LeadingNote.parts(of: annotated)
                if let parts, placedMarkers.contains(cursor + parts.note.lowerBound) {
                    placed += 1
                    // The note is the plan's note for this sentence, and removing it gives back the sentence.
                    #expect(Sentences.string(annotated[parts.note]) == plan.notes.first { $0.sentence == index }?.note.marker, "\(context)")
                    var restored = annotated
                    restored.removeSubrange(parts.note.lowerBound..<(parts.note.upperBound + 1))
                    #expect(restored == original, "\(context)")
                } else {
                    #expect(annotated == original, "\(context)")
                }
                cursor += annotated.count
            }
            #expect(placed == ranges.count, "\(context)")
            #expect(plan.annotate(noted).text.unicodeScalars.elementsEqual(noted.unicodeScalars), "\(context)")
        }
    }

    @Test func notesGoAfterEveryKindOfLeadingWhitespace() {
        let plan = ExpressionPlan(notes: (0..<8).map { .init(sentence: $0, note: .calm) })
        // CRLF: the CR belongs to the first sentence's end; the note opens the line after it.
        #expect(plan.annotate("Hi.\r\nThere.").text == "(calm) Hi.\r\n(calm) There.")
        // A lone CR is whitespace after the full stop, so it leads the next sentence.
        #expect(plan.annotate("Hi.\rThere.").text == "(calm) Hi.\r(calm) There.")
        #expect(plan.annotate("Hi.\u{3000}\u{A0}There.").text == "(calm) Hi.\u{3000}\u{A0}(calm) There.")
        #expect(plan.annotate("  \tIndented.").text == "  \t(calm) Indented.")
        // Right-to-left text: the note is placed in logical order, before the first letter.
        #expect(plan.annotate("שלום. مرحبا!").text == "(calm) שלום. (calm) مرحبا!")
        // A sentence of only emoji or punctuation has no words, so it gets nothing.
        #expect(plan.annotate("😀👍. …!? Yes.").text == "😀👍. …!? (calm) Yes.")
        // Digits count as words.
        #expect(plan.annotate("42.").text == "(calm) 42.")
    }

    @Test func notesBeforeCombiningMarksKeepTheMarkAndReportExactRanges() {
        let text = "Go.\n\u{301}accent here."
        let (noted, ranges) = ExpressionPlan(notes: [.init(sentence: 2, note: .proud)]).annotate(text)
        #expect(noted.unicodeScalars.elementsEqual("Go.\n(proud) \u{301}accent here.".unicodeScalars))
        #expect(ranges.count == 1 && String(noted[ranges[0]]) == "(proud)")
        #expect(Self.strip(noted, ranges) == Self.scalars(text))
    }

    // MARK: Sentences and notes

    /// Property: Sentences.split loses nothing and cuts exactly where the rule says, for any Unicode.
    @Test(arguments: [21, 22, 23] as [UInt64])
    func sentencesFollowTheRuleForAnyUnicode(seed: UInt64) {
        var rng = Seeded(state: seed)
        for _ in 0..<300 {
            let text = Self.scalars(Self.text(&rng))
            let pieces = Sentences.split(text)
            #expect(Array(pieces.joined()) == text)
            // Every piece but the last ends at a cut; no piece contains a cut inside it.
            for (index, piece) in pieces.enumerated() {
                let isLast = index == pieces.count - 1
                for i in 0..<piece.count {
                    let next: Unicode.Scalar? = i + 1 < piece.count ? piece[i + 1] : (isLast ? nil : pieces[index + 1].first)
                    let cut = piece[i] == "\n" || (Sentences.ends.contains(piece[i].value) && next.map(Sentences.isSpace) == true)
                    #expect(cut == (i == piece.count - 1 && !isLast), "seed \(seed): \(String(String.UnicodeScalarView(text)).debugDescription)")
                }
            }
        }
    }

    @Test func pythonWhitespaceIsExactlyTheIsspaceSet() {
        let expected: Set<UInt32> = Set(Array(0x09...0x0D) + Array(0x1C...0x20) + [0x85, 0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
        for value in UInt32(0)...0x3100 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect(Sentences.isSpace(scalar) == expected.contains(value), "U+\(String(value, radix: 16))")
        }
        // Zero-width space and BOM are not whitespace for Python.
        #expect(!Sentences.isSpace("\u{200B}") && !Sentences.isSpace("\u{FEFF}"))
    }

    @Test func everyCatalogNoteIsALeadingNote() throws {
        var raws = Set<String>()
        for note in ExpressionNote.allCases {
            #expect(raws.insert(note.rawValue).inserted)
            #expect(ExpressionNote(rawValue: note.rawValue) == note)
            #expect(!note.meaning.isEmpty && !note.meaning.contains("\n") && !note.rawValue.contains(")"))
            let sentence = Self.scalars(note.marker + " Words follow.")
            let parts = try #require(LeadingNote.parts(of: sentence), "\(note.marker)")
            #expect(Sentences.string(sentence[parts.note]) == note.marker)
            #expect(Sentences.string(sentence[parts.body]) == "Words follow.")
        }
    }

    @Test func leadingNoteLimitsAreExact() {
        func parts(_ s: String) -> LeadingNote.Parts? { LeadingNote.parts(of: Self.scalars(s)) }
        #expect(parts("(" + String(repeating: "a", count: 40) + ") x") != nil)
        #expect(parts("(" + String(repeating: "a", count: 41) + ") x") == nil)
        #expect(parts("[" + String(repeating: "a", count: 60) + "] x") != nil)
        #expect(parts("[" + String(repeating: "a", count: 61) + "] x") == nil)
        // Limits count scalars: 40 letters each with a combining mark is 80 scalars.
        #expect(parts("(" + String(repeating: "e\u{301}", count: 20) + ") x") != nil)
        #expect(parts("(" + String(repeating: "e\u{301}", count: 21) + ") x") == nil)
        // A note may start after any Python whitespace, and may be the whole sentence.
        for space in ["\u{3000}", "\u{85}", "\t", "\u{A0}", "\u{1C}"] { #expect(parts(space + "(calm) x")?.leading == 0..<1) }
        #expect(parts("(calm)")?.body == 6..<6)
        // Only spaces and tabs after a note are skipped.
        #expect(parts("(calm) \t x")?.body.lowerBound == 9)
        #expect(parts("(calm)\u{3000}x")?.body.lowerBound == 6)
        // Words: a letter first; then letters, marks, spaces, hyphens and apostrophes only.
        for text in ["(\u{301}a) x", "(-a) x", "( a) x", "('a) x", "(a.b) x", "(a,b) x", "(a\u{200B}b) x", "(a_b) x", "(😀) x", "(a\tb) x"] {
            #expect(parts(text) == nil, "\(text.debugDescription)")
        }
        for text in ["(a-b) x", "(a' b) x", "(a’b) x", "(ne\u{301}) x", "(日本) x", "(שלום) x"] {
            #expect(parts(text) != nil, "\(text.debugDescription)")
        }
        // One letter, or a Roman numeral, is a list marker.
        for text in ["(e\u{301}) x", "(a) x", "(B) x", "(iv) x", "(XII) x"] { #expect(parts(text) == nil, "\(text.debugDescription)") }
        // Directions: anything on one line without another opening bracket or a control character.
        for text in ["[a\tb] x", "[a\rb] x", "[a[b] x", "[a\u{7}b] x", "[] x", "()"] { #expect(parts(text) == nil, "\(text.debugDescription)") }
        for text in ["[a(b)c] x", "[laughs!] x", "[soft tone] x"] { #expect(parts(text) != nil, "\(text.debugDescription)") }
        // Citations, checkboxes, symbols and Markdown links are text.
        for text in ["[1] x", "[12, 13] x", "[Smith 2019] x", "[x] Buy milk", "[ ] x", "[😀] x", "[docs](https://example.com) x"] {
            #expect(parts(text) == nil, "\(text.debugDescription)")
        }
    }

    /// Fuzz: LeadingNote.parts never traps, and whatever it returns is well-formed.
    @Test(arguments: [31, 32] as [UInt64])
    func leadingNotePartsAreWellFormedForAnyInput(seed: UInt64) {
        var rng = Seeded(state: seed)
        let pieces = Self.unicodePieces + ["(", "(", "[", "a", "b", "-", " ", ")", "]", "(calm)", "[x]"]
        for _ in 0..<2_000 {
            let sentence = Self.scalars(Self.text(&rng, pieces: pieces, upTo: 12))
            guard let parts = LeadingNote.parts(of: sentence) else { continue }
            #expect(parts.leading.lowerBound == 0 && parts.leading.upperBound == parts.note.lowerBound)
            #expect(parts.note.upperBound <= parts.body.lowerBound && parts.body.upperBound == sentence.count)
            #expect(sentence[parts.leading].allSatisfy(Sentences.isSpace))
            let open = sentence[parts.note.lowerBound], close = sentence[parts.note.upperBound - 1]
            #expect((open == "(" && close == ")") || (open == "[" && close == "]"))
            #expect(sentence[parts.note.upperBound..<parts.body.lowerBound].allSatisfy { $0 == " " || $0 == "\t" })
        }
    }

    // MARK: Replies from the model

    @Test func repliesRefuseAnythingButWholeNumbersInRange() {
        func notes(_ json: String, count: Int = 3) -> [Int: ExpressionNote] { ExpressionReview.notes(in: Data(json.utf8), count: count) }
        // A boolean is not a sentence number, even though JSON true bridges to 1.
        #expect(notes(#"{"notes":[{"sentence":true,"note":"sad"}]}"#).isEmpty)
        #expect(notes(#"{"notes":[{"sentence":false,"note":"sad"}]}"#).isEmpty)
        // Fractions, huge and negative numbers, strings and null are dropped; 2.0 is the whole number 2.
        #expect(notes(#"{"notes":[{"sentence":1.5,"note":"sad"},{"sentence":1e300,"note":"sad"},{"sentence":-1,"note":"sad"},{"sentence":18446744073709551616,"note":"sad"},{"sentence":9223372036854775807,"note":"sad"},{"sentence":null,"note":"sad"},{"sentence":"1","note":"sad"},{"sentence":2.0,"note":"calm"}]}"#)
            == [2: .calm])
        // Notes must match the catalog exactly: no case, space or type changes.
        #expect(notes(#"{"notes":[{"sentence":1,"note":"Excited"},{"sentence":1,"note":" excited"},{"sentence":1,"note":["excited"]},{"sentence":1,"note":null},{"sentence":1,"note":"soft tone"}]}"#)
            == [1: .softTone])
        // Extra keys are ignored; the first note for a sentence wins.
        #expect(notes(#"{"notes":[{"sentence":3,"note":"sad","why":"x"},{"sentence":3,"note":"happy"}],"extra":{"a":[1,2]}}"#) == [3: .sad])
        // Shapes that are not the schema's mean no notes.
        for reply in [#"[{"sentence":1,"note":"sad"}]"#, #"{"notes":{"sentence":1,"note":"sad"}}"#, #"{"notes":"sad"}"#, #"{"Notes":[{"sentence":1,"note":"sad"}]}"#,
                      #"{"notes":[{"sentence":1,"note":"sad"},7]}"#, "null", "", "{", "\u{0}", #"{"notes":[[{"sentence":1,"note":"sad"}]]}"#] {
            #expect(notes(reply).isEmpty, "\(reply.debugDescription)")
        }
        // With no sentences nothing can be chosen.
        #expect(notes(#"{"notes":[{"sentence":1,"note":"sad"}]}"#, count: 0).isEmpty)
        #expect(notes(#"{"notes":[{"sentence":1,"note":"sad"}]}"#, count: -5).isEmpty)
    }

    /// A random JSON value, nested up to `depth`, biased toward the reply's own keys.
    static func junk(_ rng: inout Seeded, depth: Int) -> Any {
        let keys = ["notes", "sentence", "note", "x", "", "Notes"]
        switch Int.random(in: 0..<(depth > 0 ? 10 : 7), using: &rng) {
        case 0: return Int.random(in: -3...30, using: &rng)
        case 1: return [Int.max, Int.min, 0, 1, 24, 25][Int.random(in: 0..<6, using: &rng)]
        case 2: return Double.random(in: -5...30, using: &rng)
        case 3: return Bool.random(using: &rng)
        case 4: return NSNull()
        case 5: return (ExpressionNote.allCases.map(\.rawValue) + ["", "EXCITED", "yodeling", "sad "]).randomElement(using: &rng)!
        case 6: return String(repeating: "é", count: Int.random(in: 0...5, using: &rng))
        case 7: return (0..<Int.random(in: 0...6, using: &rng)).map { _ in junk(&rng, depth: depth - 1) }
        default:
            var object: [String: Any] = [:]
            for _ in 0..<Int.random(in: 0...4, using: &rng) { object[keys.randomElement(using: &rng)!] = junk(&rng, depth: depth - 1) }
            return object
        }
    }

    /// Fuzz: whatever JSON (or bytes) comes back, the notes are in range, from the catalog, the first
    /// valid choice for their sentence, and the same every time.
    @Test(arguments: [41, 42, 43, 44] as [UInt64])
    func hostileRepliesNeverYieldOutOfRangeNotes(seed: UInt64) throws {
        var rng = Seeded(state: seed)
        for round in 0..<600 {
            let count = Int.random(in: 0...26, using: &rng)
            var items: [Any] = (0..<Int.random(in: 0...12, using: &rng)).map { _ -> Any in
                Int.random(in: 0..<4, using: &rng) == 0 ? Self.junk(&rng, depth: 2)
                    : ["sentence": Self.junk(&rng, depth: 0), "note": Self.junk(&rng, depth: 0)] as [String: Any]
            }
            if Bool.random(using: &rng) { items = items.filter { $0 is [String: Any] } }
            let root: Any = Int.random(in: 0..<5, using: &rng) == 0 ? Self.junk(&rng, depth: 3) : ["notes": items]
            let reply = try JSONSerialization.data(withJSONObject: ["root": root]).dropFirst(8).dropLast()
            let result = ExpressionReview.notes(in: Data(reply), count: count)
            let context = "seed \(seed) round \(round): \(String(decoding: reply, as: UTF8.self))"
            #expect(result.keys.allSatisfy { (1...max(count, 1)).contains($0) && count > 0 }, "\(context)")
            #expect(ExpressionReview.notes(in: Data(reply), count: count) == result, "\(context)")
            // Each chosen note is the first well-formed item for its sentence.
            for (number, note) in result {
                let first = (items as? [[String: Any]])?.first {
                    ($0["sentence"] as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0 as? Int == number } == true
                        && ($0["note"] as? String).flatMap(ExpressionNote.init(rawValue:)) != nil
                }
                #expect(first?["note"] as? String == note.rawValue, "\(context)")
            }
        }
        // Raw bytes too.
        for _ in 0..<300 {
            let bytes = Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            #expect(ExpressionReview.notes(in: bytes, count: 5).keys.allSatisfy { (1...5).contains($0) })
        }
    }

    @Test func aHugeReplyIsReadQuicklyAndKeepsOnlyInRangeNotes() {
        let items = (0..<10_000).map { #"{"sentence":\#($0 % 40),"note":"\#(ExpressionNote.allCases[$0 % ExpressionNote.allCases.count].rawValue)"}"# }
        let reply = Data(#"{"notes":[\#(items.joined(separator: ","))]}"#.utf8)
        let clock = ContinuousClock()
        var result: [Int: ExpressionNote] = [:]
        let elapsed = clock.measure { result = ExpressionReview.notes(in: reply, count: 24) }
        #expect(result.count == 24 && result.keys.sorted() == Array(1...24))
        // The first item for each sentence wins: sentence n is first seen at item n.
        #expect(result[1] == ExpressionNote.allCases[1] && result[24] == ExpressionNote.allCases[24 % ExpressionNote.allCases.count])
        #expect(elapsed < .seconds(2), "10,000 entries took \(elapsed)")
    }

    // MARK: Windows

    /// Property: windows cover every sentence with words exactly once, in order, within both limits
    /// (a single sentence longer than the character limit travels alone).
    @Test(arguments: [51, 52, 53] as [UInt64])
    func windowsCoverEveryWordSentenceOnceWithinLimits(seed: UInt64) {
        var rng = Seeded(state: seed)
        for _ in 0..<200 {
            let sentences = (0..<Int.random(in: 0...80, using: &rng)).map { _ -> String in
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: " ..."
                case 1: "\n"
                case 2: String(repeating: "word ", count: Int.random(in: 1...300, using: &rng))
                default: " Sentence \(Int.random(in: 0...99, using: &rng))."
                }
            }
            let maxSentences = Int.random(in: 1...30, using: &rng), maxCharacters = Int.random(in: 1...3_000, using: &rng)
            let windows = ExpressionReview.windows(sentences, maxSentences: maxSentences, maxCharacters: maxCharacters)
            let expected = sentences.indices.filter { sentences[$0].unicodeScalars.contains(where: ExpressionPlan.isWordScalar) }
            #expect(windows.flatMap { $0 } == expected)
            for window in windows {
                #expect(!window.isEmpty && window.count <= maxSentences)
                let size = window.reduce(0) { $0 + sentences[$1].count }
                #expect(window.count == 1 || size <= maxCharacters)
            }
            // Greedy: each window is as full as the limits allowed.
            for (window, next) in zip(windows, windows.dropFirst()) {
                let size = window.reduce(0) { $0 + sentences[$1].count }
                #expect(window.count == maxSentences || size + sentences[next[0]].count > maxCharacters)
            }
        }
    }

    // MARK: The review

    /// A fake model that answers from a script, counting calls.
    actor Script {
        var calls = 0
        var asked: [[String]] = []
        var budgets: [Duration] = []
        func next(_ sentences: [String], _ left: Duration) -> Int { calls += 1; asked.append(sentences); budgets.append(left); return calls }
    }

    static func sentences(_ n: Int) -> String { (0..<n).map { "Sentence number \($0)." }.joined(separator: " ") }

    @Test func numbersOutsideTheWindowAreIgnored() async {
        let outcome = await ExpressionReview.run(Self.sentences(3), budget: .seconds(30)) { sentences, _ in
            [0: .sad, -1: .sad, Int.min: .sad, Int.max: .sad, sentences.count + 1: .sad, 2: .calm]
        }
        #expect(outcome.plan.notes == [.init(sentence: 1, note: .calm)])
        #expect(outcome.reviewed == 3 && outcome.total == 3 && outcome.message == nil)
    }

    /// Property: when the Nth window fails, the notes of the windows before it are kept and nothing after,
    /// and the message says how far the review got.
    @Test(arguments: [61, 62, 63] as [UInt64])
    func aFailingWindowKeepsExactlyTheWindowsBeforeIt(seed: UInt64) async {
        var rng = Seeded(state: seed)
        for _ in 0..<12 {
            let text = Self.sentences(Int.random(in: 1...90, using: &rng))
            let windows = ExpressionReview.windows(Sentences.split(text))
            let failAt = Int.random(in: 1...(windows.count + 1), using: &rng)
            let script = Script()
            let outcome = await ExpressionReview.run(text, budget: .seconds(60)) { sentences, left in
                let call = await script.next(sentences, left)
                if call == failAt { throw OllamaError.server("boom") }
                return Dictionary(uniqueKeysWithValues: (1...sentences.count).map { ($0, ExpressionNote.allCases[$0 % ExpressionNote.allCases.count]) })
            }
            let done = windows.prefix(failAt - 1)
            let expected = done.flatMap { $0 }
            #expect(outcome.plan.notes.map(\.sentence) == expected)
            #expect(outcome.reviewed == expected.count && outcome.total == windows.joined().count)
            #expect(await script.calls == min(failAt, windows.count))
            if failAt > windows.count {
                #expect(outcome.message == nil)
            } else if failAt == 1 {
                #expect(outcome.message == "Spoken without expression notes. Ollama: boom")
            } else {
                #expect(outcome.message == "Notes cover the first \(expected.count) of \(outcome.total) sentences; the review then failed. Ollama: boom")
            }
            // The model saw each window's sentences trimmed, in order.
            let asked = await script.asked
            #expect(asked.first == windows.first.map { $0.map { Sentences.split(text)[$0].trimmingCharacters(in: .whitespacesAndNewlines) } })
        }
    }

    @Test func eachWindowIsGivenTheTimeLeft() async {
        let script = Script()
        let outcome = await ExpressionReview.run(Self.sentences(80), budget: .seconds(20)) { sentences, left in
            _ = await script.next(sentences, left)
            try await Task.sleep(for: .milliseconds(30))
            return [:]
        }
        let budgets = await script.budgets
        #expect(budgets.count == 4 && outcome.message == nil && outcome.reviewed == 80)
        // Never more than the budget, and (under a loaded test run) still most of it.
        #expect(budgets.allSatisfy { $0 <= .seconds(20) && $0 > .seconds(10) })
        #expect(zip(budgets, budgets.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func aWindowThatOverrunsTheBudgetKeepsItsNotesAndStopsTheRest() async {
        let script = Script()
        let outcome = await ExpressionReview.run(Self.sentences(50), budget: .milliseconds(300)) { sentences, left in
            _ = await script.next(sentences, left)
            try await Task.sleep(for: .milliseconds(400))
            return [1: .excited]
        }
        #expect(await script.calls == 1)
        #expect(outcome.plan.notes == [.init(sentence: 0, note: .excited)])
        #expect(outcome.reviewed == 24 && outcome.total == 50)
        #expect(outcome.message == "Notes cover the first 24 of 50 sentences; the rest did not fit in the time available.")
        // Less than a quarter second left is not worth a request.
        let short = Script()
        let none = await ExpressionReview.run("Hello there.", budget: .milliseconds(250)) { sentences, left in _ = await short.next(sentences, left); return [1: .happy] }
        #expect(await short.calls == 0 && none.plan.isEmpty && none.reviewed == 0 && none.total == 1)
        let negative = await ExpressionReview.run("Hello there.", budget: .seconds(-5)) { _, _ in [1: .happy] }
        #expect(negative.plan.isEmpty && negative.message == "Spoken without expression notes: the review did not finish in the time available.")
    }

    @Test func textWithoutWordsIsNeverSentToTheModel() async {
        let script = Script()
        for text in ["", "   ", "...\n!!!", "😀 👍", "\n\n\n"] {
            let outcome = await ExpressionReview.run(text, budget: .seconds(5)) { sentences, left in _ = await script.next(sentences, left); return [1: .sad] }
            #expect(outcome == ExpressionReview.Outcome(), "\(text.debugDescription)")
        }
        #expect(await script.calls == 0)
    }

    @Test func aReviewCancelledBeforeItStartsAsksNothing() async {
        let script = Script()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ExpressionReview.run(Self.sentences(5), budget: .seconds(5)) { sentences, left in _ = await script.next(sentences, left); return [1: .sad] }
        }.value
        #expect(await script.calls == 0)
        #expect(outcome.plan.isEmpty && outcome.message == "The review was cancelled.")
    }

    @Test func cancellationBetweenWindowsKeepsTheFinishedWindows() async {
        let script = Script()
        let outcome = await Task {
            await ExpressionReview.run(Self.sentences(60), budget: .seconds(30)) { sentences, left in
                let call = await script.next(sentences, left)
                // The model answers the first window, then the task is cancelled; the answer still counts.
                if call == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return [1: .worried]
            }
        }.value
        #expect(await script.calls == 1)
        #expect(outcome.plan.notes == [.init(sentence: 0, note: .worried)] && outcome.reviewed == 24 && outcome.total == 60)
        #expect(outcome.message == "The review was cancelled.")
        // A model call that throws CancellationError mid-review keeps what was reviewed before it.
        let second = Script()
        let thrown = await ExpressionReview.run(Self.sentences(60), budget: .seconds(30)) { sentences, left in
            if await second.next(sentences, left) == 2 { throw CancellationError() }
            return [2: .hopeful]
        }
        #expect(thrown.plan.notes == [.init(sentence: 1, note: .hopeful)] && thrown.reviewed == 24 && thrown.message == "The review was cancelled.")
    }

    // MARK: Plans

    @Test func plansDecodeDefensively() throws {
        func decode(_ json: String) throws -> ExpressionPlan { try JSONDecoder().decode(ExpressionPlan.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"notes":[]}"#).isEmpty)
        #expect(try decode(#"{"notes":[{"sentence":-3,"note":"sad"},{"sentence":9223372036854775807,"note":"calm"}]}"#).notes == [.init(sentence: Int.max, note: .calm)])
        #expect(throws: DecodingError.self) { try decode("{}") }
        #expect(throws: DecodingError.self) { try decode(#"{"notes":[{"sentence":1.5,"note":"sad"}]}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"notes":[{"sentence":1}]}"#) }
        // A far-away sentence number places nothing and does not trap.
        #expect(try decode(#"{"notes":[{"sentence":9223372036854775807,"note":"calm"}]}"#).annotate("Hi.").text == "Hi.")
        // Round trip, including through a saved job.
        let plan = ExpressionPlan(notes: [.init(sentence: 4, note: .inAHurryTone), .init(sentence: 0, note: .softTone)])
        #expect(try JSONDecoder().decode(ExpressionPlan.self, from: JSONEncoder().encode(plan)) == plan)
        var job = SpeechJob(request: SpeechRequest(voice: "v", text: "Hi.", expressive: true), voiceName: "V")
        job.expressive = true; job.expressionPlan = plan; job.expressionModel = "m"; job.expressionMessage = "why"
        let restored = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(job))
        #expect(restored.expressionPlan == plan && restored.expressive == true && restored.expressionModel == "m" && restored.expressionMessage == "why")
        #expect(restored.request.expressive == true)
    }

    @Test func requestsDecodeWithoutExpressiveAsTheSetting() throws {
        let old = try JSONDecoder().decode(SpeechRequest.self, from: Data(#"{"voice":"v","text":"Hi.","pace":1,"mode":"play"}"#.utf8))
        #expect(old.expressive == nil)
        let job = try JSONDecoder().decode(SpeechJob.self, from: JSONEncoder().encode(SpeechJob(request: old, voiceName: "V")))
        #expect(job.expressive == nil && job.expressionPlan == nil)
    }

    // MARK: Pronunciations leave notes alone

    /// Property (against a reference): respelling annotated text while protecting its notes gives exactly
    /// the notes placed on the respelled original. Notes are never changed and every other match is the
    /// same as respelling the text without notes. Entries deliberately include words from the catalog.
    @Test(arguments: [71, 72, 73, 74, 75] as [UInt64])
    func protectedRespellingMatchesTheReference(seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let pieces = ["SQL", " ", "excited", "Excited", "calm", "soft tone", "Soft Tone", "tone", "hurry", "in a hurry tone", "IBM's", "SQLite",
                      ". ", "! ", "? ", "\n", "\r\n", "é", "Straße", "中文", "😀", "(aside) ", "[whisper] ", "4.2", "  ", "\t", "emphasis",
                      "happy", "proud", "worried", "scared", "sad", "the", "e\u{301}clair", "Éclair"]
        let pool: [(String, String, Bool)] = [("SQL", "sequel", true), ("excited", "ek-SY-ted", false), ("calm", "kahm", false),
                                              ("soft tone", "sawft tohn", false), ("tone", "tohn", false), ("in a hurry", "in uh HUR-ee", false),
                                              ("emphasis", "EM-fuh-sis", false), ("Straße", "SHTRAH-suh", false), ("happy", "HAP-ee", false),
                                              ("proud", "prowd", false), ("worried", "WUR-eed", false), ("the", "thuh", false), ("éclair", "ay-KLAIR", false)]
        for round in 0..<200 {
            let text = Self.text(&rng, pieces: pieces, upTo: 30)
            let list = try PronunciationTests.list(pool.filter { _ in Bool.random(using: &rng) })
            let plan = Self.plan(for: text, &rng)
            let (noted, ranges) = plan.annotate(text)
            let context = "seed \(seed) round \(round): \(text.debugDescription)"
            let protected = try list.respell(noted, protecting: ranges)
            let reference = plan.annotate(try list.respell(text)).text
            #expect(protected.unicodeScalars.elementsEqual(reference.unicodeScalars), "\(context)\n  got \(protected.debugDescription)\n  ref \(reference.debugDescription)")
            // Every placed note survives exactly.
            let markers = ranges.map { String(noted[$0]) }
            let found = Sentences.split(protected).compactMap { sentence -> String? in
                let scalars = Self.scalars(sentence)
                return LeadingNote.parts(of: scalars).map { Sentences.string(scalars[$0.note]) }
            }.filter { found in ExpressionNote.allCases.contains { $0.marker == found } }
            #expect(found == markers, "\(context)")
        }
    }

    @Test func protectedRangesThatAreEmptyOrOutOfOrderAreHarmless() throws {
        let list = try PronunciationTests.list([("calm", "kahm", false)])
        let text = "(calm) Stay calm. Calm."
        let first = text.range(of: "(calm)")!, empty = text.startIndex..<text.startIndex
        #expect(try list.respell(text, protecting: [empty]) == "(kahm) Stay kahm. kahm.")
        #expect(try list.respell(text, protecting: [first, first, empty]) == "(calm) Stay kahm. kahm.")
        let whole = text.startIndex..<text.endIndex
        #expect(try list.respell(text, protecting: [whole]) == text)
        // A protected range covering half a word stops that word from matching.
        let half = text.range(of: "Cal")!
        #expect(try list.respell(text, protecting: [half]) == "(kahm) Stay kahm. Calm.")
        // No entries or no text: returned as is.
        #expect(try PronunciationList().respell(text, protecting: [first]) == text)
        #expect(try list.respell("", protecting: []) == "")
    }

    @Test func protectingNotesKeepsLongTextsFast() throws {
        let list = try PronunciationTests.list((0..<200).map { ("word\($0)", "wurd \($0)", false) } + [("excited", "ek-SY-ted", false)])
        let text = (0..<4_000).map { "The word\($0 % 300) was excited here." }.joined(separator: " ")
        let plan = ExpressionPlan(notes: (0..<4_000).map { .init(sentence: $0, note: .excited) })
        let clock = ContinuousClock()
        var noted = "", ranges: [Range<String.Index>] = [], spoken = ""
        let annotating = clock.measure { (noted, ranges) = plan.annotate(text) }
        let respelling = try clock.measure { spoken = try list.respell(noted, protecting: ranges) }
        #expect(ranges.count == 4_000)
        #expect(spoken.components(separatedBy: "(excited) ").count - 1 == 4_000)
        #expect(!spoken.contains("(ek-SY-ted)"))
        #expect(annotating < .seconds(2) && respelling < .seconds(10), "annotate \(annotating), respell \(respelling)")
    }

    // MARK: Pronunciation suggestions

    /// Property: every suggestion is something the panel accepts, made of respelling characters, tidy,
    /// never the written form, never repeated, and at most four; the result is deterministic.
    @Test(arguments: [81, 82, 83] as [UInt64])
    func suggestionsAreAlwaysAcceptableEntries(seed: UInt64) {
        var rng = Seeded(state: seed)
        let pieces = ["koo", "-", "ber", "NET", " ", "  ", "eez", "'", "’", "é", "\u{301}", "\u{200B}", "\u{FEFF}", "\t", "\n", "@", "/", "3",
                      "٣", "½", "😀", "(", "x", "SQL", "sequel", "Ω", "\u{202E}", "a"]
        let written = ["Kubernetes", "SQL", "IBM", "CI/CD", "GIF", "x", "Straße", "S3", " AWS ", "sequel", "Ω"]
        for _ in 0..<500 {
            let term = written.randomElement(using: &rng)!
            let proposals = (0..<Int.random(in: 0...8, using: &rng)).map { _ in Self.text(&rng, pieces: pieces, upTo: 10) }
            let result = PronunciationSuggestions.usable(proposals, for: term)
            let context = "\(term) ← \(proposals.map(\.debugDescription))"
            #expect(result.count <= PronunciationSuggestions.maxSuggestions, "\(context)")
            #expect(PronunciationSuggestions.usable(proposals, for: term) == result, "\(context)")
            for (index, spelling) in result.enumerated() {
                #expect((try? PronunciationList.validated(Pronunciation(written: term, sayAs: spelling, matchCase: false)))?.sayAs == spelling, "\(context)")
                #expect(spelling.unicodeScalars.allSatisfy(PronunciationSuggestions.isRespellingScalar), "\(context)")
                #expect(spelling.count <= 80 && spelling == spelling.trimmingCharacters(in: .whitespaces) && !spelling.contains("  "), "\(context)")
                #expect(spelling.caseInsensitiveCompare(PronunciationList.cleaned(term)) != .orderedSame, "\(context)")
                #expect(!result[..<index].contains { $0.caseInsensitiveCompare(spelling) == .orderedSame }, "\(context)")
            }
            // The spelled-out letters are offered whenever there is room for them.
            if let letters = PronunciationSuggestions.spelledOut(term), result.count < PronunciationSuggestions.maxSuggestions {
                #expect(result.contains { $0.caseInsensitiveCompare(letters) == .orderedSame }, "\(context)")
            }
        }
    }

    /// Property: an initialism of two to eight ASCII capitals (digits allowed, ten characters at most) is
    /// spelled out letter by letter in order, whatever separates them; anything else is nil.
    @Test(arguments: [91, 92] as [UInt64])
    func spelledOutIsExactlyTheInitialismRule(seed: UInt64) {
        var rng = Seeded(state: seed)
        let capitals = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), digits = Array("0123456789"), separators = ["", "", "/", "-", ".", "&", " ", "\u{200B}"]
        for _ in 0..<1_000 {
            var characters: [Character] = []
            for _ in 0..<Int.random(in: 0...12, using: &rng) {
                characters.append(Int.random(in: 0..<4, using: &rng) == 0 ? digits.randomElement(using: &rng)! : capitals.randomElement(using: &rng)!)
            }
            let written = characters.map { String($0) + separators.randomElement(using: &rng)! }.joined()
            let letters = characters.filter(\.isLetter).count
            let expected = (2...8).contains(letters) && characters.count <= 10 ? characters.map(String.init).joined(separator: " ") : nil
            #expect(PronunciationSuggestions.spelledOut(written) == expected, "\(written.debugDescription)")
            // One lowercase or non-ASCII letter anywhere and it is not an initialism.
            if !characters.isEmpty {
                #expect(PronunciationSuggestions.spelledOut(written + "s") == nil)
                #expect(PronunciationSuggestions.spelledOut("É" + written) == nil)
            }
        }
        #expect(PronunciationSuggestions.spelledOut("ＩＢＭ") == nil)
        #expect(PronunciationSuggestions.spelledOut("I\u{200B}BM") == "I B M")
        #expect(PronunciationSuggestions.spelledOut("") == nil)
    }

    @Test func suggestionRepliesAreReadDefensively() {
        func candidates(_ json: String, _ written: String = "Kubernetes") -> [String] { PronunciationSuggestions.candidates(in: Data(json.utf8), for: written) }
        #expect(candidates(#"{"candidates":[{"sayAs":7},{"sayAs":null},{"sayAs":["koo"]},{"sayAs":"koo-ber-NET-eez","extra":1}]}"#) == ["koo-ber-NET-eez"])
        #expect(candidates(#"{"candidates":[{"sayAs":"koo"},"koo"]}"#).isEmpty)
        #expect(candidates(#"{"candidates":{"sayAs":"koo"}}"#).isEmpty)
        #expect(candidates(#"[{"sayAs":"koo"}]"#).isEmpty)
        // An empty reply still offers the letters of an initialism.
        #expect(candidates(#"{"candidates":[]}"#, "IBM") == ["I B M"])
        let many = (0..<1_000).map { #"{"sayAs":"say \#($0)"}"# }.joined(separator: ",")
        #expect(candidates(#"{"candidates":[\#(many)]}"#) == ["say 0", "say 1", "say 2", "say 3"])
        #expect(PronunciationSuggestions.prompt(for: "Siobhan") == "Term: Siobhan")
    }

    @Test func suggestionSchemaAsksForOneToThreeRespellings() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: PronunciationSuggestions.schema) as? [String: Any])
        #expect(schema["required"] as? [String] == ["candidates"])
        let candidates = try #require((schema["properties"] as? [String: Any])?["candidates"] as? [String: Any])
        #expect(candidates["minItems"] as? Int == 1 && candidates["maxItems"] as? Int == 3)
        let item = try #require(candidates["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["sayAs"])
        let review = try #require(try JSONSerialization.jsonObject(with: ExpressionReview.schema) as? [String: Any])
        #expect(review["required"] as? [String] == ["notes"])
        let reviewItem = try #require(((review["properties"] as? [String: Any])?["notes"] as? [String: Any])?["items"] as? [String: Any])
        #expect(reviewItem["required"] as? [String] == ["sentence", "note"])
        #expect(((reviewItem["properties"] as? [String: Any])?["sentence"] as? [String: Any])?["type"] as? String == "integer")
    }
}

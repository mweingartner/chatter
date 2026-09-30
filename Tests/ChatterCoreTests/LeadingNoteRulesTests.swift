import Foundation
import Testing
@testable import ChatterCore

/// The rules that tell a typed note from ordinary text (list markers, Roman numerals, citations, digits,
/// Markdown links, any script), where `LeadingNote.ranges(in:)` finds notes, what a review's outcome
/// says for every way it can stop, and that respelling never touches a note the writer typed. Seeded,
/// so a failure names the seed that reproduces it.
struct LeadingNoteRulesTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    static func parts(_ sentence: String) -> LeadingNote.Parts? { LeadingNote.parts(of: Array(sentence.unicodeScalars)) }
    static func note(_ sentence: String) -> String? {
        let scalars = Array(sentence.unicodeScalars)
        return LeadingNote.parts(of: scalars).map { Sentences.string(scalars[$0.note]) }
    }

    // MARK: Roman numerals and list markers

    /// Roman numerals in any case are list markers, in parentheses or brackets, with or without spaces.
    @Test(arguments: ["i", "ii", "iii", "iv", "v", "vi", "ix", "x", "xi", "xii", "xiv", "xl", "xc", "cd", "cm", "mi", "mix", "mcmxciv", "mmxxvi",
                      "IV", "Iv", "iV", "XII", "xIi", "MCMXCIV", "LXXXVIII", "dc", "lx", "mm"])
    func romanNumeralsAreListMarkers(numeral: String) {
        #expect(Self.parts("(\(numeral)) Returns are free.") == nil, "(\(numeral))")
        #expect(Self.parts("[\(numeral)] Returns are free.") == nil, "[\(numeral)]")
        #expect(LeadingNote.isRomanNumeral(Array(numeral.unicodeScalars)), "\(numeral)")
    }

    /// Words made only of the letters I V X L C D M are notes unless they spell a numeral: "livid" is a feeling.
    @Test(arguments: ["livid", "mild", "vivid", "dim", "civil", "did", "id", "ill", "lid", "mid", "iiii", "vv", "ll", "dd", "il", "vx", "Livid", "MILD"])
    func wordsThatOnlyLookRomanAreNotes(word: String) {
        #expect(!LeadingNote.isRomanNumeral(Array(word.unicodeScalars)), "\(word)")
        #expect(Self.note("(\(word)) Get out of my house!") == "(\(word))")
        #expect(Self.note("[\(word)] Get out of my house!") == "[\(word)]")
    }

    @Test func romanNumeralCheckRejectsWhatIsNotASCIIRoman() {
        for letters in ["", "ok", "é", "ⅳ", "Ⅻ", "i\u{301}v", "xyz"] {
            #expect(!LeadingNote.isRomanNumeral(Array(letters.unicodeScalars)), "\(letters.debugDescription)")
        }
        // Every numeral from 1 to 3999, written the usual way, in upper and lower case, is recognized.
        let table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        for value in 1...3999 {
            var rest = value, numeral = ""
            for (amount, letters) in table { while rest >= amount { numeral += letters; rest -= amount } }
            #expect(LeadingNote.isRomanNumeral(Array(numeral.unicodeScalars)) && LeadingNote.isRomanNumeral(Array(numeral.lowercased().unicodeScalars)), "\(value)")
        }
    }

    /// Two letters are enough for a note; one letter (any script) is a list marker.
    @Test func twoLetterWordsAreNotesAndSingleLettersAreMarkers() {
        for word in ["ok", "OK", "no", "hi", "ah", "oh", "Hm", "日本", "ΑΒ", "да"] {
            #expect(Self.note("(\(word)) Fine.") == "(\(word))", "\(word)")
        }
        for marker in ["a", "B", "z", "é", "e\u{301}", "ж", "笑", "א", "a-", "a '", "a -"] {
            #expect(Self.parts("(\(marker)) Fine.") == nil, "\(marker.debugDescription)")
        }
    }

    /// Chinese numerals and Unicode Roman numeral letters are list markers too; words written with
    /// ideographs that also count (一, 十) are notes.
    @Test func numeralsInOtherScriptsAreListMarkers() {
        for marker in ["(十一)", "(二十)", "(一百)", "[十二]", "(ⅰⅴ)", "(ⅻⅰ)"] {
            #expect(Self.parts(marker + " Item.") == nil, "\(marker)")
        }
        for note in ["(一緒に)", "(十分に嬉しい)", "[一緒に笑う]", "[二人で話す]", "[小声で一言]", "[一边笑一边说]"] {
            #expect(Self.note(note + " 行こう。") == note, "\(note)")
        }
    }

    // MARK: Other scripts

    @Test(arguments: ["(嬉しい)", "(ख़ुश)", "(سعيد)", "(שמח)", "(радостно)", "(χαρούμενος)", "(기쁘게)", "(ดีใจ)", "(e\u{301}mu)", "[ささやき声]", "[на ухо]", "[بهمس]"])
    func notesInAnyScriptAreRecognized(note: String) {
        #expect(Self.note(note + " x") == note)
        #expect(Self.note("\u{3000}" + note + "\tx") == note)
    }

    // MARK: Brackets

    /// A direction needs letters and no digit of any script.
    @Test func bracketDirectionsRefuseDigitsOfAnyScript() {
        for text in ["[take 2]", "[1]", "[12, 13]", "[p. 4]", "[whisper²]", "[laugh ①]", "[٣ laughs]", "[३ bar]", "[ⅳ laugh]", "[2x]", "[x2]",
                     "[x]", "[ ]", "[...]", "[!!]", "[😀😀]", "[-]"] {
            #expect(Self.parts(text + " Buy milk.") == nil, "\(text)")
        }
        for text in ["[laughs]", "[soft tone]", "[laughing, then serious]", "[aside (quietly)]", "[whisper!]", "[a b]"] {
            #expect(Self.note(text + " Hello.") == text, "\(text)")
        }
    }

    /// "[text](url)" is a Markdown link wherever the "(" follows directly; a space, tab or line break
    /// between them makes a direction followed by text.
    @Test func markdownLinksAreTextButSpacedParenthesesAreNot() {
        for text in ["[docs](https://example.com) explains it.", "[docs](", "[soft tone](calm) Hello.", "[whisper](excited) Hi.",
                     "  [read this](#anchor) now", "[docs]()"] {
            #expect(Self.parts(text) == nil, "\(text)")
        }
        #expect(Self.note("[whisper] (excited) Hi.") == "[whisper]")
        #expect(Self.parts("[whisper] (excited) Hi.")?.body == 10..<23)
        #expect(Self.note("[whisper]\t(excited) Hi.") == "[whisper]")
        #expect(Self.note("[docs]") == "[docs]")          // alone, at the end of the text
        #expect(Self.note("[docs]) x") == "[docs]")       // a closing parenthesis is not a link
        #expect(!LeadingNote.isPresent(in: "See [the docs](https://x.y). [Notes](./n.md) too.\n[docs](u)"))
        // A link's text on its own line before the URL is a direction on that line.
        #expect(LeadingNote.isPresent(in: "[docs]\n(https://example.com)"))
    }

    // MARK: Nested and adjacent

    @Test func nestedAndAdjacentNotesTakeOnlyTheFirst() {
        #expect(Self.note("(excited)(calm) x") == "(excited)")
        #expect(Self.note("(excited) (calm) x") == "(excited)")
        #expect(Self.note("[laughs][sighs] x") == "[laughs]")
        #expect(Self.note("(excited) [whisper] x") == "(excited)")
        #expect(Self.parts("((excited)) x") == nil)
        #expect(Self.parts("[[whisper]] x") == nil)
        #expect(Self.parts("(excited (very)) x") == nil)
        #expect(Self.note("[aside [x] ] y") == nil)
        // Parentheses inside a direction are part of it; the first "]" closes it.
        #expect(Self.note("[aside (quietly)] y") == "[aside (quietly)]")
        #expect(Self.note("[ab]] y") == "[ab]")
        // A list marker followed by a note: the marker is text, so the sentence has no note.
        #expect(Self.parts("(a) (excited) x") == nil && Self.parts("(iv) [whisper] x") == nil)
    }

    // MARK: ranges(in:)

    /// Property: ranges(in:) finds exactly the notes that parts(of:) finds, sentence by sentence, at the
    /// same scalars, in order, for any Unicode.
    @Test(arguments: [211, 212, 213, 214] as [UInt64])
    func rangesAgreeWithParts(seed: UInt64) {
        var rng = Seeded(state: seed)
        let pieces = ExpressionPropertyTests.unicodePieces + ["(livid) ", "(iv) ", "(ok) ", "[docs](u) ", "[take 2] ", "[一緒に笑う] ", "(十一) ",
                                                              "(excited)", "[x]", "\u{301}", ")\u{301}", "(a) ", "   (calm) "]
        for round in 0..<400 {
            let text = ExpressionPropertyTests.text(&rng, pieces: pieces, upTo: 30)
            let scalars = text.unicodeScalars
            let context = "seed \(seed) round \(round): \(text.debugDescription)"
            var expected: [Range<Int>] = [], offset = 0
            for sentence in Sentences.split(Array(scalars)) {
                if let parts = LeadingNote.parts(of: sentence) {
                    expected.append((offset + parts.note.lowerBound)..<(offset + parts.note.upperBound))
                }
                offset += sentence.count
            }
            let ranges = LeadingNote.ranges(in: text)
            let found = ranges.map { scalars.distance(from: scalars.startIndex, to: $0.lowerBound)..<scalars.distance(from: scalars.startIndex, to: $0.upperBound) }
            #expect(found == expected, "\(context)")
            #expect(!ranges.isEmpty == LeadingNote.isPresent(in: text), "\(context)")
            for range in ranges {
                let note = Array(scalars[range])
                #expect((note.first == "(" && note.last == ")") || (note.first == "[" && note.last == "]"), "\(context)")
                // Each range is a whole note on its own.
                #expect(LeadingNote.parts(of: note)?.note == 0..<note.count, "\(context)")
            }
            #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound }, "\(context)")
        }
    }

    /// Ranges are exact even when a note is followed by a combining mark or sits after CRLF, so the
    /// UTF-16 offsets respelling uses cover the note and nothing else.
    @Test func rangesAreScalarExactAroundCombiningMarksAndCRLF() throws {
        let text = "Hi.\r\n(calm)\u{301} calm. é. (livid) livid!"
        let ranges = LeadingNote.ranges(in: text)
        #expect(ranges.map { Sentences.string(text.unicodeScalars[$0]) } == ["(calm)", "(livid)"])
        let list = try PronunciationTests.list([("calm", "kahm", false), ("livid", "LIV-id", false)])
        #expect(try list.respell(text, protecting: ranges) == "Hi.\r\n(calm)\u{301} kahm. é. (livid) LIV-id!")
    }

    // MARK: Outcome messages

    /// Every way a review stops, with nothing reviewed and with part of the text reviewed, reads as specified,
    /// for speech receipts and for Studio's Add notes now.
    @Test(arguments: [
        (ExpressionReview.Outcome.Stop.finished, 0, nil, nil),
        (.finished, 5, nil, nil),
        (.cancelled, 0, "The review was cancelled.", "Stopped. No notes were added."),
        (.cancelled, 3, "The review was cancelled.", "Stopped. No notes were added."),
        (.outOfTime, 0, "Spoken without expression notes: the review did not finish in the time available.",
         "No notes were added: the model did not finish in time."),
        (.outOfTime, 3, "Notes cover the first 3 of 7 sentences; the rest did not fit in the time available.",
         "Notes were added to the first 3 of 7 sentences; the rest did not fit in the time available."),
        (.failed("Ollama: boom"), 0, "Spoken without expression notes. Ollama: boom", "No notes were added. Ollama: boom"),
        (.failed("Ollama: boom"), 1, "Notes cover the first 1 of 7 sentences; the review then failed. Ollama: boom",
         "Notes were added to the first 1 of 7 sentences; the model then failed. Ollama: boom"),
    ] as [(ExpressionReview.Outcome.Stop, Int, String?, String?)])
    func outcomeMessagesForEveryStop(stop: ExpressionReview.Outcome.Stop, reviewed: Int, message: String?, editorMessage: String?) {
        let outcome = ExpressionReview.Outcome(reviewed: reviewed, total: 7, stop: stop)
        #expect(outcome.message == message)
        #expect(outcome.editorMessage == editorMessage)
        // A cancelled review says the same whatever it had reviewed; the plan never changes the wording.
        let withPlan = ExpressionReview.Outcome(plan: ExpressionPlan(notes: [.init(sentence: 0, note: .calm)]), reviewed: reviewed, total: 7, stop: stop)
        #expect(withPlan.message == message && withPlan.editorMessage == editorMessage)
    }

    /// The wording follows the counts: nothing reviewed is "no notes"; anything reviewed names how far it got.
    @Test func outcomeMessagesNameTheCounts() throws {
        var rng = Seeded(state: 909)
        for _ in 0..<200 {
            let total = Int.random(in: 1...500, using: &rng), reviewed = Int.random(in: 0...total, using: &rng)
            for stop in [ExpressionReview.Outcome.Stop.outOfTime, .failed("why")] {
                let outcome = ExpressionReview.Outcome(reviewed: reviewed, total: total, stop: stop)
                let message = try #require(outcome.message), editor = try #require(outcome.editorMessage)
                if reviewed == 0 {
                    #expect(message.hasPrefix("Spoken without expression notes") && editor.hasPrefix("No notes were added"))
                } else {
                    #expect(message.hasPrefix("Notes cover the first \(reviewed) of \(total) sentences;"))
                    #expect(editor.hasPrefix("Notes were added to the first \(reviewed) of \(total) sentences;"))
                }
                if case .failed = stop { #expect(message.hasSuffix(" why") && editor.hasSuffix(" why")) }
            }
        }
    }

    /// A timeout from any window, first or later, ends the review as out of time and keeps what was reviewed.
    @Test func aTimeoutInALaterWindowKeepsTheEarlierNotes() async {
        let text = (0..<50).map { "Sentence number \($0)." }.joined(separator: " ")
        let calls = Recorder()
        let outcome = await ExpressionReview.run(text, budget: .seconds(30)) { sentences, _ in
            await calls.add(sentences)
            if await calls.batches.count == 2 { throw OllamaError.timedOut }
            return [1: .proud]
        }
        #expect(outcome.stop == .outOfTime && outcome.reviewed == 24 && outcome.total == 50)
        #expect(outcome.plan.notes == [.init(sentence: 0, note: .proud)])
        #expect(outcome.message == "Notes cover the first 24 of 50 sentences; the rest did not fit in the time available.")
        #expect(outcome.editorMessage == "Notes were added to the first 24 of 50 sentences; the rest did not fit in the time available.")
        // Other Ollama errors are failures, with the error's words.
        let missing = await ExpressionReview.run(text, budget: .seconds(30)) { _, _ in throw OllamaError.modelMissing("m") }
        #expect(missing.stop == .failed(OllamaError.modelMissing("m").localizedDescription))
    }

    // MARK: Respelling protects typed notes

    /// End to end as a speech job does it: annotate, then respell protecting `LeadingNote.ranges(in:)` of
    /// the noted text. Notes the writer typed and notes the review placed both come through unchanged.
    @Test func typedAndPlacedNotesSurviveRespelling() throws {
        let list = try PronunciationTests.list([("livid", "LIV-id", false), ("whispering", "WHIS-per-ing", false), ("soft tone", "sawft tohn", false),
                                                ("excited", "ek-SY-ted", false), ("一緒に", "いっしょに", false), ("ok", "oh-KAY", false), ("docs", "DOX", false)])
        let text = "(livid) I am livid. [soft tone] A soft tone. Ok. (ok) ok!\n[一緒に 笑う] 一緒に 行こう。 [docs](u) docs. (iv) whispering here."
        let plan = ExpressionPlan(notes: (0..<9).map { .init(sentence: $0, note: .excited) })
        let noted = plan.annotate(text).text
        #expect(LeadingNote.ranges(in: noted).map { Sentences.string(noted.unicodeScalars[$0]) }
                == ["(livid)", "[soft tone]", "(excited)", "(ok)", "[一緒に 笑う]", "(excited)", "(excited)"])
        let spoken = try list.respell(noted, protecting: LeadingNote.ranges(in: noted))
        // A Markdown link and a list marker are text, so their words are respelled like any other.
        #expect(spoken == "(livid) I am LIV-id. [soft tone] A sawft tohn. (excited) oh-KAY. (ok) oh-KAY!\n[一緒に 笑う] いっしょに 行こう。 (excited) [DOX](u) DOX. (excited) (iv) WHIS-per-ing here.")
    }

    /// Property: respelling noted text while protecting ranges(in:) equals placing the notes on the text
    /// respelled with its own typed notes protected; and every note of the noted text survives verbatim, in
    /// order. Entries deliberately match words that appear inside notes.
    @Test(arguments: [231, 232, 233, 234] as [UInt64])
    func typedNotesAreNeverRespelled(seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let pieces = ["(livid) ", "(soft tone) ", "[soft tone] ", "(whispering) ", "[laughs] ", "(ok) ", "(iv) ", "[docs](u) ", "(十一) ", "[一緒に笑う] ",
                      "livid", "soft", "tone", "whispering", "laughs", "ok", "docs", "一緒に", " ", ". ", "! ", "\n", "\r\n", "  ", "é", "(", "]", "x"]
        let pool: [(String, String, Bool)] = [("livid", "LIV-id", false), ("soft tone", "sawft tohn", false), ("tone", "tohn", false),
                                              ("whispering", "WHIS-per-ing", false), ("laughs", "laffs", false), ("ok", "oh-KAY", false),
                                              ("docs", "DOX", false), ("一緒に", "いっしょに", false), ("excited", "ek-SY-ted", false), ("calm", "kahm", false)]
        for round in 0..<250 {
            let text = ExpressionPropertyTests.text(&rng, pieces: pieces, upTo: 24)
            let list = try PronunciationTests.list(pool.filter { _ in Bool.random(using: &rng) })
            let plan = ExpressionPropertyTests.plan(for: text, &rng)
            let noted = plan.annotate(text).text
            let context = "seed \(seed) round \(round): \(text.debugDescription)"
            let ranges = LeadingNote.ranges(in: noted)
            let spoken = try list.respell(noted, protecting: ranges)
            let reference = plan.annotate(try list.respell(text, protecting: LeadingNote.ranges(in: text))).text
            #expect(spoken.unicodeScalars.elementsEqual(reference.unicodeScalars), "\(context)\n  got \(spoken.debugDescription)\n  ref \(reference.debugDescription)")
            let before = ranges.map { Sentences.string(noted.unicodeScalars[$0]) }
            let after = LeadingNote.ranges(in: spoken).map { Sentences.string(spoken.unicodeScalars[$0]) }
            #expect(after == before, "\(context)")
        }
    }

    // MARK: Performance

    /// ranges(in:) is linear: a long text with a note on every sentence is found quickly.
    @Test func rangesStayFastOnLongText() {
        let text = (0..<20_000).map { $0 % 3 == 0 ? "(livid) Line \($0)." : ($0 % 3 == 1 ? "[soft tone] Line." : "(iv) Line.") }.joined(separator: " ")
        let clock = ContinuousClock()
        var ranges: [Range<String.Index>] = []
        let elapsed = clock.measure { ranges = LeadingNote.ranges(in: text) }
        #expect(ranges.count == 13_334)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}

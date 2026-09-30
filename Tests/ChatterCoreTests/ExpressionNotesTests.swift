import Foundation
import Testing
@testable import ChatterCore

/// Expression notes: where sentences begin, what counts as a note, how a review's notes are placed and
/// checked, and that pronunciations never touch them.
struct ExpressionNotesTests {
    // MARK: Sentences

    @Test func sentencesSplitLikeTheEngineAndLoseNothing() {
        #expect(Sentences.split("Hi there. How are you? Fine!") == ["Hi there.", " How are you?", " Fine!"])
        #expect(Sentences.split("Revenue was 4.2 million. Next.") == ["Revenue was 4.2 million.", " Next."])
        #expect(Sentences.split("One\nTwo") == ["One\n", "Two"])
        #expect(Sentences.split("") == [""])
        var rng = PronunciationEdgeTests.Seeded(state: 77)
        let pieces = ["word ", "é", "中文", ". ", "! ", "? ", "。", "\n", "  ", "(excited) ", "[whisper] ", "x"]
        for _ in 0..<500 {
            let text = (0..<Int.random(in: 0...40, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            #expect(Sentences.split(text).joined() == text)
        }
    }

    // MARK: Leading notes

    @Test(arguments: [("(excited) I am here!", "(excited)"), ("  (soft tone) Goodnight.", "(soft tone)"), ("\n(in a hurry tone) Run!", "(in a hurry tone)"),
                      ("(don’t-stop) Go.", "(don’t-stop)"), ("[professional broadcast tone] Welcome.", "[professional broadcast tone]"),
                      ("(ख़ुश) नमस्ते।", "(ख़ुश)")])
    func notesAreRecognized(sentence: String, note: String) throws {
        let scalars = Array(sentence.unicodeScalars)
        let parts = try #require(LeadingNote.parts(of: scalars))
        #expect(Sentences.string(scalars[parts.note]) == note)
        #expect(!Sentences.string(scalars[parts.body]).hasPrefix(" "))
    }

    @Test(arguments: ["(2019) was a year.", "(see page 4) for details.", "( excited) no.", "() Empty.", "(unclosed text", "Text (excited) later.",
                      "[multi\nline] x", "(" + String(repeating: "a", count: 41) + ") long", "[" + String(repeating: "a", count: 61) + "] long", "(a1) digit"])
    func otherParenthesesAreText(sentence: String) {
        #expect(LeadingNote.parts(of: Array(sentence.unicodeScalars)) == nil)
    }

    /// Everything the review can place is recognized as a note; ordinary list and reference openings are not.
    @Test func catalogNotesAreNotesAndListMarkersAreText() {
        for note in ExpressionNote.allCases {
            #expect(LeadingNote.parts(of: Array((note.marker + " Words.").unicodeScalars)) != nil, "\(note.marker)")
        }
        #expect(!LeadingNote.isPresent(in: "The terms: (a) you pay. (b) We ship. (iv) Returns are free."))
        #expect(!LeadingNote.isPresent(in: "[1] Smith, 2019. [x] Buy milk.\n[docs](https://example.com) explains it."))
        #expect(LeadingNote.isPresent(in: "Sure. (laughing) That was fun."))
    }

    @Test func noteRangesCoverTypedAndPlacedNotes() throws {
        let text = "(whispering) Don't tell. It was (maybe) fine.\n[soft tone] Goodnight. (a) Next."
        let ranges = LeadingNote.ranges(in: text)
        #expect(ranges.map { String(text[$0]) } == ["(whispering)", "[soft tone]"])
        let list = try PronunciationTests.list([("whispering", "WHIS-per-ing", false), ("soft", "SAWFT", false), ("tell", "TELL", false)])
        #expect(try list.respell(text, protecting: ranges) == "(whispering) Don't TELL. It was (maybe) fine.\n[soft tone] Goodnight. (a) Next.")
        #expect(LeadingNote.ranges(in: "No notes here.").isEmpty)
    }

    @Test func messagesFitWhereTheyAreShown() {
        typealias O = ExpressionReview.Outcome
        #expect(O(reviewed: 0, total: 3, stop: .failed("Ollama isn’t running.")).message == "Spoken without expression notes. Ollama isn’t running.")
        #expect(O(reviewed: 0, total: 3, stop: .failed("Ollama isn’t running.")).editorMessage == "No notes were added. Ollama isn’t running.")
        #expect(O(reviewed: 0, total: 3, stop: .outOfTime).editorMessage == "No notes were added: the model did not finish in time.")
        #expect(O(reviewed: 24, total: 30, stop: .outOfTime).editorMessage == "Notes were added to the first 24 of 30 sentences; the rest did not fit in the time available.")
        #expect(O(reviewed: 24, total: 30, stop: .failed("x")).editorMessage == "Notes were added to the first 24 of 30 sentences; the model then failed. x")
        #expect(O(stop: .cancelled).editorMessage == "Stopped. No notes were added." && O(stop: .cancelled).message == "The review was cancelled.")
        #expect(O().message == nil && O().editorMessage == nil)
    }

    @Test func aTimedOutRequestCountsAsOutOfTime() async {
        let outcome = await ExpressionReview.run("One. Two.", budget: .seconds(30)) { _, _ in throw OllamaError.timedOut }
        #expect(outcome.stop == .outOfTime && outcome.message == "Spoken without expression notes: the review did not finish in the time available.")
    }

    @Test func notesAreFoundInAnySentence() {
        #expect(LeadingNote.isPresent(in: "Plain start. (excited) Then this!"))
        #expect(LeadingNote.isPresent(in: "First line\n[whisper] second line"))
        #expect(!LeadingNote.isPresent(in: "We met (briefly) in 2019. It went well (mostly)."))
    }

    // MARK: Placing notes

    @Test func notesOpenTheirSentencesAndTheWordsStayTheSame() {
        let text = "I am so happy to be here! Thank you all.\nGet off that roof! 42."
        // Sentences: "I am…here!", " Thank you all.", "\n", "Get off that roof!", " 42." (a newline is a sentence of its own).
        let plan = ExpressionPlan(notes: [.init(sentence: 0, note: .happy), .init(sentence: 2, note: .sad), .init(sentence: 3, note: .shouting), .init(sentence: 4, note: .calm)])
        let (noted, ranges) = plan.annotate(text)
        #expect(noted == "(happy) I am so happy to be here! Thank you all.\n(shouting) Get off that roof! (calm) 42.")
        #expect(ranges.map { String(noted[$0]) } == ["(happy)", "(shouting)", "(calm)"])
        // Removing the notes gives back the words exactly.
        var stripped = noted
        for range in ranges.reversed() { stripped.removeSubrange(range.lowerBound..<noted.index(after: range.upperBound)) }
        #expect(stripped == text)
    }

    @Test func sentencesWithoutWordsOrWithTheirOwnNoteGetNothing() {
        let text = "Hello. ... (sad) Already noted. Last."
        let plan = ExpressionPlan(notes: (0..<5).map { .init(sentence: $0, note: .excited) })
        #expect(plan.annotate(text).text == "(excited) Hello. ... (sad) Already noted. (excited) Last.")
        #expect(ExpressionPlan().annotate(text).text == text)
        #expect(ExpressionPlan(notes: [.init(sentence: 99, note: .sad)]).annotate(text).text == text)
    }

    @Test func plansKeepOneNotePerSentenceInOrder() throws {
        let plan = ExpressionPlan(notes: [.init(sentence: 3, note: .sad), .init(sentence: 1, note: .happy), .init(sentence: 3, note: .angry), .init(sentence: -1, note: .calm)])
        #expect(plan.notes == [.init(sentence: 1, note: .happy), .init(sentence: 3, note: .sad)])
        let decoded = try JSONDecoder().decode(ExpressionPlan.self, from: Data(#"{"notes":[{"sentence":2,"note":"sad"},{"sentence":2,"note":"happy"},{"sentence":0,"note":"soft tone"}]}"#.utf8))
        #expect(decoded.notes == [.init(sentence: 0, note: .softTone), .init(sentence: 2, note: .sad)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ExpressionPlan.self, from: Data(#"{"notes":[{"sentence":0,"note":"yodeling"}]}"#.utf8)) }
    }

    /// Property: whatever the plan, annotating only inserts "(note) " before sentences, and the ranges it
    /// reports are exactly those notes.
    @Test func annotatingOnlyInsertsNotes() {
        var rng = PronunciationEdgeTests.Seeded(state: 4242)
        let pieces = ["Hello", " world", ". ", "! ", "? ", "\n", "  ", "é", "中文", "(aside) ", "4.2", "…"]
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 0...30, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let count = Sentences.split(text).count
            let plan = ExpressionPlan(notes: (0..<count).compactMap { Bool.random(using: &rng) ? .init(sentence: $0, note: ExpressionNote.allCases.randomElement(using: &rng)!) : nil })
            let (noted, ranges) = plan.annotate(text)
            var stripped = noted
            for range in ranges.reversed() {
                #expect(noted[range].hasPrefix("(") && noted[range].hasSuffix(")"))
                stripped.removeSubrange(range.lowerBound..<noted.index(after: range.upperBound))
            }
            #expect(stripped == text, "\(text.debugDescription) → \(noted.debugDescription)")
        }
    }

    // MARK: Review

    @Test func windowsSkipWordlessSentencesAndStayBounded() {
        let sentences = ["One.", " ...", " Two.", " 3.", " Four."]
        #expect(ExpressionReview.windows(sentences) == [[0, 2, 3, 4]])
        #expect(ExpressionReview.windows(sentences, maxSentences: 2) == [[0, 2], [3, 4]])
        let long = Array(repeating: String(repeating: "a", count: 1_000), count: 5)
        #expect(ExpressionReview.windows(long, maxCharacters: 2_400) == [[0, 1], [2, 3], [4]])
        #expect(ExpressionReview.windows([]) == [])
    }

    @Test func repliesAreCheckedAgainstTheSentencesAndCatalog() {
        let reply = Data(#"{"notes":[{"sentence":1,"note":"excited"},{"sentence":1,"note":"sad"},{"sentence":0,"note":"calm"},{"sentence":4,"note":"calm"},{"sentence":2,"note":"yodeling"},{"sentence":3,"note":"in a hurry tone"},{"sentence":"2","note":"sad"}]}"#.utf8)
        #expect(ExpressionReview.notes(in: reply, count: 3) == [1: .excited, 3: .inAHurryTone])
        #expect(ExpressionReview.notes(in: Data("not json".utf8), count: 3).isEmpty)
        #expect(ExpressionReview.notes(in: Data(#"{"notes":[]}"#.utf8), count: 0).isEmpty)
    }

    @Test func instructionsListEveryNoteAndRespectTheTone() throws {
        let natural = ExpressionReview.instructions(tone: .natural)
        for note in ExpressionNote.allCases { #expect(natural.contains("- \(note.rawValue): \(note.meaning)")) }
        #expect(!natural.contains("overall delivery"))
        #expect(ExpressionReview.instructions(tone: .cheerful).contains("already cheerful"))
        #expect(ExpressionReview.prompt(["Hi.", "Bye!"]) == "1. Hi.\n2. Bye!")
        let schema = try #require(try JSONSerialization.jsonObject(with: ExpressionReview.schema) as? [String: Any])
        let item = try #require(((schema["properties"] as? [String: Any])?["notes"] as? [String: Any])?["items"] as? [String: Any])
        let allowed = try #require(((item["properties"] as? [String: Any])?["note"] as? [String: Any])?["enum"] as? [String])
        #expect(allowed == ExpressionNote.allCases.map(\.rawValue))
    }

    @Test func reviewMapsWindowNumbersToSentences() async {
        let text = "One. ... Two. Three. Four."
        let seen = Recorder()
        let outcome = await ExpressionReview.run(text, budget: .seconds(30)) { sentences, _ in
            await seen.add(sentences)
            return [1: .happy, sentences.count: .sad]
        }
        #expect(await seen.batches == [["One.", "Two.", "Three.", "Four."]])
        #expect(outcome.plan.notes == [.init(sentence: 0, note: .happy), .init(sentence: 4, note: .sad)])
        #expect(outcome.reviewed == 4 && outcome.total == 4 && outcome.message == nil)
    }

    @Test func reviewKeepsWhatItHadWhenTheModelFails() async {
        let text = (0..<30).map { "Sentence \($0)." }.joined(separator: " ")
        let calls = Recorder()
        let outcome = await ExpressionReview.run(text, budget: .seconds(30)) { sentences, _ in
            await calls.add(sentences)
            if await calls.batches.count == 2 { throw OllamaError.notRunning("http://127.0.0.1:11434") }
            return [1: .calm]
        }
        #expect(outcome.plan.notes == [.init(sentence: 0, note: .calm)])
        #expect(outcome.reviewed == 24 && outcome.total == 30)
        #expect(outcome.message?.hasPrefix("Notes cover the first 24 of 30 sentences; the review then failed. Ollama isn’t running") == true)
        let failed = await ExpressionReview.run("Hello there.", budget: .seconds(30)) { _, _ in throw OllamaError.modelMissing("qwen") }
        #expect(failed.plan.isEmpty && failed.message?.hasPrefix("Spoken without expression notes. Ollama doesn’t have “qwen”") == true)
    }

    @Test func reviewStopsWhenTheBudgetIsSpent() async {
        let text = (0..<30).map { "Sentence \($0)." }.joined(separator: " ")
        let outcome = await ExpressionReview.run(text, budget: .milliseconds(400)) { _, left in
            try await Task.sleep(for: .milliseconds(300))
            #expect(left <= .milliseconds(400))
            return [2: .excited]
        }
        #expect(outcome.reviewed == 24 && outcome.message == "Notes cover the first 24 of 30 sentences; the rest did not fit in the time available.")
        let none = await ExpressionReview.run("Hi there.", budget: .zero) { _, _ in [1: .happy] }
        #expect(none.plan.isEmpty && none.message == "Spoken without expression notes: the review did not finish in the time available.")
    }

    @Test func cancellingStopsTheReview() async {
        let review = Task {
            await ExpressionReview.run((0..<60).map { "Line \($0)." }.joined(separator: " "), budget: .seconds(30)) { _, _ in
                try await Task.sleep(for: .seconds(10)); return [:]
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        review.cancel()
        let outcome = await review.value
        #expect(outcome.plan.isEmpty && outcome.message == "The review was cancelled.")
    }

    // MARK: Pronunciations leave notes alone

    @Test func respellingNeverTouchesProtectedNotes() throws {
        let list = try PronunciationTests.list([("excited", "ek-SY-ted", false), ("SQL", "sequel", true), ("calm", "kahm", false)])
        let plan = ExpressionPlan(notes: [.init(sentence: 0, note: .excited), .init(sentence: 1, note: .calm)])
        let (noted, ranges) = plan.annotate("SQL is excited. Stay calm.")
        #expect(noted == "(excited) SQL is excited. (calm) Stay calm.")
        #expect(try list.respell(noted, protecting: ranges) == "(excited) sequel is ek-SY-ted. (calm) Stay kahm.")
        // Without protection the same words inside notes would change.
        #expect(try list.respell(noted) == "(ek-SY-ted) sequel is ek-SY-ted. (kahm) Stay kahm.")
    }

    // MARK: Pronunciation suggestions

    @Test func suggestionsAreCheckedLikeTypedEntries() {
        let usable = PronunciationSuggestions.usable(["koo-ber-NET-eez", "koo-ber-net-eez", "Kubernetes", "see eye / see dee", "", "  koo   BER  netes  ",
                                                      "\u{200B}koo-ber-NEET-eez", String(repeating: "a", count: 81), "x@y"], for: "Kubernetes")
        #expect(usable == ["koo-ber-NET-eez", "koo BER netes", "koo-ber-NEET-eez"])
        #expect(PronunciationSuggestions.usable(["sequel"], for: "SQL") == ["sequel", "S Q L"])
        #expect(PronunciationSuggestions.usable(["S Q L", "sequel"], for: "SQL") == ["S Q L", "sequel"])
        #expect(PronunciationSuggestions.usable(["a", "b", "c", "d", "e"], for: "Word").count == PronunciationSuggestions.maxSuggestions)
        let reply = Data(#"{"candidates":[{"sayAs":"JIF"},{"sayAs":"GIF"},{"other":1}]}"#.utf8)
        #expect(PronunciationSuggestions.candidates(in: reply, for: "GIF") == ["JIF", "G I F"])
        #expect(PronunciationSuggestions.candidates(in: Data("{".utf8), for: "GIF").isEmpty)
    }

    @Test(arguments: [("IBM", "I B M"), ("CI/CD", "C I C D"), ("AWS", "A W S"), ("B2B", "B 2 B"), (" FBI ", "F B I")])
    func initialismsAreSpelledOut(written: String, letters: String) {
        #expect(PronunciationSuggestions.spelledOut(written) == letters)
    }

    @Test(arguments: ["iOS", "Kubernetes", "A", "S3", "ÉCOLE", "ABCDEFGHI", "a b"])
    func otherWordsAreNotSpelledOut(written: String) {
        #expect(PronunciationSuggestions.spelledOut(written) == nil)
    }
}

/// Collects what a fake model was asked, safely across tasks.
actor Recorder {
    var batches: [[String]] = []
    func add(_ batch: [String]) { batches.append(batch) }
}

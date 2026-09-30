import Foundation

/// An expression note: a parenthetical direction at the start of a sentence, such as
/// "(excited) I am so happy to be here!". Chatter separates it from spoken text and sends it as a Qwen instruction. The catalog
/// contains curated emotions and delivery directions; the notes are written in parentheses,
/// which the model reads as silently as its documented [brackets].
public enum ExpressionNote: String, CaseIterable, Codable, Sendable {
    case happy, sad, angry, excited, calm, nervous, confident, surprised, delighted, scared, worried, upset, frustrated
    case empathetic, embarrassed, disgusted, moved, proud, relaxed, grateful, curious, sarcastic, hopeful, disappointed
    case determined, anxious, confused, nostalgic, shouting, whispering
    case softTone = "soft tone", inAHurryTone = "in a hurry tone", emphasis

    /// The note as it appears in text.
    public var marker: String { "(\(rawValue))" }

    /// What the note asks of the reader, in a few words (shown to the language model and in Settings).
    public var meaning: String {
        switch self {
        case .happy: "joyful, pleased"
        case .sad: "sorrowful, subdued"
        case .angry: "forceful displeasure"
        case .excited: "enthusiastic, animated"
        case .calm: "relaxed and composed"
        case .nervous: "uneasy, hesitant"
        case .confident: "self-assured, certain"
        case .surprised: "an unexpected realization"
        case .delighted: "very pleased"
        case .scared: "fearful"
        case .worried: "concerned about what may happen"
        case .upset: "distressed"
        case .frustrated: "impatient, exasperated"
        case .empathetic: "caring about another person’s feelings"
        case .embarrassed: "self-conscious"
        case .disgusted: "revulsion"
        case .moved: "touched, emotional"
        case .proud: "a sense of achievement"
        case .relaxed: "at ease"
        case .grateful: "thankful"
        case .curious: "interested, questioning"
        case .sarcastic: "dry irony"
        case .hopeful: "looking forward to something"
        case .disappointed: "let down"
        case .determined: "resolved, committed"
        case .anxious: "tense, uneasy"
        case .confused: "puzzled"
        case .nostalgic: "wistful about the past"
        case .shouting: "a raised, loud voice"
        case .whispering: "quiet and secretive"
        case .softTone: "quiet and gentle"
        case .inAHurryTone: "rushed, urgent"
        case .emphasis: "stressing the words"
        }
    }
}

/// A note that a sentence already opens with, typed by a person or added by a review: "(words)" made of
/// letters, spaces, hyphens and apostrophes (at most 40 scalars), or a legacy "[direction]" (at most 60
/// scalars) with letters and no digits, after optional whitespace. Other openings are text: "(2019)",
/// "(see page 4)", list markers such as "(a)" and "(iv)", citations such as "[1]", checkboxes such as
/// "[x]", and Markdown links "[text](url)".
public enum LeadingNote {
    public struct Parts: Equatable, Sendable {
        /// Whitespace before the note.
        public var leading: Range<Int>
        /// The note, brackets included.
        public var note: Range<Int>
        /// What follows the note and the spaces after it.
        public var body: Range<Int>
    }

    static let maxWords = 40
    static let maxDirection = 60

    public static func parts(of sentence: [Unicode.Scalar]) -> Parts? {
        var start = 0
        while start < sentence.count, Sentences.isSpace(sentence[start]) { start += 1 }
        guard start < sentence.count else { return nil }
        let open = sentence[start]
        guard open == "(" || open == "[" else { return nil }
        let close: Unicode.Scalar = open == "(" ? ")" : "]"
        let limit = open == "(" ? maxWords : maxDirection
        var end = start + 1
        while end < sentence.count, sentence[end] != close, end - start - 1 <= limit {
            let s = sentence[end]
            if open == "(" {
                let category = s.properties.generalCategory
                let allowed = s.properties.isAlphabetic || category == .nonspacingMark || category == .spacingMark
                    || s == " " || s == "-" || s == "'" || s == "\u{2019}"
                guard allowed, end > start + 1 || s.properties.isAlphabetic else { return nil }
            } else {
                guard s != "[", s != "\n", s != "\r", s.properties.generalCategory != .control else { return nil }
            }
            end += 1
        }
        let length = end - start - 1
        guard end < sentence.count, sentence[end] == close, (1...limit).contains(length) else { return nil }
        let content = sentence[(start + 1)..<end]
        let letters = content.filter(\.properties.isAlphabetic)
        // One letter, or letters that only spell a number (a Roman numeral such as "iv", or numerals such
        // as "十一" or "ⅳ"), make a list marker, not a note. Words such as "livid" or "mild" are notes.
        guard letters.count >= 2, !isRomanNumeral(letters), !letters.allSatisfy({ $0.properties.numericType != nil }) else { return nil }
        if open == "[" {
            // Digits of any script refuse a direction; ideographs that also count (一, 十) are words.
            guard !content.contains(where: { [.decimalNumber, .otherNumber, .letterNumber].contains($0.properties.generalCategory) }) else { return nil }
            if end + 1 < sentence.count, sentence[end + 1] == "(" { return nil }   // a Markdown link
        }
        var body = end + 1
        while body < sentence.count, sentence[body] == " " || sentence[body] == "\t" { body += 1 }
        return Parts(leading: 0..<start, note: start..<(end + 1), body: body..<sentence.count)
    }

    /// Whether ASCII `letters` spell a Roman numeral in its usual form, in any case: "iv", "XII", "mcmxciv"
    /// and "mix" do; "livid", "mild", "dim" and "iiii" don't.
    static func isRomanNumeral(_ letters: [Unicode.Scalar]) -> Bool {
        let values: [UInt32: Int] = [0x49: 1, 0x56: 5, 0x58: 10, 0x4C: 50, 0x43: 100, 0x44: 500, 0x4D: 1000]   // I V X L C D M
        let upper = letters.map { (0x61...0x7A).contains($0.value) ? $0.value - 0x20 : $0.value }
        let digits = upper.compactMap { values[$0] }
        guard !digits.isEmpty, digits.count == upper.count else { return false }
        var value = 0
        for (i, digit) in digits.enumerated() { value += i + 1 < digits.count && digit < digits[i + 1] ? -digit : digit }
        guard value > 0 else { return false }
        // The numeral is Roman only if writing its value back gives the same letters.
        var canonical: [UInt32] = [], rest = value
        for (amount, numeral) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                                  (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while rest >= amount { canonical += numeral.unicodeScalars.map(\.value); rest -= amount }
        }
        return canonical == upper
    }

    /// Whether any sentence of `text` already opens with a note.
    public static func isPresent(in text: String) -> Bool {
        Sentences.split(Array(text.unicodeScalars)).contains { parts(of: $0) != nil }
    }

    /// Where the notes that open sentences are in `text`, so pronunciations can leave them alone.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        let scalars = text.unicodeScalars
        var ranges: [Range<String.Index>] = [], start = scalars.startIndex
        for sentence in Sentences.split(Array(scalars)) {
            if let parts = parts(of: sentence) {
                ranges.append(scalars.index(start, offsetBy: parts.note.lowerBound)..<scalars.index(start, offsetBy: parts.note.upperBound))
            }
            start = scalars.index(start, offsetBy: sentence.count)
        }
        return ranges
    }
}

/// The notes an expression review chose: at most one per sentence, by index into `Sentences.split(text)`.
public struct ExpressionPlan: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        public var sentence: Int
        public var note: ExpressionNote
        public init(sentence: Int, note: ExpressionNote) { self.sentence = sentence; self.note = note }
    }

    /// In sentence order, one per sentence.
    public private(set) var notes: [Note]

    public init(notes: [Note] = []) {
        var seen = Set<Int>()
        self.notes = notes.filter { $0.sentence >= 0 && seen.insert($0.sentence).inserted }.sorted { $0.sentence < $1.sentence }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(notes: try values.decode([Note].self, forKey: .notes))
    }

    public var isEmpty: Bool { notes.isEmpty }

    /// The text with each note placed at the start of its sentence (after the whitespace that precedes the
    /// sentence), and where the notes are in it, so pronunciations can leave them alone. A sentence that
    /// has no words, or already opens with a note, gets nothing; the words are never changed.
    public func annotate(_ text: String) -> (text: String, notes: [Range<String.Index>]) {
        guard !notes.isEmpty else { return (text, []) }
        let byIndex = Dictionary(notes.map { ($0.sentence, $0.note) }, uniquingKeysWith: { first, _ in first })
        var result = ""
        result.reserveCapacity(text.utf8.count + notes.count * 24)
        var ranges: [Range<String.Index>] = []
        for (index, sentence) in Sentences.split(Array(text.unicodeScalars)).enumerated() {
            let start = sentence.firstIndex { !Sentences.isSpace($0) }
            guard let note = byIndex[index], let start, sentence.contains(where: Self.isWordScalar),
                  LeadingNote.parts(of: sentence) == nil else {
                result.unicodeScalars.append(contentsOf: sentence); continue
            }
            result.unicodeScalars.append(contentsOf: sentence[..<start])
            let lower = result.endIndex
            result += note.marker
            ranges.append(lower..<result.endIndex)
            result += " "
            result.unicodeScalars.append(contentsOf: sentence[start...])
        }
        return (result, ranges)
    }

    static func isWordScalar(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic || s.properties.numericType != nil }
}

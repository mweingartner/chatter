import Foundation
import Testing
@testable import ChatterCore

/// The numeral rules that tell a list marker from a typed note: `LeadingNote.isRomanNumeral(_:)` against an
/// independent oracle (exhaustively for short numerals, every value 1–3999 in every case, and every single
/// edit of each), the rule that letters which only spell a number are a marker, and the bracket rule that
/// refuses digits of any script but not ideographs that also count. Seeded, so a failure names its seed.
struct LeadingNoteNumeralTests {
    typealias Seeded = PronunciationEdgeTests.Seeded

    static let romanLetters: [Character] = ["I", "V", "X", "L", "C", "D", "M"]

    /// The usual Roman form of `value`, written digit by digit (a different method from the one under test):
    /// thousands as repeated M, then the hundreds, tens and ones tables.
    static func roman(_ value: Int) -> String {
        let hundreds = ["", "C", "CC", "CCC", "CD", "D", "DC", "DCC", "DCCC", "CM"]
        let tens = ["", "X", "XX", "XXX", "XL", "L", "LX", "LXX", "LXXX", "XC"]
        let ones = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX"]
        return String(repeating: "M", count: value / 1000) + hundreds[value / 100 % 10] + tens[value / 10 % 10] + ones[value % 10]
    }

    /// Every numeral in its usual form, up to a value whose numerals are longer than any string tested here
    /// could be while still being all M's.
    static let oracle: Set<String> = Set((1...12_000).map(roman))

    static func isRoman(_ s: String) -> Bool { LeadingNote.isRomanNumeral(Array(s.unicodeScalars)) }
    static func parts(_ sentence: String) -> LeadingNote.Parts? { LeadingNote.parts(of: Array(sentence.unicodeScalars)) }
    static func note(_ sentence: String) -> String? {
        let scalars = Array(sentence.unicodeScalars)
        return LeadingNote.parts(of: scalars).map { Sentences.string(scalars[$0.note]) }
    }

    /// `s` with each letter's case chosen by `rng`.
    static func mixedCase(_ s: String, _ rng: inout Seeded) -> String {
        String(s.map { Bool.random(using: &rng) ? Character($0.lowercased()) : $0 })
    }

    // MARK: isRomanNumeral against the oracle

    /// Exhaustive: every string of one to five letters from I V X L C D M (19,607 of them) is a numeral
    /// exactly when it is some value's usual form, in upper case, lower case and a seeded mix of both.
    @Test func everyShortLetterStringMatchesTheOracle() {
        var rng = Seeded(state: 301)
        var strings: [String] = [""], accepted = 0
        for _ in 1...5 {
            strings = strings.flatMap { prefix in Self.romanLetters.map { prefix + String($0) } }
            for s in strings {
                let expected = Self.oracle.contains(s)
                if expected { accepted += 1 }
                let mixed = Self.mixedCase(s, &rng)
                #expect(Self.isRoman(s) == expected, "\(s)")
                #expect(Self.isRoman(s.lowercased()) == expected, "\(s.lowercased())")
                #expect(Self.isRoman(mixed) == expected, "\(mixed)")
            }
        }
        // Sanity on the oracle itself: of the 19,607 strings, only the usual forms of short numerals pass.
        #expect(accepted == Self.oracle.filter { $0.count <= 5 }.count)
        #expect(Self.isRoman("MMMMM") && Self.isRoman("mmmcm") && !Self.isRoman("IIII") && !Self.isRoman("VX") && !Self.isRoman("IL"))
    }

    /// Every value from 1 to 3999 is a list marker in parentheses and in brackets, in upper, lower and mixed
    /// case, and with spaces between its letters; the numeral alone parses back to the same value.
    @Test func everyNumeralFrom1To3999IsAListMarker() {
        var rng = Seeded(state: 302)
        for value in 1...3999 {
            let numeral = Self.roman(value)
            for form in [numeral, numeral.lowercased(), Self.mixedCase(numeral, &rng), numeral.map(String.init).joined(separator: " ")] {
                #expect(Self.parts("(\(form)) Returns are free.") == nil, "\(value): (\(form))")
                #expect(Self.parts("[\(form)] Returns are free.") == nil, "\(value): [\(form)]")
                #expect(Self.parts("  (\(form))\tReturns.") == nil, "\(value): indented (\(form))")
            }
        }
    }

    /// Near misses: every single deletion, insertion, substitution and adjacent swap of every numeral from 1
    /// to 3999 is a numeral exactly when the oracle says so. Those that aren't, with two letters or more,
    /// are notes in parentheses and brackets: "(xiiii)" is a word the rule has no reason to refuse.
    @Test func everySingleEditOfEveryNumeralMatchesTheOracle() {
        var checked = 0, rejected = 0, sampledNotes = 0
        var rng = Seeded(state: 303)
        for value in 1...3999 {
            let letters = Array(Self.roman(value))
            var edits: Set<String> = []
            for i in letters.indices {
                var deleted = letters; deleted.remove(at: i); edits.insert(String(deleted))
                for letter in Self.romanLetters where letter != letters[i] {
                    var substituted = letters; substituted[i] = letter; edits.insert(String(substituted))
                }
                if i + 1 < letters.count, letters[i] != letters[i + 1] {
                    var swapped = letters; swapped.swapAt(i, i + 1); edits.insert(String(swapped))
                }
            }
            for i in 0...letters.count {
                for letter in Self.romanLetters { var inserted = letters; inserted.insert(letter, at: i); edits.insert(String(inserted)) }
            }
            for edit in edits where !edit.isEmpty {
                let expected = Self.oracle.contains(edit)
                checked += 1
                #expect(Self.isRoman(edit) == expected && Self.isRoman(edit.lowercased()) == expected, "\(value) → \(edit)")
                // Parsing a sentence is slower; check a seeded sample of the refused edits end to end.
                if !expected, edit.count >= 2 {
                    rejected += 1
                    if Int.random(in: 0..<20, using: &rng) == 0 {
                        sampledNotes += 1
                        let word = edit.lowercased()
                        #expect(Self.note("(\(word)) Get out!") == "(\(word))", "\(value) → (\(word))")
                        #expect(Self.note("[\(word)] Get out!") == "[\(word)]", "\(value) → [\(word)]")
                    }
                }
            }
        }
        #expect(checked > 100_000 && rejected > 90_000 && sampledNotes > 3_000, "\(checked) \(rejected) \(sampledNotes)")
    }

    /// Words spelled only with Roman letters: those that happen to be a numeral's usual form are list
    /// markers ("mix" is 1009), the rest are notes. The expectation comes from the oracle, the list pins
    /// the words people type.
    @Test(arguments: ["mix", "mi", "di", "civ", "lix", "dix", "xi", "vi", "li", "ci", "dc", "cm", "mcc", "cd",
                      "livid", "vivid", "mild", "civil", "civic", "mimic", "dim", "did", "mid", "lid", "ill", "id", "vim", "mil", "cid", "dvd", "lcd", "mill", "dill"])
    func romanLookingWordsFollowTheOracle(word: String) {
        let numeral = Self.oracle.contains(word.uppercased())
        #expect(Self.isRoman(word) == numeral && Self.isRoman(word.uppercased()) == numeral, "\(word)")
        #expect((Self.note("(\(word)) Well.") == "(\(word))") == !numeral, "(\(word))")
        #expect((Self.note("[\(word)] Well.") == "[\(word)]") == !numeral, "[\(word)]")
    }

    /// Only ASCII I V X L C D M count. Look-alikes from other scripts and forms (fullwidth, dotless i,
    /// Cyrillic і, Roman numeral symbols) are not ASCII Roman numerals, and neither is an empty string,
    /// a value spelled with zero-width or combining scalars, or a letter outside the seven.
    @Test func onlyASCIIRomanLettersCount() {
        for s in ["ＩＶ", "ｉｖ", "ıv", "іv", "ⅰⅴ", "ⅳ", "Ⅻ", "x\u{200B}i", "x\u{301}", "IVa", "MCMXCIVs", "iv ", " iv", "i-v", "e", "IJ"] {
            #expect(!Self.isRoman(s), "\(s.debugDescription)")
        }
        #expect(!LeadingNote.isRomanNumeral([]))
        // Letters outside a–z are not folded: U+212A KELVIN SIGN and U+0130 are not "K" or "I".
        #expect(!Self.isRoman("\u{130}V"))
    }

    /// The parser is linear and bounded: a long run of M's (longer than any note may be) is a numeral,
    /// and a long non-numeral is refused, both without blowing up.
    @Test func longRunsAreHandledQuickly() {
        let clock = ContinuousClock()
        var results: [Bool] = []
        let elapsed = clock.measure {
            for count in 1...200 {
                results.append(Self.isRoman(String(repeating: "M", count: count) + "CMXCIX"))
                results.append(Self.isRoman(String(repeating: "IV", count: count)))
            }
        }
        #expect(results.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element : ($0.offset == 1) == $0.element })
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    // MARK: Letters that only spell a number

    /// Numeral letters of other scripts: ideographs that count and Unicode letter numbers. Each is a letter
    /// with a numeric value, which is what the rule reads; if Unicode data changed this would say so first.
    static let numeralLetters = Array("一二三四五六七八九十百千万〇零億兆两廿卅ⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹⅺⅻⅼⅽⅾⅿⅠⅤⅩᛮ".unicodeScalars)
    /// Letters with no numeric value, from several scripts.
    static let wordLetters = Array("笑分月緒声ab日жξשأक".unicodeScalars)

    @Test func theNumeralPoolsAreWhatTheRuleReads() {
        for s in Self.numeralLetters { #expect(s.properties.isAlphabetic && s.properties.numericType != nil, "\(s)") }
        for s in Self.wordLetters { #expect(s.properties.isAlphabetic && s.properties.numericType == nil, "\(s)") }
    }

    /// Property: two or more numeral letters, with or without spaces and hyphens between them, are a list
    /// marker in parentheses and in brackets. Metamorphic: adding one letter with no numeric value turns
    /// the parenthesised marker into a note; in brackets it becomes a direction only when no scalar is a
    /// digit, number sign or letter number (so "〇" and "ⅰ" still refuse it).
    @Test(arguments: [311, 312, 313] as [UInt64])
    func lettersThatOnlySpellANumberAreMarkers(seed: UInt64) {
        var rng = Seeded(state: seed)
        let separators: [String] = ["", "", "", " ", "-"]
        for round in 0..<500 {
            let count = Int.random(in: 2...12, using: &rng)
            var content = ""
            for i in 0..<count {
                if i > 0 { content += separators.randomElement(using: &rng)! }
                content.unicodeScalars.append(Self.numeralLetters.randomElement(using: &rng)!)
            }
            let context = "seed \(seed) round \(round): \(content.debugDescription)"
            #expect(Self.parts("(\(content)) Item.") == nil, "\(context)")
            #expect(Self.parts("[\(content)] Item.") == nil, "\(context)")

            var word = content.unicodeScalars
            let at = word.index(word.startIndex, offsetBy: Int.random(in: 0...word.count, using: &rng))
            word.insert(Self.wordLetters.randomElement(using: &rng)!, at: at)
            let noted = String(word)
            // Parentheses allow only letters, spaces, hyphens and apostrophes; the first must be a letter.
            #expect(Self.note("(\(noted)) Item.") == "(\(noted))", "\(context) + \(noted.debugDescription)")
            let hasNumber = word.contains { [.decimalNumber, .otherNumber, .letterNumber].contains($0.properties.generalCategory) }
            #expect((Self.note("[\(noted)] Item.") == "[\(noted)]") == !hasNumber, "\(context) + [\(noted)]")
        }
    }

    /// A single numeral letter is a marker whatever it is; words made with counting ideographs are notes.
    @Test func ideographWordsThatCountAreNotesButNumbersAreNot() {
        for marker in ["(十)", "(〇)", "(ⅳ)", "(二十一)", "(三百)", "(〇〇)", "[百万]", "[ⅹⅱ]", "(十 一)", "(一-二)"] {
            #expect(Self.parts(marker + " Item.") == nil, "\(marker)")
        }
        for note in ["(十分)", "(一緒)", "(三日月)", "[一緒に]", "[十分に]", "[三日月の下で]"] {
            #expect(Self.note(note + " 行こう。") == note, "\(note)")
        }
        // A letter number in brackets refuses the direction even among words; in parentheses it doesn't.
        #expect(Self.parts("[〇で笑う] x") == nil)
        #expect(Self.note("(〇で笑う) x") == "(〇で笑う)")
    }

    // MARK: Brackets refuse digits of any script

    /// Metamorphic: a direction that is accepted stays accepted with any ideograph that counts added, and
    /// is refused once any scalar of category Nd, No or Nl is added anywhere inside it.
    @Test(arguments: [321, 322] as [UInt64])
    func oneNumberOfAnyScriptRefusesADirection(seed: UInt64) {
        var rng = Seeded(state: seed)
        let directions = ["[laughs]", "[soft tone]", "[一緒に笑う]", "[на ухо]", "[بهمس]", "[whisper, then shout]", "[aside (quietly)]"]
        let numbers = Array("0795٣३๓０²③½¼①⑳ⅳⅿ〇ᛮ𐍁".unicodeScalars)
        let counting = Array("一二十百千万".unicodeScalars)
        for round in 0..<400 {
            let direction = directions.randomElement(using: &rng)!
            #expect(Self.note(direction + " Hi.") == direction)
            var inner = Array(direction.unicodeScalars.dropFirst().dropLast())
            let at = Int.random(in: 0...inner.count, using: &rng)
            var withCounting = inner
            withCounting.insert(counting.randomElement(using: &rng)!, at: at)
            let counted = "[" + Sentences.string(withCounting) + "]"
            #expect(Self.note(counted + " Hi.") == counted, "seed \(seed) round \(round): \(counted)")
            let number = numbers.randomElement(using: &rng)!
            inner.insert(number, at: at)
            let refused = "[" + Sentences.string(inner) + "]"
            #expect(Self.parts(refused + " Hi.") == nil, "seed \(seed) round \(round): \(refused) (\(number.properties.generalCategory))")
        }
    }
}

import Foundation

/// Where sentences begin and end, by the rule the speech engine uses to apply delivery cues: a sentence
/// ends after . ! ? 。 ！ or ？ followed by whitespace, and after every newline. Expression notes are placed
/// with the same rule, so a note always opens the sentence the engine sees. Pieces never drop a scalar:
/// joined, they give back the text.
public enum Sentences {
    /// Python `str.isspace()` (regex `\s` for str patterns), which the original passage splitter used.
    public static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    static let ends: Set<UInt32> = [0x2E, 0x21, 0x3F, 0x3002, 0xFF01, 0xFF1F] // . ! ? 。 ！ ？

    /// `re.split(r'(?<=[.!?。！？])(?=\s)|(?<=\n)', text)`: split after sentence punctuation that is
    /// followed by whitespace, and after every newline.
    public static func split(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var pieces: [[Unicode.Scalar]] = []
        var start = 0
        var i = 1
        while i <= text.count {
            let previous = text[i - 1]
            let afterSentence = i < text.count && ends.contains(previous.value) && isSpace(text[i])
            if afterSentence || previous == "\n" {
                pieces.append(Array(text[start..<i])); start = i
            }
            i += 1
        }
        pieces.append(Array(text[start...]))
        return pieces
    }

    public static func split(_ text: String) -> [String] {
        split(Array(text.unicodeScalars)).map(string)
    }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var s = ""; s.unicodeScalars.append(contentsOf: scalars); return s
    }
}

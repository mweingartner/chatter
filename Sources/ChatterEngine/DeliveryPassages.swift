import Foundation
import ChatterCore

/// Unicode-safe text boundaries, with delivery annotations passed separately from spoken words.
public enum DeliveryPassages {
    public enum PassageError: LocalizedError, Equatable {
        case limitTooSmall
        case invalidCue
        public var errorDescription: String? {
            switch self {
            case .limitTooSmall: "Passage limit is too small"
            case .invalidCue: "Invalid internal delivery cue."
            }
        }
    }

    /// Python `str.isspace()` / regex `\s` for str patterns (shared with the app through `Sentences`).
    static func isPythonSpace(_ s: Unicode.Scalar) -> Bool { Sentences.isSpace(s) }

    /// `re.split(r'(?<=[.!?。！？])(?=\s)|(?<=\n)', text)`: split after sentence punctuation that is
    /// followed by whitespace, and after every newline. Never drops a scalar. The app places expression
    /// notes with the same rule.
    static func sentenceSplit(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] { Sentences.split(text) }

    @inline(__always) static func bytes(_ s: Unicode.Scalar) -> Int { UTF8.width(s) }
    static func bytes<C: Collection>(_ scalars: C) -> Int where C.Element == Unicode.Scalar { scalars.reduce(0) { $0 + UTF8.width($1) } }

    /// Bounds passages to `maxBytes` UTF-8 bytes (a split at a space may add that one space),
    /// preferring sentence and word boundaries. The concatenation always equals the input.
    public static func split(_ text: String, maxBytes: Int = 300) throws -> [String] {
        try split(Array(text.unicodeScalars), maxBytes: maxBytes).map(string)
    }

    static func split(_ text: [Unicode.Scalar], maxBytes: Int) throws -> [[Unicode.Scalar]] {
        guard maxBytes >= 32 else { throw PassageError.limitTooSmall }
        var parts: [[Unicode.Scalar]] = []
        for original in sentenceSplit(text) {
            var piece = original[...]
            while bytes(piece) > maxBytes {
                var n = 0, used = 0
                for c in piece {
                    let size = bytes(c)
                    if used + size > maxBytes { break }
                    used += size; n += 1
                }
                // rfind(' ', 0, n + 1)
                let searchEnd = min(n + 1, piece.count)
                var boundary = -1
                var index = searchEnd - 1
                while index >= 0 {
                    if piece[piece.startIndex + index] == " " { boundary = index; break }
                    index -= 1
                }
                if boundary > n / 3 { n = boundary + 1 }
                parts.append(Array(piece.prefix(n)))
                piece = piece.dropFirst(n)
            }
            if !piece.isEmpty { parts.append(Array(piece)) }
        }
        var grouped: [[Unicode.Scalar]] = []
        var pending: [Unicode.Scalar] = []
        for piece in parts {
            if !pending.isEmpty && bytes(pending) + bytes(piece) > maxBytes { grouped.append(pending); pending = [] }
            pending += piece
        }
        if !pending.isEmpty { grouped.append(pending) }
        return grouped
    }

    public struct Passage: Sendable, Equatable { public var text: String; public var instruction: String }
    public static func passages(_ text: String, maxBytes: Int = 300, instruction: String = "", supportsInstructions: Bool) throws -> [Passage] {
        var result: [Passage] = []
        for sentence in Sentences.split(Array(text.unicodeScalars)) {
            let note = LeadingNote.parts(of: sentence)
            let body = note.map { string(Array(sentence[$0.leading])) + string(Array(sentence[$0.body])) } ?? string(sentence)
            let local = note.map { String(string(Array(sentence[$0.note])).dropFirst().dropLast()) }
            for part in try split(body, maxBytes: maxBytes) where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Passage(text: part, instruction: supportsInstructions ? [instruction,local].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") : ""))
            }
        }
        return result
    }
    static func string(_ scalars: [Unicode.Scalar]) -> String { var s = ""; s.unicodeScalars.append(contentsOf: scalars); return s }
}

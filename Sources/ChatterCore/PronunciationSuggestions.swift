import Foundation

/// Draft "Say it as" spellings for a written form: a language model's respellings, checked like anything
/// typed into the panel, plus the letters spelled out for an all-caps initialism. They are suggestions to
/// preview and edit, never applied on their own; a model's phonetic knowledge is uneven.
public enum PronunciationSuggestions {
    public static let maxSuggestions = 4
    static let maxLength = 80

    public static let instructions = """
    You help a text-to-speech voice pronounce names and terms the way people actually say them. The voice reads ordinary \
    English spelling, so write how the term sounds using plain English letters: separate syllables with hyphens and write \
    the stressed syllable in capitals. Examples: Kubernetes -> koo-ber-NET-eez; Porsche -> PORSH-uh; Siobhan -> shih-VAWN. \
    For an initialism read letter by letter, write the letters with spaces: IBM -> I B M. For an acronym said as a word, \
    write the word: SQL -> sequel, NASA -> NASS-uh. Give one to three respellings, the most common pronunciation first. \
    Reply with JSON only.
    """

    public static func prompt(for written: String) -> String { "Term: \(written)" }

    /// `{"candidates": [{"sayAs": "koo-ber-NET-eez"}]}`, one to three of them.
    public static let schema: Data = {
        let item: [String: Any] = ["type": "object", "required": ["sayAs"], "properties": ["sayAs": ["type": "string"]]]
        let root: [String: Any] = ["type": "object", "required": ["candidates"],
                                   "properties": ["candidates": ["type": "array", "minItems": 1, "maxItems": 3, "items": item]]]
        return (try? JSONSerialization.data(withJSONObject: root, options: .sortedKeys)) ?? Data()
    }()

    /// The usable respellings in a reply, in order.
    public static func candidates(in reply: Data, for written: String) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let items = root["candidates"] as? [[String: Any]] else { return [] }
        return usable(items.compactMap { $0["sayAs"] as? String }, for: written)
    }

    /// Model respellings that pass the panel's own checks, plus the spelled-out letters for an initialism,
    /// without repeats (ignoring case) and never the written form itself.
    public static func usable(_ proposals: [String], for written: String) -> [String] {
        var result: [String] = []
        func add(_ proposal: String) {
            let spelling = PronunciationList.cleaned(proposal).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !spelling.isEmpty, spelling.count <= maxLength, result.count < maxSuggestions,
                  spelling.unicodeScalars.allSatisfy(isRespellingScalar),
                  spelling.caseInsensitiveCompare(PronunciationList.cleaned(written)) != .orderedSame,
                  !result.contains(where: { $0.caseInsensitiveCompare(spelling) == .orderedSame }),
                  (try? PronunciationList.validated(Pronunciation(written: written, sayAs: spelling, matchCase: false))) != nil else { return }
            result.append(spelling)
        }
        proposals.forEach(add)
        if let letters = spelledOut(written) { add(letters) }
        return result
    }

    /// Letters, marks and digits, spaces, hyphens and apostrophes: what a respelling is made of.
    static func isRespellingScalar(_ s: Unicode.Scalar) -> Bool {
        let category = s.properties.generalCategory
        return s.properties.isAlphabetic || category == .nonspacingMark || category == .spacingMark || category == .decimalNumber
            || s == " " || s == "-" || s == "'" || s == "\u{2019}"
    }

    /// "I B M" for "IBM" and "C I C D" for "CI/CD": two to eight capital letters (digits allowed, such as
    /// "S3") and no lowercase letters, spelled out one by one. Nil for anything else.
    public static func spelledOut(_ written: String) -> String? {
        let characters = PronunciationList.cleaned(written).filter { $0.isLetter || $0.isNumber }
        let letters = characters.filter(\.isLetter)
        guard (2...8).contains(letters.count), characters.count <= 10, letters.allSatisfy({ $0.isUppercase }),
              letters.allSatisfy({ $0.isASCII }) else { return nil }
        return characters.map(String.init).joined(separator: " ")
    }
}

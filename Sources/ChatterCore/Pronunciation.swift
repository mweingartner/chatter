import Foundation

/// How a written word, name or acronym should be said: wherever `written` appears as a whole word,
/// Chatter speaks `sayAs` instead (for example "Kubernetes" → "koo-ber-NET-eez", "SQL" → "sequel").
/// The speech model reads spelling directly (it has no phonetic input), so a respelling in plain
/// letters is how its pronunciation is steered.
public struct Pronunciation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var written: String
    public var sayAs: String
    /// Match only this exact capitalization (acronyms: "IT" must not change "it").
    public var matchCase: Bool

    public init(id: UUID = UUID(), written: String, sayAs: String, matchCase: Bool) {
        self.id = id; self.written = written; self.sayAs = sayAs; self.matchCase = matchCase
    }

    /// Acronyms and stylized names (two or more capitals, as in "IBM" or "iOS") usually need their
    /// exact capitalization matched; ordinary words should match however they are capitalized.
    public static func suggestsMatchCase(for written: String) -> Bool {
        written.unicodeScalars.filter { $0.properties.isUppercase }.count >= 2
    }

    /// Whether this entry and `other` would claim the same text, so only one of them may exist.
    func collides(with other: Pronunciation) -> Bool {
        matchCase && other.matchCase ? written == other.written : written.caseInsensitiveCompare(other.written) == .orderedSame
    }
}

/// The user's pronunciations, applied to text just before it is spoken. Receipts, captions and the
/// Studio keep the original spelling; only the words sent to the speech model change.
///
/// Respelling rules:
/// - whole words only: the character before and after a match is not a letter or digit, so "IBM's"
///   matches "IBM" but "SQLite" does not match "SQL";
/// - case-insensitive unless the entry matches case; always insensitive to Unicode composition;
/// - longer written forms win over shorter ones they overlap, matches never overlap, and a
///   replacement is never itself respelled.
public struct PronunciationList: Codable, Equatable, Sendable {
    public static let maxEntries = 1_000
    public static let maxWrittenLength = 100
    public static let maxSayAsLength = 200
    /// Respelled text may grow to this many UTF-8 bytes (twice the request limit), no further.
    public static let maxRespelledBytes = 200_000

    public private(set) var entries: [Pronunciation] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }

    /// A saved list is checked like typed entries: anything invalid means the file was damaged or edited by hand.
    public init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self).decode([Pronunciation].self, forKey: .entries)
        for entry in saved {
            // Upserting a repeated id would silently replace the earlier entry, losing it.
            guard !entries.contains(where: { $0.id == entry.id }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.entries], debugDescription: "“\(entry.written)”: another entry has the same id."))
            }
            do { try upsert(entry) } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.entries], debugDescription: "“\(entry.written)”: \(error.localizedDescription)"))
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Entries in the order the panel lists them.
    public var sorted: [Pronunciation] {
        entries.sorted { $0.written.localizedStandardCompare($1.written) == .orderedAscending }
    }

    // MARK: Respelling

    /// Respells whole words. Nothing inside `protecting` changes (the expression notes a review placed), and
    /// no match may overlap it.
    public func respell(_ text: String, protecting protected: [Range<String.Index>] = []) throws -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var claimed = [Bool](repeating: false, count: text.utf16.count)
        for range in protected {
            let lower = max(0, range.lowerBound.utf16Offset(in: text)), upper = min(claimed.count, range.upperBound.utf16Offset(in: text))
            if lower < upper { for offset in lower..<upper { claimed[offset] = true } }
        }
        var replacements: [(range: Range<String.Index>, sayAs: String)] = []
        // Longest first, so "Visual Studio Code" wins over "Visual Studio"; ties break by spelling
        // (and exact-case entries first) so the result never depends on insertion order.
        let byPriority = entries.sorted {
            ($0.written.count, $0.matchCase ? 1 : 0, $1.written) > ($1.written.count, $1.matchCase ? 1 : 0, $0.written)
        }
        let words = Self.lowercasedWords(in: text)
        for entry in byPriority {
            // A whole-word match starts where the text has the entry's leading word, so an entry whose
            // (ASCII) leading word never occurs cannot match: skip the search. Lists stay fast.
            if let lead = Self.leadingWord(of: entry.written), lead.allSatisfy(\.isASCII), !words.contains(lead.lowercased()) { continue }
            let options: String.CompareOptions = entry.matchCase ? [] : [.caseInsensitive]
            var from = text.startIndex
            while from < text.endIndex, let found = text.range(of: entry.written, options: options, range: from..<text.endIndex) {
                guard !found.isEmpty else { break }
                let lower = found.lowerBound.utf16Offset(in: text), upper = found.upperBound.utf16Offset(in: text)
                if Self.isWholeWord(found, in: text), !claimed[lower..<upper].contains(true) {
                    for offset in lower..<upper { claimed[offset] = true }
                    replacements.append((found, entry.sayAs))
                    from = found.upperBound
                } else {
                    from = text.index(after: found.lowerBound)
                }
            }
        }
        guard !replacements.isEmpty else { return text }
        // The size is known before anything is built, so a respelling can never allocate past the cap.
        let size = replacements.reduce(text.utf8.count) { $0 + $1.sayAs.utf8.count - text[$1.range].utf8.count }
        guard size <= Self.maxRespelledBytes else {
            throw ChatterError.invalid("With your pronunciations applied, this text is longer than 200,000 bytes. Split it into separate requests.")
        }
        var result = ""
        result.reserveCapacity(size)
        var cursor = text.startIndex
        for replacement in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += text[cursor..<replacement.range.lowerBound]
            result += replacement.sayAs
            cursor = replacement.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Every maximal run of letters and digits in `text`, lowercased, plus the case folding of any
    /// non-ASCII run: case-insensitive search treats "Straße" as "strasse" and "ﬁle" as "file", so the
    /// pre-filter must see those spellings too.
    static func lowercasedWords(in text: String) -> Set<String> {
        var words = Set<String>(), word = ""
        func finishWord() {
            words.insert(word.lowercased())
            if !word.allSatisfy(\.isASCII) { words.insert(word.folding(options: .caseInsensitive, locale: nil)) }
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber { word.append(character) } else if !word.isEmpty { finishWord() }
        }
        if !word.isEmpty { finishWord() }
        return words
    }

    /// The run of letters and digits a written form starts with ("Visual" for "Visual Studio",
    /// "AT" for "AT&T"); nil when it starts with punctuation (".NET").
    static func leadingWord(of written: String) -> String? {
        let lead = written.prefix { $0.isLetter || $0.isNumber }
        return lead.isEmpty ? nil : String(lead)
    }

    static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        if range.lowerBound > text.startIndex, isWordCharacter(text[text.index(before: range.lowerBound)]) { return false }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) { return false }
        return true
    }

    // MARK: Editing

    /// Adds `entry`, or replaces the entry with the same id. Fields are trimmed and validated; a
    /// written form another entry already covers is refused.
    @discardableResult
    public mutating func upsert(_ entry: Pronunciation) throws -> Pronunciation {
        let entry = try Self.validated(entry)
        if let clash = entries.first(where: { $0.id != entry.id && $0.collides(with: entry) }) {
            throw ChatterError.invalid("“\(clash.written)” already has a pronunciation. Edit that entry instead.")
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            guard entries.count < Self.maxEntries else { throw ChatterError.invalid("Chatter keeps up to 1,000 pronunciations. Remove some before adding more.") }
            entries.append(entry)
        }
        return entry
    }

    public mutating func remove(id: UUID) { entries.removeAll { $0.id == id } }

    /// The existing entry that already covers `written` (by the same rule `upsert` enforces), if any.
    public func entry(covering written: String, matchCase: Bool, excluding id: UUID? = nil) -> Pronunciation? {
        // Cleaned as `upsert` cleans it, so a pasted look-alike ("S\u{200B}QL") finds the entry it clashes with.
        let probe = Pronunciation(written: Self.cleaned(written), sayAs: "", matchCase: matchCase)
        return entries.first { $0.id != id && $0.collides(with: probe) }
    }

    static func validated(_ entry: Pronunciation) throws -> Pronunciation {
        var entry = entry
        entry.written = cleaned(entry.written)
        entry.sayAs = cleaned(entry.sayAs)
        func check(_ value: String, _ name: String, _ limit: Int) throws {
            guard value.contains(where: { $0.isLetter || $0.isNumber }) else { throw ChatterError.invalid("\(name) needs at least one letter or number.") }
            guard value.count <= limit else { throw ChatterError.invalid("\(name) can be at most \(limit) characters.") }
            // Unicode scalars and bytes too: one letter carrying thousands of combining marks is a single
            // character, and respelling and layout cost grow with its bytes.
            guard value.unicodeScalars.count <= limit * 4, value.utf8.count <= limit * 8 else {
                throw ChatterError.invalid("\(name) is too long. Accented and combined characters take extra room, so shorten it.")
            }
            guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator }) else {
                throw ChatterError.invalid("\(name) must be a single line.")
            }
        }
        try check(entry.written, "Written", maxWrittenLength)
        try check(entry.sayAs, "Say it as", maxSayAsLength)
        return entry
    }

    /// A field as it is stored: without invisible characters, which would make an entry look different
    /// from what it does or never match text that looks the same. Every format character and every
    /// default-ignorable code point goes (zero-width spaces, direction overrides, soft hyphens, byte-order
    /// marks, tags, Hangul fillers, variation selectors), then surrounding spaces. The joiners U+200C and
    /// U+200D stay inside a field, since Persian and Indic spellings and emoji sequences need them, but
    /// not at its edges, where they join nothing.
    static func cleaned(_ value: String) -> String {
        func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
            scalar != "\u{200C}" && scalar != "\u{200D}"
                && (scalar.properties.generalCategory == .format || scalar.properties.isDefaultIgnorableCodePoint)
        }
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: value.unicodeScalars.filter { !isInvisible($0) })
        return String(visible).trimmingCharacters(in: fieldEdges)
    }

    static let fieldEdges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{200C}\u{200D}"))

    // MARK: CSV

    static let csvHeader = ["written", "say_it_as", "match_case"]

    /// `written,say_it_as,match_case` with a header row (RFC 4180 quoting), sorted like the panel.
    public var csv: String {
        // Checked and escaped by Unicode scalar, as `parseCSV` reads them: a comma or quote carrying a
        // combining mark is a different Character but still the separator or quote in the file.
        func field(_ raw: String) -> String {
            // A cell starting with = + - @ would run as a formula if the file is opened in a spreadsheet.
            let value = Self.needsFormulaGuard(raw) ? "'" + raw : raw
            return value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\"" : value
        }
        return ([Self.csvHeader.joined(separator: ",")] + sorted.map { [field($0.written), field($0.sayAs), $0.matchCase ? "true" : "false"].joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }

    /// The entry a row without a match-case value updates: the same spelling, or else the only entry
    /// with the same spelling in any capitalization.
    static func entryToUpdate(for written: String, in list: PronunciationList) -> Pronunciation? {
        let written = written.trimmingCharacters(in: .whitespaces)
        if let exact = list.entries.first(where: { $0.written == written }) { return exact }
        let folded = list.entries.filter { $0.written.caseInsensitiveCompare(written) == .orderedSame }
        return folded.count == 1 ? folded[0] : nil
    }

    /// First characters a spreadsheet treats as the start of a formula.
    static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// Whether a cell starts with a formula character, possibly after apostrophes (so the guard
    /// round-trips values that already begin with one).
    static func needsFormulaGuard(_ cell: String) -> Bool {
        guard let first = cell.unicodeScalars.first(where: { $0 != "'" }) else { return false }
        return formulaStarts.contains(first)
    }

    /// Undoes the export's formula guard: one apostrophe in front of a guarded cell is dropped.
    static func unguarded(_ cell: String) -> String {
        guard cell.unicodeScalars.first == "'" else { return cell }
        let rest = String(cell.unicodeScalars.dropFirst())
        return needsFormulaGuard(rest) ? rest : cell
    }

    /// "written, say_it_as" in any capitalization or spacing ("Written, Say it as"). Cleaned like the
    /// data cells: a prepended format character (U+0600, U+08E2) would otherwise merge with the letter
    /// after it into one non-letter character and hide the header.
    static func isHeader(_ row: [String]) -> Bool {
        let names = row.prefix(2).map { cleaned($0).lowercased().filter { $0.isLetter } }
        return names == ["written", "sayitas"]
    }

    public struct ImportSummary: Equatable, Sendable {
        public var added = 0
        public var updated = 0
    }

    /// Merges a CSV of `written,say_it_as[,match_case]` rows (header optional). An imported row
    /// replaces the entry for the same written form. Nothing changes unless every row is valid.
    public mutating func importCSV(_ text: String) throws -> ImportSummary {
        guard text.utf8.count <= 1_000_000 else { throw ChatterError.invalid("That file is larger than 1 MB. Import a smaller list.") }
        var rows = try Self.parseCSV(text)
        if let first = rows.first, first.count >= 2, Self.isHeader(first) { rows.removeFirst() }
        guard rows.count <= Self.maxEntries else {
            throw ChatterError.invalid("That file lists more than 1,000 pronunciations, and Chatter keeps up to 1,000. Split it or remove some.")
        }
        var merged = self
        var summary = ImportSummary()
        for (index, row) in rows.enumerated() {
            let line = "Row \(index + 1)"
            guard row.count == 2 || row.count == 3 else { throw ChatterError.invalid("\(line): expected written, say it as, and optionally match case.") }
            let explicitMatchCase: Bool?
            if row.count == 3, !row[2].trimmingCharacters(in: .whitespaces).isEmpty {
                switch row[2].trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "1": explicitMatchCase = true
                case "false", "no", "0": explicitMatchCase = false
                default: throw ChatterError.invalid("\(line): match case must be true or false.")
                }
            } else {
                explicitMatchCase = nil
            }
            do {
                // Cleaned first, so a space after the comma or an invisible character never hides the guard.
                let written = Self.unguarded(Self.cleaned(row[0])), sayAs = Self.unguarded(Self.cleaned(row[1]))
                // Without a match-case value, a row naming an existing word updates that entry's respelling
                // and keeps its spelling and match case: an import never silently flips either.
                if explicitMatchCase == nil, var existing = Self.entryToUpdate(for: written, in: merged) {
                    existing.sayAs = sayAs
                    try merged.upsert(existing)
                    summary.updated += 1
                    continue
                }
                var entry = try Self.validated(Pronunciation(written: written, sayAs: sayAs,
                                                             matchCase: explicitMatchCase ?? Pronunciation.suggestsMatchCase(for: written)))
                if let existing = merged.entries.first(where: { $0.collides(with: entry) }) {
                    entry.id = existing.id
                    try merged.upsert(entry)
                    summary.updated += 1
                } else {
                    try merged.upsert(entry)
                    summary.added += 1
                }
            } catch {
                throw ChatterError.invalid("\(line): \(error.localizedDescription)")
            }
        }
        self = merged
        return summary
    }

    /// RFC 4180 fields: commas separate, double quotes wrap fields and escape as "", and CRLF or LF
    /// ends a row. A leading byte-order mark and blank rows are ignored.
    static func parseCSV(_ text: String) throws -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, atFieldStart = true, i = 0
        func endRow() {
            row.append(field); field = ""
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
            row = []; atFieldStart = true
        }
        while i < scalars.count {
            let scalar = scalars[i]; i += 1
            if quoted {
                if scalar == "\"" {
                    if i < scalars.count, scalars[i] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
                continue
            }
            switch scalar {
            case "\"" where atFieldStart: quoted = true; atFieldStart = false; field = ""   // spaces before an opening quote are dropped
            case ",": row.append(field); field = ""; atFieldStart = true
            case "\r": if i < scalars.count, scalars[i] == "\n" { i += 1 }; endRow()
            case "\n": endRow()
            default: field.unicodeScalars.append(scalar); if scalar != " " && scalar != "\t" { atFieldStart = false }
            }
        }
        guard !quoted else { throw ChatterError.invalid("The file ends inside a quoted field. Check its quotation marks.") }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

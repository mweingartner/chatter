import Foundation

/// An accent a voice description asks for. Qwen voice design cannot produce one, so Chatter
/// starts an accented voice from a speaker who has it: an installed macOS voice in the accent's
/// locale, or a recording the user provides. Cloning that speaker carries the accent.
public struct VoiceAccent: Sendable, Equatable, Identifiable {
    public let id: String
    /// How the accent is named in the interface, e.g. "Indian English".
    public let name: String
    /// BCP 47 languages of macOS voices that speak with it, matched by prefix ("en-IN").
    public let languages: [String]
    /// Lowercased words in a description that ask for it.
    let keywords: [String]
}

public enum VoiceAccents {
    /// English accents macOS voices carry. Others are still recognised as an accent request
    /// (`QwenCapabilities.describesAccent`) and offered the recording route only.
    public static let catalog: [VoiceAccent] = [
        VoiceAccent(id: "indian", name: "Indian English", languages: ["en-IN"],
                    keywords: ["indian", "india", "hindi", "desi", "delhi", "mumbai", "bombay", "bangalore", "bengaluru", "chennai", "kolkata", "punjabi", "tamil"]),
        VoiceAccent(id: "scottish", name: "Scottish English", languages: ["en-GB-u-sd-gbsct", "en-scotland"],
                    keywords: ["scottish", "scots", "scotland", "glasgow", "edinburgh"]),
        VoiceAccent(id: "irish", name: "Irish English", languages: ["en-IE"], keywords: ["irish", "ireland", "dublin"]),
        VoiceAccent(id: "british", name: "British English", languages: ["en-GB"],
                    keywords: ["british", "england", "london", "londoner", "cockney", "received pronunciation", "uk", "u.k.", "an english accent"]),
        VoiceAccent(id: "australian", name: "Australian English", languages: ["en-AU"], keywords: ["australian", "australia", "aussie", "sydney", "melbourne", "new south wales"]),
        VoiceAccent(id: "south-african", name: "South African English", languages: ["en-ZA"], keywords: ["south african", "south africa", "johannesburg", "cape town"]),
        VoiceAccent(id: "american", name: "American English", languages: ["en-US"], keywords: ["american", "usa", "u.s."]),
    ]

    /// The catalog accent a description asks for, if it asks for an accent at all: the first catalog
    /// entry whose keyword appears, with Scottish and Irish before British so their place names win.
    /// A variety counts as its adjective ("American English" as "American"); "an English accent"
    /// means British, while "a Canadian English accent" names no catalog accent. Place names that
    /// contain a keyword but name another accent ("West Indian", "New England") are ignored.
    public static func requested(in description: String) -> VoiceAccent? {
        guard QwenCapabilities.describesAccent(description) else { return nil }
        var text = misleading.stringByReplacingMatches(in: description, range: NSRange(description.startIndex..., in: description), withTemplate: " ")
        text = variety.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        return catalog.first { accent in matchers[accent.id].map { matches($0, text) } ?? false }
    }

    /// Whether a description names a variety such as "Indian English".
    static func namesVariety(_ description: String) -> Bool { matches(varieties, description) }

    // Compiled once: descriptions are checked on every keystroke. Matching with a shared
    // NSRegularExpression is thread-safe.
    nonisolated(unsafe) private static let varieties = alternation(catalog.map(\.name))
    nonisolated(unsafe) private static let matchers: [String: NSRegularExpression] =
        Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, alternation($0.keywords)) })
    /// Whitespace, hyphens and typographic dashes between the words of a variety or place name.
    private static let joiner = #"[\s\-\x{2010}-\x{2015}]+"#
    /// "Indian English" and the like, capturing the adjective.
    nonisolated(unsafe) private static let variety = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])("# + catalog.map { NSRegularExpression.escapedPattern(for: String($0.name.dropLast(" English".count))) }.joined(separator: "|") + #")"# + joiner + #"english(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive])
    /// Caribbean, Canadian, American and Northern Irish accents whose names contain a keyword.
    nonisolated(unsafe) private static let misleading = alternation([
        "west indian", "west indians", "american indian", "indian ocean", "native american", "central american",
        "south american", "latin american", "new england", "british columbia", "irish american", "ulster scots",
    ], hyphenated: true)

    /// Any of `phrases` as whole words, ignoring case; with `hyphenated`, their words may also be
    /// joined by hyphens or several spaces.
    private static func alternation(_ phrases: [String], hyphenated: Bool = false) -> NSRegularExpression {
        let body = phrases.map { phrase in
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return hyphenated ? escaped.replacingOccurrences(of: " ", with: joiner) : escaped
        }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + body + #")(?![\p{L}\p{N}])"#, options: [.caseInsensitive])
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A 20–30 second passage with varied sounds and an even pace, read by the macOS voice to
    /// become the new voice's reference recording (its exact transcript).
    public static let referencePassage = "Hello, and thank you for taking a moment to listen. I'd like to walk you through today's plan. First, we'll look at what changed since last week, and then we'll go over a few numbers together. Some of it is very good news, and some of it still needs a little more work. Either way, I'll keep things clear and simple, and we can talk about the next steps whenever you're ready."
}

public enum VoiceGender: String, Sendable, Equatable {
    case male, female

    /// The gender a description asks for, from its words; nil when it names neither or both.
    public static func requested(in description: String) -> VoiceGender? {
        let words = Set(description.lowercased().split { !$0.isLetter }.map(String.init))
        let male: Set = ["male", "man", "men", "boy", "gentleman", "he", "his", "him", "father", "grandfather", "husband", "son", "masculine", "baritone", "bass", "tenor"]
        let female: Set = ["female", "woman", "women", "girl", "lady", "she", "her", "hers", "mother", "grandmother", "wife", "daughter", "feminine", "soprano", "alto"]
        let isMale = !words.isDisjoint(with: male), isFemale = !words.isDisjoint(with: female)
        return isMale == isFemale ? nil : (isMale ? .male : .female)
    }
}

/// An installed macOS voice, as far as choosing one is concerned.
public struct SystemVoiceOption: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let language: String
    public let gender: VoiceGender?
    /// 0 default, 1 enhanced, 2 premium.
    public let quality: Int
    public let isNovelty: Bool

    public init(id: String, name: String, language: String, gender: VoiceGender?, quality: Int, isNovelty: Bool = false) {
        self.id = id; self.name = name; self.language = language; self.gender = gender; self.quality = quality; self.isNovelty = isNovelty
    }

    /// "Aman (enhanced)", for pickers.
    public var title: String {
        switch quality { case 2: "\(name) (premium)"; case 1: "\(name) (enhanced)"; default: name }
    }

    /// Voices that speak with `accent`, best first: the requested gender, then voices of no
    /// stated gender, then the other gender; within those, higher quality first. Novelty, MacinTalk
    /// and Eloquence voices (robotic by design) and super-compact voices (low-storage copies) are
    /// never offered; a voice listed twice appears once.
    public static func candidates(for accent: VoiceAccent, gender: VoiceGender?, among voices: [SystemVoiceOption]) -> [SystemVoiceOption] {
        var seen = Set<String>()
        let matching = voices.filter { voice in
            !voice.isNovelty && !voice.id.lowercased().contains(".eloquence.") && !voice.id.lowercased().contains("super-compact")
                && !voice.id.lowercased().hasPrefix("com.apple.speech.synthesis.voice.")
                && accent.languages.contains { voice.language.lowercased().hasPrefix($0.lowercased()) }
                && seen.insert(voice.id).inserted
        }
        // Scottish voices also start with en-GB: a British request must not offer them.
        let filtered = accent.id == "british" ? matching.filter { !$0.language.lowercased().contains("sct") } : matching
        func rank(_ voice: SystemVoiceOption) -> Int {
            guard let gender else { return 0 }
            return voice.gender == gender ? 0 : voice.gender == nil ? 1 : 2
        }
        return filtered.sorted {
            (rank($0), -$0.quality, $0.name, $0.id) < (rank($1), -$1.quality, $1.name, $1.id)
        }
    }
}

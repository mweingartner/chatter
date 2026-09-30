import Foundation

/// An expression review: a language model reads the text and chooses a note, or none, for each sentence.
/// The model never rewrites anything. It answers with sentence numbers and notes from the catalog (the
/// reply is constrained to a JSON schema and checked again here), and Chatter places the notes.
public enum ExpressionReview {
    /// How long a review may take before speech starts. Live speech waits for it, so its budget is short;
    /// sentences not reached in time are spoken without notes.
    public static let liveBudget: Duration = .seconds(8)
    public static let savedBudget: Duration = .seconds(90)

    /// Whether a job gets a review. The user's Expression settings decide: Studio passes its own switch
    /// as `studioChoice`; HTTP and MCP requests pass nil and follow `forRequests`. Pronunciation previews
    /// (`respell` false) speak their text exactly.
    public static func isWanted(respell: Bool, studioChoice: Bool?, forRequests: Bool) -> Bool {
        respell && (studioChoice ?? forRequests)
    }

    public struct Outcome: Equatable, Sendable {
        /// Why the review ended.
        public enum Stop: Equatable, Sendable { case finished, outOfTime, cancelled, failed(String) }
        public var plan: ExpressionPlan
        /// Sentences with words, and how many of them the model reviewed.
        public var reviewed: Int
        public var total: Int
        public var stop: Stop
        public init(plan: ExpressionPlan = ExpressionPlan(), reviewed: Int = 0, total: Int = 0, stop: Stop = .finished) {
            self.plan = plan; self.reviewed = reviewed; self.total = total; self.stop = stop
        }

        /// For the receipt of speech this review directed: why notes are missing or partial.
        public var message: String? {
            switch stop {
            case .finished: nil
            case .cancelled: "The review was cancelled."
            case .outOfTime: reviewed == 0 ? "Spoken without expression notes: the review did not finish in the time available."
                : "Notes cover the first \(reviewed) of \(total) sentences; the rest did not fit in the time available."
            case .failed(let reason): reviewed == 0 ? "Spoken without expression notes. \(reason)"
                : "Notes cover the first \(reviewed) of \(total) sentences; the review then failed. \(reason)"
            }
        }

        /// For text the notes are added to before anything is spoken (Studio's Add notes now).
        public var editorMessage: String? {
            switch stop {
            case .finished: nil
            case .cancelled: "Stopped. No notes were added."
            case .outOfTime: reviewed == 0 ? "No notes were added: the model did not finish in time."
                : "Notes were added to the first \(reviewed) of \(total) sentences; the rest did not fit in the time available."
            case .failed(let reason): reviewed == 0 ? "No notes were added. \(reason)"
                : "Notes were added to the first \(reviewed) of \(total) sentences; the model then failed. \(reason)"
            }
        }
    }

    // MARK: Prompt

    public static func instructions(tone: SpeechTone) -> String {
        let catalog = ExpressionNote.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        let baseline = tone == .natural ? "" :
            " The speaker’s overall delivery is already \(tone.title.lowercased()); add a note only where a sentence calls for a different or stronger feeling."
        return """
        You direct a voice actor who reads text aloud. You receive numbered sentences. For each sentence that carries a clear \
        feeling or calls for a special delivery, choose the one note from this list that best tells the actor how to say it:
        \(catalog)
        Judge each sentence in the context of the ones around it. Leave out neutral, factual sentences. Never add a note the \
        words do not support.\(baseline) Reply with JSON only.
        """
    }

    /// The sentences, numbered from 1.
    public static func prompt(_ sentences: [String]) -> String {
        sentences.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// `{"notes": [{"sentence": 1, "note": "excited"}]}`, with the note limited to the catalog.
    public static let schema: Data = {
        let item: [String: Any] = ["type": "object", "required": ["sentence", "note"],
                                   "properties": ["sentence": ["type": "integer"],
                                                  "note": ["type": "string", "enum": ExpressionNote.allCases.map(\.rawValue)]]]
        let root: [String: Any] = ["type": "object", "required": ["notes"], "properties": ["notes": ["type": "array", "items": item]]]
        return (try? JSONSerialization.data(withJSONObject: root, options: .sortedKeys)) ?? Data()
    }()

    /// The notes in a reply, by sentence number (1-based). Numbers outside `1...count`, unknown notes and
    /// repeats are dropped; an unreadable reply means no notes.
    public static func notes(in reply: Data, count: Int) -> [Int: ExpressionNote] {
        guard let root = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let items = root["notes"] as? [[String: Any]] else { return [:] }
        var result: [Int: ExpressionNote] = [:]
        for item in items {
            // JSON true bridges to 1, so a boolean is refused before it is read as a number.
            guard let value = item["sentence"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
                  let number = value as? Int, (1...max(count, 1)).contains(number), count > 0,
                  let raw = item["note"] as? String, let note = ExpressionNote(rawValue: raw), result[number] == nil else { continue }
            result[number] = note
        }
        return result
    }

    // MARK: Review

    /// Groups the sentences worth reviewing (those with a letter or digit) into requests of at most
    /// `maxSentences` sentences and about `maxCharacters` characters, in order, by sentence index.
    public static func windows(_ sentences: [String], maxSentences: Int = 24, maxCharacters: Int = 2_400) -> [[Int]] {
        var windows: [[Int]] = [], current: [Int] = [], size = 0
        for (index, sentence) in sentences.enumerated() where sentence.unicodeScalars.contains(where: ExpressionPlan.isWordScalar) {
            let length = sentence.count
            if !current.isEmpty, current.count >= maxSentences || size + length > maxCharacters { windows.append(current); current = []; size = 0 }
            current.append(index); size += length
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }

    /// Reviews `text` window by window until the budget runs out, the task is cancelled or the model fails.
    /// `reviewWindow` receives the window's sentences (trimmed, numbered from 1 in the prompt) and the time
    /// left, and returns notes by sentence number. What was reviewed before a failure is kept.
    public static func run(_ text: String, budget: Duration, clock: ContinuousClock = ContinuousClock(),
                           reviewWindow: @Sendable ([String], Duration) async throws -> [Int: ExpressionNote]) async -> Outcome {
        let deadline = clock.now + budget
        let sentences = Sentences.split(text)
        let windows = windows(sentences)
        let total = windows.reduce(0) { $0 + $1.count }
        var notes: [ExpressionPlan.Note] = [], reviewed = 0
        func outcome(_ stop: Outcome.Stop) -> Outcome { Outcome(plan: ExpressionPlan(notes: notes), reviewed: reviewed, total: total, stop: stop) }
        for window in windows {
            let left = deadline - clock.now
            if Task.isCancelled { return outcome(.cancelled) }
            guard left > .milliseconds(250) else { return outcome(.outOfTime) }
            let batch = window.map { sentences[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            do {
                // Numbers outside the window are ignored, whoever produced them.
                for (number, note) in try await reviewWindow(batch, left) where (1...window.count).contains(number) {
                    notes.append(.init(sentence: window[number - 1], note: note))
                }
                reviewed += window.count
            } catch is CancellationError {
                return outcome(.cancelled)
            } catch OllamaError.timedOut {
                return outcome(.outOfTime)
            } catch {
                return outcome(.failed(error.localizedDescription))
            }
        }
        return outcome(.finished)
    }
}

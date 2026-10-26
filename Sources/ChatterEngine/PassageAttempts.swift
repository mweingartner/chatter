import Qwen3Speech

/// Qwen sometimes never ends a passage: it loops in near-silence until the frame budget runs out.
/// Measured 2026-10-25 on the 0.6B Base model at Chatter's sampling settings, with references trimmed
/// for conditioning: 0 to 9 % of passages by recorded voice, most often for a one-word sentence.
/// Another draw from the job's seeded generator almost always finishes it, so each passage gets a few
/// attempts and a job stays reproducible for its seed. (The model's published temperature 0.9 and
/// top-p 1.0 run on less often but about double the word errors, so Chatter keeps its settings.)
enum PassageAttempts {
    static let limit = 3

    /// Runs `generate` until it returns. Only running out of frames is retried, with `retrying` called
    /// before each further attempt; any other error, cancellation included, ends at once.
    static func run<T>(passage: Int, of count: Int, limit: Int = limit, retrying: () -> Void, _ generate: () throws -> T) throws -> T {
        precondition(limit >= 1)
        var attempt = 1
        while true {
            do { return try generate() }
            catch AudioGenerationError.frameBudgetReached where attempt < limit { retrying(); attempt += 1 }
            catch AudioGenerationError.frameBudgetReached {
                throw EngineFailure.failed("The voice did not finish passage \(passage) of \(count) in \(limit) attempts. Try rewording that sentence.")
            }
        }
    }
}

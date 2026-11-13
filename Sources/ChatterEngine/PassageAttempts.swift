import Qwen3Speech

/// Qwen sometimes fails a passage in a way another draw does not: it never ends (it loops in
/// near-silence until the frame budget runs out), never starts, or goes quiet partway through.
/// Measured 2026-11-12 with the reference encoder and decoder corrected: the 0.6B Base model ran on
/// for 1 to 4 % of JARVIS's passages and the 1.7B model for none of 192; one "Yes." took eight
/// seconds to start. Each passage therefore gets a few attempts. Every attempt draws from its own
/// seed, derived from the passage, so a job is reproducible and the same sentence is always spoken
/// the same way.
enum PassageAttempts {
    static let limit = 3

    /// Why an attempt cannot be used as it is.
    enum Fault: Error, Equatable {
        /// The frame budget ran out before the model ended the passage.
        case neverEnded
        /// No speech within `PassageWatch.latestStart`.
        case neverSpoke
        /// The voice went quiet with too little said, or paused for too long.
        case stalled
    }

    /// Runs `generate` with attempt numbers from 0 until it returns. Only a `Fault` (or running out
    /// of frames) is retried, with `retrying` called before each further attempt; any other error,
    /// cancellation included, ends at once. When every attempt has failed, `fallback` may supply the
    /// best imperfect result; otherwise the job fails.
    static func run<T>(passage: Int, of count: Int, limit: Int = limit, retrying: (Fault) -> Void,
                       fallback: () -> T? = { nil }, _ generate: (_ attempt: Int) throws -> T) throws -> T {
        precondition(limit >= 1)
        var attempt = 0
        while true {
            let fault: Fault
            do { return try generate(attempt) }
            catch AudioGenerationError.frameBudgetReached { fault = .neverEnded }
            catch let known as Fault { fault = known }
            attempt += 1
            guard attempt < limit else {
                if let usable = fallback() { return usable }
                throw EngineFailure.failed("The voice did not finish passage \(passage) of \(count) in \(limit) attempts. Try rewording that sentence.")
            }
            retrying(fault)
        }
    }
}

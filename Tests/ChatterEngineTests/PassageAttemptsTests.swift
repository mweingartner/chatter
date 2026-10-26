import Foundation
import Testing
@testable import ChatterEngine
import Qwen3Speech

/// A passage that runs out of frames is generated again, up to `PassageAttempts.limit` times; every
/// other outcome, success or failure, is final on the attempt that produced it.
struct PassageAttemptsTests {
    /// Fails with `failure` for the first `failures` attempts, then returns the attempt number.
    final class Script {
        let failures: Int, failure: Error
        private(set) var attempts = 0
        init(failures: Int, failure: Error = AudioGenerationError.frameBudgetReached) { self.failures = failures; self.failure = failure }
        func generate() throws -> Int {
            attempts += 1
            if attempts <= failures { throw failure }
            return attempts
        }
    }

    @Test func aPassageThatEndsIsGeneratedOnce() throws {
        let script = Script(failures: 0)
        var retries = 0
        #expect(try PassageAttempts.run(passage: 1, of: 1, retrying: { retries += 1 }, script.generate) == 1)
        #expect(script.attempts == 1 && retries == 0)
    }

    @Test(arguments: [1, 2])
    func aRunawayIsGeneratedAgainUntilItEnds(failures: Int) throws {
        let script = Script(failures: failures)
        var retries = 0
        #expect(try PassageAttempts.run(passage: 2, of: 3, retrying: { retries += 1 }, script.generate) == failures + 1)
        #expect(script.attempts == failures + 1)
        #expect(retries == failures, "one notice before each further attempt")
    }

    @Test func aPassageThatNeverEndsFailsTheJobAfterTheLimit() {
        let script = Script(failures: .max)
        var retries = 0
        #expect(PassageAttempts.limit == 3)
        do {
            _ = try PassageAttempts.run(passage: 2, of: 5, retrying: { retries += 1 }, script.generate)
            Issue.record("a passage that never ends must fail")
        } catch EngineFailure.failed(let message) {
            #expect(message == "The voice did not finish passage 2 of 5 in 3 attempts. Try rewording that sentence.")
        } catch { Issue.record("unexpected \(error)") }
        #expect(script.attempts == 3 && retries == 2)
    }

    @Test(arguments: [1, 2, 5])
    func theLimitIsExact(limit: Int) {
        let script = Script(failures: .max)
        #expect(throws: EngineFailure.self) { try PassageAttempts.run(passage: 1, of: 1, limit: limit, retrying: {}, script.generate) }
        #expect(script.attempts == limit)
    }

    /// Cancellation, invalid audio and every other generation error are final: retrying them would only
    /// delay the failure or ignore the user.
    @Test(arguments: [
        EngineFailure.cancelled as Error, CancellationError(), EngineFailure.failed("Model produced invalid audio."),
        AudioGenerationError.generationFailed("x"), AudioGenerationError.modelNotInitialized("Qwen produced no audio."),
    ])
    func otherErrorsAreNeverRetried(error: Error) {
        let script = Script(failures: 1, failure: error)
        var retries = 0
        #expect(throws: (any Error).self) { try PassageAttempts.run(passage: 1, of: 1, retrying: { retries += 1 }, script.generate) }
        #expect(script.attempts == 1 && retries == 0)
    }

    /// A cancellation that arrives on a retry still ends the passage at once.
    @Test func cancellationDuringARetryIsFinal() {
        var attempts = 0
        #expect(throws: EngineFailure.self) {
            try PassageAttempts.run(passage: 1, of: 1, retrying: {}) { () throws -> Int in
                attempts += 1
                if attempts == 1 { throw AudioGenerationError.frameBudgetReached }
                throw EngineFailure.cancelled
            }
        }
        #expect(attempts == 2)
    }

    /// Each notice comes after the attempt that ran out and before the next one, never after the last.
    @Test func noticesFallBetweenAttempts() {
        var events: [String] = []
        #expect(throws: EngineFailure.self) {
            try PassageAttempts.run(passage: 1, of: 1, retrying: { events.append("notice") }) { () throws -> Int in
                events.append("attempt")
                throw AudioGenerationError.frameBudgetReached
            }
        }
        #expect(events == ["attempt", "notice", "attempt", "notice", "attempt"])
    }

    /// SynthesisJob's shape: a streamed run-on that has already spoken is caught inside the attempt and
    /// returns nil, which ends the passage at once; one that has not spoken propagates and is tried
    /// again. A nil result is a result, not a failure.
    @Test(arguments: [[false, true], [true], [false, false, true]])
    func aRunOnThatHasSpokenEndsThePassage(spoken: [Bool]) throws {
        var attempt = 0, retries = 0
        let result: Int? = try PassageAttempts.run(passage: 1, of: 1, retrying: { retries += 1 }) { () throws -> Int? in
            let heard = spoken[attempt]
            attempt += 1
            do { throw AudioGenerationError.frameBudgetReached }
            catch AudioGenerationError.frameBudgetReached where heard { return nil }
        }
        #expect(result == nil)
        #expect(attempt == spoken.count && retries == spoken.count - 1)
    }

    /// A result from a later attempt is that attempt's own, not an earlier one's.
    @Test func theFinishingAttemptsResultIsReturned() throws {
        var attempt = 0
        let result = try PassageAttempts.run(passage: 3, of: 3, retrying: {}) { () throws -> [Float] in
            attempt += 1
            if attempt < 3 { throw AudioGenerationError.frameBudgetReached }
            return [Float(attempt)]
        }
        #expect(result == [3])
    }

    /// The budget error reads as a sentence the user can act on, not as an uninitialized model.
    @Test func theBudgetErrorDescribesWhatHappened() {
        #expect(AudioGenerationError.frameBudgetReached.localizedDescription == "Generation reached its frame budget without finishing the sentence. Try shorter passages.")
    }
}

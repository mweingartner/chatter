import ChatterCore
import Foundation
import Testing
@testable import ChatterEngine
import Qwen3Speech

/// A passage that never ends, never starts or goes quiet partway is generated again, up to
/// `PassageAttempts.limit` times; every other outcome, success or failure, is final on the attempt
/// that produced it.
struct PassageAttemptsTests {
    /// Fails with `failure` for the first `failures` attempts, then returns the attempt number.
    final class Script {
        let failures: Int, failure: Error
        private(set) var attempts = 0
        private(set) var numbers: [Int] = []
        init(failures: Int, failure: Error = AudioGenerationError.frameBudgetReached) { self.failures = failures; self.failure = failure }
        func generate(_ attempt: Int) throws -> Int {
            attempts += 1
            numbers.append(attempt)
            if attempts <= failures { throw failure }
            return attempts
        }
    }

    @Test func aPassageThatEndsIsGeneratedOnce() throws {
        let script = Script(failures: 0)
        var retries = 0
        #expect(try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in retries += 1 }, script.generate) == 1)
        #expect(script.attempts == 1 && retries == 0)
    }

    @Test(arguments: [1, 2])
    func aRunawayIsGeneratedAgainUntilItEnds(failures: Int) throws {
        let script = Script(failures: failures)
        var retries = 0
        #expect(try PassageAttempts.run(passage: 2, of: 3, retrying: { _ in retries += 1 }, script.generate) == failures + 1)
        #expect(script.attempts == failures + 1)
        #expect(retries == failures, "one notice before each further attempt")
    }

    /// Attempts are numbered from zero, so each can draw from its own seed.
    @Test func attemptsAreNumberedFromZero() throws {
        let script = Script(failures: 2)
        _ = try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in }, script.generate)
        #expect(script.numbers == [0, 1, 2])
    }

    @Test func aPassageThatNeverEndsFailsTheJobAfterTheLimit() {
        let script = Script(failures: .max)
        var retries = 0
        #expect(PassageAttempts.limit == 3)
        do {
            _ = try PassageAttempts.run(passage: 2, of: 5, retrying: { _ in retries += 1 }, script.generate)
            Issue.record("a passage that never ends must fail")
        } catch EngineFailure.failed(let message) {
            #expect(message == "The voice did not finish passage 2 of 5 in 3 attempts. Try rewording that sentence.")
        } catch { Issue.record("unexpected \(error)") }
        #expect(script.attempts == 3 && retries == 2)
    }

    @Test(arguments: [1, 2, 5])
    func theLimitIsExact(limit: Int) {
        let script = Script(failures: .max)
        #expect(throws: EngineFailure.self) { try PassageAttempts.run(passage: 1, of: 1, limit: limit, retrying: { _ in }, script.generate) }
        #expect(script.attempts == limit)
    }

    /// Every fault is retried, and the notice names the fault of the attempt before it.
    @Test(arguments: [PassageAttempts.Fault.neverEnded, .neverSpoke, .stalled])
    func everyFaultIsRetried(fault: PassageAttempts.Fault) throws {
        let script = Script(failures: 2, failure: fault)
        var seen: [PassageAttempts.Fault] = []
        #expect(try PassageAttempts.run(passage: 1, of: 1, retrying: { seen.append($0) }, script.generate) == 3)
        #expect(seen == [fault, fault])
    }

    @Test func runningOutOfFramesIsReportedAsNeverEnding() throws {
        let script = Script(failures: 1)
        var seen: [PassageAttempts.Fault] = []
        _ = try PassageAttempts.run(passage: 1, of: 1, retrying: { seen.append($0) }, script.generate)
        #expect(seen == [.neverEnded])
    }

    /// When no attempt is good, an imperfect one that did finish is better than failing the job.
    @Test func anImperfectResultIsUsedWhenNoAttemptIsGood() throws {
        let script = Script(failures: .max, failure: PassageAttempts.Fault.stalled)
        var retries = 0
        let result = try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in retries += 1 }, fallback: { -1 }, script.generate)
        #expect(result == -1)
        #expect(script.attempts == 3 && retries == 2, "the fallback is used only after every attempt")
    }

    @Test func aGoodAttemptIsPreferredToTheFallback() throws {
        let script = Script(failures: 1, failure: PassageAttempts.Fault.stalled)
        #expect(try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in }, fallback: { -1 }, script.generate) == 2)
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
        #expect(throws: (any Error).self) { try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in retries += 1 }, fallback: { -1 }, script.generate) }
        #expect(script.attempts == 1 && retries == 0)
    }

    /// A cancellation that arrives on a retry still ends the passage at once.
    @Test func cancellationDuringARetryIsFinal() {
        var attempts = 0
        #expect(throws: EngineFailure.self) {
            try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in }) { _ throws -> Int in
                attempts += 1
                if attempts == 1 { throw AudioGenerationError.frameBudgetReached }
                throw EngineFailure.cancelled
            }
        }
        #expect(attempts == 2)
    }

    /// Each notice comes after the attempt that failed and before the next one, never after the last.
    @Test func noticesFallBetweenAttempts() {
        var events: [String] = []
        #expect(throws: EngineFailure.self) {
            try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in events.append("notice") }) { _ throws -> Int in
                events.append("attempt")
                throw AudioGenerationError.frameBudgetReached
            }
        }
        #expect(events == ["attempt", "notice", "attempt", "notice", "attempt"])
    }

    /// SynthesisJob's shape: a streamed run-on that has already been heard is caught inside the attempt
    /// and returns, which ends the passage at once; one that has not been heard propagates and is tried
    /// again.
    @Test(arguments: [[false, true], [true], [false, false, true]])
    func aRunOnThatHasBeenHeardEndsThePassage(spoken: [Bool]) throws {
        var retries = 0
        let result: Int? = try PassageAttempts.run(passage: 1, of: 1, retrying: { _ in retries += 1 }) { attempt throws -> Int? in
            let heard = spoken[attempt]
            do { throw AudioGenerationError.frameBudgetReached }
            catch AudioGenerationError.frameBudgetReached where heard { return nil }
        }
        #expect(result == nil)
        #expect(retries == spoken.count - 1)
    }

    /// A result from a later attempt is that attempt's own, not an earlier one's.
    @Test func theFinishingAttemptsResultIsReturned() throws {
        let result = try PassageAttempts.run(passage: 3, of: 3, retrying: { _ in }) { attempt throws -> [Float] in
            if attempt < 2 { throw AudioGenerationError.frameBudgetReached }
            return [Float(attempt)]
        }
        #expect(result == [2])
    }

    /// The budget error reads as a sentence the user can act on, not as an uninitialized model.
    @Test func theBudgetErrorDescribesWhatHappened() {
        #expect(AudioGenerationError.frameBudgetReached.localizedDescription == "Generation reached its frame budget without finishing the sentence. Try shorter passages.")
    }
}

/// A voice says a sentence the same way every time, and differently from any other sentence or voice.
struct PassageSeedTests {
    let reference = EngineReference(reference: "/voices/a/reference.wav", transcript: "Hello there.")

    @Test func theSameVoiceAndSentenceAlwaysGiveTheSameSeed() {
        let voice = QwenVoiceConfiguration()
        let base = PassageSeed.voice(voice, references: [reference], profile: "quality", language: "Auto")
        #expect(base == PassageSeed.voice(voice, references: [reference], profile: "quality", language: "Auto"))
        #expect(PassageSeed.passage(base: base, text: "The gate is open.", prompt: "", attempt: 0)
            == PassageSeed.passage(base: base, text: "The gate is open.", prompt: "", attempt: 0))
    }

    @Test func anythingThatChangesTheSpeechChangesTheSeed() {
        let voice = QwenVoiceConfiguration()
        let base = PassageSeed.voice(voice, references: [reference], profile: "quality", language: "Auto")
        var others: Set<UInt64> = [base]
        others.insert(PassageSeed.voice(voice, references: [reference], profile: "fast", language: "Auto"))
        others.insert(PassageSeed.voice(voice, references: [reference], profile: "quality", language: "English"))
        others.insert(PassageSeed.voice(voice, references: [EngineReference(reference: "/voices/b/reference.wav", transcript: "Hello there.")], profile: "quality", language: "Auto"))
        others.insert(PassageSeed.voice(voice, references: [EngineReference(reference: "/voices/a/reference.wav", transcript: "Hello, there.")], profile: "quality", language: "Auto"))
        others.insert(PassageSeed.voice(QwenVoiceConfiguration(kind: .preset, speaker: "Ryan"), references: [], profile: "custom", language: "Auto"))
        others.insert(PassageSeed.voice(QwenVoiceConfiguration(kind: .preset, speaker: "Aiden"), references: [], profile: "custom", language: "Auto"))
        #expect(others.count == 7)

        var passages: Set<UInt64> = []
        passages.insert(PassageSeed.passage(base: base, text: "The gate is open.", prompt: "", attempt: 0))
        passages.insert(PassageSeed.passage(base: base, text: "The gate is open.", prompt: "", attempt: 1))
        passages.insert(PassageSeed.passage(base: base, text: "The gate is open", prompt: "", attempt: 0))
        passages.insert(PassageSeed.passage(base: base, text: "The gate is open.", prompt: "Speak warmly", attempt: 0))
        passages.insert(PassageSeed.passage(base: base &+ 1, text: "The gate is open.", prompt: "", attempt: 0))
        #expect(passages.count == 5)
    }

    /// Parts are length-prefixed: moving a character from one part to the next is a different seed.
    @Test func partsDoNotRunTogether() {
        #expect(PassageSeed.passage(base: 1, text: "ab", prompt: "c", attempt: 0) != PassageSeed.passage(base: 1, text: "a", prompt: "bc", attempt: 0))
        #expect(PassageSeed.passage(base: 1, text: "a", prompt: "", attempt: 10) != PassageSeed.passage(base: 11, text: "a", prompt: "", attempt: 0))
    }
}

/// Only passages with something to say reach the model.
struct SpeakablePassageTests {
    @Test(arguments: ["Yes.", "7", "a", "OK!", "¿Qué?", "你好。", "こんにちは", "٣", "Ⅷ", "x²", "…and then"])
    func textWithALetterOrDigitIsSpoken(text: String) { #expect(SynthesisJob.isSpeakable(text)) }

    @Test(arguments: ["", " ", "...", "…", "—", "?!", "(–)", "*** ---", "👍", "🙂🙂", "\n\t"])
    func textWithoutOneIsNot(text: String) { #expect(!SynthesisJob.isSpeakable(text)) }

    @Test func everyFaultHasAPlainDescription() {
        #expect(SynthesisJob.described(.neverEnded) == "did not finish")
        #expect(SynthesisJob.described(.neverSpoke) == "did not start")
        #expect(SynthesisJob.described(.stalled) == "went quiet partway")
    }
}

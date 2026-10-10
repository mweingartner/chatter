import ChatterCore
import Darwin
import Foundation
import Testing

/// The render sweep as the app runs it (`trimHistory`): `JobDatabase.renderedAudio` finds finished
/// render receipts that still name audio, archived or not; `AudioStorage.removeExpiredRenders` removes
/// the expired ones; the receipt's path is cleared through `save`, which must leave an archived
/// receipt archived. `AudioStorage.offersAudio` is the read-time backstop between sweeps.
struct RenderSweepTests {
    /// A scratch database and Jobs folder. Receipts get increasing sequence numbers in creation order,
    /// and their audio is dated relative to `base`, so tests move time by passing `now`.
    final class Store {
        let root: URL
        let database: JobDatabase
        var jobs: URL { root.appending(path: "Jobs") }
        let base = Date()
        private(set) var sequence: UInt64 = 0

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "render-sweep-\(UUID().uuidString)")
            database = try JobDatabase(root: root)
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// Saves a receipt. `writtenAgo` nil means no audio file (a path is still recorded when
        /// `path` is true); otherwise `speech.wav` is written and dated `writtenAgo` seconds before `base`.
        @discardableResult
        func receipt(_ mode: String = "render", state: String = "completed", text: String = "Hi.",
                     writtenAgo: TimeInterval? = nil, path: Bool = true, sequence explicit: UInt64? = nil,
                     createdAgo: TimeInterval = 0) throws -> SpeechJob {
            var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: text, mode: mode), voiceName: "Scar")
            if let explicit { job.sequence = explicit; sequence = max(sequence, explicit) } else { sequence += 1; job.sequence = sequence }
            job.state = state
            job.createdAt = base.addingTimeInterval(-createdAgo)
            let audio = jobs.appending(path: "\(job.id)/speech.wav")
            if let writtenAgo { try Self.write(audio, modified: base.addingTimeInterval(-writtenAgo)) }
            if path { job.path = audio.path }
            try database.save(job)
            return job
        }

        static func write(_ audio: URL, modified: Date) throws {
            try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: audio)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: audio.path)
        }

        /// What `trimHistory` does before retention: sweep, then clear each expired receipt's path.
        @discardableResult
        func sweep(now: Date? = nil) throws -> [String] {
            let renders = try database.renderedAudio()
            let expired = try AudioStorage.removeExpiredRenders(renders, jobs: jobs, now: now ?? base)
            for id in expired {
                guard var receipt = renders.first(where: { $0.id == id }) else { continue }
                receipt.path = nil
                try database.save(receipt)
            }
            return expired
        }
    }

    // MARK: renderedAudio: order, limit and filter

    /// Oldest first by sequence (not by insertion order), only finished renders with a path, the
    /// limit taken from the front, and a limit below one still returns one.
    @Test func renderedAudioIsOldestFirstAndHonoursItsLimit() throws {
        let store = try Store()
        var renders: [(UInt64, String)] = []
        // Inserted out of order: sequence, not row order, decides.
        for sequence in [7, 2, 9, 4, 1, 10, 3] as [UInt64] {
            renders.append((sequence, try store.receipt(writtenAgo: 5, sequence: sequence * 10).id))
            // Interleaved receipts that never qualify.
            try store.receipt("play", writtenAgo: 5, sequence: sequence * 10 + 1)
            try store.receipt("save", sequence: sequence * 10 + 2)
            try store.receipt("render", state: "generating", writtenAgo: 5, sequence: sequence * 10 + 3)
            try store.receipt("render", writtenAgo: 5, path: false, sequence: sequence * 10 + 4)
        }
        let ordered = renders.sorted { $0.0 < $1.0 }.map(\.1)
        #expect(try store.database.renderedAudio().map(\.id) == ordered)
        #expect(try store.database.renderedAudio(limit: 3).map(\.id) == Array(ordered.prefix(3)))
        #expect(try store.database.renderedAudio(limit: ordered.count).map(\.id) == ordered)
        #expect(try store.database.renderedAudio(limit: 10_000).map(\.id) == ordered)
        for tiny in [1, 0, -1, Int.min] {
            #expect(try store.database.renderedAudio(limit: tiny).map(\.id) == [ordered[0]], "limit \(tiny)")
        }
        // Archiving changes nothing about what the sweep sees.
        try store.database.archiveFinished()
        #expect(try store.database.renderedAudio().map(\.id) == ordered)
        // Every terminal state with a path is a candidate; the sweep decides what expires.
        let failed = try store.receipt(state: "failed", writtenAgo: 5)
        let cancelled = try store.receipt(state: "cancelled", writtenAgo: nil)
        #expect(try store.database.renderedAudio().map(\.id).suffix(2) == [failed.id, cancelled.id])
        #expect(try store.database.renderedAudio().allSatisfy { $0.request.mode == "render" && $0.path != nil && $0.isTerminal })
    }

    /// Receipts whose text, voice name, message or warnings spell `"mode":"render"` and `"path":` are
    /// never returned, and (since JSON escapes their quotes) never even reach the decoder: hundreds of
    /// them older than one real render cannot push it out of a limit of one.
    @Test func textThatSpellsTheModeNeverComesBackOrTakesASlot() throws {
        let store = try Store()
        let spellings = [
            #""mode":"render""#, #"{"mode":"render","path":"/tmp/x.wav"}"#, #"\"mode\":\"render\""#,
            #"\\"mode\\":\\"render\\""#, #""mode" : "render""#, #""MODE":"RENDER""#, #"%"mode":"render"%_"#,
            "\u{22}mode\u{22}:\u{22}render\u{22} \u{201C}path\u{201D}:", #""path":"#,
        ]
        for index in 0..<300 {
            let words = spellings[index % spellings.count]
            var job = SpeechJob(request: SpeechRequest(voice: "Scar", text: "Say \(words) aloud.", mode: ["play", "save"][index % 2]),
                                voiceName: words)
            job.sequence = UInt64(index + 1); job.state = "completed"; job.message = words; job.warnings = [words]
            job.path = store.jobs.appending(path: "\(job.id)/speech.wav").path
            try store.database.save(job)
        }
        // A render without a path whose text names a path, and an unfinished render: neither qualifies.
        var pathless = SpeechJob(request: SpeechRequest(voice: "Scar", text: #""path":"/x""#, mode: "render"), voiceName: "Scar")
        pathless.sequence = 301; pathless.state = "completed"
        try store.database.save(pathless)
        try store.receipt(state: "generating", writtenAgo: 5, sequence: 302)
        // The real render is the newest receipt, and its own text spells another mode.
        let real = try store.receipt(text: #"{"mode":"play"} "mode":"save""#, writtenAgo: 5, sequence: 303)
        #expect(try store.database.renderedAudio(limit: 1).map(\.id) == [real.id])
        #expect(try store.database.renderedAudio().map(\.id) == [real.id])
        try store.database.archiveFinished()
        #expect(try store.database.renderedAudio(limit: 1).map(\.id) == [real.id])
        // A sweep long after touches only the real render.
        #expect(try store.sweep(now: store.base.addingTimeInterval(SpeechMode.renderRetention * 10)) == [real.id])
        #expect(try store.database.renderedAudio().isEmpty)
        #expect(try store.database.recent().isEmpty || store.database.recent().allSatisfy { !$0.isTerminal })
    }

    /// A mode spelled in another case is not render (validation refuses it, but a receipt written by
    /// hand or an old build might hold one): the decoded filter drops it even though SQL's LIKE is
    /// case-insensitive, and its audio is never swept.
    @Test func aModeInAnotherCaseIsNotARender() throws {
        let store = try Store()
        let upper = try store.receipt("RENDER", writtenAgo: SpeechMode.renderRetention * 2)
        let title = try store.receipt("Render", writtenAgo: SpeechMode.renderRetention * 2)
        let real = try store.receipt(writtenAgo: SpeechMode.renderRetention * 2)
        #expect(try store.database.renderedAudio().map(\.id) == [real.id])
        #expect(try store.sweep() == [real.id])
        for kept in [upper, title] { #expect(FileManager.default.fileExists(atPath: kept.path!)) }
    }

    /// Large receipts: one page stops at the 16 MB read budget (always returning at least one, oldest
    /// first), and repeated sweeps still drain every expired render, page by page.
    @Test func theReadBudgetPagesLargeReceiptsWithoutStarvingTheSweep() throws {
        let store = try Store()
        let text = String(repeating: "a", count: 6_000_000)
        let big = try (0..<3).map { _ in try store.receipt(text: text, writtenAgo: SpeechMode.renderRetention + 60) }
        #expect(try store.database.renderedAudio().map(\.id) == [big[0].id, big[1].id])
        #expect(try store.database.renderedAudio(limit: 1).map(\.id) == [big[0].id])
        #expect(try store.sweep() == [big[0].id, big[1].id])
        #expect(try store.database.renderedAudio().map(\.id) == [big[2].id])
        #expect(try store.sweep() == [big[2].id])
        #expect(try store.database.renderedAudio().isEmpty)
        for receipt in big { #expect(try store.database.find(id: receipt.id)?.path == nil) }
    }

    /// Load: 1,000 renders, audio written in sequence order as the engine does (so the expired ones are
    /// the oldest). A page is the default 200, oldest first; four sweeps drain all 800 expired ones, the
    /// following ones find nothing, fresh renders are never touched, and a page stays fast.
    ///
    /// (Pages are taken before the age check, so 200 un-expired renders older than an expired one would
    /// hold the sweep until they expire, at most `renderRetention` later. Audio is written in sequence
    /// order, so that does not arise in practice.)
    @Test func manyRendersDrainInBoundedPages() throws {
        let store = try Store()
        var expired: [String] = [], fresh: [String] = []
        for index in 0..<1_000 {
            let old = index < 800
            let job = try store.receipt(writtenAgo: old ? SpeechMode.renderRetention + 1_000 - Double(index) : 1)
            if old { expired.append(job.id) } else { fresh.append(job.id) }
        }
        try store.database.archiveFinished()
        var timings: [Duration] = []
        for _ in 0..<5 {
            let clock = ContinuousClock()
            timings.append(try clock.measure { _ = try store.database.renderedAudio() })
        }
        let median = timings.sorted()[timings.count / 2]
        #expect(median < .milliseconds(500), "renderedAudio median \(median)")
        #expect(try store.database.renderedAudio().count == 200)

        var swept: [String] = []
        for pass in 0..<6 {
            let ids = try store.sweep()
            if pass >= 4 { #expect(ids.isEmpty, "pass \(pass)") } else { #expect(ids.count == 200, "pass \(pass)") }
            swept += ids
        }
        #expect(swept == expired)  // oldest first, each exactly once
        #expect(try store.database.renderedAudio().map(\.id) == fresh)
        for id in fresh { #expect(FileManager.default.fileExists(atPath: store.jobs.appending(path: "\(id)/speech.wav").path)) }
        #expect(try store.database.recent().isEmpty)  // all archived, and they stayed archived
    }

    // MARK: With retention: expired() and remove()

    /// The sweep and retention work on the same receipts without stepping on each other: retention
    /// still finds a swept receipt (by age or count, archived or not), removing it ends it for the
    /// sweep too, and a receipt removed before the sweep is simply gone.
    @Test func sweepAndRetentionShareReceipts() throws {
        let store = try Store()
        let oldDay = try store.receipt(writtenAgo: SpeechMode.renderRetention * 2, createdAgo: 10 * 86_400)
        let removedFirst = try store.receipt(writtenAgo: SpeechMode.renderRetention * 2)
        let fresh = try store.receipt(writtenAgo: 1)
        let running = try store.receipt(state: "generating", writtenAgo: SpeechMode.renderRetention * 2)
        try store.database.archiveFinished()

        // Retention removes one receipt before any sweep: the sweep never sees it again.
        try store.database.remove(id: removedFirst.id)
        #expect(try store.database.renderedAudio().map(\.id) == [oldDay.id, fresh.id])

        // The sweep clears the old render's path; retention by age still finds it, path and all cleared.
        #expect(try store.sweep() == [oldDay.id])
        let byAge = try store.database.expired(days: 7, keep: 1_000, now: store.base)
        #expect(byAge.map(\.id) == [oldDay.id] && byAge.first?.path == nil)
        // Sweeping kept `created`: a swept receipt does not look new to retention.
        #expect(try store.database.expired(days: 7, keep: 1_000, now: store.base.addingTimeInterval(-86_400 * 2)).map(\.id) == [oldDay.id])
        try store.database.remove(id: oldDay.id)
        #expect(try store.database.find(id: oldDay.id) == nil)

        // Retention by count reaches archived receipts too, and never the running render.
        #expect(try store.database.expired(days: 3650, keep: 1, now: store.base).map(\.id).isEmpty)
        let older = try store.receipt(writtenAgo: 1, sequence: 0)
        #expect(try store.database.expired(days: 3650, keep: 1, now: store.base).map(\.id) == [older.id])
        try store.database.remove(id: running.id)  // refused: not terminal
        #expect(try store.database.find(id: running.id)?.state == "generating")
        #expect(try store.database.recent().map(\.id).contains(running.id))
        #expect(try store.database.renderedAudio().map(\.id) == [older.id, fresh.id])
    }

    // MARK: offersAudio: the shapes a path can take

    /// The path is a symlink: its own time decides, never its target's, so an old link to fresh audio
    /// is not offered. (Serving opens with O_NOFOLLOW, so a link is never sent either way.)
    @Test func aSymlinkedPathIsJudgedByTheLinkNotItsTarget() throws {
        let store = try Store()
        let target = store.root.appending(path: "fresh.wav")
        try Store.write(target, modified: Date())
        var job = try store.receipt(writtenAgo: nil, path: false)
        let link = store.jobs.appending(path: "\(job.id)/speech.wav")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var times = [timeval(tv_sec: time(nil) - 86_400, tv_usec: 0), timeval(tv_sec: time(nil) - 86_400, tv_usec: 0)]
        #expect(lutimes(link.path, &times) == 0)
        job.path = link.path
        #expect(!AudioStorage.offersAudio(job))
        // The sweep agrees, and removes the link without touching the target.
        #expect(try AudioStorage.removeExpiredRenders([job], jobs: store.jobs) == [job.id])
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!AudioStorage.offersAudio(job))
    }

    /// A directory where the audio should be is judged by the same clock as the sweep uses: an old
    /// one is not offered and is swept.
    @Test func aDirectoryAtThePathFollowsTheSweepsClock() throws {
        let store = try Store()
        var job = try store.receipt(writtenAgo: nil)
        let audio = try #require(job.path)
        try FileManager.default.createDirectory(atPath: audio, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: audio)
        #expect(!AudioStorage.offersAudio(job))
        #expect(try AudioStorage.removeExpiredRenders([job], jobs: store.jobs) == [job.id])
        job.path = nil
        #expect(!AudioStorage.offersAudio(job))
    }

    /// Audio dated in the future (the clock moved back) is offered, as the sweep keeps it; at exactly
    /// the window it is not; a moment before, it is. Judged against the time the file system stored.
    @Test(arguments: [-86_400.0, -3_600, -1, 0, 1, 599, 599.999, 600, 600.001, 601, 86_400])
    func offeringAgreesWithTheSweepAtEveryAge(age: Double) throws {
        let store = try Store()
        let job = try store.receipt(writtenAgo: 0)
        let audio = try #require(job.path)
        let stored = try #require(try FileManager.default.attributesOfItem(atPath: audio)[.modificationDate] as? Date)
        let now = stored.addingTimeInterval(age)
        let offered = AudioStorage.offersAudio(job, now: now)
        #expect(offered == (age < SpeechMode.renderRetention), "age \(age)")
        let swept = try AudioStorage.removeExpiredRenders([job], jobs: store.jobs, now: now)
        #expect(swept.isEmpty == offered, "age \(age): the sweep and the offer disagree")
    }

    /// Only a completed job offers audio, whatever its mode; render needs its file too.
    @Test(arguments: ["failed", "cancelled", "queued", "generating", "Completed", ""])
    func onlyACompletedJobOffersAudio(state: String) throws {
        let store = try Store()
        for mode in ["play", "save", "render"] {
            var job = try store.receipt(mode, writtenAgo: 1)
            job.state = state
            #expect(!AudioStorage.offersAudio(job), "\(mode) \(state)")
            job.state = "completed"
            #expect(AudioStorage.offersAudio(job), "\(mode)")
        }
    }

    // MARK: Property: archived stays archived

    /// Seeded random histories of receipts (any mode and state, audio of any age or none), archiving,
    /// jobs finishing, time passing and sweeps. After every step: no archived receipt is in `recent()`;
    /// `renderedAudio()` is exactly the model's finished renders with a path, oldest first; a swept
    /// receipt never returns to `renderedAudio()` and never offers audio; and nothing unfinished is lost.
    @Test(arguments: UInt64(0)..<30)
    func sweptArchivedReceiptsNeverReturn(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        let store = try Store()
        struct Model { var job: SpeechJob; var archived = false; var swept = false }
        var model: [String: Model] = [:]
        var now = store.base
        let modes = ["play", "save", "render", "render", "render"]
        let states = ["completed", "completed", "failed", "cancelled", "queued", "generating"]
        func check(_ step: Int, _ operation: String) throws {
            let label = Comment(rawValue: "seed \(seed) step \(step) after \(operation)")
            let recent = Set(try store.database.recent().map(\.id))
            for entry in model.values {
                if entry.archived { #expect(!recent.contains(entry.job.id), label) }
                if !entry.job.isTerminal || !entry.archived { #expect(recent.contains(entry.job.id), label) }
            }
            let expected = model.values
                .filter { $0.job.isTerminal && $0.job.request.mode == "render" && $0.job.path != nil }
                .sorted { $0.job.sequence < $1.job.sequence }.map(\.job.id)
            let rendered = try store.database.renderedAudio(limit: 1_000).map(\.id)
            #expect(rendered == expected, label)
            for entry in model.values where entry.swept {
                #expect(!rendered.contains(entry.job.id), label)
                #expect(!AudioStorage.offersAudio(try #require(try store.database.find(id: entry.job.id)), now: now), label)
            }
        }
        for step in 0..<Int.random(in: 10...40, using: &rng) {
            let operation: String
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                let state = states.randomElement(using: &rng)!
                let age: Double? = Int.random(in: 0..<5, using: &rng) == 0 ? nil
                    : [-30, 0, 30, 590, 600, 900, 86_400].randomElement(using: &rng)!
                let job = try store.receipt(modes.randomElement(using: &rng)!, state: state, writtenAgo: age,
                                            path: Int.random(in: 0..<6, using: &rng) > 0)
                model[job.id] = Model(job: job)
                operation = "add \(job.request.mode) \(state)"
            case 4:
                try store.database.archiveFinished()
                for (id, entry) in model where entry.job.isTerminal { model[id]?.archived = true }
                operation = "archive"
            case 5:
                // An unfinished job finishes (and is saved, as the app does): it is not archived.
                guard let id = model.values.filter({ !$0.job.isTerminal }).map(\.job.id).sorted().first else { continue }
                model[id]?.job.state = "completed"
                try store.database.save(model[id]!.job)
                operation = "finish"
            case 6:
                now = now.addingTimeInterval(Double(Int.random(in: 0...700, using: &rng)))
                operation = "time passes"
            default:
                for id in try store.sweep(now: now) {
                    model[id]?.job.path = nil
                    model[id]?.swept = true
                }
                operation = "sweep"
            }
            try check(step, operation)
        }
        // Finally, long after everything: every finished render is swept, and the archived ones stay archived.
        for id in try store.sweep(now: now.addingTimeInterval(86_400 * 2)) { model[id]?.job.path = nil; model[id]?.swept = true }
        try check(-1, "final sweep")
        #expect(try store.database.renderedAudio().isEmpty, "seed \(seed)")
    }
}

// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation
import os

/// Incrementally writes a mono 24-bit PCM WAV identical to `AudioIO.writePCM24` for the same samples.
///
/// Audio is written to `<name>.partial`; `finish()` patches the RIFF/data sizes and atomically renames
/// it to the destination, `cancel()` deletes it. Thread-safe: every call is serialized by a lock, so a
/// writer may be shared between tasks and used from any actor.
public final class WAVStreamWriter: Sendable {
    private enum Phase { case open(FileHandle), finished, cancelled }
    private struct State { var phase: Phase; var frames: Int }

    /// The final destination, which exists only after `finish()` succeeds.
    public let url: URL
    /// The in-progress file (`url` + `.partial`).
    public let partialURL: URL
    private let sampleRate: UInt32
    private let state: OSAllocatedUnfairLock<State>

    /// Creates `<url>.partial` (replacing a stale one) with a provisional header.
    public init(url: URL, sampleRate: Double = 44100) throws {
        let rate = try PCM24.headerRate(sampleRate)
        let partialURL = URL(filePath: url.path(percentEncoded: false) + ".partial")
        let header = Data(PCM24.header(sampleRate: rate, dataBytes: 0))
        guard FileManager.default.createFile(atPath: partialURL.path(percentEncoded: false), contents: header) else {
            throw ChatterAudioError.writeFailed(reason: "Cannot create \(partialURL.lastPathComponent).")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
        } catch {
            AtomicFile.discard(partialURL)
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        self.url = url
        self.partialURL = partialURL
        self.sampleRate = rate
        self.state = OSAllocatedUnfairLock(uncheckedState: State(phase: .open(handle), frames: 0))
    }

    deinit {
        // An abandoned writer must not leave a partial file behind.
        cancel()
    }

    /// Number of samples appended so far.
    public var frameCount: Int { state.withLockUnchecked { $0.frames } }

    /// Encodes and appends samples. Throws on NaN samples, I/O failure, or after finish/cancel.
    public func append(_ samples: [Float]) throws {
        try state.withLockUnchecked { state in
            guard case .open(let handle) = state.phase else {
                throw ChatterAudioError.writeFailed(reason: "The audio file is already closed.")
            }
            _ = try PCM24.dataSize(frames: state.frames + samples.count)
            var bytes: [UInt8] = []
            try PCM24.encode(samples, into: &bytes)
            do {
                try handle.write(contentsOf: bytes)
            } catch {
                throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
            }
            state.frames += samples.count
        }
    }

    /// Patches the header sizes, adds the RIFF pad byte when needed, and atomically moves the file
    /// to `url`. On failure the partial file is removed.
    public func finish() throws {
        try state.withLockUnchecked { state in
            guard case .open(let handle) = state.phase else {
                throw ChatterAudioError.writeFailed(reason: "The audio file is already closed.")
            }
            state.phase = .finished
            do {
                let dataBytes = try PCM24.dataSize(frames: state.frames)
                if dataBytes % 2 == 1 { try handle.write(contentsOf: [UInt8(0)]) }
                let header = PCM24.header(sampleRate: sampleRate, dataBytes: dataBytes)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: header)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()  // Already failing; the write error below is what matters.
                AtomicFile.discard(partialURL)
                if let failure = error as? ChatterAudioError { throw failure }
                throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
            }
            try AtomicFile.rename(partialURL, to: url)
        }
    }

    /// Stops writing and deletes the partial file. Safe to call repeatedly; no effect after `finish()`.
    public func cancel() {
        state.withLockUnchecked { state in
            guard case .open(let handle) = state.phase else { return }
            state.phase = .cancelled
            do {
                try handle.close()
            } catch {
                AtomicFile.logger.error("Cannot close \(self.partialURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            AtomicFile.discard(partialURL)
        }
    }
}

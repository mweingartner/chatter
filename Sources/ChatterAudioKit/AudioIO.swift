// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import AVFoundation
import Foundation
import ChatterCore
import os

/// Decoding, resampling and 24-bit WAV writing for Chatter's 44.1 kHz mono pipeline.
public enum AudioIO {
    /// The sample rate of every recording Chatter processes.
    public static let sampleRate: Double = 44100

    private static let readChunkFrames: AVAudioFrameCount = 65536
    /// How far a codec's declared `length` may exceed the frames it actually decodes.
    private static let lengthSlackFrames: AVAudioFramePosition = 8192

    /// Decodes any AVFoundation-readable file (WAV, MP3, M4A, AAC, FLAC, AIFF, CAF, Ogg/Vorbis,
    /// Ogg/Opus) to 44.1 kHz mono float samples.
    ///
    /// Channels are downmixed by their arithmetic mean (numpy `a.mean(axis=1)`); other rates are
    /// converted with AVAudioConverter's mastering-quality resampler, drained to end of stream.
    public static func readMono44k(_ url: URL) throws -> [Float] { try readMono(url, sampleRate: 44100) }

    public static func readMono(_ url: URL, sampleRate: Double, maximumSeconds: Double = 7200) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ChatterAudioError.undecodable(reason: "The file \(url.lastPathComponent) does not exist.")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ChatterAudioError.undecodable(reason: error.localizedDescription)
        }
        let format = file.processingFormat
        guard maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 7200,
              format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate),
              sampleRate.isFinite, (8000...192000).contains(sampleRate),
              file.length >= 0, Double(file.length) <= maximumSeconds * format.sampleRate else {
            throw ChatterAudioError.unsupportedDuration
        }
        let channels = Int(format.channelCount)
        guard (1...8).contains(channels), format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkFrames) else {
            throw ChatterAudioError.undecodable(reason: "Unsupported audio layout.")
        }
        var mono: [Float] = []
        mono.reserveCapacity(Int(clamping: max(0, file.length)))
        // A single read(into:) can return fewer frames than requested, so read until `length`.
        // Reading at end of file fails, and the error varies by host process (eofErr, or no
        // NSError at all), so never read past `length`. Ogg/Vorbis overstates `length` by up to a
        // packet: a failure within `lengthSlackFrames` of the end is the end of the stream, while
        // any earlier failure is a real decoding error.
        while file.framePosition < file.length {
            do {
                try file.read(into: chunk, frameCount: readChunkFrames)
            } catch where file.length - file.framePosition <= lengthSlackFrames {
                break
            } catch {
                throw ChatterAudioError.undecodable(reason: error.localizedDescription)
            }
            let frames = Int(chunk.frameLength)
            if frames == 0 { break }
            guard let data = chunk.floatChannelData else {
                throw ChatterAudioError.undecodable(reason: "Unsupported audio layout.")
            }
            guard mono.count + frames <= Int(maximumSeconds * format.sampleRate) else { throw ChatterAudioError.unsupportedDuration }
            try appendDownmix(data, channels: channels, frames: frames, to: &mono)
        }
        guard !mono.isEmpty else { throw ChatterAudioError.emptyOrInvalidSamples }
        guard format.sampleRate != sampleRate else { return mono }
        return try resample(mono, from: format.sampleRate, to: sampleRate)
    }

    /// Duration in seconds of an audio file, from its frame count and file sample rate.
    public static func duration(of url: URL) throws -> Double {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.fileFormat.sampleRate
        } catch {
            throw ChatterAudioError.undecodable(reason: error.localizedDescription)
        }
    }

    /// Writes mono 24-bit little-endian PCM WAV, bit-exact with `soundfile.write(..., subtype='PCM_24')`.
    ///
    /// Out-of-range samples are clipped to [−8388608, 8388607]; NaN samples are rejected. The file is
    /// written to a temporary file in the destination directory and atomically renamed into place.
    public static func writePCM24(_ samples: [Float], sampleRate: Double = 44100, to url: URL) throws {
        let rate = try PCM24.headerRate(sampleRate)
        let dataBytes = try PCM24.dataSize(frames: samples.count)
        var bytes = PCM24.header(sampleRate: rate, dataBytes: dataBytes)
        try PCM24.encode(samples, into: &bytes)
        if dataBytes % 2 == 1 { bytes.append(0) }
        try AtomicFile.write(Data(bytes), to: url)
    }

    /// Appends the channel mean of `frames` deinterleaved frames, rejecting non-finite input.
    private static func appendDownmix(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int,
                                      frames: Int, to mono: inout [Float]) throws {
        for channel in 0..<channels {
            let samples = UnsafeBufferPointer(start: data[channel], count: frames)
            guard samples.allSatisfy(\.isFinite) else { throw ChatterAudioError.emptyOrInvalidSamples }
        }
        if channels == 1 {
            mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            return
        }
        let divisor = Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += data[channel][frame] }
            mono.append(sum / divisor)
        }
    }

    /// Resamples mono audio to 44.1 kHz. The result has scipy `resample_poly`'s length,
    /// `ceil(n · 44100 / rate)`; AVAudioConverter's normal priming keeps it time-aligned.
    public static func resample(_ samples: [Float], from inputRate: Double, to sampleRate: Double = 44100) throws -> [Float] {
        guard inputRate.isFinite, inputRate > 0,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
            throw ChatterAudioError.resamplingFailed(reason: "Unsupported sample rate \(inputRate).")
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let expected = Int((Double(samples.count) * sampleRate / inputRate).rounded(.up))
        let feeder = ConverterFeeder(samples: samples, format: inputFormat)
        var result: [Float] = []
        result.reserveCapacity(expected + 8192)
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                feeder.next(requested, status: inputStatus)
            }
            if let failure = feeder.failure { throw ChatterAudioError.resamplingFailed(reason: failure) }
            if status == .error {
                throw ChatterAudioError.resamplingFailed(reason: conversionError?.localizedDescription ?? "Unknown converter error.")
            }
            if output.frameLength > 0, let data = output.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .inputRanDry && output.frameLength == 0 {
                throw ChatterAudioError.resamplingFailed(reason: "The converter stopped before the end of the recording.")
            }
        }
        // The drained converter yields scipy's length (verified for 48 kHz and 22.05 kHz); a small
        // discrepancy from filter rounding is squared off, anything larger is a real failure.
        guard abs(result.count - expected) <= 64 else {
            throw ChatterAudioError.resamplingFailed(reason: "Expected \(expected) frames but produced \(result.count).")
        }
        if result.count > expected {
            result.removeLast(result.count - expected)
        } else if result.count < expected {
            result.append(contentsOf: repeatElement(0, count: expected - result.count))
        }
        return result
    }
}

/// Supplies an AVAudioConverter with consecutive slices of a mono signal, then end of stream.
/// Used only synchronously inside `AVAudioConverter.convert`, on the calling thread.
private final class ConverterFeeder: @unchecked Sendable {
    private let samples: [Float]
    private let format: AVAudioFormat
    private var position = 0
    private(set) var failure: String?

    init(samples: [Float], format: AVAudioFormat) {
        self.samples = samples
        self.format = format
    }

    func next(_ requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = samples.count - position
        guard remaining > 0 else {
            status.pointee = .endOfStream
            return nil
        }
        // Never hand over an empty buffer with .haveData: the converter treats it as end of stream.
        let count = min(max(Int(requested), 1), remaining, 1 << 20)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.floatChannelData?[0] else {
            failure = "Cannot allocate an audio buffer."
            status.pointee = .endOfStream
            return nil
        }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base + position, count: count)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        position += count
        status.pointee = .haveData
        return buffer
    }
}

/// Atomic file replacement: write a temporary file in the destination directory, then rename.
enum AtomicFile {
    /// A unique temporary URL beside `url`, keeping its extension so AVFoundation infers the file type.
    static func temporaryURL(beside url: URL) -> URL {
        let pathExtension = url.pathExtension.isEmpty ? "tmp" : url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).\(pathExtension)")
    }

    /// Atomically writes `data` to `url`.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = temporaryURL(beside: url)
        do {
            try PrivateStorage.write(data, to: temporary)
        } catch {
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        try rename(temporary, to: url)
    }

    /// Atomically moves `source` over `destination` (POSIX rename), removing `source` on failure.
    static func rename(_ source: URL, to destination: URL) throws {
        guard Foundation.rename(source.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
            let reason = String(cString: strerror(errno))
            discard(source)
            throw ChatterAudioError.writeFailed(reason: "Cannot move audio into place: \(reason).")
        }
    }

    /// Best-effort cleanup of a temporary or partial file; failures other than "missing" are logged.
    static func discard(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("Cannot remove \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static let logger = Logger(subsystem: "ChatterAudioKit", category: "Files")

    /// Copies `source` byte-for-byte over `destination` via a temporary file and atomic rename.
    static func copy(_ source: URL, to destination: URL) throws {
        let temporary = temporaryURL(beside: destination)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try PrivateStorage.protectFile(temporary)
        } catch {
            throw ChatterAudioError.writeFailed(reason: error.localizedDescription)
        }
        try rename(temporary, to: destination)
    }
}

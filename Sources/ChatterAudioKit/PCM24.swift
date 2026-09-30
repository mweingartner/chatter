// Native audio services for Chatter (AVFoundation, Accelerate, Speech).
import Foundation

/// 24-bit mono PCM WAV encoding, bit-exact with libsndfile (`soundfile.write(..., subtype='PCM_24')`).
///
/// libsndfile's float→PCM_24 rule (its clipping path, `f2let_clip_array`):
/// `scaled = x · 2³¹`; `scaled ≥ 2³¹−1` → `0x7FFFFFFF`; `scaled ≤ −2³¹` → `0x80000000`;
/// otherwise `lrint(scaled)` (round half to even); the stored 24-bit sample is `value >> 8`
/// (arithmetic shift, i.e. floor). So `1.0 → 8388607`, `−1.0 → −8388608`, `0.5 → 4194304`,
/// `−1e−9 → −1`. The header is libsndfile's 44-byte `WAVE_FORMAT_PCM` layout and an odd-sized data
/// chunk is followed by one zero pad byte (counted in the RIFF size, not the data size).
enum PCM24 {
    static let headerSize = 44
    static let bytesPerSample = 3

    /// Converts one float sample to a 24-bit integer exactly as libsndfile does. NaN is rejected.
    static func quantize(_ sample: Float) throws(ChatterAudioError) -> Int32 {
        guard !sample.isNaN else { throw .writeFailed(reason: "The audio contains NaN samples.") }
        let scaled = Double(sample) * 2_147_483_648.0
        let value: Int64
        if scaled >= 2_147_483_647.0 {
            value = 0x7FFF_FFFF
        } else if scaled <= -2_147_483_648.0 {
            value = -0x8000_0000
        } else {
            value = Int64(scaled.rounded(.toNearestOrEven))
        }
        return Int32(truncatingIfNeeded: value >> 8)
    }

    /// Appends little-endian 24-bit samples to `bytes`.
    static func encode(_ samples: [Float], into bytes: inout [UInt8]) throws(ChatterAudioError) {
        bytes.reserveCapacity(bytes.count + samples.count * bytesPerSample)
        for sample in samples {
            let value = try quantize(sample)
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        }
    }

    /// Validates and converts a sample rate for the WAV header.
    static func headerRate(_ sampleRate: Double) throws(ChatterAudioError) -> UInt32 {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= 768_000, sampleRate.rounded() == sampleRate else {
            throw .writeFailed(reason: "Unsupported sample rate \(sampleRate).")
        }
        return UInt32(sampleRate)
    }

    /// Validates that `frames` mono 24-bit samples fit in a RIFF file and returns the data size in bytes.
    static func dataSize(frames: Int) throws(ChatterAudioError) -> UInt32 {
        let bytes = frames * bytesPerSample
        guard frames >= 0, bytes + headerSize + 1 <= Int(UInt32.max) else {
            throw .writeFailed(reason: "The recording is too long for a WAV file.")
        }
        return UInt32(bytes)
    }

    /// The 44-byte RIFF/WAVE header for mono 24-bit PCM with `dataBytes` of sample data.
    static func header(sampleRate: UInt32, dataBytes: UInt32) -> [UInt8] {
        let padding: UInt32 = dataBytes % 2
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerSize)
        func tag(_ text: String) { bytes.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        tag("RIFF"); u32(36 + dataBytes + padding); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 3); u16(3); u16(24)
        tag("data"); u32(dataBytes)
        return bytes
    }
}

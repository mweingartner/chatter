// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation

/// The PCM layout of a RIFF/WAVE file, read with the same chunk rules as Python's `wave` module:
/// chunks are bounded by the RIFF size, `fmt ` must precede `data`, and parsing stops at `data`.
public struct WAVFormat: Sendable, Equatable {
    public let channels: Int
    public let sampleRate: Int
    /// Bytes per sample, `(bitsPerSample + 7) / 8`.
    public let sampleWidth: Int
    /// Frames declared by the `data` chunk size.
    public let frameCount: Int
    /// Data bytes actually present (bounded by the chunk, RIFF and file sizes).
    public let availableDataBytes: Int

    public var bitsPerSample: Int { sampleWidth * 8 }
    public var durationSeconds: Double { Double(frameCount) / Double(sampleRate) }
    /// True when every declared frame is present on disk.
    public var isComplete: Bool { availableDataBytes >= frameCount * channels * sampleWidth }

    private static let pcmTag = 0x0001
    private static let extensibleTag = 0xFFFE
    private static let pcmSubformat: [UInt8] = [
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ]

    /// Reads the header of the WAV at `url` without loading its samples.
    public static func read(from url: URL) throws -> WAVFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        func bytes(at offset: Int, count: Int, limit: Int) throws -> [UInt8] {
            let end = min(offset + count, limit, fileSize)
            guard end > offset else { return [] }
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: end - offset) ?? Data())
        }
        let riffHeader = try bytes(at: 0, count: 8, limit: fileSize)
        guard riffHeader.count == 8 else { throw WAVFormatError.incompleteHeader }
        guard riffHeader[0..<4] == [0x52, 0x49, 0x46, 0x46] else { throw WAVFormatError.notRIFF }
        let riffEnd = 8 + Int(littleEndian(riffHeader, 4, 4))
        guard try bytes(at: 8, count: 4, limit: riffEnd) == Array("WAVE".utf8) else { throw WAVFormatError.notWAVE }

        var format: (channels: Int, rate: Int, width: Int)?
        var offset = 12
        while true {
            let header = try bytes(at: offset, count: 8, limit: riffEnd)
            guard header.count == 8 else { break }
            let name = String(decoding: header[0..<4], as: UTF8.self)
            let size = Int(littleEndian(header, 4, 4))
            let body = offset + 8
            if name == "fmt " {
                format = try readFormatChunk(try bytes(at: body, count: min(size, 40), limit: min(riffEnd, body + size)))
            } else if name == "data" {
                guard let format else { throw WAVFormatError.dataBeforeFormat }
                let available = max(0, min(size, riffEnd - body, fileSize - body))
                return WAVFormat(
                    channels: format.channels, sampleRate: format.rate, sampleWidth: format.width,
                    frameCount: size / (format.channels * format.width), availableDataBytes: available)
            }
            offset = body + size + (size & 1)
        }
        throw WAVFormatError.missingChunks
    }

    private static func readFormatChunk(_ chunk: [UInt8]) throws(WAVFormatError) -> (channels: Int, rate: Int, width: Int) {
        guard chunk.count >= 14 else { throw .incompleteHeader }
        let tag = Int(littleEndian(chunk, 0, 2))
        guard tag == pcmTag || tag == extensibleTag else { throw .unknownFormat(tag) }
        guard chunk.count >= 16 else { throw .incompleteHeader }
        let bits = Int(littleEndian(chunk, 14, 2))
        if tag == extensibleTag {
            guard chunk.count >= 40 else { throw .incompleteHeader }
            guard Array(chunk[24..<40]) == pcmSubformat else { throw .unknownExtendedFormat }
        }
        let width = (bits + 7) / 8
        guard width > 0 else { throw .badSampleWidth }
        let channels = Int(littleEndian(chunk, 2, 2))
        guard channels > 0 else { throw .badChannelCount }
        return (channels, Int(littleEndian(chunk, 4, 4)), width)
    }

    private static func littleEndian(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt32 {
        (0..<count).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << (8 * UInt32($1)) }
    }
}

/// Malformed WAV headers, worded like Python's `wave.Error`.
public enum WAVFormatError: ChatterToolingFailure, Sendable, Equatable {
    case incompleteHeader
    case notRIFF
    case notWAVE
    case missingChunks
    case dataBeforeFormat
    case unknownFormat(Int)
    case unknownExtendedFormat
    case badSampleWidth
    case badChannelCount

    public var description: String {
        switch self {
        case .incompleteHeader: "the WAV header is incomplete"
        case .notRIFF: "file does not start with RIFF id"
        case .notWAVE: "not a WAVE file"
        case .missingChunks: "fmt chunk and/or data chunk missing"
        case .dataBeforeFormat: "data chunk before fmt chunk"
        case .unknownFormat(let tag): "unknown format: \(tag)"
        case .unknownExtendedFormat: "unknown extended format"
        case .badSampleWidth: "bad sample width"
        case .badChannelCount: "bad # of channels"
        }
    }
}

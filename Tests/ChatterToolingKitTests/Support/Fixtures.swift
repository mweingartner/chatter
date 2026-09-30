// Chatter integration tooling (Swift replacement for the former Python helpers).
import ChatterToolingKit
import Foundation

/// Builds PCM WAV files byte-for-byte like Python's `wave` writer (44-byte header, silent samples).
enum WAVFixture {
    static func data(frames: Int, channels: Int = 1, sampleRate: Int = 44100, bytesPerSample: Int = 3, fill: UInt8 = 0) -> Data {
        let dataSize = frames * channels * bytesPerSample
        var bytes = Data("RIFF".utf8) + le32(36 + dataSize) + Data("WAVEfmt ".utf8) + le32(16)
        bytes += le16(1) + le16(channels) + le32(sampleRate) + le32(sampleRate * channels * bytesPerSample)
        bytes += le16(channels * bytesPerSample) + le16(bytesPerSample * 8)
        bytes += Data("data".utf8) + le32(dataSize) + Data(repeating: fill, count: dataSize)
        return bytes
    }

    static func write(to url: URL, frames: Int, channels: Int = 1, sampleRate: Int = 44100, bytesPerSample: Int = 3) throws {
        try data(frames: frames, channels: channels, sampleRate: sampleRate, bytesPerSample: bytesPerSample).write(to: url)
    }

    static func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    static func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
}

/// A fresh temporary directory removed when the value is discarded via `remove()`.
struct TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "chatter-tooling-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// Locates the `chatter-mcp` / `chatter-tools` executables built alongside the test bundle.
enum BuiltProducts {
    static var directory: URL {
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug")
    }

    static var bridge: String { directory.appending(path: "chatter-mcp").path }
    static var tools: String { directory.appending(path: "chatter-tools").path }
}

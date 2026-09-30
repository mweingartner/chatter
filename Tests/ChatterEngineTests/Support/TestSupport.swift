import Foundation

/// Seeded SplitMix64: every generated case replays from its seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// Concatenates `count` random pieces.
    mutating func text(from pieces: [String], count: ClosedRange<Int>) -> String {
        (0..<Int.random(in: count, using: &self)).map { _ in pieces.randomElement(using: &self)! }.joined()
    }
}

/// A scratch directory removed by `remove()`.
struct Scratch {
    let url: URL
    init(_ label: String = "engine") throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    /// The canonical (symlink-free) path, e.g. /private/var/... for /var/...
    var canonicalPath: String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

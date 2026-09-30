// Chatter integration tooling (Swift replacement for the former Python helpers).
import Foundation
import os

/// A destination for user-visible text (stdout, stderr, or a test capture).
public protocol TextOutput: Sendable {
    /// Writes `text` immediately (unbuffered); throws when the destination is gone.
    func write(_ text: String) throws
}

extension TextOutput {
    /// Writes `text` plus a newline, like Python's `print(..., flush=True)`.
    public func line(_ text: String) throws { try write(text + "\n") }
}

/// Unbuffered writes to a file descriptor such as stdout or stderr.
public struct FileHandleOutput: TextOutput {
    private let handle: FileHandle

    public init(_ handle: FileHandle) { self.handle = handle }

    public static let standardOutput = FileHandleOutput(.standardOutput)
    public static let standardError = FileHandleOutput(.standardError)

    public func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
}

/// Thread-safe in-memory capture for tests and diagnostics.
public final class CapturedOutput: TextOutput {
    private let buffer = OSAllocatedUnfairLock(initialState: "")

    public init() {}

    public var text: String { buffer.withLock { $0 } }

    /// Captured text split into lines, without the trailing empty element.
    public var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) }

    public func write(_ text: String) { buffer.withLock { $0 += text } }
}

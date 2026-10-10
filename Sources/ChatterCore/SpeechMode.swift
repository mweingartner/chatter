import Foundation

/// What a speech request does with its audio. Requests and receipts keep the raw string so older
/// receipts stay readable; this type holds the rules each mode follows.
public enum SpeechMode: String, CaseIterable, Sendable {
    /// Speaks on this Mac as the audio is generated, at the requested or live quality.
    case play
    /// Exports a WAV to the output folder, always at Studio quality.
    case save
    /// Generates audio for a client to download, silently and at the requested or live quality.
    /// Nothing plays on the Mac and nothing is exported; the audio is kept for `renderRetention`.
    case render

    /// Only `play` uses the Mac's speakers, so only `play` may start, stop or wait for playback.
    public var playsOnMac: Bool { self == .play }
    /// Only `save` writes into the user's output folder.
    public var exportsWAV: Bool { self == .save }
    /// `save` forces Studio; the other modes honour the request's quality.
    public var honoursQuality: Bool { self != .save }

    /// How long a render's audio stays downloadable after it is generated.
    public static let renderRetention: TimeInterval = 600

    /// The engine's passage and chunking policy: every mode but `save` is live audio.
    public var engineMode: String { self == .save ? "save" : rawValue }

    public static let validationMessage = "Mode must be play, save or render."
}

/// `?wait=` on speech submission and job lookup: hold the reply until the job finishes, for at most
/// `maximum` seconds. `true` waits the maximum; a number waits that many seconds.
public enum JobWait {
    public static let maximum: TimeInterval = 30
    /// Concurrent waiting requests allowed per credential; further requests answer at once.
    public static let perCredential = 8

    /// Nil when the query does not ask to wait.
    public static func seconds(from query: [String: String]) throws -> TimeInterval? {
        guard let value = query["wait"] else { return nil }
        switch value.lowercased() {
        case "true", "": return maximum
        case "false", "0": return nil
        default:
            guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= maximum else {
                throw ChatterError.invalid("wait must be true, false or a number of seconds up to \(Int(maximum)).")
            }
            return seconds
        }
    }
}

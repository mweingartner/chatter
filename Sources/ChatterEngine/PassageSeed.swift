import ChatterCore
import CryptoKit
import Foundation

/// Where each passage's random draws start. A voice speaks a sentence the same way every time: the
/// seed comes from the voice, the model and the sentence itself, not from the clock, so cadence no
/// longer changes from one run to the next, and a retry draws from a different, equally fixed seed.
enum PassageSeed {
    /// The seed for everything a voice says with one model: its kind, speaker or description,
    /// language, and its recordings with their transcripts.
    static func voice(_ configuration: QwenVoiceConfiguration, references: [EngineReference], profile: String, language: String) -> UInt64 {
        var parts = ["voice", profile, language, configuration.kind.rawValue, configuration.speaker ?? "", configuration.description ?? ""]
        for reference in references { parts += [reference.reference, reference.transcript] }
        return digest(parts)
    }

    /// The seed for one attempt at one passage. `prompt` is the delivery instruction, if any.
    static func passage(base: UInt64, text: String, prompt: String, attempt: Int) -> UInt64 {
        digest(["passage", String(base), text, prompt, String(attempt)])
    }

    /// Length-prefixed, so no two lists of parts share a digest by running into each other.
    private static func digest(_ parts: [String]) -> UInt64 {
        var hash = SHA256()
        for part in parts {
            let bytes = Array(part.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        return hash.finalize().prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

import ChatterAudioKit
import Foundation

/// `chatter-tools transcribe <wav>...` → one JSON object per line: {"path", "text"} (on-device).
enum TranscribeCommand {
    static func run(_ paths: [String]) async throws {
        let transcriber = LocalTranscriber(installsMissingAssets: false)
        for path in paths {
            var object: [String: Any] = ["path": path]
            do { object["text"] = try await transcriber.transcribe(try AudioIO.readMono44k(URL(filePath: path))) }
            catch { object["error"] = error.localizedDescription }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}

import Foundation
import ChatterCore

extension AppModel {
    /// Downloads (or verifies and repairs) the pinned speech models, then starts the engine.
    /// Resumable and integrity-checked; no Python or package manager is involved.
    func installModels() {
        guard !installing else { return }
        installing = true
        let installer = ModelInstaller()
        let needed = installer.missingBytes
        installLog = needed > 0
            ? "Downloading \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of pinned Qwen3-TTS models…\n"
            : "Verifying installed models…\n"
        engine.stop()
        installTask = Task { [weak self] in
            do {
                try await installer.install { message in
                    Task { @MainActor in
                        guard let self else { return }
                        self.installLog = String((self.installLog + message).suffix(20_000))
                    }
                }
                guard let self else { return }
                self.installing = false; self.installTask = nil
                self.installLog += "\nModels verified. Starting the speech engine…\n"
                self.engine.start()
            } catch {
                guard let self else { return }
                self.installing = false; self.installTask = nil
                self.error = error.localizedDescription
                self.installLog += "\n" + error.localizedDescription + "\n"
            }
        }
    }
}

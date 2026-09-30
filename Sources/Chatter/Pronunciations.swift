import Foundation
import ChatterCore

extension AppModel {
    var pronunciationsURL: URL { ChatterPaths.root.appending(path: "pronunciations.json") }

    func loadPronunciations() {
        guard FileManager.default.fileExists(atPath: pronunciationsURL.path) else { return }
        do { pronunciations = try ChatterPaths.load(PronunciationList.self, from: pronunciationsURL) }
        catch {
            // Keep the unreadable file for recovery instead of overwriting it with the next save.
            let aside = pronunciationsURL.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: pronunciationsURL, to: aside)
                notice = "Chatter couldn’t read your pronunciations, so it set that file aside as \(aside.lastPathComponent) and started an empty list."
            } catch {
                self.error = "Chatter couldn’t read or set aside pronunciations.json: \(error.localizedDescription)"
            }
        }
    }

    /// Adds or updates an entry. The list is saved before the change is shown, so what you see is on disk.
    @discardableResult
    func savePronunciation(_ entry: Pronunciation) throws -> Pronunciation {
        var updated = pronunciations
        let saved = try updated.upsert(entry)
        try ChatterPaths.save(updated, to: pronunciationsURL)
        pronunciations = updated
        return saved
    }

    /// Removes an entry once the shorter list is saved. Returns false, with the reason shown, if it wasn't.
    @discardableResult
    func removePronunciation(id: UUID) -> Bool {
        var updated = pronunciations
        updated.remove(id: id)
        do {
            try ChatterPaths.save(updated, to: pronunciationsURL)
            pronunciations = updated
            return true
        } catch {
            self.error = "Couldn’t delete that pronunciation. \(error.localizedDescription)"
            return false
        }
    }

    func importPronunciations(from url: URL) throws -> PronunciationList.ImportSummary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Only a regular file is read, and never more than 1 MB of it (a device or pipe would never end).
        let data = try ChatterPaths.readRegularFile(at: url, upTo: 1_000_000)
        guard data.count <= 1_000_000 else { throw ChatterError.invalid("That file is larger than 1 MB. Import a smaller list.") }
        guard let text = String(data: data, encoding: .utf8) else { throw ChatterError.invalid("Save the list as UTF-8 CSV and try again.") }
        var updated = pronunciations
        let summary = try updated.importCSV(text)
        try ChatterPaths.save(updated, to: pronunciationsURL)
        pronunciations = updated
        return summary
    }

    /// Speaks `text` exactly as written (no pronunciations applied) in `voiceID`, like a short live
    /// request, and returns the job so its progress can be shown and just that preview stopped.
    func previewPronunciation(_ text: String, voiceID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.last.map { $0.isPunctuation } == true ? trimmed : trimmed + "."
        do { return try submit(SpeechRequest(voice: voiceID, text: sentence, pace: settings.defaultPace, mode: "play", quality: "responsive"), respell: false).id }
        catch { self.error = error.localizedDescription; return nil }
    }
}

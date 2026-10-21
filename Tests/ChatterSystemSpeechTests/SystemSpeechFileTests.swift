@testable import ChatterSystemSpeech
import AVFoundation
import ChatterCore
import Foundation
import Testing

/// Where `render(_:voiceIdentifier:to:)` writes: odd paths, a missing folder, and things already
/// at the destination. Extends `SystemSpeechTests`, so renders stay serialized on the main actor.
extension SystemSpeechTests {
    static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "chatter-system-speech-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Spaces, accents, ideographs and emoji in the folder and file names render a readable AIFF.
    @Test func pathsWithSpacesAndUnicodeRender() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appending(path: "My Voices é 声")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let file = inner.appending(path: "Aman’s voice 🎙.aiff")
        try await SystemSpeech.render("A short sentence.", voiceIdentifier: Self.englishVoice().id, to: file)
        let audio = try AVAudioFile(forReading: file)
        #expect(audio.length > 1_000 && audio.fileFormat.sampleRate >= 8_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inner.path) == ["Aman’s voice 🎙.aiff"])
    }

    /// A destination whose folder is gone fails as no audio, without creating the folder.
    @Test func aMissingFolderIsNotCreated() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appending(path: "gone")
        await #expect(throws: SystemSpeech.RenderError.noAudio) {
            try await SystemSpeech.render("Hello.", voiceIdentifier: Self.englishVoice().id, to: missing.appending(path: "voice.aiff"))
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// A folder at the destination is refused and left as it was, contents included.
    @Test func aDirectoryAtTheDestinationIsRefusedAndKept() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appending(path: "voice.aiff")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: directory.appending(path: "inside.txt"))
        do {
            try await SystemSpeech.render("Hello.", voiceIdentifier: Self.englishVoice().id, to: directory)
            Issue.record("rendered over a directory")
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteFileExists)
            #expect(error.userInfo[NSFilePathErrorKey] as? String == directory.path)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try String(contentsOf: directory.appending(path: "inside.txt"), encoding: .utf8) == "keep")
    }

    /// A symlink to an existing file is refused: neither the link nor its target changes.
    @Test func aSymlinkToAFileIsRefused() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "notes.txt"), link = folder.appending(path: "voice.aiff")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: CocoaError.self) {
            try await SystemSpeech.render("Hello.", voiceIdentifier: Self.englishVoice().id, to: link)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    /// A symlink to nothing is refused like a file: it is something at the destination, so the
    /// render neither writes through it nor deletes it.
    @Test func aDanglingSymlinkIsRefusedAndKept() async throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "elsewhere.aiff"), link = folder.appending(path: "voice.aiff")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            try await SystemSpeech.render("Hello.", voiceIdentifier: Self.englishVoice().id, to: link)
            Issue.record("rendered through a dangling symlink")
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteFileExists)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path), "the render wrote through the link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }
}

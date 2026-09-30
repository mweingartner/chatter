import Foundation
import Testing
@testable import ChatterCore

@Suite("Public starter voices")
struct DefaultVoicesTests {
    @Test func onlyAidenAndRyanWithoutPrivateSamples() throws {
        let voices = DefaultVoices.profiles
        #expect(voices.map(\.name) == ["Aiden", "Ryan"])
        #expect(Set(voices.map(\.id)).count == 2)
        for voice in voices {
            #expect(voice.kind == .preset && voice.isReady)
            #expect(voice.samples.isEmpty && voice.selectedSampleID == nil)
            #expect(try voice.references().isEmpty)
            #expect(try voice.synthesisConfiguration.validated().speaker == voice.name)
        }
    }

    @Test func seedPersistsButNeverOverwritesExistingLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "voices.json")
        let first = try DefaultVoices.loadOrCreate(at: url)
        #expect(first.map(\.name) == ["Aiden", "Ryan"])
        #expect(try DefaultVoices.loadOrCreate(at: url).map(\.id) == first.map(\.id))
        let custom = VoiceProfile(name: "Private test voice")
        try ChatterPaths.save([custom], to: url)
        #expect(try DefaultVoices.loadOrCreate(at: url).map(\.id) == [custom.id])
        try ChatterPaths.save([VoiceProfile](), to: url)
        #expect(try DefaultVoices.loadOrCreate(at: url).isEmpty)
        let damaged = Data("not json".utf8)
        try damaged.write(to: url)
        #expect(throws: (any Error).self) { try DefaultVoices.loadOrCreate(at: url) }
        #expect(try Data(contentsOf: url) == damaged)
    }
}

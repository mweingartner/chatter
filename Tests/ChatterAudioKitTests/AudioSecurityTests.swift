import Foundation
import Testing
@testable import ChatterAudioKit

@Suite("Audio security") struct AudioSecurityTests {
    @Test func writerIsPrivateAndBounded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "out.wav")
        let writer = try WAVStreamWriter(url: url, sampleRate: 24000, maximumSeconds: 1)
        #expect(try FileManager.default.attributesOfItem(atPath: writer.partialURL.path)[.posixPermissions] as? Int == 0o600)
        try writer.append([Float](repeating: 0.1, count: 24000))
        #expect(throws: ChatterAudioError.unsupportedDuration) { try writer.append([0.1]) }
        try writer.finish()
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: ChatterAudioError.unsupportedDuration) { try AudioIO.readMono(url, sampleRate: 24000, maximumSeconds: 0.5) }
        let victim = root.appending(path: "victim"); try Data("keep".utf8).write(to: victim)
        let linked = root.appending(path: "linked.wav")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathExtension("partial"), withDestinationURL: victim)
        let replacement = try WAVStreamWriter(url: linked); replacement.cancel()
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
    }
}

import CryptoKit
import Foundation
import Testing
@testable import ChatterCore

/// Model installation must never accept bytes that do not match the pinned SHA-256, must resume
/// interrupted downloads, and must deduplicate the legacy per-profile codec copies without data loss.
struct ModelInstallerTests {
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "model-installer-\(UUID().uuidString)")
    }
    static let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    /// Serves `body`, honoring `Range: bytes=N-` like Hugging Face's CDN.
    static func server(_ body: Data, status: Int = 200, honorRange: Bool = true) async throws -> MockHTTPServer {
        try await MockHTTPServer.start { request in
            if status != 200 { return MockResponse(status: status) }
            if honorRange, let range = request.headers["range"], range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()) {
                return MockResponse(status: 206, headers: ["Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)"], body: body.subdata(in: start..<body.count))
            }
            return MockResponse(status: 200, body: body)
        }
    }

    static func file(_ destination: String = "p/model.bin", content: Data = Self.content) -> ModelFile {
        ModelFile(repository: "org/repo", revision: "abc123", path: "model.bin", destination: destination, size: Int64(content.count), sha256: sha(content))
    }

    @Test func downloadsVerifiesAndInstalls() async throws {
        let server = try await Self.server(Self.content)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        #expect(!installer.isInstalled)
        try await installer.install { _ in }
        #expect(installer.isInstalled)
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
        #expect(server.requests.map(\.path) == ["/org/repo/resolve/abc123/model.bin"])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin.partial").path))
    }

    @Test func resumesAnInterruptedDownload() async throws {
        let server = try await Self.server(Self.content)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        try Self.content.prefix(120_000).write(to: root.appending(path: "p/model.bin.partial"))
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        try await installer.install { _ in }
        #expect(server.requests.first?.headers["range"] == "bytes=120000-")
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
    }

    @Test func restartsWhenTheServerIgnoresTheRange() async throws {
        let server = try await Self.server(Self.content, honorRange: false)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 50_000).write(to: root.appending(path: "p/model.bin.partial"))
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        try await installer.install { _ in }
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
    }

    @Test func tamperedContentIsRejectedAndDiscarded() async throws {
        var tampered = Self.content; tampered[1000] ^= 0xFF
        let server = try await Self.server(tampered)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        await #expect(throws: ModelInstallerError.self) { try await installer.install { _ in } }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "p/model.bin.partial").path))
    }

    @Test func httpErrorsAreReported() async throws {
        let server = try await Self.server(Self.content, status: 404)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        do { try await installer.install { _ in }; Issue.record("expected failure") }
        catch { #expect(error.localizedDescription.contains("HTTP 404")) }
    }

    @Test func validFilesAreVerifiedWithoutDownloadingAndDamagedOnesReplaced() async throws {
        let server = try await Self.server(Self.content)
        let root = Self.temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        try Self.content.write(to: root.appending(path: "p/model.bin"))
        let installer = ModelInstaller(modelsRoot: root, files: [Self.file()], baseURL: URL(string: server.baseURL)!)
        try await installer.install { _ in }
        #expect(server.requests.isEmpty)
        // Same size, different bytes: detected by hash, replaced by a verified download.
        var damaged = Self.content; damaged[0] ^= 1
        try damaged.write(to: root.appending(path: "p/model.bin"))
        try await installer.install { _ in }
        #expect(server.requests.count == 1)
        #expect(try Data(contentsOf: root.appending(path: "p/model.bin")) == Self.content)
    }

    @Test func manifestPinsEveryFileByRevisionAndHash() {
        #expect(ModelManifest.files.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.size > 0 })
        #expect(Set(ModelManifest.files.map(\.destination)).count == ModelManifest.files.count)
        #expect(ModelManifest.files.filter { $0.destination.hasSuffix("speech_tokenizer/model.safetensors") }.count == 4)
    }
}

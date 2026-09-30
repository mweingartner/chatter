import Foundation
import Testing
@testable import ChatterCore

/// The Ollama client against a stubbed server: which models are offered, what a chat request carries,
/// and how failures read. Serialized, because the stub is shared.
@Suite(.serialized)
struct OllamaClientTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var respond: (URLRequest) throws -> (Int, Data) = { _ in (200, Data("{}".utf8)) }
        nonisolated(unsafe) static var requests: [URLRequest] = []
        /// Seconds before the stubbed reply arrives (a stalled server).
        nonisolated(unsafe) static var delay: TimeInterval = 0
        private let lock = NSLock()
        private var stopped = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var captured = request
            if captured.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
                captured.httpBody = body
            }
            Self.requests.append(captured)
            let reply = { [self] in
                guard lock.withLock({ !stopped }) else { return }
                do {
                    let (status, data) = try Self.respond(captured)
                    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: error) }
            }
            if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: reply) } else { reply() }
        }
        override func stopLoading() { lock.withLock { stopped = true } }
    }

    static func client(delay: TimeInterval = 0, _ respond: @escaping (URLRequest) throws -> (Int, Data)) throws -> OllamaClient {
        Stub.respond = respond; Stub.requests = []; Stub.delay = delay
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return try OllamaClient(session: URLSession(configuration: configuration))
    }

    @Test func onlyLocalTextModelsAreOffered() async throws {
        let tags = #"""
        {"models":[
          {"name":"qwen3.8:27b-mlx","size":18174721847,"details":{"parameter_size":""},"capabilities":["completion","vision","tools","thinking"]},
          {"name":"minimax-m3:cloud","remote_model":"minimax-m3","remote_host":"https://ollama.com:443","size":362,"capabilities":["completion"]},
          {"name":"nomic-embed-text:latest","size":274302450,"capabilities":["embedding"]},
          {"name":"granite4.1:8b","size":5347933017,"details":{"parameter_size":"8.8B"},"capabilities":["completion","tools"]},
          {"name":"old-model:7b","size":1000}
        ]}
        """#
        let client = try Self.client { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/tags")
            return (200, Data(tags.utf8))
        }
        let models = try await client.localModels()
        #expect(models.map(\.name) == ["granite4.1:8b", "old-model:7b", "qwen3.8:27b-mlx"])
        #expect(models.first { $0.name == "qwen3.8:27b-mlx" }?.canThink == true)
        #expect(models.first { $0.name == "granite4.1:8b" }?.parameterSize == "8.8B")
        #expect(models.first { $0.name == "qwen3.8:27b-mlx" }?.parameterSize == nil)
    }

    @Test func chatAsksForJSONAtTemperatureZero() async throws {
        let client = try Self.client { _ in (200, Data(#"{"message":{"role":"assistant","content":"{\"notes\":[]}"}}"#.utf8)) }
        let reply = try await client.chat(model: "qwen3.8:27b-mlx", instructions: "Direct.", prompt: "1. Hi.", schema: ExpressionReview.schema, think: false, timeout: .seconds(8))
        #expect(String(decoding: reply, as: UTF8.self) == #"{"notes":[]}"#)
        let request = try #require(Stub.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.path == "/api/chat")
        #expect(request.timeoutInterval == 8)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "qwen3.8:27b-mlx" && body["stream"] as? Bool == false && body["think"] as? Bool == false)
        #expect((body["options"] as? [String: Any])?["temperature"] as? Int == 0)
        #expect((body["format"] as? [String: Any])?["type"] as? String == "object")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Direct."], ["role": "user", "content": "1. Hi."]])
        // Without a thinking preference the model's default is left alone.
        _ = try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(1))
        let second = try #require(try JSONSerialization.jsonObject(with: Stub.requests.last?.httpBody ?? Data()) as? [String: Any])
        #expect(second["think"] == nil)
    }

    @Test func failuresSayWhatToDo() async throws {
        let missing = try Self.client { _ in (404, Data(#"{"error":"model \"qwen9\" not found, try pulling it first"}"#.utf8)) }
        await #expect(throws: OllamaError.modelMissing("qwen9")) { try await missing.chat(model: "qwen9", instructions: "", prompt: "", schema: Data("{}".utf8), think: nil, timeout: .seconds(1)) }
        let broken = try Self.client { _ in (500, Data(#"{"error":"out of memory"}"#.utf8)) }
        await #expect(throws: OllamaError.server("out of memory")) { try await broken.chat(model: "m", instructions: "", prompt: "", schema: Data("{}".utf8), think: nil, timeout: .seconds(1)) }
        let garbled = try Self.client { _ in (200, Data("not json".utf8)) }
        await #expect(throws: OllamaError.unreadable) { try await garbled.version() }
        let down = try Self.client { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: OllamaError.notRunning("http://127.0.0.1:11434")) { try await down.localModels() }
        let slow = try Self.client { _ in throw URLError(.timedOut) }
        await #expect(throws: OllamaError.timedOut) { try await slow.version() }
        #expect(OllamaError.notRunning("http://127.0.0.1:11434").localizedDescription == "Ollama isn’t running at http://127.0.0.1:11434. Open Ollama and try again.")
    }

    /// A server that keeps the connection open without answering can't hold a review past its time.
    @Test func aStalledServerTimesOutOnTime() async throws {
        let stalled = try Self.client(delay: 5) { _ in (200, Data(#"{"message":{"content":"{}"}}"#.utf8)) }
        let start = ContinuousClock.now
        await #expect(throws: OllamaError.timedOut) {
            try await stalled.chat(model: "m", instructions: "", prompt: "", schema: Data("{}".utf8), think: nil, timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func onlyAMissingModelIsReportedAsMissing() async throws {
        for (status, message, expected) in [(404, "model \"x\" not found, try pulling it first", OllamaError.modelMissing("x")),
                                            (500, "model 'x' not found", OllamaError.modelMissing("x")),
                                            (500, "file not found", OllamaError.server("file not found")),
                                            (400, "invalid format", OllamaError.server("invalid format"))] {
            let client = try Self.client { _ in (status, try JSONSerialization.data(withJSONObject: ["error": message])) }
            await #expect(throws: expected) { try await client.chat(model: "x", instructions: "", prompt: "", schema: Data("{}".utf8), think: nil, timeout: .seconds(2)) }
        }
    }

    @Test(arguments: ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434", "https://127.0.0.1:8443/", "  http://127.0.0.1:11434  "])
    func loopbackAddressesAreAccepted(address: String) throws {
        #expect(try OllamaClient.validatedAddress(address).host != nil)
    }

    @Test(arguments: ["http://192.168.1.20:11434", "http://ollama.example.com", "ftp://127.0.0.1", "http://user:pw@127.0.0.1:11434", "http://127.0.0.1:11434/api",
                      "http://127.0.0.1:11434?x=1", "127.0.0.1:11434", "", "http://127.0.0.1.evil.com:11434", "http://0.0.0.0:11434"])
    func otherAddressesAreRefused(address: String) {
        #expect(throws: OllamaError.invalidAddress) { try OllamaClient.validatedAddress(address) }
    }

    @Test func savedSettingsFallBackToTheLocalAddress() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"ollamaAddress":"http://10.0.0.5:11434","expressionModel":"gemma4:12b-mlx"}"#.utf8))
        #expect(settings.ollamaAddress == OllamaClient.defaultAddress && settings.expressionModel == "gemma4:12b-mlx")
        let defaults = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(defaults.expressionModel == "qwen3.8:27b-mlx" && defaults.expressionNotesInStudio && defaults.expressionNotesForRequests)
    }
}

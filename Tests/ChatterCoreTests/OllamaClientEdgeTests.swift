import Foundation
import Testing
@testable import ChatterCore

/// Edge cases for the Ollama client, in the same serialized suite as `OllamaClientTests` because they
/// share its stubbed URL protocol: how every transport failure and odd reply reads, what each request
/// carries, and that only loopback addresses are ever accepted.
extension OllamaClientTests {
    static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    // MARK: Failures

    @Test(arguments: [URLError.Code.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed])
    func unreachableServersReadAsNotRunning(code: URLError.Code) async throws {
        let client = try Self.client { _ in throw URLError(code) }
        await #expect(throws: OllamaError.notRunning("http://127.0.0.1:11434")) { try await client.version() }
        await #expect(throws: OllamaError.notRunning("http://127.0.0.1:11434")) {
            try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(1))
        }
    }

    @Test func aCancelledRequestIsACancellationNotAFailure() async throws {
        let client = try Self.client { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await client.localModels() }
        await #expect(throws: CancellationError.self) {
            try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: false, timeout: .seconds(1))
        }
    }

    @Test func otherTransportErrorsKeepTheSystemsWords() async throws {
        let client = try Self.client { _ in throw URLError(.badServerResponse) }
        do {
            _ = try await client.version()
            Issue.record("expected a failure")
        } catch let error as OllamaError {
            guard case .server(let message) = error else { Issue.record("expected .server, got \(error)"); return }
            #expect(!message.isEmpty)
            #expect(error.localizedDescription.hasPrefix("Ollama: "))
        }
    }

    @Test func statusCodesAndBodiesMapToErrors() async throws {
        func failure(_ status: Int, _ body: Data, model: Bool) async throws -> OllamaError? {
            let client = try Self.client { _ in (status, body) }
            do {
                if model { _ = try await client.chat(model: "gemma", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(1)) }
                else { _ = try await client.version() }
                return nil
            } catch let error as OllamaError { return error }
        }
        // A 404 for a model means the model is missing, whatever the body says.
        #expect(try await failure(404, Data("<html>".utf8), model: true) == .modelMissing("gemma"))
        #expect(try await failure(404, Self.json(["error": "nope"]), model: true) == .modelMissing("gemma"))
        // Without a model, a 404 is just the server's answer.
        #expect(try await failure(404, Data(), model: false) == .server("HTTP 404"))
        // "not found" in any case, for any status, names the missing model.
        #expect(try await failure(400, Self.json(["error": "Model 'gemma' NOT FOUND"]), model: true) == .modelMissing("gemma"))
        // An error that is not a string, or no body at all, reads as the status.
        #expect(try await failure(500, Self.json(["error": 42]), model: true) == .server("HTTP 500"))
        #expect(try await failure(503, Data(), model: true) == .server("HTTP 503"))
        #expect(try await failure(500, Data("[1,2]".utf8), model: false) == .server("HTTP 500"))
        // A success that isn't a JSON object is unreadable.
        #expect(try await failure(200, Data("[1,2]".utf8), model: false) == .unreadable)
        #expect(try await failure(204, Data(), model: false) == .unreadable)
        #expect(try await failure(200, Data("\"text\"".utf8), model: true) == .unreadable)
    }

    @Test func repliesWithoutTheExpectedFieldsAreUnreadable() async throws {
        for body: [String: Any] in [[:], ["message": "hi"], ["message": ["role": "assistant"]], ["message": ["content": 7]], ["message": NSNull()]] {
            let client = try Self.client { _ in (200, Self.json(body)) }
            await #expect(throws: OllamaError.unreadable) {
                try await client.chat(model: "m", instructions: "", prompt: "", schema: ExpressionReview.schema, think: nil, timeout: .seconds(1))
            }
        }
        for body: [String: Any] in [["version": 3], [:], ["version": NSNull()]] {
            let client = try Self.client { _ in (200, Self.json(body)) }
            await #expect(throws: OllamaError.unreadable) { try await client.version() }
        }
        for body: [String: Any] in [[:], ["models": "none"], ["models": [1, 2]], ["models": ["name": "x"]]] {
            let client = try Self.client { _ in (200, Self.json(body)) }
            await #expect(throws: OllamaError.unreadable) { try await client.localModels() }
        }
        // An empty model list is fine.
        let empty = try Self.client { _ in (200, Self.json(["models": []])) }
        #expect(try await empty.localModels().isEmpty)
    }

    @Test func aSchemaThatIsNotJSONFailsBeforeAnyRequest() async throws {
        let client = try Self.client { _ in (200, Self.json(["message": ["content": "{}"]])) }
        await #expect(throws: (any Error).self) {
            try await client.chat(model: "m", instructions: "", prompt: "", schema: Data("not json".utf8), think: nil, timeout: .seconds(1))
        }
        #expect(Stub.requests.isEmpty)
    }

    @Test func messagesTellThePersonWhatToDo() {
        #expect(OllamaError.modelMissing("qwen").localizedDescription.contains("ollama pull qwen"))
        #expect(OllamaError.timedOut.localizedDescription == "The language model took too long to answer.")
        #expect(OllamaError.invalidAddress.localizedDescription.contains("http://127.0.0.1:11434"))
        #expect(OllamaError.server("x").localizedDescription == "Ollama: x")
        #expect(OllamaError.unreadable.localizedDescription == "Ollama sent a reply Chatter couldn’t read.")
    }

    // MARK: Requests

    @Test func modelsAreReadLeniently() async throws {
        let tags: [String: Any] = ["models": [
            ["model": "only-model-key:1b", "capabilities": ["completion"]],
            ["size": 5],
            ["name": "model10", "size": "big", "capabilities": ["completion"], "details": ["parameter_size": 12]],
            ["name": "model9", "size": 9_000_000_000, "capabilities": ["completion", "thinking"]],
            ["name": "no-capabilities-listed"],
            ["name": "vision-only", "capabilities": ["vision"]],
            ["name": "empty-capabilities", "capabilities": []],
            ["name": "remote-only", "remote_host": "https://ollama.com:443"],
            ["name": "remote-model-only", "remote_model": "x"],
        ]]
        let client = try Self.client { _ in (200, Self.json(tags)) }
        let models = try await client.localModels()
        #expect(models.map(\.name) == ["model9", "model10", "no-capabilities-listed", "only-model-key:1b"])
        #expect(models[0].sizeBytes == 9_000_000_000 && models[0].canThink && !models[1].canThink)
        #expect(models[1].sizeBytes == 0 && models[1].parameterSize == nil)
        #expect(models.map(\.id) == models.map(\.name))
    }

    @Test func loadingAModelPostsToGenerate() async throws {
        let client = try Self.client { _ in (200, Self.json(["done": true])) }
        try await client.load(model: "qwen3.8:27b-mlx")
        let request = try #require(Stub.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
        #expect(request.timeoutInterval == 120 && request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body.count == 1 && body["model"] as? String == "qwen3.8:27b-mlx")
        // A missing model says so.
        let missing = try Self.client { _ in (404, Self.json(["error": "model not found"])) }
        await #expect(throws: OllamaError.modelMissing("gone")) { try await missing.load(model: "gone") }
    }

    @Test func chatCarriesThinkingAndTheSchemaVerbatim() async throws {
        let client = try Self.client { _ in (200, Self.json(["message": ["content": "{\"candidates\":[]}"]])) }
        _ = try await client.chat(model: "m", instructions: "i", prompt: "p", schema: PronunciationSuggestions.schema, think: true, timeout: .seconds(180))
        let request = try #require(Stub.requests.first)
        #expect(request.timeoutInterval == 180)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["think"] as? Bool == true)
        let format = try #require(body["format"] as? [String: Any])
        let schema = try #require(try JSONSerialization.jsonObject(with: PronunciationSuggestions.schema) as? [String: Any])
        #expect(NSDictionary(dictionary: format).isEqual(to: schema))
    }

    @Test func timeoutsAreSecondsWithAFloor() {
        #expect(OllamaClient.seconds(.seconds(8)) == 8)
        #expect(OllamaClient.seconds(.milliseconds(1_500)) == 1.5)
        #expect(OllamaClient.seconds(.milliseconds(100)) == 0.5)
        #expect(OllamaClient.seconds(.zero) == 0.5)
        #expect(OllamaClient.seconds(.seconds(-3)) == 0.5)
        #expect(OllamaClient.seconds(.seconds(90)) == 90)
    }

    // MARK: Addresses

    @Test func aTrailingSlashNeitherDoublesPathsNorShowsInMessages() async throws {
        Stub.respond = { _ in throw URLError(.cannotConnectToHost) }; Stub.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let client = try OllamaClient(address: "http://localhost:8080/", session: URLSession(configuration: configuration))
        await #expect(throws: OllamaError.notRunning("http://localhost:8080")) { try await client.version() }
        #expect(Stub.requests.first?.url?.absoluteString == "http://localhost:8080/api/version")
    }

    @Test(arguments: ["HTTP://LOCALHOST:11434", "http://127.0.0.1", "http://[::1]", "https://localhost/", "\thttp://localhost:11434\n", "http://127.0.0.1:1/"])
    func moreLoopbackFormsAreAccepted(address: String) throws {
        let url = try OllamaClient.validatedAddress(address)
        #expect(["127.0.0.1", "::1", "localhost"].contains(url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""))
    }

    @Test(arguments: ["http://localhost.:11434", "http://@127.0.0.1:11434", "http://127.0.0.1:11434/?", "http://127.0.0.1:11434#", "http://127.0.0.1:11434//",
                      "http://[::1%25en0]:11434", "http://127.0.0.1\\@evil.com", "http:/127.0.0.1", "http://127.1:11434", "http://127.0.0.2:11434",
                      "http://[::ffff:127.0.0.1]:11434", "http://localhost@evil.com", "http://evil.com#@localhost", "http://evil.com?@localhost",
                      "file:///etc/passwd", "javascript:alert(1)", "http://localhost:11434/api/chat", "http://0x7f000001", "http://2130706433",
                      "ws://127.0.0.1:11434", "http:// 127.0.0.1", "http://127.0.0.1 evil", "localhost"])
    func trickyNonLoopbackAddressesAreRefused(address: String) {
        #expect(throws: OllamaError.invalidAddress) { try OllamaClient.validatedAddress(address) }
    }

    /// Property: over generated addresses, every accepted one points at a loopback host with no path,
    /// query, fragment or credentials, and acceptance matches the rule.
    @Test func generatedAddressesAreAcceptedOnlyForLoopback() {
        var rng = PronunciationEdgeTests.Seeded(state: 1_011)
        let schemes = ["http", "https", "HTTP", "ftp", "ws", ""], hosts = ["127.0.0.1", "localhost", "LocalHost", "[::1]", "10.0.0.5", "evil.com", "localhost.evil.com", "127.0.0.1.nip.io", ""]
        let users = ["", "", "", "u@", "u:p@", "@"], ports = ["", ":11434", ":1", ":65535"], tails = ["", "", "/", "/api", "?q", "#f", "/?", "//"]
        for _ in 0..<2_000 {
            let scheme = schemes.randomElement(using: &rng)!, host = hosts.randomElement(using: &rng)!, user = users.randomElement(using: &rng)!, tail = tails.randomElement(using: &rng)!
            let address = (scheme.isEmpty ? "" : scheme + "://") + user + host + ports.randomElement(using: &rng)! + tail
            let expected = ["http", "https"].contains(scheme.lowercased()) && ["127.0.0.1", "localhost", "[::1]"].contains(host.lowercased()) && user.isEmpty && ["", "/"].contains(tail)
            let url = try? OllamaClient.validatedAddress(address)
            #expect((url != nil) == expected, "\(address)")
            if let url {
                #expect(["127.0.0.1", "::1", "localhost"].contains(url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""), "\(address)")
                #expect(url.user() == nil && url.query() == nil && url.fragment() == nil && ["", "/"].contains(url.path()), "\(address)")
            }
        }
    }

    @Test func settingsKeepTheirExpressionChoicesThroughASave() throws {
        var settings = Settings()
        settings.expressionModel = "granite4.1:8b"; settings.expressionNotesInStudio = false; settings.expressionNotesForRequests = false
        settings.ollamaAddress = "http://localhost:8080"
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(restored.expressionModel == "granite4.1:8b" && !restored.expressionNotesInStudio && !restored.expressionNotesForRequests)
        #expect(restored.ollamaAddress == "http://localhost:8080")
        // An address edited by hand to point off this Mac falls back to the local one.
        for address in ["http://192.168.1.2:11434", "", "http://localhost@evil.com", "http://127.0.0.1:11434/api"] {
            let json = Self.json(["ollamaAddress": address])
            #expect(try JSONDecoder().decode(Settings.self, from: json).ollamaAddress == OllamaClient.defaultAddress, "\(address)")
        }
    }
}

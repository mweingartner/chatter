import Foundation
import ChatterCore

/// Availability of the optional local pronunciation assistant.
enum ExpressionStatus: Equatable {
    case checking
    case ready(version: String)
    case unavailable(String)

    var isReady: Bool { if case .ready = self { true } else { false } }
    /// For the health endpoint: "ready", "checking" or "unavailable".
    var state: String {
        switch self { case .checking: "checking"; case .ready: "ready"; case .unavailable: "unavailable" }
    }
}

extension AppModel {
    /// The Ollama server at the configured (loopback-only) address.
    var ollama: OllamaClient? { try? OllamaClient(address: settings.ollamaAddress) }

    /// Reads Ollama's local models and whether the chosen one is among them.
    func refreshExpressionModels() async {
        guard let client = ollama else { expressionStatus = .unavailable(OllamaError.invalidAddress.localizedDescription); return }
        let previous = expressionStatus
        if !expressionStatus.isReady { expressionStatus = .checking }
        do {
            let version = try await client.version()
            ollamaModels = try await client.localModels()
            expressionStatus = ollamaModels.contains { $0.name == settings.expressionModel }
                ? .ready(version: version) : .unavailable(OllamaError.modelMissing(settings.expressionModel).localizedDescription)
        } catch is CancellationError {
            // A stopped review or suggestion says nothing about Ollama.
            if expressionStatus == .checking { expressionStatus = previous }
        } catch {
            expressionStatus = .unavailable(error.localizedDescription)
        }
    }

    /// The chosen model, once Ollama has confirmed it keeps it on this Mac (a cloud model is never used).
    /// Checks again when the model isn't known to be ready, so the status follows what Ollama says.
    private func localModel() async throws -> String {
        let model = settings.expressionModel
        if expressionStatus.isReady, ollamaModels.contains(where: { $0.name == model }) { return model }
        await refreshExpressionModels()
        try Task.checkCancellation()   // a stopped review is stopped, not a missing model
        guard ollamaModels.contains(where: { $0.name == model }), expressionStatus.isReady else {
            if case .unavailable(let reason) = expressionStatus { throw ChatterError.unavailable(reason) }
            throw OllamaError.modelMissing(model)
        }
        return model
    }

    /// Draft respellings for a written form from the chosen model, thinking first when it can (slower,
    /// noticeably better), plus spelled-out letters for an initialism.
    func suggestPronunciations(for written: String) async throws -> [String] {
        guard let client = ollama else { throw OllamaError.invalidAddress }
        let model = try await localModel()
        let think: Bool? = ollamaModels.first { $0.name == model }.map { $0.canThink ? true : false }
        let reply = try await client.chat(model: model, instructions: PronunciationSuggestions.instructions,
                                          prompt: PronunciationSuggestions.prompt(for: written),
                                          schema: PronunciationSuggestions.schema, think: think, timeout: .seconds(180))
        return PronunciationSuggestions.candidates(in: reply, for: written)
    }
}

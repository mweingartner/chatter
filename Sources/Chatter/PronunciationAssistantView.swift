import SwiftUI
import ChatterCore

/// Optional, on-demand assistance. These settings never affect the speech generation path.
struct PronunciationAssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    var body: some View {
        @Bindable var model = model
        DisclosureGroup("Optional pronunciation assistant") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ollama is used only when you request pronunciation suggestions. Qwen speech and expression do not need it.").font(.callout).foregroundStyle(.secondary)
                Picker("Suggestion model", selection: $model.settings.expressionModel) {
                    ForEach(model.ollamaModels) { item in Text(item.name).tag(item.name) }
                    if !model.ollamaModels.contains(where: { $0.name == model.settings.expressionModel }) {
                        Text(model.settings.expressionModel).tag(model.settings.expressionModel)
                    }
                }
                HStack {
                    TextField("Ollama address", text: $address).textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        do {
                            _ = try OllamaClient.validatedAddress(address)
                            model.settings.ollamaAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.saveSettings()
                            Task { await model.refreshExpressionModels() }
                        } catch { model.error = error.localizedDescription }
                    }.disabled(address == model.settings.ollamaAddress)
                    Button("Refresh models") { Task { await model.refreshExpressionModels() } }
                }
                switch model.expressionStatus {
                case .checking: Text("Checking locally installed models…")
                case .ready: Text("The selected local model is available for suggestions.")
                case .unavailable(let reason): Text(reason).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
        }
        .onAppear { address = model.settings.ollamaAddress }
        .onChange(of: model.settings.expressionModel) { _, _ in
            model.saveSettings()
            Task { await model.refreshExpressionModels() }
        }
    }
}

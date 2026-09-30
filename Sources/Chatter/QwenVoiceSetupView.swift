import SwiftUI
import ChatterCore

struct QwenVoiceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name="New voice"
    @State private var kind:VoiceKind = .preset
    @State private var speaker="Aiden"
    @State private var description="A warm, clear adult voice, with an optimistic and conversational delivery."
    @State private var language="English"
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Create a Qwen voice").font(.title.bold())
            TextField("Saved voice name",text:$name).textFieldStyle(.roundedBorder)
            Picker("Voice source",selection:$kind) { Text("Built-in speaker").tag(VoiceKind.preset);Text("Design a voice").tag(VoiceKind.designed) }.pickerStyle(.segmented)
            if kind == .preset {
                Picker("Speaker",selection:$speaker) { ForEach(QwenCapabilities.speakers) { Text("\($0.id) — \($0.description)").tag($0.id) } }
            } else {
                Text("Describe the speaker’s timbre, age range, accent, and delivery. Voice design is generative; for a consistent character across scenes, save a successful preview as a recorded voice.").foregroundStyle(.secondary)
                TextEditor(text:$description).frame(height:140).accessibilityLabel("Voice description")
            }
            Picker("Language",selection:$language) { ForEach(QwenCapabilities.languages,id:\.self) { Text($0).tag($0) } }
            Text("These voices support tone and natural-language delivery instructions. All synthesis runs locally.").font(.callout).foregroundStyle(.secondary)
            HStack { Button("Cancel") { dismiss() };Spacer();Button("Create voice") { create() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width:660)
    }
    private func create() {
        do {
            let config=try QwenVoiceConfiguration(kind:kind,speaker:kind == .preset ? speaker : nil,description:kind == .designed ? description : nil,language:language).validated()
            let id=try model.createVoice(name:name)
            guard var voice=model.voices.first(where:{$0.id == id}) else { return }
            voice.qwen=config;model.updateVoice(voice);dismiss()
        } catch { model.error=error.localizedDescription }
    }
}

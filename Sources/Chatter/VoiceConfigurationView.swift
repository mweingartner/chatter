import SwiftUI
import ChatterCore

struct VoiceConfigurationView: View {
    @Environment(AppModel.self) private var model
    let voice:VoiceProfile
    @State private var language="Auto"
    @State private var description=""
    private let previewText="Welcome. There is so much we can achieve together. Let us take the next step with confidence."
    var body: some View {
        Surface {
            Text(voice.kind.title).font(.headline)
            Picker("Default language",selection:$language) { ForEach(QwenCapabilities.languages,id:\.self) { Text($0).tag($0) } }
            if voice.kind == .preset { LabeledContent("Speaker",value:voice.synthesisConfiguration.speaker ?? "") }
            if voice.kind == .designed { TextField("Voice description",text:$description,axis:.vertical).textFieldStyle(.roundedBorder) }
            Text(voice.kind.supportsInstructions ? "Supports tone presets and natural-language instructions." : QwenCapabilities.cloneDeliveryNotice).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Save voice settings") {
                    var v=voice;var c=v.synthesisConfiguration;c.language=language;if c.kind == .designed { c.description=description }
                    do { v.qwen=try c.validated();model.updateVoice(v) } catch { model.error=error.localizedDescription }
                }
                if voice.kind == .cloned { Button("Export fine-tuning dataset…") { exportDataset() }.disabled(voice.referenceSamples.isEmpty) }
                else { Button("Create preview WAV") { preview() }.disabled(!model.engine.ready) }
            }
            if voice.kind == .designed, let job=model.jobs.first(where:{$0.request.voice == voice.id && $0.state == "completed" && $0.request.text == previewText && $0.request.dialogue == nil}), let path=job.path {
                Button("Save this preview as a consistent recorded voice") { Task {
                    do { let id=try model.createVoice(name:voice.name+" (recorded)"); _ = await model.addSample(voiceID:id,source:URL(filePath:path),transcript:previewText,label:"Qwen designed reference") }
                    catch { model.error=error.localizedDescription }
                } }.disabled(model.preparing)
                Text("The recorded version preserves this speaker through reference conditioning. It inherits this delivery and no longer accepts tone instructions.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { refresh() }
        .onChange(of:voice.id) { _,_ in refresh() }
    }
    private func refresh() { language=voice.synthesisConfiguration.language;description=voice.synthesisConfiguration.description ?? "" }
    private func preview() {
        do { _ = try model.submit(SpeechRequest(voice:voice.id,text:previewText,mode:"save",tone:"optimistic",expressive:false),respell:false) }
        catch { model.error=error.localizedDescription }
    }
    private func exportDataset() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt="Export dataset here"
        guard panel.runModal() == .OK,let folder=panel.url else { return }
        do {
            let destination=folder.appending(path:"Chatter-Dataset-"+UUID().uuidString)
            try TrainingDataset.export(voice:voice,to:destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination]);model.notice="Dataset exported. Review transcripts before using Qwen’s external CUDA fine-tuning workflow."
        } catch { model.error=error.localizedDescription }
    }
}

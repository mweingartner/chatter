import SwiftUI
import UniformTypeIdentifiers
import ChatterCore

struct VoicesView: View {
    @Environment(AppModel.self) private var model
    @State private var setup: VoiceSetupRequest?
    @State private var qwenSetup = false
    @State private var selection: String?
    @State private var editingSample: SampleEdit?
    @State private var renamed = ""
    @State private var notes = ""
    struct SampleEdit: Identifiable { var id: String; var voiceID: String; var text: String }
    var selected: VoiceProfile? { model.voices.first { $0.id == selection } ?? model.voices.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { PageTitle(title: "Your voice library", subtitle: "Combine recordings of your voice, review transcripts, and compare the result."); Menu("Add voice",systemImage:"plus") { Button("Record or import my voice") { setup=VoiceSetupRequest(voiceID:nil) }; Button("Built-in or designed voice") { qwenSetup=true } }.buttonStyle(.borderedProminent) }
                if model.voices.isEmpty { ContentUnavailableView("Your voice starts here", systemImage: "person.wave.2", description: Text("Record a guided script or import clean audio. Everything stays on your Mac.")) }
                else {
                    Picker("Voice profile", selection: $selection) { ForEach(model.voices) { Text($0.name).tag(Optional($0.id)) } }.pickerStyle(.menu)
                    if let voice = selected {
                        Surface {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) { Text(voice.name).font(.title2.bold()); Text("\(voice.samples.count) reference recordings • Created \(voice.createdAt.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary).font(.caption) }
                                Spacer()
                                if voice.id == model.settings.defaultVoiceID { Label("Default", systemImage: "star.fill").foregroundStyle(.teal) }
                                else { Button("Make default") { model.settings.defaultVoiceID = voice.id; model.saveSettings() } }
                            }
                            HStack { TextField("Voice name", text: $renamed); Button("Rename") { var v = voice; v.name = renamed.trimmingCharacters(in: .whitespacesAndNewlines); if !v.name.isEmpty { model.updateVoice(v) } } }
                            HStack { TextField("Notes about this voice", text: $notes); Button("Save notes") { var v = voice; v.notes = notes; model.updateVoice(v) } }
                            HStack { if voice.kind == .cloned { Button("Add recordings", systemImage: "mic.badge.plus") { setup = VoiceSetupRequest(voiceID: voice.id) } }; Spacer(); Button("Remove profile", role: .destructive) { model.removeVoice(voice.id); selection = model.voices.first?.id } }
                        }
                        VoiceConfigurationView(voice:voice)
                        if voice.kind == .cloned {
                        Surface {
                            Text("Voice conditioning").font(.headline)
                            HStack {
                                Button { setMode(voice, useSet: true) } label: { Label("Use voice set", systemImage: voice.usesReferenceSet ? "checkmark.circle.fill" : "circle") }
                                Button { setMode(voice, useSet: false) } label: { Label("Use one take", systemImage: !voice.usesReferenceSet ? "checkmark.circle.fill" : "circle") }
                                Spacer()
                                Button("Preview voice set", systemImage: "waveform") { compare(voice: voice, sample: nil) }.disabled(!model.engine.ready || voice.referenceSamples.isEmpty || !voice.usesReferenceSet)
                            }
                            Text(voice.usesReferenceSet ? "\(voice.referenceSamples.count) of \(voice.samples.count) recordings included • \(Int(voice.referenceSamples.reduce(0) { $0 + $1.metrics.duration })) seconds together" : "Only the selected take conditions speech. Other recordings are saved for comparison.").foregroundStyle(.secondary)
                            if voice.usesReferenceSet {
                                Text("Every included recording and its transcript condition the same speaker. Mix guided reading styles and imports of the same person. This does not retrain the model’s weights.").font(.callout).foregroundStyle(.secondary)
                                if voice.referenceSamples.isEmpty { Label("Include at least one recording before speaking.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                                if voice.referenceSamples.reduce(0, { $0 + $1.metrics.duration }) > 90 { Text("Longer sets increase preparation and response time. More audio does not always improve likeness; compare a focused set of clean takes.").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        ForEach(voice.samples) { sample in
                            Surface {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sample.label).font(.headline)
                                        Text("\(sample.metrics.duration.formatted(.number.precision(.fractionLength(1)))) seconds • Recording health: \(Int(sample.metrics.score))/100").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if voice.usesReferenceSet {
                                        Button { toggleIncluded(voice, sample: sample) } label: {
                                            Label(voice.referenceSamples.contains { $0.id == sample.id } ? "Included in set" : "Excluded from set", systemImage: voice.referenceSamples.contains { $0.id == sample.id } ? "checkmark.square.fill" : "square")
                                        }.tint(voice.referenceSamples.contains { $0.id == sample.id } ? .teal : .secondary)
                                    }
                                    else if voice.selectedSample?.id == sample.id { Label("Selected take", systemImage: "checkmark.seal.fill").foregroundStyle(.teal) }
                                    else { Button("Use this take") { model.selectSample(voiceID: voice.id, sampleID: sample.id) } }
                                }
                                Text(sample.transcript).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                                ForEach(sample.metrics.warnings, id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button("Hear recording", systemImage: "play.circle") { preview(voice.sampleDirectory(sample).appending(path: "reference.wav")) }
                                    Button("Show original", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([voice.sampleDirectory(sample).appending(path: sample.originalFileName ?? "original.wav")]) }
                                    Button("Preview this take", systemImage: "waveform") { compare(voice: voice, sample: sample) }.disabled(!model.engine.ready)
                                    Button("Edit transcript", systemImage: "text.cursor") { editingSample = SampleEdit(id: sample.id, voiceID: voice.id, text: sample.transcript) }
                                }
                            }
                        }
                        Text("For the strongest likeness, use a quiet room, your usual microphone distance, and your normal voice. Use clean 10–30 second takes with exact transcripts. All included takes condition the voice set; exclude noisy or unrepresentative recordings. Recording health measures signal quality; your listening judgment determines likeness.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(30)
        }
        .onAppear { selection = model.defaultVoice?.id; refreshFields() }
        .onChange(of: selection) { _, _ in refreshFields() }
        .onChange(of: model.voices.count) { old, count in
            if count > old { selection = model.voices.last?.id }
            else if selection == nil { selection = model.voices.first?.id }
            refreshFields()
        }
        .sheet(isPresented:$qwenSetup) { QwenVoiceSetupView().environment(model) }
        .sheet(item: $setup) { request in VoiceSetupView(existingVoiceID: request.voiceID).environment(model) }
        .sheet(item: $editingSample) { edit in TranscriptEditor(edit: edit).environment(model) }
    }
    private func refreshFields() { renamed = selected?.name ?? ""; notes = selected?.notes ?? "" }
    private func preview(_ url: URL) { guard model.activeJobs == 0 else { model.error = "Wait for speech to finish before previewing a recording."; return }; model.playback.stop(); model.playback.enqueue(url) }
    private func setMode(_ voice: VoiceProfile, useSet: Bool) {
        var updated = voice; updated.useReferenceSet = useSet; model.updateVoice(updated)
        Task { await model.warmVoices() }
    }
    private func toggleIncluded(_ voice: VoiceProfile, sample: VoiceSample) {
        var updated = voice
        var excluded = Set(voice.excludedSampleIDs ?? [])
        if excluded.contains(sample.id) { excluded.remove(sample.id) } else { excluded.insert(sample.id) }
        updated.excludedSampleIDs = excluded.sorted(); model.updateVoice(updated)
        Task { await model.warmVoices() }
    }
    private func compare(voice: VoiceProfile, sample: VoiceSample?) {
        do { _ = try model.submit(SpeechRequest(voice: voice.id, text: "Here is a new sentence that was not in my recording. On a quiet morning, I enjoy taking a moment to think about what matters most.", quality: "studio", sampleID: sample?.id, expressive: false)) }
        catch { model.error = error.localizedDescription }
    }
}

struct TranscriptEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let edit: VoicesView.SampleEdit
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Match every spoken word").font(.title2.bold())
            Text("The transcript should match this recording exactly. Punctuation helps preserve its rhythm.").foregroundStyle(.secondary)
            TextEditor(text: $text).frame(height: 240).accessibilityLabel("Reference transcript")
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save transcript") { save() }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 640).onAppear { text = edit.text }
    }
    private func save() {
        guard var voice = model.voices.first(where: { $0.id == edit.voiceID }), let i = voice.samples.firstIndex(where: { $0.id == edit.id }) else { return }
        voice.samples[i].transcript = text
        do { try text.write(to: voice.sampleDirectory(voice.samples[i]).appending(path: "transcript.txt"), atomically: true, encoding: .utf8) }
        catch { model.error = error.localizedDescription; return }
        model.updateVoice(voice); Task { await model.warmVoices() }; dismiss()
    }
}

import SwiftUI
import UniformTypeIdentifiers
import ChatterCore

struct VoiceSetupRequest: Identifiable { let id = UUID(); let voiceID: String? }

struct VoiceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existingVoiceID: String?
    @State private var recorder = VoiceRecorder()
    @State private var name = "My voice"
    @State private var label = "Natural narration"
    @State private var source = "record"
    @State private var readFullSet = true
    @State private var savedReadings: Set<Int> = []
    @State private var imports: [AudioImport] = []
    @State private var importing = false
    struct AudioImport: Identifiable {
        let id = UUID()
        let url: URL
        var label: String
        var transcript: String
        var saved = false
    }
    private var busy: Bool { model.preparing || importing }
    private var canPrepare: Bool { source == "record" ? selectedURL != nil : imports.contains { !$0.saved } }
    private var prepareTitle: String {
        if source == "file" { return "Add recordings to voice set" }
        return readFullSet && savedReadings.union([scriptIndex]).count < Self.scripts.count ? "Save take & read next" : "Finish voice set"
    }
    @State private var scriptIndex = 0
    @State private var selectedURL: URL?
    @State private var transcript = ""
    @State private var localError: String?
    @State private var createdVoiceID: String?
    private static let scripts = [
        ("Natural narration", "Every voice tells a story. Mine carries the places I have been, the people I have met, and the things I care about. Today, I am reading at a comfortable pace, just as I would speak to a friend. There is no need to perform. A small pause, a clear thought, and a natural breath are enough."),
        ("Conversation & questions", "Have you ever noticed how a familiar voice can change your day? I was thinking about that this morning. The coffee was ready, the window was open, and the room was quiet. Then someone called to say hello. It was such a simple moment, but it made me smile. What would you like to do this afternoon?"),
        ("Expressive storytelling", "At first, the path looked ordinary. A few trees, a wooden fence, and sunlight on the grass. But just around the corner, the whole valley came into view. I stopped and took a breath. What a wonderful surprise! Some days, the best thing you can do is slow down and pay attention."),
        ("Numbers & clear instructions", "Let's review the plan. We will meet at nine thirty on Tuesday, October fifteenth. Bring three examples, a notebook, and any questions you want to discuss. The first session lasts forty-five minutes, followed by a short break. If something changes, call me before you leave. We can always find another time that works.")
    ]
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(existingVoiceID == nil ? "Create your voice" : "Add to your voice set").font(.title.bold()); Text("Build one voice from clean recordings of the same speaker.").foregroundStyle(.secondary) }; Spacer(); Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(busy || recorder.recording) }.padding(26)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if existingVoiceID == nil { TextField("Voice name", text: $name).textFieldStyle(.roundedBorder).disabled(createdVoiceID != nil || busy) }
                    Picker("Input", selection: $source) { Text("Read a guided script").tag("record"); Text("Import audio files").tag("file") }.pickerStyle(.segmented).disabled(recorder.recording || busy)
                    if source == "record" {
                        Toggle("Read all four styles into one voice set", isOn: $readFullSet).disabled(recorder.recording || busy)
                        if readFullSet { Text("\(savedReadings.count) of 4 reading styles available. New takes join the same voice set.").font(.caption).foregroundStyle(.secondary) }
                        Picker("Reading style", selection: $scriptIndex) { ForEach(Self.scripts.indices, id: \.self) { Text(Self.scripts[$0].0).tag($0) } }.disabled(recorder.recording || busy)
                        Text(Self.scripts[scriptIndex].1).font(.system(size: 22, weight: .medium, design: .serif)).lineSpacing(9)
                            .padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        HStack(spacing: 16) {
                            Button(recorder.recording ? "Finish recording" : "Start recording", systemImage: recorder.recording ? "stop.circle.fill" : "mic.circle.fill") { toggleRecording() }.buttonStyle(.borderedProminent).tint(recorder.recording ? .red : .teal).disabled(busy)
                            if recorder.recording { ProgressView(value: recorder.level).frame(width: 150).accessibilityLabel("Microphone level"); Text("\(Int(recorder.seconds)) s").monospacedDigit() }
                            else if selectedURL != nil { Label("Take recorded", systemImage: "checkmark.circle").foregroundStyle(.teal) }
                        }
                    } else {
                        Surface {
                            Label("Import recordings together", systemImage: "waveform.badge.plus").font(.headline)
                            Text("WAV, MP3, M4A/AAC, FLAC, AIFF, CAF and Ogg/Opus audio. Choose clean takes of one person without music or echo. Each file can be 3 seconds to 3 minutes. The enabled set must fit 180 seconds; focused 10–30 second takes respond faster.").foregroundStyle(.secondary)
                            Button("Choose audio files…", systemImage: "folder") { chooseFiles() }.disabled(busy)
                            Text("Matching .lab or .txt transcripts are loaded automatically. Blank transcripts use local transcription; review them after import.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach($imports) { $item in
                            Surface {
                                HStack {
                                    Text(item.url.lastPathComponent).font(.headline)
                                    Spacer()
                                    if item.saved { Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.teal) }
                                    else { Button("Remove", systemImage: "minus.circle") { imports.removeAll { $0.id == item.id } }.disabled(busy) }
                                }
                                TextField("Take label", text: $item.label).textFieldStyle(.roundedBorder).disabled(busy || item.saved)
                                TextEditor(text: $item.transcript).frame(height: 100).accessibilityLabel("Transcript for \(item.url.lastPathComponent)").disabled(busy || item.saved)
                            }
                        }
                    }
                    if source == "record" {
                        TextField("Take label", text: $label).textFieldStyle(.roundedBorder).disabled(busy)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What did you say?").font(.headline)
                            Text("The script is prefilled. Correct any words you changed while reading.").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $transcript).frame(height: 120).padding(8).background(.quinary, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Recording transcript").disabled(busy)
                        }
                    }
                    if let localError { Label(localError, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                    if model.preparing { HStack { ProgressView().controlSize(.small); Text(model.preparationMessage) }.foregroundStyle(.secondary) }
                }.padding(26)
            }
            Divider()
            HStack {
                Text("Local processing. Originals are preserved.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(prepareTitle, systemImage: "sparkles") { prepare() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canPrepare || recorder.recording || busy || !model.engine.ready || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(24)
        }.frame(width: 760, height: 780)
        .onAppear {
            if let voice = model.voices.first(where: { $0.id == existingVoiceID }) {
                savedReadings = Set(Self.scripts.indices.filter { index in voice.samples.contains { $0.label == Self.scripts[index].0 } })
                scriptIndex = Self.scripts.indices.first { !savedReadings.contains($0) } ?? 0
            }
            transcript = Self.scripts[scriptIndex].1; label = Self.scripts[scriptIndex].0
        }
        .onChange(of: scriptIndex) { _, i in transcript = Self.scripts[i].1; label = Self.scripts[i].0; selectedURL = nil }
        .onChange(of: source) { _, source in selectedURL = nil; transcript = source == "record" ? Self.scripts[scriptIndex].1 : "" }
        .onChange(of: recorder.recording) { _, active in if !active { selectedURL = recorder.url } }
        .onDisappear { recorder.stop() }
    }
    private func toggleRecording() {
        if recorder.recording { recorder.stop(); selectedURL = recorder.url }
        else { Task { do { try await recorder.start(); selectedURL = nil; localError = nil } catch { localError = error.localizedDescription } } }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio] + ["wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "caf", "ogg", "opus"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !imports.contains(where: { $0.url == url }) {
            let base = url.deletingPathExtension()
            let text = ["lab", "txt"].compactMap { try? String(contentsOf: base.appendingPathExtension($0), encoding: .utf8) }.first ?? ""
            imports.append(AudioImport(url: url, label: base.lastPathComponent, transcript: text))
        }
    }
    private func prepare() {
        guard canPrepare else { return }
        Task {
            importing = true; localError = nil
            defer { importing = false }
            do {
                let id: String
                if let existingVoiceID { id = existingVoiceID }
                else if let createdVoiceID { id = createdVoiceID }
                else { id = try model.createVoice(name: name); createdVoiceID = id }
                if source == "file" {
                    for index in imports.indices where !imports[index].saved {
                        let item = imports[index]
                        guard await model.addSample(voiceID: id, source: item.url, transcript: item.transcript, label: item.label.isEmpty ? "Imported recording" : item.label, warm: false) else {
                            localError = "\(item.url.lastPathComponent): \(model.error ?? "Import failed")"; return
                        }
                        imports[index].saved = true
                    }
                } else if let selectedURL {
                    guard await model.addSample(voiceID: id, source: selectedURL, transcript: transcript, label: label.isEmpty ? "Voice recording" : label, warm: false) else { localError = model.error; return }
                    savedReadings.insert(scriptIndex)
                }
                // Completing enrollment explicitly enables joint conditioning, even for a former single-take profile.
                if var voice = model.voices.first(where: { $0.id == id }) { voice.useReferenceSet = true; model.updateVoice(voice) }
                await model.warmVoices()
                if source == "record", readFullSet, let next = Self.scripts.indices.first(where: { !savedReadings.contains($0) }) {
                    scriptIndex = next; selectedURL = nil
                } else { dismiss() }
            } catch { localError = error.localizedDescription }
        }
    }
}

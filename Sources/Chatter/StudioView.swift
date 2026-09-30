import SwiftUI
import ChatterCore

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @State private var voiceID = ""
    @State private var text = "Hello. This is Chatter, speaking in my own voice. Everything you hear is created right here on this Mac."
    @State private var pace = 1.0
    @State private var quality = "responsive"
    @State private var mode = "play"
    @State private var tone: SpeechTone = .natural
    @State private var language = "Auto"
    @State private var instruction = ""
    private var supportsInstructions: Bool { model.voices.first { $0.id == voiceID }?.kind.supportsInstructions ?? false }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Make it sound like you.", subtitle: "Write something, choose your voice, and let Chatter speak — or save a studio-quality WAV.")
                Surface {
                    HStack {
                        Label("Speech studio", systemImage: "waveform").font(.headline)
                        Spacer()
                        Label(model.engine.ready ? "Ready" : model.engine.state.capitalized, systemImage: model.engine.ready ? "bolt.fill" : "hourglass").font(.caption).foregroundStyle(.teal)
                    }
                    Picker("Voice", selection: $voiceID) {
                        Text("Choose a voice").tag("")
                        ForEach(model.voices) { voice in Text(voice.name).tag(voice.id) }
                    }
                    Picker("Language",selection:$language) { ForEach(QwenCapabilities.languages,id:\.self) { Text($0).tag($0) } }
                    if supportsInstructions {
                        TonePicker(selection: $tone)
                        TextField("Delivery instruction (optional)",text:$instruction,axis:.vertical).textFieldStyle(.roundedBorder)
                        Text("Qwen interprets your words and this direction directly. No annotation model is needed.").font(.caption).foregroundStyle(.secondary)
                    } else { Text(QwenCapabilities.cloneDeliveryNotice).font(.callout).foregroundStyle(.secondary) }
                    TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(12)
                        .frame(minHeight: 170).background(.quinary, in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Text to speak")
                    HStack {
                        Text("\(text.count) characters").font(.caption).foregroundStyle(.secondary)
                        Spacer(); Text("Local processing • Private voice library").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Delivery").font(.subheadline.weight(.semibold))
                            Picker("Output", selection: $mode) { Text("Speak aloud").tag("play"); Text("Save WAV").tag("save") }.pickerStyle(.segmented)
                            if mode == "play" {
                                Picker("Quality", selection: $quality) { ForEach(SpeechQuality.allCases) { Text($0.title).tag($0.rawValue) } }
                                Text((SpeechQuality(rawValue: quality) ?? .responsive).detail).font(.caption).foregroundStyle(.secondary)
                            } else { Text(SpeechQuality.saveNotice).font(.caption).foregroundStyle(.secondary) }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Pace").font(.subheadline.weight(.semibold)); Spacer(); Text(pace.formatted(.number.precision(.fractionLength(2))) + "×").monospacedDigit() }
                            Slider(value: $pace, in: 0.5...2, step: 0.05) { Text("Speech pace") }.labelsHidden()
                            Text("Changes timing while preserving pitch.").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 230)
                    }
                    HStack {
                        Button(mode == "play" ? "Speak now" : "Save WAV", systemImage: mode == "play" ? "play.fill" : "square.and.arrow.down") { submit() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.engine.ready || voiceID.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                        if model.activeJobs > 0 { Button("Stop speech", systemImage: "stop.fill") { model.cancelAll() } }
                        Spacer()
                        if mode == "save" { Button("Open output folder", systemImage: "folder") { NSWorkspace.shared.open(URL(filePath: model.settings.outputDirectory)) }.buttonStyle(.link) }
                    }
                }
                if let job = model.jobs.first { JobCard(job: job) }
                if model.voices.isEmpty { ContentUnavailableView("Start with your voice", systemImage: "mic", description: Text("Open Your voices to record a guided script or import audio.")) }
            }.padding(30)
        }.background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            voiceID = model.defaultVoice?.id ?? ""; pace = model.settings.defaultPace; quality = model.settings.liveQuality; tone = SpeechTone(rawValue: model.settings.studioTone) ?? .natural
        }
        .onChange(of: tone) { _, value in model.settings.studioTone = value.rawValue; model.saveSettings() }
        .onChange(of: model.voices.count) { _, _ in if voiceID.isEmpty { voiceID = model.defaultVoice?.id ?? "" } }
    }
    private func submit() {
        do { _ = try model.submit(SpeechRequest(voice: voiceID, text: text, pace: pace, mode: mode, quality: quality, tone: supportsInstructions ? tone.rawValue : "natural", expressive: false, language: language, instruction: supportsInstructions ? instruction : nil)) }
        catch { model.error = error.localizedDescription }
    }
}

struct JobCard: View {
    @Environment(AppModel.self) private var model
    let job: SpeechJob
    var body: some View {
        Surface {
            HStack {
                Image(systemName: job.state == "completed" ? "checkmark.circle.fill" : job.isTerminal ? "exclamationmark.circle" : "waveform").foregroundStyle(job.state == "completed" ? .teal : .secondary)
                VStack(alignment: .leading, spacing: 5) { Text(job.voiceName).font(.headline); Text(job.message).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if !job.isTerminal { ProgressView().controlSize(.small); Button("Cancel") { model.cancelJob(job.id) } }
                if let path = job.path, job.state == "completed" { Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) } }
            }
            Text("Tone: \(job.request.effectiveTone.title)").font(.caption).foregroundStyle(.secondary)
            ForEach(job.warnings ?? [],id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            ExpressionSummary(job: job)
            if let turns = job.dialogueTurns { Text("\(Set(turns.map(\.actor)).count) actors • \(turns.count) turns").font(.caption).foregroundStyle(.secondary) }
            else if let references = job.references { Text("\(references.count) reference recording\(references.count == 1 ? "" : "s") used").font(.caption).foregroundStyle(.secondary) }
            // Two lines show only the beginning, so only the beginning is annotated (cards redraw often).
            Text(job.expressionPlan.map { $0.annotate(String(job.request.text.prefix(600))).text } ?? job.request.text).lineLimit(2).font(.callout).foregroundStyle(.secondary)
            if let duration = job.duration {
                HStack {
                    Text("\(duration.formatted(.number.precision(.fractionLength(1)))) s audio")
                    if let first = job.firstAudioSeconds { Text("First audio: \(first.formatted(.number.precision(.fractionLength(2)))) s") }
                    if let elapsed = job.elapsedSeconds { Text("Generated in \(elapsed.formatted(.number.precision(.fractionLength(1)))) s") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

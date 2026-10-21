import SwiftUI
import ChatterCore
import ChatterSystemSpeech

/// Shown while a voice description asks for an accent or dialect. Qwen voice design can't
/// produce one, so this offers the two ways to start an accented voice from a speaker who has
/// it: an installed macOS voice (quick start) or a recording of a real person (best quality).
struct AccentVoiceOffer: View {
    @Environment(AppModel.self) private var model
    let description: String
    /// Name for the recorded voice this creates.
    let newVoiceName: String
    let language: String
    /// Whether the macOS-voice button is this view's primary action.
    var prominent = false
    /// Opens the recording sheet for a new recorded voice (name, accent name); nil hides that route.
    var recordInstead: ((String, String?) -> Void)?
    /// Called with the new voice's ID once it is ready.
    var onCreated: ((String) -> Void)?
    @State private var installed: [SystemVoiceOption] = []
    @State private var choice: String?
    @State private var creating = false

    private var accent: VoiceAccent? { VoiceAccents.requested(in: description) }
    private var options: [SystemVoiceOption] {
        guard let accent else { return [] }
        return SystemVoiceOption.candidates(for: accent, gender: VoiceGender.requested(in: description), among: installed)
    }

    var body: some View {
        if QwenCapabilities.describesAccent(description) {
            VStack(alignment: .leading, spacing: 12) {
                Label { Text(headline) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .accessibilityElement(children: .combine)
                if let accent {
                    if options.isEmpty {
                        Text("No \(accent.name) macOS voice is installed. Add one in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices, then return here.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            Picker("macOS speaker", selection: $choice) {
                                ForEach(options) { Text($0.title).tag(Optional($0.id)) }
                            }
                            .fixedSize()
                            createButton(accent)
                            if creating { ProgressView().controlSize(.small).accessibilityLabel("Creating voice") }
                        }
                        Text("The new recorded voice sounds like this macOS speaker, accent included. Apple's license limits macOS voices to personal, non-commercial use: don't publish or share audio made with it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let recordInstead {
                    Button("Record or import a speaker…", systemImage: "mic.badge.plus") { recordInstead(newVoiceName, accent?.name) }
                        .disabled(creating)
                    Text("Best quality: 10–30 seconds of a real person with this accent. Only use recordings of someone who agreed to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .task { installed = await SystemVoiceList.shared.installed() }
            .onChange(of: options) { _, new in if !new.contains(where: { $0.id == choice }) { choice = new.first?.id } }
            .onAppear { if choice == nil { choice = options.first?.id } }
        }
    }

    private var headline: String {
        guard let accent else { return QwenCapabilities.designAccentNotice }
        let article = "aeiou".contains(accent.name.lowercased().prefix(1)) ? "an" : "a"
        return "Qwen voice design can't produce accents, so this would sound like standard American English. Start the voice from a speaker with \(article) \(accent.name) accent instead."
    }

    @ViewBuilder private func createButton(_ accent: VoiceAccent) -> some View {
        let button = Button("Create from macOS voice") { create(accent) }
            .disabled(creating || model.preparing || !model.engine.ready || choice == nil)
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }

    private func create(_ accent: VoiceAccent) {
        guard let voice = options.first(where: { $0.id == choice }) else { return }
        creating = true
        Task {
            defer { creating = false }
            if let id = await model.createVoice(name: newVoiceName, from: voice, accent: accent, language: language, description: description) {
                onCreated?(id)
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import ChatterCore

/// Pronunciations: how product names and acronyms should be said. Each entry maps a written form to a
/// respelling Chatter speaks instead; Preview plays a respelling (or the original spelling) so it can be
/// tuned by ear before it is used.
struct PronunciationsView: View {
    @Environment(AppModel.self) private var model
    @State private var written = ""
    @State private var sayAs = ""
    @State private var matchCase = false
    /// Once the user sets Match case, stop suggesting it from the spelling.
    @State private var matchCaseChosen = false
    @State private var editing: Pronunciation?
    @State private var voiceID = ""
    @State private var problem: String?
    /// An existing entry the typed written form collides with, offered for editing.
    @State private var conflicting: Pronunciation?
    @State private var previewJobID: String?
    @State private var recentlyDeleted: Pronunciation?
    @State private var filter = ""
    @State private var importing = false
    @State private var exporting = false
    /// Draft respellings from the expression model for `suggestedFor`, and the request in progress.
    @State private var suggestions: [String] = []
    @State private var suggestedFor = ""
    @State private var suggestionNote: String?
    @State private var suggestionError: String?
    @State private var suggesting: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case written, sayAs }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageTitle(title: "Say it your way", subtitle: "Teach Chatter how to say product names and acronyms. Before speaking, Chatter swaps each written form below for how it should sound. Your text, receipts and captions keep the original spelling.")
                    Surface { editor }.id(Self.editorID)
                    Surface { list(scroller) }
                    Surface { PronunciationAssistantView() }
                }.padding(30)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if voiceID.isEmpty { voiceID = model.defaultVoice?.id ?? "" } }
        .onChange(of: model.voices.count) { _, _ in if !model.voices.contains(where: { $0.id == voiceID }) { voiceID = model.defaultVoice?.id ?? "" } }
        .task { await model.refreshExpressionModels() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in importList(result) }
        .fileExporter(isPresented: $exporting, document: PronunciationsCSV(text: model.pronunciations.csv), contentType: .commaSeparatedText,
                      defaultFilename: "Chatter pronunciations") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
    }

    private static let editorID = "pronunciation-editor"

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editing.map { "Edit “\($0.written)”" } ?? "Add a pronunciation").font(.headline)
                Spacer()
                Picker("Preview voice", selection: $voiceID) {
                    if model.voices.isEmpty { Text("No voices yet").tag("") }
                    ForEach(model.voices) { voice in Text(voice.name).tag(voice.id) }
                }.frame(maxWidth: 260)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Written").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                    TextField("Written", text: $written, prompt: Text("Kubernetes")).textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityLabel("Written").accessibilityHint("The word or acronym as it appears in text")
                        .focused($focus, equals: .written).onSubmit { focus = .sayAs }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.bottom, 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Say it as").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                        Spacer()
                        Button("Suggest", systemImage: "wand.and.stars") { suggest() }
                            .buttonStyle(.borderless).controlSize(.small)
                            .disabled(isBlank(written) || suggesting != nil || !model.expressionStatus.isReady)
                            .help(model.expressionStatus.isReady ? "Ask \(model.settings.expressionModel) how “\(written)” is said. Suggestions can be wrong, so preview them."
                                  : "Suggestions need Ollama; open Optional pronunciation assistant below.")
                    }
                    TextField("Say it as", text: $sayAs, prompt: Text("koo-ber-NET-eez")).textFieldStyle(.roundedBorder).labelsHidden()
                        .accessibilityLabel("Say it as").accessibilityHint("How Chatter should say it, spelled as it sounds")
                        .focused($focus, equals: .sayAs).onSubmit { save() }
                }
            }
            suggestionRow
            HStack(spacing: 12) {
                Toggle("Match case", isOn: Binding(get: { matchCase }, set: { matchCase = $0; matchCaseChosen = true }))
                    .help("Only this exact capitalization is replaced. Use it for acronyms, so “IT” doesn’t change “it”.")
                if let editing {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(editing) }
                        .help("Delete this pronunciation")
                        .accessibilityLabel("Delete \(editing.written)")
                }
                Spacer()
                PreviewControl(canPreview: canPreview(sayAs), canHearOriginal: canPreview(written),
                               preview: { preview(sayAs) }, hearOriginal: { preview(written) })
                    .keyboardShortcut(.return, modifiers: .command)
                if editing != nil { Button("Cancel") { reset() }.keyboardShortcut(.cancelAction) }
                Button(editing == nil ? "Add" : "Save changes", systemImage: editing == nil ? "plus" : "checkmark") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBlank(written) || isBlank(sayAs))
            }
            if let problem {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let conflicting {
                        Button("Edit “\(conflicting.written)”") { edit(conflicting) }.buttonStyle(.link)
                    }
                }
            }
            if let unavailable = previewUnavailableReason {
                Label(unavailable.text, systemImage: unavailable.symbol).font(.caption).foregroundStyle(.secondary)
            }
            if let job = previewJob, !job.isTerminal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.state == "queued" ? "Waiting to preview…" : "Speaking “\(job.request.text)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop", systemImage: "stop.fill") { model.cancelJob(job.id) }.buttonStyle(.borderless).controlSize(.small)
                }
            }
            Text("Tips: separate syllables with hyphens and capitalize the stressed one (koo-ber-NET-eez). Spell initialisms with spaces (I B M). Only whole words change, so add forms like “APIs” as their own entries.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: written) { _, value in
            if !matchCaseChosen { matchCase = Pronunciation.suggestsMatchCase(for: value) }
            clearProblem()
            // Suggestions belong to one written form: a new spelling drops them and stops any request for the old one.
            if value.trimmingCharacters(in: .whitespaces) != suggestedFor { suggesting?.cancel(); suggestions = []; suggestionNote = nil; suggestionError = nil }
        }
        .onChange(of: sayAs) { _, _ in clearProblem() }
        .onChange(of: problem) { _, value in
            if let value { AccessibilityNotification.Announcement(value).post() }
        }
    }

    /// Suggestions for the written form, or the request for them in progress.
    @ViewBuilder private var suggestionRow: some View {
        if suggesting != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(model.settings.expressionModel) how to say “\(suggestedFor)”…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Stop", systemImage: "stop.fill") { suggesting?.cancel() }.buttonStyle(.borderless).controlSize(.small)
            }
        } else if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Suggestions for “\(suggestedFor)”").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { sayAs = suggestion; focus = .sayAs }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Use “\(suggestion)”, then preview it")
                            .accessibilityLabel("Use \(suggestion)")
                    }
                }
                Text("Drafts from \(model.settings.expressionModel): often close, sometimes wrong. Preview before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let suggestionError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(suggestionError).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        } else if let suggestionNote {
            Label(suggestionNote, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        } else if !isBlank(written), !model.expressionStatus.isReady {
            Label("Suggestions need Ollama. Open Optional pronunciation assistant below.", systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func suggest() {
        let term = written.trimmingCharacters(in: .whitespaces)
        suggestedFor = term; suggestions = []; suggestionNote = nil; suggestionError = nil
        suggesting = Task {
            defer { suggesting = nil }
            // Results count only for the word that is still in Written.
            func current() -> Bool { !Task.isCancelled && term == suggestedFor && term == written.trimmingCharacters(in: .whitespaces) }
            do {
                let found = try await model.suggestPronunciations(for: term)
                guard current() else { return }
                suggestions = found
                if found.isEmpty { suggestionNote = "No usable suggestion for “\(term)”. Try writing how it sounds." }
                AccessibilityNotification.Announcement(found.isEmpty ? suggestionNote ?? "" : "\(found.count) suggestion\(found.count == 1 ? "" : "s") for \(term)").post()
            } catch is CancellationError {
            } catch {
                guard current() else { return }
                suggestionError = "Couldn’t get suggestions. \(error.localizedDescription)"
                AccessibilityNotification.Announcement(suggestionError ?? "").post()
            }
        }
    }

    // MARK: List

    @ViewBuilder private func list(_ scroller: ScrollViewProxy) -> some View {
        let all = model.sortedPronunciations
        let rows = filtered(all)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(all.isEmpty ? "Your pronunciations" : all.count == 1 ? "1 pronunciation" : "\(all.count) pronunciations").font(.headline)
                Spacer()
                if all.count > 10 {
                    TextField("Filter", text: $filter, prompt: Text("Filter")).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        .accessibilityLabel("Filter pronunciations")
                }
                Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                    .help("Add or update pronunciations from a CSV file: written, say it as, match case")
                Button("Export…", systemImage: "square.and.arrow.up") { exporting = true }
                    .help("Save your pronunciations as a CSV file")
                    .disabled(all.isEmpty)
            }
            if let deleted = recentlyDeleted {
                HStack(spacing: 8) {
                    Image(systemName: "trash").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Deleted “\(deleted.written)”.").font(.callout)
                    Button("Undo") { restore(deleted) }.buttonStyle(.link)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { recentlyDeleted = nil }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(10).background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
            if all.isEmpty {
                ContentUnavailableView("No pronunciations yet", systemImage: "character.bubble",
                                       description: Text("Add names Chatter says incorrectly, such as Kubernetes → koo-ber-NET-eez or SQL → sequel, or import a CSV."))
                    .frame(maxWidth: .infinity)
            } else if rows.isEmpty {
                Text("No pronunciations match “\(filter)”.").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        PronunciationRow(entry: entry, isEditing: editing?.id == entry.id, canPreview: canPreview(entry.sayAs),
                                         preview: { preview(entry.sayAs) }, hearOriginal: { preview(entry.written) },
                                         edit: { edit(entry); withAnimation { scroller.scrollTo(Self.editorID, anchor: .top) } },
                                         delete: { delete(entry) })
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var previewJob: SpeechJob? { previewJobID.flatMap { id in model.jobs.first { $0.id == id } } }

    private var previewUnavailableReason: (text: String, symbol: String)? {
        if model.voices.isEmpty { return ("Add a voice in Your voices to hear previews.", "person.wave.2") }
        if !model.engine.ready { return ("Preview is available once the speech engine is ready.", "hourglass") }
        return nil
    }

    private func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func canPreview(_ text: String) -> Bool { model.engine.ready && !voiceID.isEmpty && !isBlank(text) }

    private func filtered(_ entries: [Pronunciation]) -> [Pronunciation] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard entries.count > 10, !query.isEmpty else { return entries }
        return entries.filter { $0.written.localizedCaseInsensitiveContains(query) || $0.sayAs.localizedCaseInsensitiveContains(query) }
    }

    private func preview(_ text: String) {
        if let id = model.previewPronunciation(text, voiceID: voiceID) { previewJobID = id }
    }

    private func save() {
        guard !isBlank(written), !isBlank(sayAs) else { return }
        do {
            try model.savePronunciation(Pronunciation(id: editing?.id ?? UUID(), written: written, sayAs: sayAs, matchCase: matchCase))
            reset()
            focus = .written
        } catch {
            problem = error.localizedDescription
            conflicting = model.pronunciations.entry(covering: written, matchCase: matchCase, excluding: editing?.id)
        }
    }

    private func edit(_ entry: Pronunciation) {
        editing = entry; written = entry.written; sayAs = entry.sayAs
        matchCase = entry.matchCase; matchCaseChosen = true
        problem = nil; conflicting = nil
        focus = .sayAs
    }

    private func delete(_ entry: Pronunciation) {
        guard model.removePronunciation(id: entry.id) else { return }
        if editing?.id == entry.id { reset() }
        recentlyDeleted = entry
    }

    private func restore(_ entry: Pronunciation) {
        do { try model.savePronunciation(entry); recentlyDeleted = nil }
        catch { model.error = "Couldn’t restore “\(entry.written)”. \(error.localizedDescription)" }
    }

    private func clearProblem() { problem = nil; conflicting = nil }

    private func reset() {
        editing = nil; written = ""; sayAs = ""; matchCase = false; matchCaseChosen = false
        suggesting?.cancel(); suggestions = []; suggestionNote = nil; suggestionError = nil
        clearProblem()
        // A fresh form starts at Written; focus elsewhere on the page stays put.
        if focus != nil { focus = .written }
    }

    private func importList(_ result: Result<URL, Error>) {
        do {
            let summary = try model.importPronunciations(from: result.get())
            if summary.added == 0, summary.updated == 0 { model.notice = "That file had no pronunciations to add."; return }
            let added = summary.added == 1 ? "1 pronunciation added" : "\(summary.added) pronunciations added"
            model.notice = summary.updated == 0 ? "\(added)." : "\(added), \(summary.updated) updated."
        } catch { model.error = "Import failed. \(error.localizedDescription)" }
    }
}

/// Preview, with "Hear original spelling" for comparison in its menu.
private struct PreviewControl: View {
    let canPreview: Bool
    let canHearOriginal: Bool
    let preview: () -> Void
    let hearOriginal: () -> Void
    var body: some View {
        Menu {
            Button("Preview respelling", systemImage: "play") { preview() }.disabled(!canPreview)
            Button("Hear original spelling", systemImage: "textformat") { hearOriginal() }.disabled(!canHearOriginal)
        } label: {
            Label("Preview", systemImage: "play.fill")
        } primaryAction: {
            preview()
        }
        .fixedSize()
        .disabled(!canPreview && !canHearOriginal)
        .help("Hear how Chatter says it in the selected voice. Use the menu to hear the original spelling for comparison.")
    }
}

/// One saved pronunciation. A separate view, so typing in the editor does not rebuild every row.
private struct PronunciationRow: View {
    let entry: Pronunciation
    let isEditing: Bool
    let canPreview: Bool
    let preview: () -> Void
    let hearOriginal: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.written).font(.body.weight(.semibold))
                    if entry.matchCase { Badge("Match case") }
                    if isEditing { Badge("Editing") }
                }
                Text(entry.sayAs).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.written), say it as \(entry.sayAs)\(entry.matchCase ? ", match case" : "")")
            .accessibilityAddTraits(isEditing ? .isSelected : [])
            Spacer()
            Menu {
                Button("Preview respelling", systemImage: "play") { preview() }
                Button("Hear original spelling", systemImage: "textformat") { hearOriginal() }
            } label: {
                Label("Preview", systemImage: "play.circle")
            } primaryAction: {
                preview()
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(!canPreview)
            .help("Preview. Use the menu to hear the original spelling for comparison.")
            .accessibilityLabel("Preview \(entry.written)")
            Button(action: edit) { Image(systemName: "pencil").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit").accessibilityLabel("Edit \(entry.written)")
            Button(role: .destructive, action: delete) { Image(systemName: "trash").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete").accessibilityLabel("Delete \(entry.written)")
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(isEditing ? Color.teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: edit)
            Button("Preview respelling", systemImage: "play", action: preview).disabled(!canPreview)
            Button("Hear original spelling", systemImage: "textformat", action: hearOriginal).disabled(!canPreview)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .padding(.horizontal, -8)
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2).background(.quinary, in: Capsule())
    }
}

/// The pronunciation list as a CSV document for export.
struct PronunciationsCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

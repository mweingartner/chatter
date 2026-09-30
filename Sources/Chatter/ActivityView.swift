import SwiftUI
import ChatterCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { PageTitle(title: "Activity", subtitle: "Requests from the studio, your AI tools, and other devices share one orderly queue."); Button("Cancel all") { model.cancelAll() }.disabled(model.activeJobs == 0) }
                HStack { Text("\(model.activeJobs) active • capacity \(model.settings.queueCapacity)").foregroundStyle(.secondary); Spacer(); Button("Archive finished activity", systemImage: "archivebox") { model.archiveFinishedJobs() }.disabled(!model.jobs.contains { $0.isTerminal }) }
                if model.jobs.isEmpty { ContentUnavailableView("Ready for your first request", systemImage: "clock", description: Text("Speech and WAV exports will appear here.")) }
                ForEach(model.jobs.prefix(100)) { JobCard(job: $0) }
            }.padding(30)
        }
    }
}

struct SavedAudioView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [URL] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Saved audio", subtitle: "Full-precision speech, ready to use anywhere. Files stay in the folder you choose.")
                Surface {
                    Text(model.settings.outputDirectory).font(.callout.monospaced()).textSelection(.enabled)
                    HStack { Button("Choose folder…", systemImage: "folder.badge.gearshape") { chooseFolder() }; Button("Open in Finder", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(URL(filePath: model.settings.outputDirectory)) }; Spacer(); Button("Refresh", systemImage: "arrow.clockwise") { refresh() } }
                    Label("24 kHz / 24-bit PCM WAV • Full Qwen precision", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                }
                if files.isEmpty { ContentUnavailableView("No WAV files yet", systemImage: "waveform", description: Text("Choose Save WAV in Studio, or send an API request with mode set to save.")) }
                ForEach(files, id: \.path) { file in
                    HStack {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(.teal)
                        Text(file.lastPathComponent).font(.callout).lineLimit(1)
                        Spacer()
                        Button("Play", systemImage: "play.fill") { if model.activeJobs == 0 { model.playback.stop(); model.playback.enqueue(file) } else { model.error = "Wait for active speech to finish." } }
                        Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(30)
        }.onAppear { refresh() }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.settings.outputDirectory = url.path; model.saveSettings(); refresh() }
    }
    private func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(at: URL(filePath: model.settings.outputDirectory), includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

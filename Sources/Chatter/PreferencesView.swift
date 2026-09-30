import SwiftUI
import ChatterCore

struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var page: String? = "studio"
    private let pages: [(String,String,String)] = [
        ("studio","Studio","waveform"),("dialogue","Dialogue","person.2.wave.2"),("voices","Your voices","person.wave.2"),("pronunciations","Pronunciations","character.bubble"),("expression","Expression","theatermasks"),("jobs","Activity","clock"),
        ("audio","Saved audio","folder"),("connections","Connections","network"),("engine","Speech engine","cpu"),("general","General","gearshape")]
    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.teal)
                    VStack(alignment: .leading) { Text("Chatter").font(.title2.bold()); Text("Your voice, always ready.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 14).padding(.top, 20)
                List(selection: $page) {
                    ForEach(pages, id: \.0) { item in Label(item.1, systemImage: item.2).tag(item.0).padding(.vertical, 5) }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.engine.ready ? "Models are warm" : model.engine.state.capitalized, systemImage: model.engine.ready ? "circle.fill" : "circle.dotted")
                        .font(.caption.weight(.semibold)).foregroundStyle(model.engine.ready ? .teal : .orange)
                    Text(model.serverStatus).font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    HStack { Image(systemName: "info.circle"); Text(notice).font(.callout); Spacer(); Button("Dismiss", systemImage: "xmark") { model.notice = nil }.labelStyle(.iconOnly).buttonStyle(.plain) }
                        .padding(12).background(.teal.opacity(0.1))
                }
                switch page {
                case "dialogue": DialogueView()
                case "voices": VoicesView()
                case "pronunciations": PronunciationsView()
                case "expression": ExpressionView()
                case "jobs": ActivityView()
                case "audio": SavedAudioView()
                case "connections": ConnectionsView()
                case "engine": EngineView()
                case "general": GeneralView()
                default: StudioView()
                }
            }
        }
        .tint(.teal)
        .alert("Chatter needs your attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(.quaternary) } }
}

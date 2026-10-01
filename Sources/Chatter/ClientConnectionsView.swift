import SwiftUI
import ChatterCore

struct ClientConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var canRead = true
    @State private var canSpeak = true
    @State private var canCancel = true
    @State private var days = 90
    @State private var voice = ""
    @State private var token: String?

    var body: some View {
        Surface {
            Text("Client access").font(.headline)
            Text("Give each integration its own expiring token. Clients can see and cancel only their own jobs. Revoke a token here without disconnecting other clients.").foregroundStyle(.secondary)
            ForEach(model.clients.filter { !$0.revoked }) { client in
                HStack {
                    VStack(alignment: .leading) {
                        Text(client.name).font(.headline)
                        Text("Expires \(client.expiresAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { model.revokeClient(client.id) }
                        .accessibilityLabel("Revoke access for \(client.name)")
                }
            }
            Divider()
            TextField("Client name", text: $name)
            HStack {
                Toggle("Read own jobs", isOn: $canRead)
                Toggle("Create speech", isOn: $canSpeak)
                Toggle("Cancel own jobs", isOn: $canCancel)
            }
            Picker("Allowed voices", selection: $voice) {
                Text("All saved voices").tag("")
                ForEach(model.voices) { Text($0.name).tag($0.id) }
            }
            Stepper("Expires after \(days) days", value: $days, in: 1...365)
            Button("Create client token") { create() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !(canRead || canSpeak || canCancel))
            if let token {
                Text("Save this token now. Chatter stores only its hash.").font(.callout.bold())
                Text(token).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                HStack {
                    Button("Copy client token") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string) }
                    Button("Done") { self.token = nil }
                }
            }
        }
        .onDisappear { token = nil }
    }
    private func create() {
        do {
            var scopes = Set<ClientScope>()
            if canRead { scopes.insert(.read) }; if canSpeak { scopes.insert(.speak) }; if canCancel { scopes.insert(.cancel) }
            token = try model.createClient(name: name, scopes: scopes, voiceIDs: voice.isEmpty ? [] : [voice], days: days)
            name = ""
        } catch { model.error = error.localizedDescription }
    }
}

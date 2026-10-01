import SwiftUI
import ServiceManagement
import ChatterCore

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Connect your tools", subtitle: "One voice service for this Mac and your local network. MCP works with Codex, Claude, and other compatible clients.")
                Surface {
                    Label(model.serverStatus, systemImage: "network").font(.headline)
                    Toggle("Allow devices on my local network", isOn: $model.settings.allowLAN)
                    HStack {
                        LabeledContent("Local port") { TextField("Local port", value: $model.settings.port, format: .number.grouping(.never)).labelsHidden() }
                        LabeledContent("LAN HTTPS port") { TextField("LAN HTTPS port", value: $model.settings.lanPort, format: .number.grouping(.never)).labelsHidden() }
                        Button("Apply connection settings") { model.applyNetwork() }
                    }
                    if model.settings.allowLAN {
                        LabeledContent("LAN HTTPS port", value: String(model.settings.lanPort))
                        Text(model.tlsFingerprint).font(.caption.monospaced()).textSelection(.enabled).accessibilityLabel("TLS certificate SHA-256 fingerprint")
                        HStack {
                            Button("Copy certificate fingerprint") { model.copyFingerprint() }
                            Button("Replace LAN identity") { model.replaceLANIdentity() }
                        }
                        Text("The certificate is valid for one year. Replace it here and update client fingerprints before expiry.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    LabeledContent("Local API", value: "http://127.0.0.1:\(model.settings.port)/v1")
                    LabeledContent("Local MCP", value: "http://127.0.0.1:\(model.settings.port)/mcp")
                    LabeledContent("LAN host", value: Host.current().localizedName ?? "Use this Mac's IP address")
                    HStack { Button("Copy connection token", systemImage: "key") { model.copyToken() }; Button("Replace token") { do { try model.rotateToken(); model.notice = "New token created. Update connections on other devices." } catch { model.error = error.localizedDescription } } }
                    Text("The local token works only on this Mac. LAN connections require HTTPS and a client token created below. Verify the certificate fingerprint on each connecting device. Playback happens on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                ClientConnectionsView()
                Surface {
                    Text("Portable MCP plugin").font(.headline)
                    Text("The Chatter plugin connects over stdio and forwards requests to this app. On another computer, set CHATTER_URL to the HTTPS address, CHATTER_TLS_SHA256 to the verified fingerprint, and provide a client token file. Clients with native HTTP MCP support can connect directly to /mcp.").foregroundStyle(.secondary)
                    HStack {
                        Button("Open integration files", systemImage: "folder") {
                            let bundled = Bundle.main.resourceURL?.appending(path: "Integration")
                            if let bundled { NSWorkspace.shared.open(bundled) }
                        }
                        Button("Open API reference", systemImage: "doc.text") { if let url = Bundle.main.resourceURL?.appending(path: "docs/API.md") { NSWorkspace.shared.open(url) } }
                    }
                }
                Surface {
                    Text("Available tools").font(.headline)
                    ForEach([("chatter_status", "Readiness and queue size"),("chatter_voices", "Your local voice library"),("chatter_speak", "Speak or save a WAV"),("chatter_job", "Completion, timing, and audio URL"),("chatter_cancel", "Stop a request")], id: \.0) { item in LabeledContent(item.0, value: item.1).font(.callout) }
                }
            }.padding(30)
        }
    }
}

struct EngineView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Speech engine", subtitle: "Qwen3-TTS, running natively on Apple Silicon with MLX. The live speech model stays warm; the studio model loads when studio work needs it.")
                Surface {
                    HStack { Image(systemName: "cpu").font(.largeTitle).foregroundStyle(.teal); VStack(alignment: .leading, spacing: 6) { Text(model.engine.state.capitalized).font(.title2.bold()); Text(model.engine.detail).foregroundStyle(.secondary) }; Spacer(); if !model.engine.ready { ProgressView().controlSize(.small) } }
                    Divider()
                    LabeledContent("Recorded voices: Studio", value: "1.7B Base • BF16 full precision • " + (model.engine.loadedProfiles.contains("quality") ? "loaded" : "loads on demand"))
                    LabeledContent("Recorded voices: Responsive & Balanced", value: "0.6B Base • 8-bit weights" + (model.engine.loadedProfiles.contains("fast") ? " • loaded" : ""))
                    Text(SpeechQuality.sharedNotice).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Acceleration", value: "MLX for Swift / Metal")
                    LabeledContent("Memory in use", value: model.engine.footprintBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—")
                    LabeledContent("Qwen source", value: "022e286 · Pinned September 29, 2026")
                    LabeledContent("Built-in voices",value:"1.7B CustomVoice • 9 speakers • instruction control")
                    LabeledContent("Voice design",value:"1.7B VoiceDesign • descriptions and delivery instructions")
                    HStack {
                        Button("Restart engine", systemImage: "arrow.clockwise") { model.cancelAll(); model.engine.restart() }.disabled(model.installing)
                        Button("Download / repair models", systemImage: "arrow.down.circle") { model.installModels() }.disabled(model.installing || model.activeJobs > 0)
                        Button("Show engine log", systemImage: "doc.text") { model.engine.refreshLog() }
                    }
                }
                Surface {
                    Text("How voice setup works").font(.headline)
                    Text("Chatter prepares clean recordings, verifies their signal quality, saves exact transcripts, and caches their voice representations. All included recordings condition the same voice together. Read the guided styles or import audio in batches, review each transcript, and compare the complete set with individual takes.")
                    Text("Recorded voices use reference conditioning. Export reviewed recordings and exact transcripts from Your voices for the official Qwen fine-tuning workflow. Weight training requires a separate compatible CUDA environment; it does not run inside this Mac app.").font(.callout).foregroundStyle(.secondary)
                    Link("Read Qwen’s fine-tuning guide", destination: URL(string: "https://github.com/QwenLM/Qwen3-TTS/tree/main/finetuning")!)
                }
                Surface {
                    Toggle("Keep the studio model loaded", isOn: $model.settings.keepStudioLoaded)
                        .onChange(of: model.settings.keepStudioLoaded) { _, _ in model.saveSettings() }
                    Text("Keeps the 1.7B cloning model resident. Built-in and design models load when needed. Idle models are released after 10 minutes or under memory pressure; first use after release takes longer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.installing || !model.installLog.isEmpty {
                    Surface { Text("Model setup").font(.headline); if model.installing { ProgressView() }; Text(model.installLog).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if !model.engine.logTail.isEmpty { Surface { Text("Recent engine log").font(.headline); Text(model.engine.logTail).font(.caption.monospaced()).textSelection(.enabled) } }
            }.padding(30)
        }
    }
}

struct GeneralView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: "Make Chatter yours", subtitle: "Background availability, delivery defaults, and local storage.")
                Surface {
                    Toggle("Launch Chatter at login", isOn: $model.settings.launchAtLogin).onChange(of: model.settings.launchAtLogin) { _, value in model.setLogin(value) }
                    Text("macOS login status: \(model.loginStatus)").font(.caption).foregroundStyle(.secondary)
                    Text("Closing the window keeps Chatter available in the menu bar. The live speech model stays warm while the app is running.").font(.caption).foregroundStyle(.secondary)
                    Picker("Default live quality", selection: $model.settings.liveQuality) { ForEach(SpeechQuality.allCases) { Text($0.title).tag($0.rawValue) } }
                    HStack { Text("Default pace"); Slider(value: $model.settings.defaultPace, in: 0.5...2, step: 0.05); Text(model.settings.defaultPace.formatted(.number.precision(.fractionLength(2))) + "×").monospacedDigit() }
                    Stepper("Queue capacity: \(model.settings.queueCapacity) requests", value: $model.settings.queueCapacity, in: 100...10000, step: 100)
                    Text("Accepted requests are saved before acknowledgement and processed in order, including after a restart.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Stepper("Keep finished jobs for \(model.settings.retentionDays) days", value: $model.settings.retentionDays, in: 1...365)
                    Stepper("Keep at most \(model.settings.retainedJobLimit) finished jobs", value: $model.settings.retainedJobLimit, in: 100...10000, step: 100)
                    Stepper("Audio storage budget: \(model.settings.storageLimitGB) GB", value: $model.settings.storageLimitGB, in: 1...1000)
                    Stepper("Maximum speech per job: \(model.settings.maximumSpeechMinutes) minutes", value: $model.settings.maximumSpeechMinutes, in: 1...120)
                    Stepper("Generation time limit: \(model.settings.maximumGenerationMinutes) minutes", value: $model.settings.maximumGenerationMinutes, in: 1...240)
                    Stepper("Queued jobs per client: \(model.settings.clientQueueLimit)", value: $model.settings.clientQueueLimit, in: 1...1000)
                    Toggle("Also delete original audio when jobs expire", isOn: $model.settings.deleteExpiredAudio)
                    Text("History expires at the limits above. Exported WAVs are kept unless automatic audio deletion is enabled; kept files still count toward the storage budget. To preserve a file when deletion is enabled, copy it outside the output folder. Voice recordings are preserved. Clients may submit 60 jobs and make 600 API requests per minute.").font(.caption).foregroundStyle(.secondary)
                    Button("Clean up expired jobs now") { model.trimHistory() }
                    Button("Save preferences") { model.saveSettings(); model.persistJobs(); model.notice = "Preferences saved." }.buttonStyle(.borderedProminent)
                }
                Surface {
                    Text("Private by design").font(.headline)
                    Text("Voice recordings, transcripts, model weights, and generated audio live on this Mac. Downloads install the speech models; synthesis and transcription run locally. Your network token is stored in a file readable only by your user account.").foregroundStyle(.secondary)
                    Button("Open Chatter data folder", systemImage: "folder") { NSWorkspace.shared.open(ChatterPaths.root) }
                    Text("Chatter \(AppModel.appVersion) • Local Qwen3-TTS • Apache 2.0 model license").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(30)
        }
    }
}

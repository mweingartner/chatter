import SwiftUI
import ChatterCore

@main
struct ChatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    init() {
        let instance = AppModel()
        _model = State(initialValue: instance)
        Task { @MainActor in instance.start() }
    }
    var body: some Scene {
        Window("Chatter", id: "chatter") {
            PreferencesView().environment(model)
                .onAppear { model.start(); delegate.model = model }
                .frame(minWidth: 960, minHeight: 680)
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .appSettings) { OpenChatterButton() } }
        MenuBarExtra("Chatter", systemImage: "waveform.circle.fill") {
            Text(model.engine.ready ? "Chatter is ready" : model.engine.detail)
            OpenChatterButton()
            Divider()
            Text("\(model.activeJobs) active requests")
            Button("Stop all speech") { model.cancelAll() }.disabled(model.activeJobs == 0)
            Divider()
            Button("Quit Chatter") { model.stop(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

struct OpenChatterButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Chatter…") { openWindow(id: "chatter"); NSApplication.shared.activate(ignoringOtherApps: true) }
            .keyboardShortcut(",", modifiers: .command)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.setActivationPolicy(.accessory) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

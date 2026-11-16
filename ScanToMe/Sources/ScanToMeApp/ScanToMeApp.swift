import AppKit
import SwiftUI

@main
struct ScanToMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var scan: ScanModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _scan = StateObject(wrappedValue: ScanModel(app: model))
    }

    var body: some Scene {
        Window("Scan to me", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(scan)
                .onAppear {
                    model.launch()
                    scan.resumeOpenJob()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Genau ein Hauptfenster.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

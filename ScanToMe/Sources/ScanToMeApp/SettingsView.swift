import DocKit
import ScanCore
import SwiftUI

/// Einstellungen (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            Form { ScannerSection() }.formStyle(.grouped)
                .tabItem { Label("Scanner", systemImage: "scanner") }
            Form { LanguageSection(); APIKeySection(); CostSection(); StorageFolderSection() }.formStyle(.grouped)
                .tabItem { Label(loc("Allgemein", "General"), systemImage: "gearshape") }
            Form { FileNameSection() }.formStyle(.grouped)
                .tabItem { Label(loc("Dateiname", "File name"), systemImage: "textformat") }
            Form { DocumentTypesSection() }.formStyle(.grouped)
                .tabItem { Label(loc("Dokumenttypen", "Document types"), systemImage: "tag") }
        }
        // Beim Umschalten der Sprache alles neu aufbauen.
        .id(model.language)
        .frame(width: 720, height: 600)
        .onAppear {
            model.browser.start()
            model.prepareStorageFolder()
        }
    }
}

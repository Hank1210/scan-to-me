import AppKit
import ScanCore
import SwiftUI

/// Einrichtungsassistent beim ersten Start: Scanner, API-Schlüssel, Ablageordner, Dateiname und Typen.
struct SetupWizardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = Step.scanner

    enum Step: Int, CaseIterable {
        case scanner, apiKey, folder, naming

        var title: String {
            switch self {
            case .scanner: return loc("Scanner auswählen", "Choose scanner")
            case .apiKey: return loc("Inhaltserkennung einrichten", "Set up content recognition")
            case .folder: return loc("Ablageordner festlegen", "Choose storage folder")
            case .naming: return loc("Dateiname und Dokumenttypen", "File name and document types")
            }
        }

        var intro: String {
            switch self {
            case .scanner:
                return loc("Wählen Sie Ihren Drucker aus. Dabei wird sein Zertifikat festgehalten, damit die App "
                    + "später nur mit genau diesem Gerät spricht. Ein Testscan zeigt, ob alles funktioniert.",
                    "Choose your printer. Its certificate is saved so that the app only talks to exactly this "
                    + "device later. A test scan shows whether everything works.")
            case .apiKey:
                return loc("Geben Sie Ihren Anthropic API-Schlüssel ein. Sie können diesen Schritt überspringen; "
                    + "dann werden Scans nur mit Datum benannt.",
                    "Enter your Anthropic API key. You can skip this step; scans are then named by date only.")
            case .folder:
                return loc("Hier landen die fertigen PDFs. macOS fragt beim ersten Mal, ob die App auf den Ordner "
                    + "„Dokumente“ zugreifen darf. Bitte erlauben Sie das.",
                    "The finished PDFs are saved here. The first time, macOS asks whether the app may access the "
                    + "“Documents” folder. Please allow this.")
            case .naming:
                return loc("Die Vorgaben passen für die meisten Fälle. Eigene Dokumenttypen sind optional.",
                           "The defaults suit most cases. Custom document types are optional.")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Step.allCases, id: \.self) { s in
                            Capsule()
                                .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: s == step ? 28 : 14, height: 6)
                        }
                        Text(loc("Schritt \(step.rawValue + 1) von \(Step.allCases.count)", "Step \(step.rawValue + 1) of \(Step.allCases.count)"))
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                    Text(step.title).font(.title2.bold())
                    Text(step.intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 8)

            Form { content }
                .formStyle(.grouped)

            Divider()
            HStack {
                if step != .scanner {
                    Button(loc("Zurück", "Back")) { step = Step(rawValue: step.rawValue - 1)! }
                }
                Spacer()
                if let hint = blockingHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if step == .apiKey && !model.hasAPIKey {
                    Button(loc("Ohne Schlüssel fortfahren", "Continue without key")) { next() }
                }
                Button(step == .naming ? loc("Fertig", "Done") : loc("Weiter", "Next")) { next() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blockingHint != nil || (step == .apiKey && !model.hasAPIKey))
            }
            .padding(16)
        }
        .frame(width: 680, height: 640)
        .id(model.language)
        .onAppear { model.browser.start() }
        .onChange(of: step) { _, newStep in
            if newStep == .folder { model.prepareStorageFolder() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .scanner:
            LanguageSection()
            ScannerSection()
        case .apiKey: APIKeySection()
        case .folder: StorageFolderSection()
        case .naming:
            FileNameSection()
            DocumentTypesSection()
        }
    }

    /// Was fehlt, bevor es weitergeht.
    private var blockingHint: String? {
        switch step {
        case .scanner: return model.settings.hasScanner ? nil : loc("Bitte zuerst einen Scanner wählen.", "Please choose a scanner first.")
        case .apiKey: return nil
        case .folder: return model.folderReady ? nil : loc("Der Ordner ist noch nicht bereit.", "The folder is not ready yet.")
        case .naming: return model.customTypesValid ? nil : loc("Bitte die markierten Freifelder korrigieren oder leeren.", "Please correct or clear the marked custom fields.")
        }
    }

    private func next() {
        if step == .naming {
            model.finishSetup()
        } else {
            step = Step(rawValue: step.rawValue + 1)!
        }
    }
}

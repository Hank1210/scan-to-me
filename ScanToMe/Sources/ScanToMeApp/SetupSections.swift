import AppKit
import ScanCore
import SwiftUI

// Bausteine der Einrichtung. Sie stehen sowohl im Assistenten als auch in den Einstellungen (⌘,).

// MARK: - Sprache

struct LanguageSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IconSection(loc("Sprache", "Language"), systemImage: "globe") {
            Picker(loc("Sprache der App", "App language"), selection: $model.language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text(loc("Gilt sofort für die Fenster der App. Die Menüleiste wechselt nach einem Neustart der App. "
                     + "Claude schlägt die Bezeichnung im Dateinamen in dieser Sprache vor.",
                     "Applies to the app’s windows right away. The menu bar changes after restarting the app. "
                     + "Claude suggests the name part of the file name in this language."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Scanner

struct ScannerSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var manualHost = ""

    var body: some View {
        IconSection(loc("Gewählter Scanner", "Selected scanner"), systemImage: "printer") {
            if model.settings.useTestScanner {
                Text(loc("Test-Scanner (ohne Gerät, erzeugt Beispielseiten)", "Test scanner (no device, creates sample pages)"))
            } else if let scanner = model.scanner {
                Label(scanner.name, systemImage: "checkmark.circle.fill").font(.headline)
                Text(scanner.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(scanner.certificateSHA256.map { loc("Zertifikat", "Certificate") + ": \($0.prefix(16))…" }
                         ?? loc("Zertifikat: noch nicht festgehalten", "Certificate: not saved yet"))
                        .font(.caption.monospaced())
                    Spacer()
                    Button(loc("Neu festhalten", "Save again")) { model.repinCertificate() }
                }
                if !model.certificateMessage.isEmpty {
                    Text(model.certificateMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let caps = model.capabilities {
                    Text(caps.summary).font(.caption)
                }
            } else {
                Text(loc("Noch kein Scanner gewählt.", "No scanner selected yet.")).foregroundStyle(.secondary)
            }
        }

        IconSection(loc("Gefundene Scanner im Netzwerk", "Scanners found on the network"), systemImage: "wifi") {
            if model.browser.found.isEmpty {
                Text(model.browser.isSearching ? loc("Suche läuft …", "Searching …") : loc("Keine gefunden. Ist der Drucker eingeschaltet?", "None found. Is the printer switched on?"))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.browser.found, id: \.self) { address in
                HStack(spacing: 10) {
                    Image(systemName: "printer").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(address.name)
                        Text(address.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.scanner?.host == address.host && !model.settings.useTestScanner {
                        Label(loc("Gewählt", "Selected"), systemImage: "checkmark").foregroundStyle(.secondary)
                    } else {
                        Button(loc("Diesen verwenden", "Use this one")) { model.chooseScanner(address) }
                    }
                }
            }
            Button(loc("Erneut suchen", "Search again")) { model.browser.start() }
        }

        IconSection(loc("Adresse von Hand eingeben", "Enter address manually"), systemImage: "keyboard") {
            HStack {
                TextField(loc("Name oder IP-Adresse, z. B. EPSON123456.local", "Name or IP address, e.g. EPSON123456.local"),
                          text: $manualHost)
                    .inputField()
                    .labelsHidden()
                    .onSubmit(useManualHost)
                Button(loc("Übernehmen", "Apply"), action: useManualHost).disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        IconSection(loc("Testscan", "Test scan"), systemImage: "doc.viewfinder") {
            Text(loc("Legen Sie ein Blatt auf das Glas und starten Sie den Testscan.", "Place a sheet on the glass and start the test scan."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.isTestScanning ? loc("Testscan läuft …", "Test scan running …") : loc("Testscan", "Test scan")) { model.runTestScan() }
                    .disabled(model.isTestScanning || !model.settings.hasScanner)
                if model.isTestScanning { ProgressView().controlSize(.small) }
            }
            if !model.testScanMessage.isEmpty {
                Text(model.testScanMessage).font(.caption)
            }
            if let image = model.testScanImage {
                PageThumbnail(image: image, width: 160)
                    .padding(.vertical, 6)
            }
        }

        IconSection(loc("Scaneinstellungen", "Scan settings"), systemImage: "slider.horizontal.3") {
            Picker(loc("Auflösung", "Resolution"), selection: Binding(
                get: { model.settings.resolution },
                set: { model.settings.resolution = $0; model.objectWillChange.send() })) {
                Text(loc("200 dpi (kleinere Dateien)", "200 dpi (smaller files)")).tag(200)
                Text(loc("300 dpi (empfohlen)", "300 dpi (recommended)")).tag(300)
            }
            Toggle(loc("In Farbe scannen", "Scan in colour"), isOn: Binding(
                get: { model.settings.color },
                set: { model.settings.color = $0; model.objectWillChange.send() }))
            Toggle(loc("Leere Seiten im Einzug aussortieren", "Set aside blank pages from the feeder"), isOn: Binding(
                get: { model.settings.removeBlankPages },
                set: { model.settings.removeBlankPages = $0; model.objectWillChange.send() }))
            Text(loc("Aussortierte Seiten bleiben sichtbar und lassen sich mit „Doch übernehmen“ zurückholen.", "Pages set aside stay visible and can be brought back with “Keep after all”."))
                .font(.caption).foregroundStyle(.secondary)
        }

        IconSection(loc("Fehlersuche", "Troubleshooting"), systemImage: "stethoscope") {
            Text(loc("Die App protokolliert die Gespräche mit dem Scanner (Zeit, Anfrage, Antwort, Status; keine Bildinhalte). "
                     + "Hängt der Drucker, hilft das Protokoll bei der Ursachensuche.",
                     "The app logs its conversation with the scanner (time, request, response, status; no image content). "
                     + "If the printer hangs, the log helps find the cause."))
                .font(.caption).foregroundStyle(.secondary)
            Button(loc("Protokoll im Finder zeigen", "Show log in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([ScanLog.shared.url])
            }
        }

        IconSection(loc("Entwicklung", "Development"), systemImage: "hammer") {
            Toggle(loc("Test-Scanner verwenden (ohne Gerät)", "Use test scanner (no device)"), isOn: Binding(
                get: { model.settings.useTestScanner },
                set: { model.setTestScanner($0) }))
        }
    }

    private func useManualHost() {
        model.chooseScanner(host: manualHost)
        manualHost = ""
    }
}

// MARK: - API-Schlüssel

struct APIKeySection: View {
    @EnvironmentObject private var model: AppModel
    @State private var key = ""

    var body: some View {
        IconSection(loc("Anthropic API-Schlüssel", "Anthropic API key"), systemImage: "key") {
            Text(model.hasAPIKey ? loc("Ein Schlüssel ist im Schlüsselbund gespeichert.", "A key is stored in the keychain.") : loc("Noch kein Schlüssel gespeichert.", "No key stored yet."))
                .foregroundStyle(model.hasAPIKey ? .primary : .secondary)
            SecureField(model.hasAPIKey ? loc("Neuen Schlüssel eingeben", "Enter new key")
                                        : loc("Schlüssel eingeben (beginnt mit sk-ant-)", "Enter key (starts with sk-ant-)"), text: $key)
                .inputField()
                .labelsHidden()
                .onSubmit(save)
            HStack {
                Button(loc("Prüfen und speichern", "Check and save"), action: save)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCheckingKey)
                if model.hasAPIKey {
                    Button(loc("Gespeicherten Schlüssel prüfen", "Check saved key")) { model.recheckSavedAPIKey() }
                        .disabled(model.isCheckingKey)
                    Button(loc("Entfernen", "Remove"), role: .destructive) { model.removeAPIKey() }
                }
                if model.isCheckingKey { ProgressView().controlSize(.small) }
            }
            if !model.apiKeyMessage.isEmpty {
                Text(model.apiKeyMessage).font(.caption)
            }
        }
        Section {
            Text(loc("Mit dem Schlüssel liest Claude Sonnet 5.5 die gescannten Dokumente und schlägt den Dateinamen vor. "
                     + "Dafür werden die Scans an Anthropic übertragen. Ohne Schlüssel oder mit ausgeschalteter "
                     + "Inhaltserkennung verlässt kein Dokument diesen Mac. Einen Schlüssel erhalten Sie unter "
                     + "console.anthropic.com.",
                     "With the key, Claude Sonnet 5.5 reads the scanned documents and suggests the file name. "
                     + "For this, the scans are sent to Anthropic. Without a key, or with content recognition "
                     + "switched off, no document leaves this Mac. You can get a key at console.anthropic.com."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        model.checkAndSaveAPIKey(key)
        key = ""
    }
}

// MARK: - Kosten

struct CostSection: View {
    @State private var now = Date()

    var body: some View {
        let ledger = UsageLedger.shared
        let current = ledger.month(containing: now)
        let previous = ledger.previousMonth(before: now)
        IconSection(loc("Kosten der Inhaltserkennung", "Content recognition costs"), systemImage: "eurosign.circle") {
            LabeledContent(loc("Dieser Monat", "This month")) {
                Text(formatCost(current.costUSD) + " · " + requests(current.requests))
            }
            LabeledContent(loc("Letzter Monat", "Last month")) {
                Text(formatCost(previous.costUSD) + " · " + requests(previous.requests))
            }
            Text(loc("Richtwert aus den Angaben in den Antworten von Anthropic (Claude Sonnet 5.5: 2 $ je Million Eingabe-, "
                     + "10 $ je Million Ausgabe-Token). Maßgeblich ist die Abrechnung unter console.anthropic.com.",
                     "Estimate from the figures in Anthropic’s responses (Claude Sonnet 5.5: $2 per million input and "
                     + "$10 per million output tokens). Your bill at console.anthropic.com is what counts."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { now = Date() }
    }

    private func requests(_ n: Int) -> String {
        n == 1 ? loc("1 Anfrage", "1 request") : loc("\(n) Anfragen", "\(n) requests")
    }
}

// MARK: - Ablageordner

struct StorageFolderSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IconSection(loc("Ablageordner", "Storage folder"), systemImage: "folder") {
            Label { FileNameText(name: model.storageFolder.path(percentEncoded: false)) } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
            }
            HStack {
                Button(loc("Anderen Ordner wählen …", "Choose another folder …")) { model.chooseStorageFolder() }
                if model.storageFolder.standardizedFileURL != StorageFolder.defaultURL.standardizedFileURL {
                    Button(loc("Standard verwenden", "Use default")) { model.resetStorageFolder() }
                }
                Button(loc("Im Finder zeigen", "Show in Finder")) { model.revealStorageFolder() }.disabled(!model.folderReady)
            }
            if !model.folderMessage.isEmpty {
                Text(model.folderMessage).font(.caption)
                    .foregroundStyle(model.folderReady ? Color.secondary : Color.red)
            }
        }
    }
}

// MARK: - Dateiname

struct FileNameSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IconSection(loc("Aufbau des Dateinamens", "File name pattern"), systemImage: "textformat") {
            Picker(loc("Schema", "Pattern"), selection: $model.nameMode) {
                Text(loc("Standard: YY-MM-DD_Typ_Von_Name_ID", "Default: YY-MM-DD_Type_From_Name_ID")).tag(NameMode.twoDigit)
                Text(loc("Jahr vierstellig: YYYY-MM-DD_Typ_Von_Name_ID", "Four-digit year: YYYY-MM-DD_Type_From_Name_ID")).tag(NameMode.fourDigit)
                Text(loc("Eigene Reihenfolge: ", "Custom order: ") + model.customNameScheme.pattern).tag(NameMode.custom)
            }
            .pickerStyle(.radioGroup)
            if model.nameMode == .custom {
                NameSchemeEditor(scheme: $model.customNameScheme)
            }
            LabeledContent(loc("Beispiel", "Example")) {
                FileNameText(name: model.previewName())
            }
            LabeledContent(loc("Ohne Inhaltserkennung", "Without content recognition")) {
                FileNameText(name: model.previewScanName())
            }
        }
        Section {
            NameTokenLegend()
        }
    }
}

/// Eigene Reihenfolge der Bausteine: verschieben mit Pfeilen, entfernen mit ×, hinzufügen über das Menü.
/// Jahr (YY/YYYY) und Bindestriche im Datum haben eigene Schalter. Die ID ist Pflicht und lässt sich nur verschieben.
struct NameSchemeEditor: View {
    @Binding var scheme: FileNameScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(scheme.tokens.enumerated()), id: \.element) { index, token in
                        if index > 0 {
                            let sep = scheme.separator(between: scheme.tokens[index - 1].isDate, and: token.isDate)
                            Text(sep.isEmpty ? "·" : sep)
                                .font(.body.monospaced()).foregroundStyle(.secondary)
                                .help(sep.isEmpty ? loc("ohne Trennzeichen", "no separator") : "")
                        }
                        chip(token, index: index)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 16) {
                if let year = scheme.yearFormat {
                    Picker(loc("Jahr", "Year"), selection: Binding(get: { year }, set: { scheme.setYearFormat($0) })) {
                        Text(loc("zweistellig (YY)", "two digits (YY)")).tag(YearFormat.twoDigit)
                        Text(loc("vierstellig (YYYY)", "four digits (YYYY)")).tag(YearFormat.fourDigit)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Toggle(loc("Datumsteile mit Bindestrich verbinden", "Join date parts with a hyphen"), isOn: $scheme.dateDashes)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Menu {
                    ForEach(scheme.addable, id: \.self) { token in
                        Button("\(token.label) – \(token.meaning)") { scheme.add(token) }
                    }
                } label: {
                    Label(loc("Baustein hinzufügen", "Add part"), systemImage: "plus")
                }
                .fixedSize()
                .disabled(scheme.addable.isEmpty)
                Spacer()
                Button(loc("Auf Standard zurücksetzen", "Reset to default")) { scheme = .standard }
                    .controlSize(.small)
            }
        }
    }

    private func chip(_ token: NameToken, index: Int) -> some View {
        HStack(spacing: 2) {
            Button { scheme.move(token, by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help(loc("Nach vorn", "Move left"))
                .accessibilityLabel(loc("\(token.label) nach vorn", "Move \(token.label) left"))
            Text(token.label)
                .font(.body.monospaced().bold())
                .padding(.horizontal, 4)
            Button { scheme.move(token, by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(index == scheme.tokens.count - 1)
                .help(loc("Nach hinten", "Move right"))
                .accessibilityLabel(loc("\(token.label) nach hinten", "Move \(token.label) right"))
            if token != .id {
                Button { scheme.remove(token) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(loc("Entfernen", "Remove"))
                    .accessibilityLabel(loc("\(token.label) entfernen", "Remove \(token.label)"))
            } else {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .help(loc("Pflicht", "Required"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(token.isDate ? 0.10 : 0.18)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
    }
}

/// Erklärung der Bausteine, gut sichtbar statt als Kleingedrucktes.
struct NameTokenLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc("Was die Bausteine bedeuten", "What the parts mean"), systemImage: "info.circle")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(NameToken.allCases, id: \.self) { token in
                    GridRow {
                        Text(token.label).font(.body.monospaced().bold())
                        Text(token.meaning)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("• Datum: Rechnungs-, Brief- oder Befunddatum; ist keines erkennbar, das Scandatum.",
                         "• Date: invoice, letter or report date; if none is found, the scan date."))
                Text(loc("• Datumsteile direkt nebeneinander werden mit „-“ verbunden (abschaltbar), alles andere mit „_“.",
                         "• Date parts next to each other are joined with “-” (can be switched off), everything else with “_”."))
                Text(loc("• Nur die ID gewählt: Der Name ist immer „Scan_ID“.", "• Only the ID chosen: the name is always “Scan_ID”."))
                Text(loc("• Ohne Inhaltserkennung steht „Scan“ an Stelle von Typ, Von und Name.",
                         "• Without content recognition, “Scan” replaces type, sender and name."))
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Dokumenttypen

struct DocumentTypesSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        IconSection(loc("Feste Typen", "Built-in types"), systemImage: "tag") {
            ForEach(DocumentTypes.builtIn) { type in
                HStack(alignment: .firstTextBaseline) {
                    TypeBadge(code: DocumentTypes.displayCode(type.code)).frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(DocumentTypes.displayTitle(type))
                        Text(DocumentTypes.displayHint(type)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        IconSection(loc("Eigene Typen (bis zu drei, optional)", "Custom types (up to three, optional)"), systemImage: "tag.badge.plus") {
            Text(loc("Beschreiben Sie, welche Dokumente zu diesem Typ gehören. Der Text geht so an die Inhaltserkennung. "
                     + "Eigene Typen werden vor den festen Typen geprüft.",
                     "Describe which documents belong to this type. The text is passed to content recognition as written. "
                     + "Custom types are checked before the built-in types."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<DocumentTypes.maxCustomTypes, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        TextField(loc("Kürzel", "Code"), text: Binding(
                            get: { model.customTypeEntries[index].code },
                            set: { model.setCustomCode($0, at: index) }))
                            .font(.body.monospaced())
                            .labelsHidden()
                            .inputField()
                            .frame(width: 70)
                        TextField(loc("Hinweis, z. B. Steuerunterlagen: Steuerbescheide, Lohnsteuerbescheinigungen",
                                      "Description, e.g. Tax documents: tax assessments, payslips"),
                                  text: Binding(
                                    get: { model.customTypeEntries[index].hint },
                                    set: { model.setCustomHint($0, at: index) }),
                                  axis: .vertical)
                            .lineLimit(1...3)
                            .labelsHidden()
                            .inputField()
                    }
                    if let error = model.customTypeErrors[index] {
                        Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Eingabefeld

extension View {
    /// Weißes Eingabefeld mit Rahmen, damit man in den grauen Einstellungen sieht, wo man tippen kann.
    func inputField() -> some View {
        self.textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }
}

import ScanCore
import SwiftUI

/// Hauptfenster: Quelle und Schalter wählen, scannen, Seiten prüfen.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var scan: ScanModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmDiscard = false
    @State private var showLater = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !model.settings.hasScanner {
                notConfigured
            } else {
                options
                if let notice = scan.notice {
                    NoticeView(text: notice)
                }
                if scan.offerFolderChoice {
                    HStack {
                        Text(loc("Die Seiten bleiben im Scan erhalten. Wählen Sie einen Ordner, in den die App schreiben darf.",
                                 "The pages are kept in the scan. Choose a folder the app is allowed to write to."))
                            .font(.callout)
                        Spacer()
                        Button(loc("Anderen Ordner wählen …", "Choose another folder …")) {
                            model.chooseStorageFolder()
                            scan.offerFolderChoice = !model.folderReady
                        }
                    }
                }
                if let job = scan.job {
                    jobArea(job)
                } else if !scan.filed.isEmpty {
                    filedArea(scan.filed)
                } else {
                    startArea
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        // PDF-Dateien und Bilder ins Fenster ziehen.
        // Dateien aus dem Finder kommen als Datei, Fotos aus der Fotos-App als Bild bzw. Dateiversprechen.
        .onDrop(of: [.fileURL, .image, .pdf], isTargeted: $dropTargeted) { providers in
            guard scan.canAddFiles, !providers.isEmpty else { return false }
            scan.addDropped(providers)
            return true
        }
        .overlay {
            if dropTargeted && scan.canAddFiles {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .overlay(Label(loc("Loslassen zum Hinzufügen", "Drop to add"), systemImage: "plus.circle")
                        .font(.title2.bold()).padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Beim Umschalten der Sprache alles neu aufbauen.
        .id(model.language)
        .sheet(isPresented: $showLater) {
            LaterRecognitionView()
                .environmentObject(model)
                .environmentObject(scan)
        }
        .sheet(isPresented: $model.showSetupWizard) {
            SetupWizardView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .confirmationDialog(loc("Diesen Scan verwerfen?", "Discard this scan?"), isPresented: $confirmDiscard) {
            Button(loc("Verwerfen", "Discard"), role: .destructive) { scan.discard() }
            Button(loc("Abbrechen", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc("Alle \(ScanModel.pages(scan.job?.pages.count ?? 0)) dieses Scans werden gelöscht.",
                     "All \(ScanModel.pages(scan.job?.pages.count ?? 0)) of this scan will be deleted."))
        }
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text("Scan to me").font(.title.bold())
                Text(loc("Scannen, benennen, ablegen", "Scan, name, file"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !scannerName.isEmpty {
                Label(scannerName, systemImage: "printer")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Button { openSettings() } label: {
                Label(loc("Einstellungen", "Settings"), systemImage: "gearshape")
            }
            .help(loc("Einstellungen", "Settings"))
        }
    }

    private var scannerName: String {
        model.settings.useTestScanner ? loc("Test-Scanner", "Test scanner") : (model.scanner?.name ?? "")
    }

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("Es ist noch kein Scanner eingerichtet.", "No scanner has been set up yet.")).font(.title3)
            Button(loc("Einrichtung starten", "Start setup")) { model.showSetupWizard = true }
        }
    }

    // MARK: - Optionen

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                Text(loc("Quelle", "Source")).font(.body.weight(.medium))
                Spacer()
                Picker(loc("Quelle", "Source"), selection: $scan.source) {
                    Label(loc("Flachbett", "Flatbed"), systemImage: "rectangle.portrait").tag(ScanSource.platen)
                    if scan.feederAvailable {
                        Label(loc("Einzug", "Feeder"), systemImage: "doc.on.doc").tag(ScanSource.feeder)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(scan.isScanning)
            }
            Divider()
            recognitionRow
            Divider()
            OptionRow(systemImage: "rectangle.split.3x1",
                      title: loc("Stapel in einzelne Dokumente trennen", "Split batch into separate documents"),
                      detail: scan.effectiveMode == .claude
                        ? loc("Mehrere Schreiben in einem Durchgang werden einzeln abgelegt.",
                              "Several letters scanned in one go are filed separately.")
                        : scan.effectiveMode == .local
                        ? loc("Geht nur mit Claude. Lokal wird alles ein Dokument; mit Schere und „Verbinden“ lässt es sich danach aufteilen.",
                              "Only with Claude. Locally, everything becomes one document; you can split it afterwards with the scissors.")
                        : loc("Trennen braucht die Inhaltserkennung mit Claude.", "Splitting needs content recognition with Claude."),
                      isOn: $scan.splitBatch,
                      enabled: scan.effectiveMode == .claude)
            if scan.effectiveSplit {
                HStack(spacing: 8) {
                    Text(loc("Bei schwierigen Stapeln hilft ein Trennblatt zwischen den Dokumenten.",
                             "For difficult batches, a separator sheet between the documents helps."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(loc("Trennblatt drucken …", "Print separator sheet …")) { scan.openSeparatorSheet() }
                        .controlSize(.small)
                }
                .padding(.leading, 40)
            }
            dataSharingHint
        }
        .card()
    }

    /// Auswahl, womit der Inhalt erkannt wird: Aus, Lokal (Apple), Claude. Nicht verfügbare Arten sind
    /// ausgegraut, mit Grund darunter.
    private var recognitionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("Inhalt erkennen und benennen", "Recognise and name content")).font(.body.weight(.medium))
                HStack(spacing: 0) {
                    ForEach(RecognitionMode.allCases, id: \.self) { mode in
                        modeButton(mode)
                    }
                }
                .fixedSize()
                .disabled(scan.isScanning)
                Text(recognitionDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .onAppear { scan.refreshLocalStatus() }
    }

    private func modeButton(_ mode: RecognitionMode) -> some View {
        let selected = scan.recognitionMode == mode
        let available = scan.isAvailable(mode)
        return Button {
            scan.recognitionMode = mode
        } label: {
            Label(mode.label, systemImage: mode == .off ? "nosign" : mode == .local ? "lock.laptopcomputer" : "icloud")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 110)
                .background(Rectangle().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                .foregroundStyle(selected ? Color.white : (available ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .help(available ? "" : (mode == .local ? scan.localStatus.explanation
                                               : loc("Dafür fehlt der API-Schlüssel (Einstellungen → Allgemein).",
                                                     "This needs the API key (Settings → General).")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var recognitionDetail: String {
        var lines: [String] = []
        switch scan.recognitionMode {
        case .off:
            lines.append(loc("Scans werden nur mit dem Datum benannt.", "Scans are named by date only."))
        case .local:
            lines.append(scan.localAvailable
                ? loc("Apples Modell auf diesem Mac schlägt Typ, Absender, Name und Datum vor. Kostenlos, ohne Internet.",
                      "Apple’s model on this Mac suggests type, sender, name and date. Free, no internet.")
                : loc("Lokal ist gerade nicht möglich: ", "Local is not possible right now: ") + scan.localStatus.explanation
                    + loc(" Scans werden dann nur mit dem Datum benannt.", " Scans are then named by date only."))
        case .claude:
            lines.append(scan.claudeAvailable
                ? loc("Claude schlägt Typ, Absender, Name und Datum vor und kann Stapel trennen.",
                      "Claude suggests type, sender, name and date and can split batches.")
                : loc("Dafür fehlt der API-Schlüssel (Einstellungen → Allgemein).", "This needs the API key (Settings → General)."))
        }
        if scan.recognitionMode != .local && !scan.localAvailable {
            lines.append(loc("Lokal (Apple): ", "Local (Apple): ") + scan.localStatus.explanation)
        }
        return lines.joined(separator: " ")
    }

    /// Wann Dokumente den Mac verlassen. Trennen schickt nichts zusätzlich; entscheidend ist die Art der Erkennung.
    private var dataSharingHint: some View {
        let sends = scan.effectiveMode == .claude
        let text: String
        switch scan.effectiveMode {
        case .claude:
            text = loc("Die gescannten Seiten werden zur Erkennung an Anthropic (Claude) gesendet. Mit „Lokal“ oder „Aus“ "
                       + "bleibt alles auf diesem Mac.",
                       "The scanned pages are sent to Anthropic (Claude) for recognition. With “Local” or “Off”, "
                       + "everything stays on this Mac.")
        case .local:
            text = loc("Die Erkennung läuft auf diesem Mac. Nichts wird gesendet. Die Qualität der Erkennung ist geringer "
                       + "als bei externen Modellen; bitte Namen vor dem Ablegen kurz prüfen.",
                       "Recognition runs on this Mac. Nothing is sent. Recognition quality is lower than with external "
                       + "models; please check the names briefly before filing.")
        case .off:
            text = loc("Die Scans bleiben auf diesem Mac. Nichts wird an Anthropic gesendet.",
                       "The scans stay on this Mac. Nothing is sent to Anthropic.")
        }
        return Label(text, systemImage: sends ? "icloud.and.arrow.up" : "lock")
            .font(.body.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill((sends ? Color.blue : Color.green).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke((sends ? Color.blue : Color.green).opacity(0.5), lineWidth: 1))
            .padding(.top, 4)
    }

    // MARK: - Ohne Auftrag

    @ViewBuilder
    private var startArea: some View {
        VStack(spacing: 16) {
            if scan.isScanning {
                progress
            } else {
                Image(systemName: scan.effectiveSource == .feeder ? "doc.on.doc" : "doc.viewfinder")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(scan.effectiveSource == .feeder
                     ? loc("Legen Sie die Blätter in den Einzug oben am Drucker.", "Put the sheets in the feeder on top of the printer.")
                     : loc("Legen Sie die erste Seite mit der Schrift nach unten auf das Glas.", "Place the first page face down on the glass."))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Button { scan.scan() } label: {
                    Label(loc("Scannen", "Scan"), systemImage: "scanner")
                        .font(.title2.bold())
                        .frame(width: 240, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 6) {
                    Text(loc("oder", "or")).foregroundStyle(.secondary)
                    Button {
                        scan.chooseFiles()
                    } label: {
                        Label(loc("PDF oder Bild hinzufügen …", "Add PDF or image …"), systemImage: "doc.badge.plus")
                    }
                    Text(loc("(auch per Ziehen ins Fenster)", "(or drag into the window)"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .card()
        if !scan.isScanning && !scan.laterScans.isEmpty && scan.recognitionAvailable {
            laterCard
        }
    }

    /// Hinweis auf Scans, die ohne Inhaltserkennung abgelegt wurden.
    private var laterCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.laterScans.count == 1
                     ? loc("1 Scan wurde ohne Inhaltserkennung abgelegt.", "1 scan was saved without content recognition.")
                     : loc("\(scan.laterScans.count) Scans wurden ohne Inhaltserkennung abgelegt.",
                           "\(scan.laterScans.count) scans were saved without content recognition."))
                    .font(.body.weight(.medium))
                Text(loc("Claude kann sie nachträglich benennen.", "Claude can name them afterwards."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("Später erkennen …", "Recognise later …")) { showLater = true }
        }
        .card(padding: 14)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(scan.runStarted)))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(progressText)
                        Text("\(seconds) s").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button(loc("Abbrechen", "Cancel")) { scan.cancelScan() }
                    }
                    if seconds >= 90 {
                        Text(loc("Der Drucker braucht länger als üblich. Das kommt beim Epson gelegentlich vor: Er hält "
                             + "manchmal einige Minuten an, besonders vor dem ersten Blatt, und macht dann von selbst weiter. "
                             + "Bitte warten. Nach 5 Minuten bricht die App ab; bereits übernommene Seiten bleiben "
                             + "erhalten. Dann den Drucker aus- und wieder einschalten.",
                             "The printer is taking longer than usual. This happens with the Epson now and then: it "
                             + "sometimes pauses for a few minutes, especially before the first sheet, and then continues "
                             + "by itself. Please wait. After 5 minutes the app cancels; pages already kept are not lost. "
                             + "Then switch the printer off and on again."))
                            .font(.caption)
                    }
                }
            }
            if case .scanning(.feeder) = scan.phase {
                Text(loc("„Abbrechen“ beendet die Übernahme. Blätter, die der Drucker danach noch einzieht, werden nicht übernommen.",
                         "“Cancel” stops taking pages. Sheets the printer still feeds afterwards are not kept."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 14)
    }

    private var progressText: String {
        let next = (scan.job?.pages.count ?? 0) + 1
        if case .scanning(.feeder) = scan.phase {
            return loc("Einzug läuft – Seite \(next) wird eingezogen …", "Feeder running – feeding page \(next) …")
        }
        return loc("Seite \(next) wird gescannt. Das dauert etwa eine halbe Minute …",
                   "Scanning page \(next). This takes about half a minute …")
    }

    // MARK: - Mit Auftrag

    @ViewBuilder
    private func jobArea(_ job: ScanJob) -> some View {
        switch job.state {
        case .scanning: pagesArea(job)
        case .scanned: processingArea(job)
        case .ready: resultArea(job)
        }
    }

    @ViewBuilder
    private func pagesArea(_ job: ScanJob) -> some View {
        let included = job.includedPages.count
        let excluded = job.pages.count - included
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("\(ScanModel.pages(included)) übernommen", "\(ScanModel.pages(included)) kept")
                 + (excluded > 0 ? loc(", \(excluded) aussortiert", ", \(excluded) set aside") : ""))
                .font(.headline)
            PageGrid(job: job)
            if let fronts = scan.frontsAwaitingBacks {
                backsCard(fronts)
            } else if job.duplex != nil && !scan.isScanning {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.doc").foregroundStyle(Color.accentColor)
                    Text(loc("Vorder- und Rückseiten sind blattweise sortiert. Stimmt die Reihenfolge der Rückseiten nicht?",
                             "Front and back sides are sorted sheet by sheet. Back sides in the wrong order?"))
                        .font(.callout)
                    Spacer()
                    Button(loc("Rückseiten andersherum", "Reverse back sides")) { scan.flipDuplexBacks() }
                }
                .card(padding: 12)
            }
            if scan.isScanning {
                progress
            } else {
                HStack {
                    Button(loc("Verwerfen …", "Discard …"), role: .destructive) { confirmDiscard = true }
                    Spacer()
                    Button {
                        scan.chooseFiles()
                    } label: {
                        Label(loc("Datei hinzufügen …", "Add file …"), systemImage: "doc.badge.plus")
                    }
                    Button(scan.effectiveSource == .feeder ? loc("Weiter scannen (Einzug)", "Continue scanning (feeder)")
                                                           : loc("Weitere Seite (Flachbett)", "Another page (flatbed)")) {
                        scan.scan()
                    }
                    Button { scan.finish() } label: {
                        Label(loc("Fertig", "Done"), systemImage: "checkmark")
                            .font(.title3.bold())
                            .frame(minWidth: 140, minHeight: 32)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Nach einem Einzug-Durchgang: Rückseiten der Blätter scannen (manuell beidseitig).
    private func backsCard(_ fronts: FeederPass) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc("Rückseiten auch scannen?", "Scan the back sides too?")).font(.body.weight(.medium))
                Text(loc("Nehmen Sie die \(fronts.count) Blätter aus der Ablage, drehen Sie den Stapel als Ganzes um "
                         + "(Reihenfolge nicht ändern) und legen Sie ihn wieder in den Einzug. Die App sortiert danach "
                         + "Vorder- und Rückseiten zusammen; leere Rückseiten werden aussortiert.",
                         "Take the \(fronts.count) sheets from the output tray, turn the whole stack over (do not change "
                         + "the order) and put it back in the feeder. The app then sorts front and back sides together; "
                         + "blank back sides are set aside."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                scan.scanBacks()
            } label: {
                Label(loc("Rückseiten scannen", "Scan back sides"), systemImage: "scanner")
            }
            .controlSize(.large)
        }
        .card(padding: 14)
    }

    /// Texterkennung und PDF-Bau laufen, oder sind fehlgeschlagen (dann mit Wiederholen).
    @ViewBuilder
    private func processingArea(_ job: ScanJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ScanModel.pages(job.includedPages.count)).font(.headline)
            PageGrid(job: job)
            if case .processing(let text) = scan.phase {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
            } else {
                HStack {
                    Button(loc("Verwerfen …", "Discard …"), role: .destructive) { confirmDiscard = true }
                    Button(loc("Zurück zu den Seiten", "Back to pages")) { scan.backToPages() }
                    Spacer()
                    Button(loc("Jetzt verarbeiten", "Process now")) { scan.process() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.top, 20)
    }

    /// Ergebnisliste: erscheint immer vor dem Ablegen (Entscheidung 15.11.2026). Bei Stapeln ein Eintrag
    /// je Dokument, mit Trennen und Zusammenlegen.
    @ViewBuilder
    private func resultArea(_ job: ScanJob) -> some View {
        let documents = scan.proposals
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(documents.count > 1 ? loc("Ergebnis: \(documents.count) Dokumente", "Result: \(documents.count) documents")
                                         : loc("Ergebnis", "Result")).font(.title2.bold())
                Spacer()
                if let cost = recognitionCost(job) {
                    Text(cost).font(.caption).foregroundStyle(.secondary)
                }
                Text(loc("Ablage: ", "Saving to: ") + model.storageFolder.path(percentEncoded: false))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if documents.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            recognitionMissing(job)
                            Divider()
                            LabeledContent(loc("Dateiname", "File name")) {
                                FileNameText(name: scan.proposedName(at: nil))
                            }
                            LabeledContent(loc("Seiten", "Pages")) { Text("\(job.includedPages.count)") }
                        }
                        .card()
                    } else {
                        ForEach(Array(documents.enumerated()), id: \.element.firstPage) { index, document in
                            DocumentCard(index: index, documents: documents, scanDate: job.createdAt)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            if case .processing(let text) = scan.phase {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(text) }
            } else {
                HStack {
                    Button(loc("Verwerfen …", "Discard …"), role: .destructive) { confirmDiscard = true }
                        .disabled(scan.anyFiled)
                    Button(loc("Zurück zu den Seiten", "Back to pages")) { scan.backToPages() }
                        .disabled(scan.anyFiled)
                    Spacer()
                    Button(documents.count > 1 ? loc("Alle \(documents.count) ablegen", "Save all \(documents.count)")
                                               : loc("Ablegen", "Save")) { scan.fileDocuments() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Kosten der Inhaltserkennung dieses Scans (Richtwert aus den Antworten).
    private func recognitionCost(_ job: ScanJob) -> String? {
        guard let input = job.inputTokens, input > 0 else { return nil }
        return loc("Erkennung: ", "Recognition: ") + formatCost(UsageLedger.costUSD(input: input, output: job.outputTokens ?? 0)) + " ·"
    }

    /// Ohne Vorschlag: Inhaltserkennung war aus oder hat nicht geklappt. Dann wird mit Scandatum benannt.
    @ViewBuilder
    private func recognitionMissing(_ job: ScanJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = job.recognitionProblem {
                Text(loc("Hinweis: Inhalt nicht erkannt. \(problem) Der Scan wird mit dem Scandatum benannt.",
                         "Note: content not recognised. \(problem) The scan is named with the scan date."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(loc("Ohne Inhaltserkennung: Der Scan wird mit dem Scandatum benannt.",
                         "Without content recognition: the scan is named with the scan date.")).foregroundStyle(.secondary)
            }
            if scan.recognitionAvailable {
                Button((job.recognitionProblem == nil ? loc("Inhalt jetzt erkennen", "Recognise content now")
                                                      : loc("Inhalt erneut erkennen", "Recognise content again"))
                       + (scan.explicitMode == .local ? loc(" (lokal)", " (local)") : " (Claude)")) {
                    scan.recognizeAgain()
                }
                .disabled(scan.isScanning)
            }
        }
    }


    private func filedArea(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text(urls.count == 1 ? loc("Abgelegt", "Saved") : loc("\(urls.count) Dokumente abgelegt", "\(urls.count) documents saved"))
                    .font(.title2.bold())
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(urls, id: \.self) { url in
                    Label { FileNameText(name: url.lastPathComponent) } icon: {
                        Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                    }
                }
            }
            if let folder = urls.first?.deletingLastPathComponent() {
                Text(loc("im Ordner", "in the folder") + " \(folder.path(percentEncoded: false))").foregroundStyle(.secondary)
            }
            HStack {
                Button(loc("Im Finder zeigen", "Show in Finder")) { scan.revealFiled() }
                Spacer()
                Button(loc("Neuer Scan", "New scan")) { scan.startNew() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .card(padding: 20)
    }
}

/// Ein Dokument der Ergebnisliste: Seitenvorschauen mit Trennstellen, Angaben und Dateiname.
private struct DocumentCard: View {
    @EnvironmentObject private var scan: ScanModel
    let index: Int
    let documents: [DocumentProposal]
    let scanDate: Date

    private var document: DocumentProposal { documents[index] }
    private var count: Int { documents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TypeBadge(code: DocumentTypes.displayCode(document.typeCode))
                    Text(count > 1 ? loc("Dokument \(index + 1) von \(count)", "Document \(index + 1) of \(count)")
                                   : loc("Dokument", "Document")).font(.headline)
                    Text(document.pagesLabel).foregroundStyle(.secondary)
                    Spacer()
                    if document.filedName != nil {
                        Label(loc("Bereits abgelegt", "Already saved"), systemImage: "checkmark.circle").font(.callout)
                    } else if count > 1 {
                        mergeMenu
                    }
                }
                if document.splitConfidence == "niedrig" {
                    Text(loc("Hinweis: Bei diesem Dokument ist die Trennung unsicher. Prüfen Sie, ob die Seiten zusammengehören.",
                             "Note: the split for this document is uncertain. Check whether the pages belong together."))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if document.needsNaming == true {
                    HStack {
                        Text(loc("Hinweis: Die Seiten wurden geändert, die Angaben sind noch die alten.",
                                 "Note: the pages have changed; the details are still the old ones."))
                            .font(.callout)
                        if scan.recognitionAvailable {
                            Button(loc("Neu benennen", "Rename")) { scan.renamePending() }
                                .controlSize(.small).disabled(scan.isScanning)
                        }
                    }
                }
                pageStrip
                ProposalEditor(index: index, proposal: document, scanDate: scanDate)
                    .disabled(document.filedName != nil)
                Divider()
                LabeledContent(loc("Dateiname", "File name")) {
                    FileNameText(name: scan.proposedName(at: index))
                }
        }
        .card()
    }

    /// „Verbinden mit …“: das Dokument mit einem beliebigen anderen zusammenführen, auch über andere hinweg.
    private var mergeMenu: some View {
        Menu(loc("Verbinden mit …", "Join with …")) {
            ForEach(Array(documents.enumerated()), id: \.element.firstPage) { other, candidate in
                if other != index {
                    Button(loc("Dokument", "Document") + " \(other + 1): \(summary(candidate)) (\(candidate.pagesLabel))") {
                        scan.mergeDocument(index, with: other)
                    }
                    .disabled(candidate.filedName != nil)
                }
            }
        }
        .fixedSize()
        .controlSize(.small)
        .disabled(scan.isScanning)
        .help(loc("Gehören Seiten zusammen, die im Stapel nicht nebeneinander lagen, verbinden Sie die Dokumente hier.",
                  "If pages belong together that were not next to each other in the batch, join the documents here."))
    }

    private func summary(_ p: DocumentProposal) -> String {
        let parts = [DocumentTypes.displayCode(p.typeCode), p.sender, p.title].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Seiten des Dokuments nebeneinander; zwischen zwei Seiten lässt sich ein neues Dokument beginnen.
    private var pageStrip: some View {
        let pages = scan.pages(of: document)
        let numbers = document.pages
        return ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.element.file) { offset, page in
                    if offset > 0 {
                        Button {
                            scan.splitDocument(atPage: numbers[offset])
                        } label: {
                            Image(systemName: "scissors")
                        }
                        .help(loc("Hier trennen: Ab Seite \(numbers[offset]) beginnt ein neues Dokument",
                                  "Split here: a new document starts at page \(numbers[offset])"))
                        .accessibilityLabel(loc("Vor Seite \(numbers[offset]) trennen", "Split before page \(numbers[offset])"))
                        .buttonStyle(.borderless)
                        .disabled(scan.isScanning || document.filedName != nil)
                    }
                    VStack(spacing: 4) {
                        PageThumbnail(image: scan.thumbnail(for: page), width: 70)
                        Text(loc("S.", "p.") + " \(numbers.indices.contains(offset) ? numbers[offset] : 0)").font(.caption2)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
    }
}

/// Seitenübersicht. Aussortierte Seiten sind blass, durchgestrichen beschriftet und lassen sich zurückholen.
private struct PageGrid: View {
    @EnvironmentObject private var scan: ScanModel
    let job: ScanJob

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14)], spacing: 14) {
                ForEach(Array(job.pages.enumerated()), id: \.element.file) { index, page in
                    VStack(spacing: 4) {
                        PageThumbnail(image: scan.thumbnail(for: page), width: 110, dimmed: page.excluded)
                        Text(loc("Seite", "Page") + " \(index + 1)" + (page.source == .feeder ? loc(" · Einzug", " · feeder")
                                                                      : page.source == .file ? loc(" · Datei", " · file") : ""))
                            .font(.caption)
                        if let name = page.importedFrom {
                            Label(name, systemImage: page.original != nil ? "doc.text" : "photo")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 120)
                                .help(page.original != nil
                                      ? loc("PDF-Seite mit eigenem Text – wird unverändert übernommen", "PDF page with its own text – kept unchanged")
                                      : loc("Wird wie ein Scan verarbeitet", "Processed like a scan"))
                        }
                        if page.excluded {
                            Text(page.isSeparator == true ? loc("Trennblatt – aussortiert", "separator sheet – set aside")
                                 : (page.looksBlank ? loc("leer – aussortiert", "blank – set aside")
                                                    : loc("aussortiert", "set aside"))).font(.caption2)
                            Button(loc("Doch übernehmen", "Keep after all")) { scan.toggleExcluded(pageIndex: index) }
                                .controlSize(.small).disabled(scan.isScanning || job.state != .scanning)
                        } else {
                            Button(loc("Weglassen", "Leave out")) { scan.toggleExcluded(pageIndex: index) }
                                .controlSize(.small).disabled(scan.isScanning || job.state != .scanning)
                        }
                    }
                }
            }
            .padding(4)
        }
        .frame(minHeight: 220)
    }
}

/// Hinweis mit Text, nie nur über Farbe.
struct NoticeView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(loc("Hinweis: ", "Note: ") + text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.45), lineWidth: 1))
    }
}

/// Felder eines Dokuments: Typ, Absender, Bezeichnung, Datum. Jede Änderung wird sofort gespeichert.
private struct ProposalEditor: View {
    @EnvironmentObject private var scan: ScanModel
    let index: Int
    let proposal: DocumentProposal
    let scanDate: Date

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(loc("Typ", "Type")).foregroundStyle(.secondary)
                Picker(loc("Typ", "Type"), selection: Binding(
                    get: { proposal.typeCode },
                    set: { code in scan.updateProposal(at: index) { $0.typeCode = code } })) {
                    ForEach(scan.typeCatalog) { type in
                        Text("\(DocumentTypes.displayCode(type.code)) – \(type.isBuiltIn ? DocumentTypes.displayTitle(type) : type.hint)")
                            .tag(type.code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
            }
            GridRow {
                Text(loc("Von", "From")).foregroundStyle(.secondary)
                TextField(loc("Absender", "Sender"), text: Binding(
                    get: { proposal.sender },
                    set: { value in scan.updateProposal(at: index) { $0.sender = value } }))
            }
            GridRow {
                Text(loc("Name", "Name")).foregroundStyle(.secondary)
                TextField(loc("Kurzbezeichnung, z. B. Stromrechnung", "Short description, e.g. Electricity bill"), text: Binding(
                    get: { proposal.title },
                    set: { value in scan.updateProposal(at: index) { $0.title = value } }))
            }
            GridRow {
                Text(loc("Datum", "Date")).foregroundStyle(.secondary)
                HStack {
                    DatePicker(loc("Datum", "Date"), selection: Binding(
                        get: { proposal.documentDate ?? scanDate },
                        set: { value in scan.updateProposal(at: index) { $0.documentDate = value; $0.dateKind = "manuell" } }),
                               displayedComponents: .date)
                        .labelsHidden()
                    Text(dateSource).font(.caption).foregroundStyle(.secondary)
                    if proposal.documentDate != nil && proposal.dateKind == "manuell" {
                        Button(loc("Scandatum", "Scan date")) { scan.updateProposal(at: index) { $0.documentDate = nil; $0.dateKind = nil } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var dateSource: String {
        guard proposal.documentDate != nil else {
            return loc("Scandatum – kein Dokumentdatum erkannt", "Scan date – no document date found")
        }
        switch proposal.dateKind {
        case "manuell": return loc("von Ihnen geändert", "changed by you")
        case let kind?: return Self.dateKindNames[kind].map { loc(kind, $0) } ?? kind
        case nil: return loc("Dokumentdatum", "Document date")
        }
    }

    /// Die Datumsarten kommen von Claude auf Deutsch (feste Liste); hier die englische Anzeige.
    private static let dateKindNames = [
        "Rechnungsdatum": "Invoice date", "Briefdatum": "Letter date",
        "Befunddatum": "Report date", "Ausstellungsdatum": "Date of issue",
    ]
}

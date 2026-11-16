import AppKit
import UniformTypeIdentifiers
import ScanCore
import SwiftUI

/// Der Scanablauf im Hauptfenster: Durchgänge starten, Seiten anzeigen, Auftrag abschließen oder verwerfen.
@MainActor
final class ScanModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(ScanSource)
        /// Texterkennung, PDF-Bau oder Ablage; der Text beschreibt den Schritt.
        case processing(String)
    }

    private let app: AppModel
    let store = JobStore()

    @Published private(set) var phase = Phase.idle
    @Published private(set) var job: ScanJob?
    /// Hinweis nach einem Durchgang (Fehler, Abbruch, wieder aufgenommener Scan). Wird immer mit Text gezeigt.
    @Published var notice: String?
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    /// Zuletzt abgelegte Dateien (Bestätigung nach „Ablegen“).
    @Published private(set) var filed: [URL] = []
    /// Ohne Inhaltserkennung abgelegte Scans im Ablageordner („Später erkennen“).
    @Published private(set) var laterScans: [FiledScan] = []
    /// Der Ablageordner war nicht beschreibbar: „Anderen Ordner wählen“ anbieten.
    @Published var offerFolderChoice = false

    private var scanTask: Task<Void, Never>?
    private var lastRunSource: ScanSource = .platen
    /// Beginn des laufenden Durchgangs bzw. Zeitpunkt der letzten angekommenen Seite (für die Zeitanzeige).
    @Published private(set) var runStarted = Date()

    @Published var source: ScanSource { didSet { app.settings.scanSource = source } }
    @Published var recognitionMode: RecognitionMode { didSet { app.settings.recognitionMode = recognitionMode } }
    /// Stand des Apple-Modells; wird beim Öffnen des Fensters und vor jeder Erkennung neu ermittelt.
    @Published private(set) var localStatus: LocalModelStatus = LocalRecognizer.status()
    @Published var splitBatch: Bool { didSet { app.settings.splitBatch = splitBatch } }

    init(app: AppModel) {
        self.app = app
        source = app.settings.scanSource
        recognitionMode = app.settings.recognitionMode
        splitBatch = app.settings.splitBatch
        Self.removeLeftoverImportFolders()
    }

    /// Vorübergehende Kopien gezogener Fotos, die ein Absturz hinterlassen hat (`Scan-to-me/Import-…`).
    private static func removeLeftoverImportFolders() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scan-to-me", isDirectory: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("Import-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    var isScanning: Bool { phase != .idle }
    var feederAvailable: Bool { app.settings.useTestScanner || app.capabilities?.hasFeeder == true }
    /// Ohne Einzug am Gerät gilt immer das Flachbett.
    var effectiveSource: ScanSource { feederAvailable ? source : .platen }
    var claudeAvailable: Bool { app.hasAPIKey }
    var localAvailable: Bool { localStatus.isAvailable }

    func refreshLocalStatus() { localStatus = LocalRecognizer.status() }

    func isAvailable(_ mode: RecognitionMode) -> Bool {
        switch mode {
        case .off: return true
        case .local: return localAvailable
        case .claude: return claudeAvailable
        }
    }

    /// Was beim nächsten Scan tatsächlich passiert. Ist die gewählte Art gerade nicht verfügbar: nichts erkennen
    /// (nie stillschweigend auf eine andere Art ausweichen, schon gar nicht von lokal auf Claude).
    var effectiveMode: RecognitionMode { isAvailable(recognitionMode) ? recognitionMode : .off }
    var effectiveRecognize: Bool { effectiveMode != .off }
    /// Stapel trennen geht nur mit Claude.
    var effectiveSplit: Bool { splitBatch && effectiveMode == .claude }
    /// Für ausdrückliche Aktionen („Inhalt jetzt erkennen“, „Neu benennen“): die gewählte Art, bei „Aus“ zuerst lokal.
    /// Von „Lokal“ wird nie auf Claude ausgewichen.
    var explicitMode: RecognitionMode? {
        switch recognitionMode {
        case .claude: return claudeAvailable ? .claude : nil
        case .local: return localAvailable ? .local : nil
        case .off: return localAvailable ? .local : (claudeAvailable ? .claude : nil)
        }
    }
    var recognitionAvailable: Bool { explicitMode != nil }

    // MARK: - Start

    /// Offenen Auftrag nach einem Neustart wieder aufnehmen; leere Aufträge entfernen.
    /// Nimmt den neuesten offenen Auftrag wieder auf (nach Neustart oder nachdem einer abgelegt/verworfen wurde).
    /// Es wird nichts automatisch verarbeitet oder an Claude geschickt; der Nutzer entscheidet.
    func refreshLaterScans() {
        laterScans = LaterRecognition.candidates(in: app.storageFolder, scheme: app.fileNameScheme)
    }

    func resumeOpenJob() {
        refreshLaterScans()
        let open = store.all().filter { candidate in
            if candidate.pages.isEmpty {
                try? store.delete(candidate.id)
                return false
            }
            return true
        }
        guard job == nil, let next = open.first else { return }
        job = next
        loadThumbnails()
        let date = next.createdAt.formatted(date: .abbreviated, time: .shortened)
        let others = open.count - 1
        let more = others == 0 ? ""
            : others == 1 ? loc(" Danach ist noch 1 weiterer Scan offen.", " After that, 1 more scan is open.")
            : loc(" Danach sind noch \(others) weitere Scans offen.", " After that, \(others) more scans are open.")
        let pages = Self.pages(next.pages.count)
        switch next.state {
        case .scanning:
            notice = loc("Ein Scan vom \(date) mit \(pages) ist noch offen. "
                         + "Sie können weiter scannen, ihn abschließen oder verwerfen.",
                         "A scan from \(date) with \(pages) is still open. "
                         + "You can continue scanning, finish it or discard it.") + more
        case .scanned:
            notice = loc("Ein Scan vom \(date) mit \(pages) wurde noch nicht verarbeitet. "
                         + "Wählen Sie „Jetzt verarbeiten“ oder verwerfen Sie ihn.",
                         "A scan from \(date) with \(pages) has not been processed yet. "
                         + "Choose “Process now” or discard it.") + more
        case .ready:
            notice = loc("Ein Scan vom \(date) wartet noch auf das Ablegen.",
                         "A scan from \(date) is still waiting to be saved.") + more
        }
    }

    // MARK: - Scannen

    /// Wartet der nächste Einzug-Durchgang als Rückseiten zu diesen Vorderseiten?
    private var backsFor: FeederPass?

    /// „Rückseiten scannen“ ist möglich, wenn der letzte Durchgang ein Einzug war und seitdem nichts dazukam.
    var frontsAwaitingBacks: FeederPass? {
        guard !isScanning, feederAvailable, let job, job.state == .scanning, let pass = job.lastFeederPass,
              pass.count > 0, pass.start + pass.count == job.pages.count else { return nil }
        return pass
    }

    func scanBacks() {
        guard let pass = frontsAwaitingBacks else { return }
        backsFor = pass
        scan(forceFeeder: true)
    }

    /// Rückseiten andersherum einsortieren (falls sie beim Gerät in anderer Reihenfolge kommen).
    func flipDuplexBacks() {
        guard let job, job.duplex != nil, !isScanning else { return }
        do {
            self.job = try store.flipDuplexBacks(job.id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func scan(forceFeeder: Bool = false) {
        guard !isScanning, let service = makeService() else { return }
        let current: ScanJob
        do {
            current = try job ?? store.create()
        } catch {
            notice = loc("Der Scan konnte nicht angelegt werden", "The scan could not be created") + ": \(error.localizedDescription)"
            return
        }
        job = current
        filed = []
        notice = nil
        let settings = scanSettings(forceFeeder: forceFeeder)
        let startIndex = current.pages.count
        phase = .scanning(settings.source)
        lastRunSource = settings.source
        runStarted = Date()
        let runner = ScanRunner(scanner: service, store: store, removeBlankPages: app.settings.removeBlankPages)
        scanTask = Task { [weak self] in
            let result = await runner.run(jobID: current.id, settings: settings) { [weak self] updated in
                await self?.pageArrived(updated)
            }
            self?.finishRun(result, jobID: current.id, service: service)
            self?.recordPass(result, jobID: current.id, start: startIndex, source: settings.source)
        }
    }

    /// Nach einem Durchgang: Vorderseiten merken bzw. Rückseiten einsortieren. Passt die Zahl nicht, bleibt alles,
    /// wie es gescannt wurde (keine Seite geht verloren), mit Hinweis.
    private func recordPass(_ result: ScanRunResult, jobID: UUID, start: Int, source: ScanSource) {
        let fronts = backsFor
        backsFor = nil
        guard store.job(jobID) != nil else { return }
        if let fronts {
            if result.error == nil && result.pagesAdded == fronts.count {
                job = try? store.mergeDuplex(jobID, fronts: fronts)
                loadThumbnails()
                let text = loc("Vorder- und Rückseiten von \(fronts.count) Blättern wurden zusammengeführt.",
                               "Front and back sides of \(fronts.count) sheets were merged.")
                    + (result.blankPages > 0 ? " " + loc("Leere Rückseiten sind aussortiert.", "Blank back sides are set aside.") : "")
                notice = notice.map { $0 + " " + text } ?? text
            } else if result.pagesAdded > 0 {
                job = try? store.update(jobID) { $0.lastFeederPass = nil }
                let text = loc("Es kamen \(result.pagesAdded) Rückseiten für \(fronts.count) Vorderseiten. Die Seiten wurden "
                               + "deshalb nicht zusammengeführt; sie bleiben in der Scan-Reihenfolge erhalten.",
                               "\(result.pagesAdded) back sides arrived for \(fronts.count) front sides, so the pages were not "
                               + "merged; they stay in scan order.")
                notice = notice.map { $0 + " " + text } ?? text
            }
            return
        }
        // Nur ein vollständiger Einzug-Durchgang kann Vorderseiten für „Rückseiten scannen“ sein.
        let pass: FeederPass? = source == .feeder && result.error == nil && result.pagesAdded > 0
            ? FeederPass(start: start, count: result.pagesAdded) : nil
        job = try? store.update(jobID) { $0.lastFeederPass = pass }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func pageArrived(_ updated: ScanJob) {
        job = updated
        runStarted = Date()
        loadThumbnails()
    }

    private func finishRun(_ result: ScanRunResult, jobID: UUID, service: ScannerService) {
        phase = .idle
        scanTask = nil
        job = store.job(jobID)
        loadThumbnails()
        app.rememberCertificateIfNeeded(from: service)

        var parts: [String] = []
        if result.cancelled {
            parts.append(loc("Abgebrochen.", "Cancelled.") + " "
                         + (result.pagesAdded > 0
                            ? loc("\(Self.pages(result.pagesAdded)) wurden übernommen.", "\(Self.pages(result.pagesAdded)) were kept.")
                            : loc("Es wurde keine Seite übernommen.", "No page was kept.")))
            if lastRunSource == .feeder {
                parts.append(loc("Der Drucker zieht die übrigen Blätter eventuell noch ein. Diese werden nicht übernommen. "
                                 + "Warten Sie, bis er fertig ist, und legen Sie sie für „Weiter scannen“ wieder ein.",
                                 "The printer may still feed the remaining sheets. These are not kept. "
                                 + "Wait until it has finished and put them back in for “Continue scanning”."))
            }
        } else if let problem = result.problemMessage {
            parts.append(problem)
        }
        if result.blankPages > 0 {
            parts.append(result.blankPages == 1
                ? loc("1 leere Seite wurde aussortiert. Sie ist markiert und lässt sich zurückholen.",
                      "1 blank page was set aside. It is marked and can be brought back.")
                : loc("\(result.blankPages) leere Seiten wurden aussortiert. Sie sind markiert und lassen sich zurückholen.",
                      "\(result.blankPages) blank pages were set aside. They are marked and can be brought back."))
        }
        notice = parts.isEmpty ? nil : parts.joined(separator: " ")

        // Ein Auftrag ohne jede Seite wird nicht aufgehoben.
        if let job, job.pages.isEmpty {
            try? store.delete(job.id)
            self.job = nil
        }
    }

    // MARK: - Dateien hinzufügen

    /// Fragt nach Dateien (PDF oder Bild) und fügt sie als Seiten hinzu.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = loc("Hinzufügen", "Add")
        panel.message = loc("Wählen Sie PDF-Dateien oder Bilder. Sie werden wie gescannte Seiten verarbeitet.",
                            "Choose PDF files or images. They are processed like scanned pages.")
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    /// Ins Fenster gezogene Objekte: Dateien aus dem Finder direkt, Bilder aus der Fotos-App über eine
    /// vorübergehende Kopie (die Fotos-App liefert keine Datei, sondern schreibt das Bild erst auf Anfrage).
    /// Die Kopien werden nach dem Hinzufügen gelöscht; die Seiten liegen dann im Auftrag.
    func addDropped(_ providers: [NSItemProvider]) {
        let temp = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scan-to-me/Import-\(UUID().uuidString.prefix(8))", isDirectory: true)
        Task { [weak self] in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) {
                    if FileImport.isSupported(url) { urls.append(url) }
                } else if let url = await Self.copyRepresentation(of: provider, into: temp) {
                    urls.append(url)
                }
            }
            guard let self else { return }
            if urls.isEmpty {
                try? FileManager.default.removeItem(at: temp)
                self.notice = loc("Nur PDF-Dateien und Bilder lassen sich hinzufügen.", "Only PDF files and images can be added.")
                return
            }
            self.addFiles(urls) { try? FileManager.default.removeItem(at: temp) }
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func copyRepresentation(of provider: NSItemProvider, into folder: URL) async -> URL? {
        guard let type = FileImport.preferredType(among: provider.registeredTypeIdentifiers) else { return nil }
        let base = (provider.suggestedName ?? loc("Foto", "Photo")).replacingOccurrences(of: "/", with: "-")
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // Die gelieferte Datei gilt nur innerhalb dieses Aufrufs: sofort kopieren.
                guard let url else { continuation.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "jpg") : url.pathExtension
                let name = (base as NSString).pathExtension.isEmpty ? "\(base).\(ext)" : base
                // Eigener Unterordner je Bild, damit der Originalname (für die Seitenübersicht) bleibt.
                let sub = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let target = sub.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Kann gerade etwas hinzugefügt werden? (Ohne Scan oder während man noch Seiten sammelt.)
    var canAddFiles: Bool { !isScanning && (job == nil || job?.state == .scanning) }

    /// Fügt Dateien in der gewählten Reihenfolge an. Nicht unterstützte Dateien werden gemeldet, nichts halb übernommen.
    func addFiles(_ urls: [URL], completion: @escaping @MainActor () -> Void = {}) {
        guard canAddFiles, !urls.isEmpty else { completion(); return }
        let current: ScanJob
        do {
            current = try job ?? store.create()
        } catch {
            notice = loc("Der Scan konnte nicht angelegt werden", "The scan could not be created") + ": \(error.localizedDescription)"
            completion()
            return
        }
        filed = []
        phase = .processing(loc("Dateien werden hinzugefügt …", "Adding files …"))
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileImport.add(urls, to: current.id, store: store) }
            }.value
            completion()
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let added):
                self.job = added.job
                self.loadThumbnails()
                self.notice = added.pagesAdded == 1
                    ? loc("1 Seite hinzugefügt.", "1 page added.")
                    : loc("\(added.pagesAdded) Seiten hinzugefügt.", "\(added.pagesAdded) pages added.")
                if added.originalPages > 0 {
                    self.notice! += " " + loc("PDF-Seiten mit eigenem Text werden unverändert übernommen.",
                                              "PDF pages with their own text are kept unchanged.")
                }
            case .failure(let error):
                self.job = self.store.job(current.id)
                if let job = self.job, job.pages.isEmpty {
                    try? self.store.delete(job.id)
                    self.job = nil
                }
                self.notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Eine Verbindung je Drucker für alle Durchgänge. Ändert sich die Adresse oder das Zertifikat,
    /// wird die alte Verbindung geschlossen.
    private var escl: ESCLScanner?

    private func makeService() -> ScannerService? {
        if app.settings.useTestScanner {
            return TestScanner(delay: 1, feeder: TestScanner.sampleFeeder)
        }
        guard let address = app.settings.scanner else {
            notice = loc("Es ist noch kein Scanner eingerichtet.", "No scanner has been set up yet.")
            return nil
        }
        if let escl, escl.address == address { return escl }
        escl?.invalidate()
        let scanner = ESCLScanner(address: address)
        escl = scanner
        return scanner
    }

    private func scanSettings(forceFeeder: Bool = false) -> ScanSettings {
        let base = ScanSettings(source: .platen, resolution: app.settings.resolution, color: app.settings.color)
        return effectiveSource == .feeder || forceFeeder ? base.forFeeder(maxWidth: app.capabilities?.feederMaxWidth) : base
    }

    // MARK: - Seiten

    func toggleExcluded(pageIndex: Int) {
        guard let job, job.pages.indices.contains(pageIndex) else { return }
        do {
            self.job = try store.setExcluded(!job.pages[pageIndex].excluded, page: pageIndex, in: job.id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func thumbnail(for page: ScanPage) -> NSImage? { thumbnails[page.file] }

    private func loadThumbnails() {
        guard let job else { thumbnails = [:]; return }
        for page in job.pages where thumbnails[page.file] == nil {
            if let image = Thumbnails.make(url: store.pageURL(job, page)) {
                thumbnails[page.file] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    // MARK: - Abschluss

    /// „Fertig“: Seiten abschließen, dann Text erkennen und PDF bauen.
    func finish() {
        guard let job, !job.includedPages.isEmpty else {
            notice = loc("Es ist keine Seite zum Übernehmen markiert.", "No page is marked to be kept.")
            return
        }
        do {
            self.job = try store.update(job.id) { job in
                job.state = .scanned
                if job.shortID == nil { job.shortID = FileNamer.newID() }
            }
            notice = nil
            process()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Texterkennung und (wenn eingeschaltet) Inhaltserkennung. Danach wartet der Auftrag in der Ergebnisliste.
    func process() {
        guard let job, job.state == .scanned, !isScanning else { return }
        let processor = DocumentProcessor(store: store)
        let total = job.includedPages.count
        refreshLocalStatus()
        let mode: RecognitionMode = recognitionMode == .local ? .local : effectiveMode
        let recognize = mode != .off
        let split = effectiveSplit
        phase = .processing(loc("Text wird erkannt: Seite 1 von \(total) …", "Recognising text: page 1 of \(total) …"))
        Task { [weak self] in
            do {
                let text = try await processor.recognizeText(job: job) { [weak self] done, total in
                    await self?.setProcessing(done < total
                        ? loc("Text wird erkannt: Seite \(done + 1) von \(total) …", "Recognising text: page \(done + 1) of \(total) …")
                        : (recognize ? loc("Inhalt wird erkannt …", "Recognising content …") : loc("Fertig.", "Done.")))
                }
                let cleaned = try processor.removeSeparators(job: processor.store.job(job.id) ?? job, text: text)
                self?.reportSeparators(cleaned.removed, split: split)
                if recognize { await self?.runRecognition(jobID: job.id, text: cleaned.text, split: split, mode: mode) }
                self?.processingDone(jobID: job.id)
            } catch {
                self?.processingFailed(error)
            }
        }
    }

    private func reportSeparators(_ count: Int, split: Bool) {
        guard count > 0 else { return }
        var text = count == 1 ? loc("1 Trennblatt wurde erkannt und aussortiert.", "1 separator sheet was found and set aside.")
            : loc("\(count) Trennblätter wurden erkannt und aussortiert.", "\(count) separator sheets were found and set aside.")
        if !split {
            text += loc(" „Stapel trennen“ ist aus, deshalb bleibt alles ein Dokument.",
                        " “Split batch” is off, so everything stays one document.")
        }
        notice = text
    }

    /// Inhaltserkennung lokal oder mit Claude. Ein Fehlschlag bricht nichts ab: Dann bleibt der Datumsname mit Hinweis.
    private func runRecognition(jobID: UUID, text: [RecognizedPage]?, split: Bool, mode: RecognitionMode) async {
        guard let job = store.job(jobID) else { return }
        let types = DocumentTypes.recognitionOrder(custom: app.customTypes)
        if mode == .local {
            do {
                let analysis = try await DocumentProcessor(store: store).analyzeLocally(job: job, text: text, types: types)
                self.job = try? store.update(jobID) { job in
                    job.proposals = analysis.proposals
                    job.recognitionProblem = nil
                    job.recognizedLocally = true
                }
            } catch {
                record(jobID: jobID, problem: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            return
        }
        guard let key = KeychainStore.anthropicAPIKey.read() else {
            record(jobID: jobID, problem: loc("Es ist kein API-Schlüssel gespeichert.", "No API key is stored."))
            return
        }
        do {
            let analysis = try await DocumentProcessor(store: store).analyze(
                job: job, text: text, client: ClaudeClient(apiKey: key, ledger: .shared), types: types, split: split)
            self.job = try? store.update(jobID) { job in
                job.proposals = analysis.proposals
                job.recognitionProblem = nil
                job.inputTokens = (job.inputTokens ?? 0) + analysis.inputTokens
                job.outputTokens = (job.outputTokens ?? 0) + analysis.outputTokens
            }
        } catch is CancellationError {
            record(jobID: jobID, problem: loc("Abgebrochen.", "Cancelled."))
        } catch {
            record(jobID: jobID, problem: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func record(jobID: UUID, problem: String) {
        job = try? store.update(jobID) { $0.recognitionProblem = problem }
    }

    /// „Inhalt erkennen“ aus der Ergebnisliste: nach einem Fehlschlag oder wenn der Schalter aus war.
    func recognizeAgain() {
        refreshLocalStatus()
        guard let job, job.state == .ready, !isScanning, let mode = explicitMode else { return }
        let text = DocumentProcessor(store: store).savedText(job: job)
        let split = mode == .claude && splitBatch
        phase = .processing(loc("Inhalt wird erkannt …", "Recognising content …"))
        Task { [weak self] in
            await self?.runRecognition(jobID: job.id, text: text, split: split, mode: mode)
            self?.setIdle()
        }
    }

    private func setIdle() {
        phase = .idle
    }

    private func setProcessing(_ text: String) {
        phase = .processing(text)
    }

    private func processingDone(jobID: UUID) {
        phase = .idle
        job = try? store.update(jobID) { job in job.state = .ready }
    }

    private func processingFailed(_ error: Error) {
        phase = .idle
        notice = loc("Die Verarbeitung ist fehlgeschlagen", "Processing failed") + ": \(error.localizedDescription) "
            + loc("Die Seiten bleiben erhalten.", "The pages are kept.")
    }

    // MARK: - Ergebnisliste

    /// Die Dokumente des Auftrags (ein Eintrag ohne Trennung). Leer = ohne Inhaltserkennung.
    var proposals: [DocumentProposal] { job?.proposals ?? [] }
    var anyFiled: Bool { proposals.contains { $0.filedName != nil } }

    /// Ändert einen Vorschlag und speichert sofort, damit Änderungen einen Neustart überstehen.
    func updateProposal(at index: Int, _ change: (inout DocumentProposal) -> Void) {
        guard let job, var proposals = job.proposals, proposals.indices.contains(index),
              proposals[index].filedName == nil else { return }
        change(&proposals[index])
        self.job = try? store.update(job.id) { $0.proposals = proposals }
    }

    /// Typen für die Auswahl in der Ergebnisliste (feste zuerst).
    var typeCatalog: [DocumentType] { DocumentTypes.catalog(custom: app.customTypes) }

    private var filer: BatchFiler {
        BatchFiler(store: store, folder: app.storageFolder, scheme: app.fileNameScheme,
                   typeTitles: Dictionary(typeCatalog.map { ($0.code, DocumentTypes.displayTitle($0)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Vorgeschlagener Name, immer mit dem aktuellen Stand der Felder und dem aktuellen Jahresformat.
    func proposedName(at index: Int?) -> String {
        guard let job else { return "" }
        let proposal = index.flatMap { proposals.indices.contains($0) ? proposals[$0] : nil }
        return proposal?.filedName ?? filer.name(job: job, proposal: proposal)
    }

    /// Seiten eines Dokuments (für die Vorschauen).
    func pages(of proposal: DocumentProposal) -> [ScanPage] {
        guard let job else { return [] }
        let included = job.includedPages
        return proposal.pages.compactMap { included.indices.contains($0 - 1) ? included[$0 - 1] : nil }
    }

    /// Neues Dokument ab dieser Seite; danach werden beide Teile neu benannt.
    func splitDocument(atPage page: Int) {
        guard let job, let current = job.proposals, let changed = DocumentRanges.split(current, at: page) else { return }
        self.job = try? store.update(job.id) { $0.proposals = changed }
        renamePending()
    }

    /// Zwei beliebige Dokumente verbinden; danach wird das verbundene neu benannt.
    func mergeDocument(_ index: Int, with other: Int) {
        guard let job, let current = job.proposals,
              let changed = DocumentRanges.merge(current, index, with: other) else { return }
        self.job = try? store.update(job.id) { $0.proposals = changed }
        renamePending()
    }

    /// Fragt für jedes Dokument mit geändertem Seitenbereich die Benennung neu an (je ein kleiner Aufruf).
    /// Ohne Schlüssel oder bei Fehlern bleiben die bisherigen Angaben stehen und lassen sich von Hand ändern.
    func renamePending() {
        refreshLocalStatus()
        // Lokal erkannte Scans werden lokal neu benannt, nie über Claude.
        let mode: RecognitionMode? = job?.recognizedLocally == true ? (localAvailable ? .local : nil) : explicitMode
        guard let job, !isScanning, let mode else { return }
        let key = KeychainStore.anthropicAPIKey.read()
        if mode == .claude && key == nil { return }
        let pending = proposals.enumerated().filter { $0.element.needsNaming == true }
        guard !pending.isEmpty else { return }
        let processor = DocumentProcessor(store: store)
        let text = processor.savedText(job: job)
        let types = DocumentTypes.recognitionOrder(custom: app.customTypes)
        phase = .processing(pending.count == 1 ? loc("Benennung wird aktualisiert …", "Updating name …")
                                               : loc("Benennungen werden aktualisiert …", "Updating names …"))
        Task { [weak self] in
            guard let self else { return }
            var failed = false
            for (_, proposal) in pending {
                do {
                    let named: (proposal: DocumentProposal, inputTokens: Int, outputTokens: Int)
                    if mode == .local {
                        named = (try await processor.renameLocally(proposal, job: job, text: text, types: types), 0, 0)
                    } else {
                        named = try await processor.rename(proposal, job: job, text: text,
                                                           client: ClaudeClient(apiKey: key!, ledger: .shared), types: types)
                    }
                    self.job = try? self.store.update(job.id) { job in
                        guard let index = job.proposals?.firstIndex(where: { $0.shortID == proposal.shortID
                                                                             && $0.pages == proposal.pages }) else { return }
                        job.proposals?[index] = named.proposal
                        job.inputTokens = (job.inputTokens ?? 0) + named.inputTokens
                        job.outputTokens = (job.outputTokens ?? 0) + named.outputTokens
                    }
                } catch {
                    failed = true
                }
            }
            if failed {
                self.notice = loc("Die Benennung konnte nicht für alle geänderten Dokumente aktualisiert werden. "
                    + "Prüfen Sie die Angaben oder wählen Sie „Neu benennen“.",
                    "The name could not be updated for all changed documents. "
                    + "Check the details or choose “Rename”.")
            }
            self.phase = .idle
        }
    }

    /// Baut je Dokument das endgültige PDF (volle Auflösung, mit Angaben) und legt es ab. Erst wenn alle Dateien
    /// geprüft sind, wird der Auftrag gelöscht. Schlägt eines fehl, bleiben die schon abgelegten vermerkt.
    func fileDocuments() {
        guard let job, job.state == .ready, !isScanning else { return }
        if job.shortID == nil { self.job = try? store.update(job.id) { $0.shortID = FileNamer.newID() } }
        guard let current = self.job else { return }
        let filer = filer
        let text = DocumentProcessor(store: store).savedText(job: current)
        phase = .processing(loc("PDF wird erstellt und abgelegt …", "Creating and saving PDF …"))
        Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await filer.fileAll(job: current, text: text) { [weak self] number, total in
                    await self?.setProcessing(total == 1 ? loc("PDF wird erstellt und abgelegt …", "Creating and saving PDF …")
                                                         : loc("Dokument \(number) von \(total) wird abgelegt …",
                                                               "Saving document \(number) of \(total) …"))
                }
                try? self.store.delete(current.id)
                self.job = nil
                self.thumbnails = [:]
                self.filed = urls
                self.notice = nil
                self.offerFolderChoice = false
                self.refreshLaterScans()
            } catch {
                self.job = self.store.job(current.id)
                let done = self.proposals.filter { $0.filedName != nil }.count
                self.offerFolderChoice = Self.isFolderProblem(error)
                self.notice = loc("Ablegen fehlgeschlagen", "Saving failed") + ": \(error.localizedDescription) "
                    + (done == 0 ? "" : done == 1 ? loc("1 Dokument ist bereits abgelegt. ", "1 document has already been saved. ")
                                   : loc("\(done) Dokumente sind bereits abgelegt. ", "\(done) documents have already been saved. "))
                    + loc("Der Scan bleibt erhalten; Sie können es erneut versuchen.", "The scan is kept; you can try again.")
            }
            self.phase = .idle
        }
    }

    /// Aus der Ergebnisliste zurück zu den Seiten (z. B. um weiterzuscannen oder Seiten wegzulassen).
    func backToPages() {
        guard let job else { return }
        // Die Seiten können sich ändern; Text und Vorschläge werden danach neu ermittelt.
        // Trennblätter werden beim nächsten „Fertig“ neu erkannt.
        self.job = try? store.update(job.id) { job in
            job.state = .scanning
            job.fileName = nil
            job.proposals = nil
            job.recognitionProblem = nil
            job.forcedStarts = nil
            for index in job.pages.indices where job.pages[index].isSeparator == true {
                job.pages[index].isSeparator = nil
                job.pages[index].excluded = false
            }
        }
        notice = nil
    }

    func revealFiled() {
        guard !filed.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(filed)
    }

    /// Trennblatt als PDF erzeugen und in Vorschau öffnen (zum Ausdrucken).
    func openSeparatorSheet() {
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scan-to-me", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(loc("Trennblatt.pdf", "Separator sheet.pdf"))
            try SeparatorSheet.pdf().write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            notice = loc("Das Trennblatt konnte nicht erstellt werden", "The separator sheet could not be created")
                + ": \(error.localizedDescription)"
        }
    }

    /// Nur nach ausdrücklicher Bestätigung in der Oberfläche aufrufen.
    func discard() {
        guard let job else { return }
        try? store.delete(job.id)
        self.job = nil
        thumbnails = [:]
        notice = nil
        resumeOpenJob()
    }

    /// Nach dem Ablegen einen neuen Scan beginnen (oder den nächsten offenen Scan zeigen).
    /// Ordner fehlt, ist keiner oder nicht beschreibbar (statt eines Problems mit der Datei selbst).
    static func isFolderProblem(_ error: Error) -> Bool {
        if error is StorageFolderError { return true }
        let code = (error as? CocoaError)?.code
        return code == .fileWriteNoPermission || code == .fileWriteVolumeReadOnly || code == .fileWriteOutOfSpace
            || code == .fileNoSuchFile || code == .fileWriteUnknown
    }

    func startNew() {
        filed = []
        notice = nil
        resumeOpenJob()
    }


    static func pages(_ count: Int) -> String {
        count == 1 ? loc("1 Seite", "1 page") : loc("\(count) Seiten", "\(count) pages")
    }
}

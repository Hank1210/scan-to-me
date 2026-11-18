import AppKit
import Combine
import DocKit
import ScanCore
import SwiftUI

/// Zustand der App. Die Logik liegt in ScanCore; hier wird sie nur verbunden.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let browser = ScannerBrowser()
    private let keychain = KeychainStore.anthropicAPIKey
    private var cancellables: Set<AnyCancellable> = []

    @Published var showSetupWizard = false

    /// Sprache der Oberfläche. Umschalten wirkt sofort auf die Fenster; die Menüleiste (von macOS) nach Neustart.
    @Published var language: AppLanguage {
        didSet {
            settings.language = language
            Self.apply(language)
        }
    }

    static func apply(_ language: AppLanguage) {
        Localization.current = language
        // Für Texte von macOS selbst (Menüleiste, Dialoge, Datumsformat) beim nächsten Start.
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    // Scanner
    @Published private(set) var certificateMessage = ""
    @Published private(set) var testScanImage: NSImage?
    @Published private(set) var testScanMessage = ""
    @Published private(set) var isTestScanning = false

    // API-Schlüssel
    @Published private(set) var hasAPIKey = false
    @Published private(set) var apiKeyMessage = ""
    @Published private(set) var isCheckingKey = false

    // Ablage
    @Published private(set) var storageFolder: URL
    @Published private(set) var folderMessage = ""
    @Published private(set) var folderReady = false

    // Dateiname und Typen
    @Published var nameMode: NameMode { didSet { settings.nameMode = nameMode } }
    @Published var customNameScheme: FileNameScheme { didSet { settings.customNameScheme = customNameScheme } }

    /// Das gültige Schema für alle Dateinamen.
    var fileNameScheme: FileNameScheme {
        switch nameMode {
        case .twoDigit: return FileNameScheme(.twoDigit)
        case .fourDigit: return FileNameScheme(.fourDigit)
        case .custom: return customNameScheme
        }
    }
    @Published var customTypeEntries: [CustomTypeEntry] { didSet { settings.customTypeEntries = customTypeEntries } }

    init() {
        language = settings.language
        Self.apply(settings.language)
        storageFolder = settings.storageFolder
        nameMode = settings.nameMode
        customNameScheme = settings.customNameScheme
        customTypeEntries = settings.customTypeEntries
        hasAPIKey = keychain.read() != nil
        browser.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        browser.$found.sink { [weak self] found in self?.adoptRediscoveredScanner(found) }.store(in: &cancellables)
    }

    func launch() {
        if !settings.setupCompleted { showSetupWizard = true }
        if let scanner = settings.scanner {
            browser.start()
            // Fähigkeiten auffrischen (z. B. Einzugsbreite, die ältere Einrichtungen noch nicht gespeichert haben).
            Task { await loadCapabilities(of: scanner) }
        }
        // Ordner nur prüfen, wenn die Einrichtung schon durch ist; sonst fragt macOS zu früh nach „Dokumente“.
        if settings.setupCompleted { prepareStorageFolder() }
    }

    func finishSetup() {
        settings.setupCompleted = true
        showSetupWizard = false
        objectWillChange.send()
    }

    // MARK: - Scanner

    var scanner: ScannerAddress? { settings.scanner }
    var capabilities: ScannerCapabilities? { settings.scannerCapabilities }

    /// Wählt den Scanner, hält das Zertifikat fest und liest seine Fähigkeiten.
    func chooseScanner(_ address: ScannerAddress) {
        var unpinned = address
        unpinned.certificateSHA256 = nil
        settings.scanner = unpinned
        settings.scannerCapabilities = nil
        settings.useTestScanner = false
        testScanImage = nil
        testScanMessage = ""
        objectWillChange.send()
        pinCertificate(of: unpinned)
    }

    /// Scanner von Hand eintragen, wenn die Suche nichts findet (eSCL über HTTPS, Port 443).
    func chooseScanner(host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        chooseScanner(ScannerAddress(name: host, host: host, port: 443, useTLS: true))
    }

    /// Fingerabdruck neu festhalten, z. B. nach Zurücksetzen oder Firmware-Update des Druckers.
    func repinCertificate() {
        guard var address = settings.scanner else { return }
        address.certificateSHA256 = nil
        settings.scanner = address
        pinCertificate(of: address)
    }

    private func pinCertificate(of address: ScannerAddress) {
        certificateMessage = loc("Zertifikat wird abgefragt …", "Requesting certificate …")
        Task {
            do {
                let probe = ESCLScanner(address: address)
                defer { probe.invalidate() }
                guard let fingerprint = try await probe.fetchCertificateFingerprint() else {
                    certificateMessage = address.useTLS
                        ? loc("Kein Zertifikat erhalten. Es wird beim ersten Scan festgehalten.",
                              "No certificate received. It will be saved during the first scan.")
                        : loc("Dieser Scanner verbindet sich ohne Verschlüsselung; es gibt kein Zertifikat.",
                              "This scanner connects without encryption; there is no certificate.")
                    await loadCapabilities(of: address)
                    return
                }
                guard var current = settings.scanner, current.host == address.host else { return }
                current.certificateSHA256 = fingerprint
                settings.scanner = current
                certificateMessage = loc("Zertifikat festgehalten.", "Certificate saved.")
                await loadCapabilities(of: current)
            } catch {
                certificateMessage = loc("Scanner nicht erreichbar. Ist er eingeschaltet und im selben Netzwerk? "
                    + "Das Zertifikat wird beim ersten Scan festgehalten.",
                    "Scanner not reachable. Is it switched on and on the same network? "
                    + "The certificate will be saved during the first scan.")
            }
            objectWillChange.send()
        }
    }

    private func loadCapabilities(of address: ScannerAddress) async {
        let probe = ESCLScanner(address: address)
        defer { probe.invalidate() }
        guard let caps = try? await probe.capabilities(),
              settings.scanner?.host == address.host else { return }
        settings.scannerCapabilities = caps
        objectWillChange.send()
    }

    /// Der Scanner hat im Netz eine neue Adresse bekommen: Host/Port übernehmen, Fingerabdruck behalten.
    private func adoptRediscoveredScanner(_ found: [ScannerAddress]) {
        guard let saved = settings.scanner,
              var match = found.first(where: { $0.name == saved.name }) else { return }
        match.certificateSHA256 = saved.certificateSHA256
        if match != saved { settings.scanner = match }
    }

    func setTestScanner(_ enabled: Bool) {
        settings.useTestScanner = enabled
        testScanImage = nil
        testScanMessage = ""
        objectWillChange.send()
    }

    /// Eine Seite vom Flachbett scannen und anzeigen.
    func runTestScan() {
        let service: ScannerService
        if settings.useTestScanner {
            service = TestScanner(delay: 1)
        } else if let address = settings.scanner {
            service = ESCLScanner(address: address)
        } else {
            return
        }
        isTestScanning = true
        testScanMessage = loc("Testscan läuft. Das dauert etwa eine halbe Minute …", "Test scan running. This takes about half a minute …")
        testScanImage = nil
        Task {
            defer {
                isTestScanning = false
                (service as? ESCLScanner)?.invalidate()
            }
            do {
                let data = try await service.scanOnePage()
                testScanImage = NSImage(data: data)
                testScanMessage = loc("Testscan erfolgreich.", "Test scan successful.")
                rememberCertificateIfNeeded(from: service)
            } catch {
                testScanMessage = loc("Testscan fehlgeschlagen", "Test scan failed") + ": \(error.localizedDescription)"
            }
        }
    }

    func rememberCertificateIfNeeded(from service: ScannerService) {
        guard let escl = service as? ESCLScanner, var saved = settings.scanner, saved.certificateSHA256 == nil,
              saved.host == escl.address.host, let fingerprint = escl.observedCertificateSHA256 else { return }
        saved.certificateSHA256 = fingerprint
        settings.scanner = saved
        certificateMessage = loc("Zertifikat festgehalten.", "Certificate saved.")
        objectWillChange.send()
    }

    // MARK: - API-Schlüssel

    /// Prüft den Schlüssel und speichert ihn nur, wenn Anthropic ihn annimmt.
    func checkAndSaveAPIKey(_ key: String) {
        let key = AnthropicKeyChecker.normalize(key)
        guard !key.isEmpty else { return }
        isCheckingKey = true
        apiKeyMessage = loc("Schlüssel wird geprüft …", "Checking key …")
        Task {
            defer { isCheckingKey = false }
            let result = await AnthropicKeyChecker().check(key)
            guard result == .valid else {
                apiKeyMessage = result.message
                return
            }
            if keychain.save(key) {
                hasAPIKey = true
                apiKeyMessage = loc("Der Schlüssel funktioniert und ist im Schlüsselbund gespeichert.", "The key works and is stored in the keychain.")
            } else {
                apiKeyMessage = loc("Der Schlüssel funktioniert, konnte aber nicht im Schlüsselbund gespeichert werden.", "The key works but could not be stored in the keychain.")
            }
        }
    }

    /// Prüft den bereits gespeicherten Schlüssel erneut.
    func recheckSavedAPIKey() {
        guard let key = keychain.read() else { return }
        isCheckingKey = true
        apiKeyMessage = loc("Schlüssel wird geprüft …", "Checking key …")
        Task {
            defer { isCheckingKey = false }
            apiKeyMessage = await AnthropicKeyChecker().check(key).message
        }
    }

    func removeAPIKey() {
        keychain.delete()
        hasAPIKey = false
        apiKeyMessage = loc("Schlüssel entfernt. Ohne Schlüssel arbeitet die App nur ohne Inhaltserkennung.", "Key removed. Without a key, the app works without content recognition only.")
    }

    // MARK: - Ablageordner

    func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = loc("Diesen Ordner verwenden", "Use this folder")
        panel.message = loc("Wählen Sie den Ordner, in dem die gescannten PDFs abgelegt werden.", "Choose the folder where the scanned PDFs are saved.")
        panel.directoryURL = storageFolder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setStorageFolder(url)
    }

    func resetStorageFolder() {
        setStorageFolder(StorageFolder.defaultURL)
    }

    private func setStorageFolder(_ url: URL) {
        settings.storageFolder = url
        storageFolder = url
        prepareStorageFolder()
    }

    /// Legt den Ordner an und prüft den Schreibzugriff. Beim ersten Mal fragt macOS nach „Dokumente“.
    func prepareStorageFolder() {
        do {
            try StorageFolder.prepare(storageFolder)
            // Zwischendateien eines Absturzes beim Ablegen entfernen (nur `.<name>.pdf.<id>.tmp`, älter als 1 Stunde).
            DocumentFiler.removeStaleTemporaryFiles(in: storageFolder)
            folderReady = true
            folderMessage = loc("Ordner ist bereit.", "Folder is ready.")
        } catch {
            folderReady = false
            folderMessage = error.localizedDescription
        }
    }

    func revealStorageFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([storageFolder])
    }

    // MARK: - Dateiname und Typen

    var customTypeErrors: [DocumentTypeError?] { DocumentTypes.validate(customTypeEntries) }
    var customTypesValid: Bool { customTypeErrors.allSatisfy { $0 == nil } }
    var customTypes: [DocumentType] { DocumentTypes.customTypes(from: customTypeEntries) }

    func previewName() -> String {
        fileNameScheme.fileName(FileNamer.exampleParts())
    }

    func previewScanName() -> String {
        fileNameScheme.scanFileName(date: FileNamer.exampleParts().date, id: "a3f9c2")
    }

    /// Kürzel beim Tippen auf zwei Großbuchstaben/Ziffern begrenzen.
    func setCustomCode(_ code: String, at index: Int) {
        let filtered = String(code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(2))
        customTypeEntries[index].code = filtered
    }

    func setCustomHint(_ hint: String, at index: Int) {
        customTypeEntries[index].hint = String(hint.prefix(DocumentTypes.hintMaxLength))
    }
}

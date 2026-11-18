import DocKit
import Foundation

/// Ergebnis eines Durchgangs. Auch bei Fehler können schon Seiten übernommen sein.
public struct ScanRunResult: Sendable {
    public var pagesAdded: Int
    public var blankPages: Int
    public var error: Error?
    public var cancelled: Bool { error is CancellationError }

    /// Text für die Oberfläche. `nil`, wenn alles geklappt hat.
    public var problemMessage: String? {
        guard let error, !cancelled else { return nil }
        var reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if error as? ScanError == .timeout {
            // Der Epson pausiert gelegentlich etwa 2 Minuten mitten im Einzug; erst nach 5 Minuten gilt er als hängend.
            // Dann gleich den Neustart empfehlen.
            reason = loc("Der Drucker hat nach 5 Minuten noch keine Seite geliefert. Der Auftrag wurde abgebrochen. "
                + "Bitte schalten Sie den Drucker aus und wieder ein. Steckt ein Blatt halb im Einzug, nehmen Sie es "
                + "danach heraus. Legen Sie die Blätter dann erneut ein und scannen Sie noch einmal.",
                "The printer has not delivered a page after 5 minutes. The job was cancelled. "
                + "Please switch the printer off and on again. If a sheet is stuck halfway in the feeder, remove it "
                + "afterwards. Then put the sheets back in and scan again.")
        }
        guard pagesAdded > 0 else { return reason }
        let kept = pagesAdded == 1 ? loc("1 Seite wurde", "1 page has") : loc("\(pagesAdded) Seiten wurden", "\(pagesAdded) pages have")
        return reason + " " + loc("\(kept) bereits übernommen. Legen Sie die übrigen Blätter erneut ein und wählen Sie „Weiter scannen“.",
                                  "\(kept) already been kept. Put the remaining sheets back in and choose “Continue scanning”.")
    }
}

/// Ein Scan-Durchgang: scannt (Flachbett: eine Seite, Einzug: alle Blätter), prüft leere Seiten und speichert
/// jede Seite sofort im Auftrag. Seiten, die vor einem Fehler oder Abbruch angekommen sind, bleiben erhalten.
public struct ScanRunner: Sendable {
    /// Höchstzahl Seiten je Auftrag (Konzept 5.4; entspricht der Kapazität des Epson-Einzugs).
    public static let maxPagesPerJob = 50

    public let scanner: ScannerService
    public let store: JobStore
    /// Gilt nur für den Einzug; auf dem Flachbett legt man bewusst jede Seite auf.
    public let removeBlankPages: Bool

    public init(scanner: ScannerService, store: JobStore, removeBlankPages: Bool) {
        self.scanner = scanner
        self.store = store
        self.removeBlankPages = removeBlankPages
    }

    public func run(jobID: UUID, settings: ScanSettings,
                    onPage: @escaping @Sendable (ScanJob) async -> Void = { _ in }) async -> ScanRunResult {
        let counter = Counter()
        do {
            guard let job = store.job(jobID) else { throw JobStoreError.notFound }
            let remaining = Self.maxPagesPerJob - job.pages.count
            guard remaining > 0 else { throw ScanError.pageLimitReached(Self.maxPagesPerJob) }

            let source = settings.source
            let checkBlank = removeBlankPages && source == .feeder
            let store = self.store
            let add: @Sendable (Data) async throws -> Void = { data in
                let blank = checkBlank && BlankPageDetector.isBlank(jpeg: data)
                let updated = try store.addPage(to: jobID, jpeg: data, source: source, looksBlank: blank)
                counter.add(blank: blank)
                await onPage(updated)
            }
            switch source {
            case .platen:
                try await add(try await scanner.scanOnePage(settings: settings))
            case .feeder:
                _ = try await scanner.scanFeeder(settings: settings, maxPages: remaining, onPage: add)
            case .file:
                break  // Dateien kommen über `FileImport`, nicht über den Scanner.
            }
            return ScanRunResult(pagesAdded: counter.pages, blankPages: counter.blanks, error: nil)
        } catch {
            return ScanRunResult(pagesAdded: counter.pages, blankPages: counter.blanks, error: error)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _pages = 0
    private var _blanks = 0
    var pages: Int { lock.withLock { _pages } }
    var blanks: Int { lock.withLock { _blanks } }
    func add(blank: Bool) {
        lock.withLock {
            _pages += 1
            if blank { _blanks += 1 }
        }
    }
}

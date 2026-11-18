import DocKit
import Foundation

/// Eine Seite aus einer hinzugefügten PDF-Datei, die unverändert ins abgelegte PDF übernommen wird.
public struct OriginalPage: Codable, Equatable, Sendable {
    /// Kopie der PDF-Datei im Auftragsordner, z. B. `datei-001.pdf`.
    public var file: String
    /// Seite in dieser Datei, 0-basiert.
    public var index: Int

    public init(file: String, index: Int) {
        self.file = file
        self.index = index
    }
}

/// Eine Seite eines Auftrags: gescannt oder aus einer hinzugefügten Datei. `file` ist immer ein JPEG
/// (für Vorschau, Texterkennung und Inhaltserkennung).
public struct ScanPage: Codable, Equatable, Sendable {
    public var file: String
    public var source: ScanSource
    /// Von der Erkennung leerer Seiten als leer eingestuft.
    public var looksBlank: Bool
    /// Wird nicht übernommen. Leere Seiten starten so; der Nutzer kann sie zurückholen.
    public var excluded: Bool
    /// Als Trennblatt erkannt und deshalb ausgeschlossen. `nil` bei älteren Aufträgen.
    public var isSeparator: Bool? = nil
    /// Name der hinzugefügten Datei (nur bei `source == .file`).
    public var importedFrom: String? = nil
    /// PDF-Seite mit eigenem Text: kommt unverändert ins abgelegte PDF statt des JPEGs.
    public var original: OriginalPage? = nil
}

public enum ScanJobState: String, Codable, Sendable {
    /// Es wird noch gescannt bzw. es kann weitergescannt werden.
    case scanning
    /// Der Nutzer hat „Fertig“ gewählt; Texterkennung und PDF laufen bzw. werden nach einem Neustart wiederholt.
    case scanned
    /// PDF ist gebaut, der Name vorgeschlagen; wartet in der Ergebnisliste auf „Ablegen“.
    case ready
}

/// Ein Scanauftrag: alle Seiten eines Scanvorgangs, auch über mehrere Durchgänge (Flachbett/Einzug).
public struct ScanJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var state: ScanJobState
    public var pages: [ScanPage]
    /// Kurz-ID für den Dateinamen; bleibt für den Auftrag gleich.
    public var shortID: String?
    /// Vorgeschlagener Dateiname (Zustand `ready`).
    public var fileName: String?
    /// Vorschläge der Inhaltserkennung, in der Ergebnisliste bearbeitet. `nil` = ohne Inhaltserkennung.
    public var proposals: [DocumentProposal]?
    /// Warum die Inhaltserkennung nicht geklappt hat (dann wird mit Datum benannt).
    public var recognitionProblem: String?
    /// Verbrauch der Inhaltserkennung für diesen Auftrag (für die Kostenanzeige in M6).
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Seiten (1-basiert, innerhalb der übernommenen Seiten), an denen wegen eines Trennblatts sicher ein
    /// neues Dokument beginnt.
    public var forcedStarts: [Int]?
    /// Letzter Einzug-Durchgang (Vorderseiten), für „Rückseiten scannen“. Wird beim Zusammenführen geleert.
    public var lastFeederPass: FeederPass?
    /// Zusammengeführte Vorder- und Rückseiten (manuell beidseitig).
    public var duplex: DuplexMerge?
    /// Die Vorschläge kommen vom Apple-Modell auf dem Mac. Neubenennungen laufen dann auch lokal, nie über Claude.
    public var recognizedLocally: Bool?
    /// Ohne Vorschläge: Name, unter dem gerade abgelegt wird (Absturzschutz wie `DocumentProposal.filingName`).
    public var filingName: String?

    public var includedPages: [ScanPage] { pages.filter { !$0.excluded } }

    public init(id: UUID, createdAt: Date, state: ScanJobState, pages: [ScanPage]) {
        self.id = id
        self.createdAt = createdAt
        self.state = state
        self.pages = pages
    }
}

public enum JobStoreError: Error, LocalizedError, Equatable {
    case notFound
    case pageIndexOutOfRange

    public var errorDescription: String? {
        switch self {
        case .notFound: return loc("Der Scanauftrag wurde nicht gefunden.", "The scan job was not found.")
        case .pageIndexOutOfRange: return loc("Diese Seite gibt es nicht.", "This page does not exist.")
        }
    }
}

/// Speichert Aufträge unter `~/Library/Application Support/Scan-to-me/Auftraege/<uuid>/`:
/// `job.json` und je Seite `seite-001.jpg` usw. Jede Seite wird sofort geschrieben, damit nach einem Absturz
/// nichts verloren ist. Seiten werden nie gelöscht, nur ausgeschlossen; gelöscht wird nur ein ganzer Auftrag.
public final class JobStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scan-to-me/Auftraege", isDirectory: true)
    }

    public init(root: URL = JobStore.defaultRoot) {
        self.root = root
    }

    public func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func pageURL(_ job: ScanJob, _ page: ScanPage) -> URL {
        folder(job.id).appendingPathComponent(page.file)
    }

    public func create(now: Date = Date()) throws -> ScanJob {
        try lock.withLock {
            let job = ScanJob(id: UUID(), createdAt: now, state: .scanning, pages: [])
            try fileManager.createDirectory(at: folder(job.id), withIntermediateDirectories: true)
            try write(job)
            return job
        }
    }

    public func job(_ id: UUID) -> ScanJob? {
        lock.withLock { read(id) }
    }

    /// Alle Aufträge, neueste zuerst. Unlesbare Ordner werden übergangen, nicht gelöscht.
    public func all() -> [ScanJob] {
        lock.withLock {
            let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return folders.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap(read) }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// Schreibt die Seite und trägt sie im Auftrag ein. Leere Seiten werden als ausgeschlossen markiert.
    @discardableResult
    public func addPage(to id: UUID, jpeg: Data, source: ScanSource, looksBlank: Bool) throws -> ScanJob {
        try lock.withLock {
            guard var job = read(id) else { throw JobStoreError.notFound }
            let file = String(format: "seite-%03d.jpg", job.pages.count + 1)
            try jpeg.write(to: folder(id).appendingPathComponent(file), options: .atomic)
            job.pages.append(ScanPage(file: file, source: source, looksBlank: looksBlank, excluded: looksBlank))
            try write(job)
            return job
        }
    }

    /// Seite aus einer hinzugefügten Datei. Wird nie als leer aussortiert.
    @discardableResult
    public func addImportedPage(to id: UUID, jpeg: Data, importedFrom name: String,
                                original: OriginalPage? = nil) throws -> ScanJob {
        try lock.withLock {
            guard var job = read(id) else { throw JobStoreError.notFound }
            let file = String(format: "seite-%03d.jpg", job.pages.count + 1)
            try jpeg.write(to: folder(id).appendingPathComponent(file), options: .atomic)
            var page = ScanPage(file: file, source: .file, looksBlank: false, excluded: false)
            page.importedFrom = name
            page.original = original
            job.pages.append(page)
            try write(job)
            return job
        }
    }

    /// Legt eine Kopie einer hinzugefügten PDF-Datei im Auftragsordner ab und liefert ihren Namen.
    public func storeImportedPDF(_ data: Data, in id: UUID) throws -> String {
        try lock.withLock {
            let folder = folder(id)
            var number = 1
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "datei-%03d.pdf", number)).path) {
                number += 1
            }
            let name = String(format: "datei-%03d.pdf", number)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        }
    }

    @discardableResult
    public func setExcluded(_ excluded: Bool, page index: Int, in id: UUID) throws -> ScanJob {
        try update(id) { job in
            guard job.pages.indices.contains(index) else { throw JobStoreError.pageIndexOutOfRange }
            job.pages[index].excluded = excluded
        }
    }

    @discardableResult
    public func setState(_ state: ScanJobState, in id: UUID) throws -> ScanJob {
        try update(id) { $0.state = state }
    }

    public func delete(_ id: UUID) throws {
        try lock.withLock {
            let url = folder(id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    @discardableResult
    public func update(_ id: UUID, _ change: (inout ScanJob) throws -> Void) throws -> ScanJob {
        try lock.withLock {
            guard var job = read(id) else { throw JobStoreError.notFound }
            try change(&job)
            try write(job)
            return job
        }
    }

    private func read(_ id: UUID) -> ScanJob? {
        let url = folder(id).appendingPathComponent("job.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanJob.self, from: data)
    }

    private func write(_ job: ScanJob) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: folder(job.id).appendingPathComponent("job.json"), options: .atomic)
    }
}

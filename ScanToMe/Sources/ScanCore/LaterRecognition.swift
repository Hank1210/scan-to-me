import DocKit
import Foundation
import PDFKit

/// Ein ohne Inhaltserkennung abgelegtes PDF (`YY-MM-DD_Scan_ID.pdf` bzw. `YYYY-…`).
public struct FiledScan: Identifiable, Equatable, Sendable {
    public var url: URL
    /// Scandatum aus dem Namen (mittags, damit Zeitzonen den Tag nicht verschieben).
    public var date: Date
    /// Kurz-ID aus dem Namen; sie bleibt beim Umbenennen erhalten.
    public var shortID: String

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

public enum LaterRecognitionError: Error, LocalizedError, Equatable {
    case unreadable
    case tooLarge(pages: Int)
    case gone

    public var errorDescription: String? {
        switch self {
        case .unreadable: return loc("Die Datei ließ sich nicht als PDF öffnen.", "The file could not be opened as a PDF.")
        case .tooLarge(let pages):
            return loc("Die Datei ist zu groß für die Erkennung (\(pages) Seiten oder mehr als 30 MB).",
                       "The file is too large for recognition (\(pages) pages or more than 30 MB).")
        case .gone: return loc("Die Datei ist nicht mehr im Ablageordner.", "The file is no longer in the storage folder.")
        }
    }
}

/// „Später erkennen“ (Konzept 5.5): Ein schon abgelegtes Scan-PDF nachträglich von Claude benennen lassen und
/// umbenennen. Der Inhalt der Datei bleibt unverändert; es ändert sich nur der Name (und das Finder-Tag).
/// Nie überschreiben: Ist der neue Name belegt, wird die ID neu gewürfelt.
public enum LaterRecognition {
    public static let maxPages = 50
    public static let maxBytes = 30_000_000

    /// `26-11-16_Scan_a3f9c2.pdf` → Datum und ID. `nil` bei anderen Namen. Erkannt werden das aktuelle Schema
    /// und die beiden festen (für Dateien von vor einem Wechsel). Ohne vollständiges Datum im Namen: `date` nil.
    public static func parse(_ name: String, scheme: FileNameScheme = .standard,
                             calendar: Calendar = .current) -> (date: Date?, id: String)? {
        for candidate in [scheme, FileNameScheme(.twoDigit), FileNameScheme(.fourDigit)] {
            if let result = candidate.parseScanName(name, calendar: calendar) { return result }
        }
        return nil
    }

    /// Alle Scan-PDFs im Ordner (nicht in Unterordnern), neueste zuerst.
    public static func candidates(in folder: URL, scheme: FileNameScheme = .standard) -> [FiledScan] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            guard let parsed = parse(url.lastPathComponent, scheme: scheme) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            return FiledScan(url: url, date: parsed.date ?? created, shortID: parsed.id)
        }
        .sorted { ($0.date, $0.name) > ($1.date, $1.name) }
    }

    /// Schickt das abgelegte PDF (mit Bild und Textebene) an Claude und liefert einen Vorschlag für ein Dokument.
    public static func analyze(_ scan: FiledScan, client: ClaudeClient, types: [DocumentType]) async throws -> DocumentProposal {
        guard FileManager.default.fileExists(atPath: scan.url.path) else { throw LaterRecognitionError.gone }
        guard let data = try? Data(contentsOf: scan.url), let document = PDFDocument(data: data) else {
            throw LaterRecognitionError.unreadable
        }
        guard document.pageCount <= maxPages, data.count <= maxBytes else {
            throw LaterRecognitionError.tooLarge(pages: document.pageCount)
        }
        let body = try DocumentAnalysis.requestBody(pdf: data, pageCount: document.pageCount, types: types, split: false)
        let response = try await client.send(body: body)
        guard var proposal = try DocumentAnalysis.proposals(fromJSON: response.text, pageCount: document.pageCount,
                                                            split: false, knownCodes: Set(types.map(\.code))).first
        else { throw ClaudeError.badResponse }
        proposal.shortID = scan.shortID
        return proposal
    }

    /// Wie `analyze`, aber lokal mit Apples Modell: Bild der ersten Seite und Text der Datei (Textebene, sonst
    /// Texterkennung des Bildes). Die Datei verlässt den Mac nicht.
    public static func analyzeLocally(_ scan: FiledScan, types: [DocumentType]) async throws -> DocumentProposal {
        guard FileManager.default.fileExists(atPath: scan.url.path) else { throw LaterRecognitionError.gone }
        guard let document = PDFDocument(url: scan.url), let first = document.page(at: 0) else {
            throw LaterRecognitionError.unreadable
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("seite-1.jpg")
        try FileImport.render(first, name: scan.name).write(to: image)
        // Erste Seite per Texterkennung (liefert die Lage der Zeilen für die Gliederung), die übrigen aus der Textebene.
        let firstPage = try await TextRecognizer.recognize(jpegURL: image, timeout: TextRecognizer.pageTimeout)
        let texts = [LocalRecognizer.structured(firstPage)]
            + (1..<max(document.pageCount, 1)).map { document.page(at: $0)?.string ?? "" }
        var proposal = try await LocalRecognizer.propose(imageURL: image, pageTexts: texts, pageCount: document.pageCount,
                                                         types: types)
        proposal.shortID = scan.shortID
        return proposal
    }

    /// Neuer Name für den Vorschlag; ohne erkanntes Datum gilt das Scandatum aus dem alten Namen.
    public static func proposedName(_ scan: FiledScan, proposal: DocumentProposal, scheme: FileNameScheme,
                                    id: String? = nil) -> String {
        scheme.fileName(proposal.nameParts(scanDate: scan.date, id: id ?? scan.shortID))
    }

    /// Legt die Datei in den Papierkorb (nie endgültig löschen). Liefert die Adresse im Papierkorb.
    @discardableResult
    public static func moveToTrash(_ scan: FiledScan) throws -> URL? {
        guard FileManager.default.fileExists(atPath: scan.url.path) else { throw LaterRecognitionError.gone }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: scan.url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Benennt die Datei um (im selben Ordner) und setzt das Finder-Tag. Liefert die neue Adresse.
    @discardableResult
    public static func rename(_ scan: FiledScan, proposal: DocumentProposal, scheme: FileNameScheme) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scan.url.path) else { throw LaterRecognitionError.gone }
        let folder = scan.url.deletingLastPathComponent()
        guard let name = DocumentFiler.freeName(in: folder, preferredID: scan.shortID,
                                                makeName: { proposedName(scan, proposal: proposal, scheme: scheme, id: $0) })
        else { throw DocumentFilerError.noFreeName }
        let target = folder.appendingPathComponent(name)
        // `moveItem` überschreibt nie; existiert das Ziel inzwischen, schlägt es fehl.
        try fm.moveItem(at: scan.url, to: target)
        try? (target as NSURL).setResourceValue([DocumentTypes.displayCode(proposal.typeCode)], forKey: .tagNamesKey)
        return target
    }
}

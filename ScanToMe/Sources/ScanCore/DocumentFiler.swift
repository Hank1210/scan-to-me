import Foundation
import PDFKit

public enum DocumentFilerError: Error, LocalizedError, Equatable {
    case nameTaken(String)
    case noFreeName
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return loc("Im Ablageordner gibt es „\(name)“ schon.", "“\(name)” already exists in the storage folder.")
        case .noFreeName: return loc("Es konnte kein freier Dateiname gefunden werden.", "No free file name could be found.")
        case .verificationFailed(let name):
            return loc("„\(name)“ wurde geschrieben, ließ sich aber nicht als PDF öffnen. Die Seiten bleiben erhalten.", "“\(name)” was written but could not be opened as a PDF. The pages are kept.")
        }
    }
}

/// Legt ein fertiges PDF im Ablageordner ab: nie überschreiben, atomar umbenennen, danach prüfen.
public enum DocumentFiler {
    /// Freier Name im Ordner; die Kurz-ID wird neu gewürfelt, solange der Name schon existiert.
    public static func freeName(in folder: URL, preferredID: String, makeName: (String) -> String,
                                newID: () -> String = { FileNamer.newID() }) -> String? {
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let preferred = makeName(preferredID)
        if !exists(preferred) { return preferred }
        return FileNamer.uniqueName(makeName: makeName, exists: exists, newID: newID)
    }

    /// Liegt die Datei vollständig im Ordner (vorhanden, als PDF lesbar, richtige Seitenzahl)?
    public static func isComplete(_ url: URL, expectedPages: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let document = PDFDocument(url: url) else { return false }
        return document.pageCount == expectedPages
    }

    /// Räumt Zwischendateien auf, die ein Absturz beim Ablegen hinterlassen hat (`.<name>.pdf.<id>.tmp`,
    /// älter als eine Stunde). Andere Dateien werden nie angefasst. Liefert die Zahl der entfernten Dateien.
    @discardableResult
    public static func removeStaleTemporaryFiles(in folder: URL, olderThan age: TimeInterval = 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp"), name.contains(".pdf.") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Schreibt das PDF und liefert die fertige Datei. Gibt es den Namen schon, wird nichts geschrieben.
    @discardableResult
    public static func file(pdfAt source: URL, name: String, in folder: URL, expectedPages: Int,
                            tags: [String] = []) throws -> URL {
        try StorageFolder.prepare(folder)
        let fm = FileManager.default
        let target = folder.appendingPathComponent(name)
        guard !fm.fileExists(atPath: target.path) else { throw DocumentFilerError.nameTaken(name) }

        let temp = folder.appendingPathComponent(".\(name).\(UUID().uuidString.prefix(8)).tmp")
        try fm.copyItem(at: source, to: temp)
        do {
            // `moveItem` überschreibt nie: existiert das Ziel inzwischen, schlägt es fehl.
            try fm.moveItem(at: temp, to: target)
        } catch {
            try? fm.removeItem(at: temp)
            throw fm.fileExists(atPath: target.path) ? DocumentFilerError.nameTaken(name) : error
        }
        guard let document = PDFDocument(url: target), document.pageCount == expectedPages else {
            throw DocumentFilerError.verificationFailed(name)
        }
        if !tags.isEmpty {
            // Finder-Tag, z. B. „RE“. Schlägt das fehl, bleibt die Datei trotzdem gültig.
            try? (target as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return target
    }
}

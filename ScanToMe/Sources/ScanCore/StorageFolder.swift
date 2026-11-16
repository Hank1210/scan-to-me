import Foundation

public enum StorageFolderError: Error, LocalizedError, Equatable {
    case notADirectory(String)
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return loc("„\(path)“ ist kein Ordner.", "“\(path)” is not a folder.")
        case .notWritable(let path):
            return loc("In den Ordner „\(path)“ kann nicht geschrieben werden. Bitte einen anderen Ordner wählen "
                + "oder in den Systemeinstellungen unter Datenschutz & Sicherheit → Dateien und Ordner den Zugriff erlauben.",
                "The app cannot write to the folder “\(path)”. Please choose another folder or allow access in "
                + "System Settings under Privacy & Security → Files and Folders.")
        }
    }
}

/// Der Ablageordner für die fertigen PDFs.
public enum StorageFolder {
    public static let defaultName = "Scan-to-me"

    /// Standard: `~/Documents/Scan-to-me`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultName, isDirectory: true)
    }

    /// Legt den Ordner bei Bedarf an und prüft, ob die App dort schreiben darf.
    /// Beim ersten Zugriff auf „Dokumente“ fragt macOS den Benutzer um Erlaubnis.
    public static func prepare(_ url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StorageFolderError.notADirectory(url.path) }
        } else {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw StorageFolderError.notWritable(url.path)
            }
        }
        let probe = url.appendingPathComponent(".scan-to-me-\(UUID().uuidString).tmp")
        do {
            try Data().write(to: probe)
            try fileManager.removeItem(at: probe)
        } catch {
            throw StorageFolderError.notWritable(url.path)
        }
    }
}

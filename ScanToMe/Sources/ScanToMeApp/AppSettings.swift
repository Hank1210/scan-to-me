import Foundation
import ScanCore

/// Gespeicherte Einstellungen. UserDefaults ist threadsicher; der API-Schlüssel liegt im Schlüsselbund.
final class AppSettings: @unchecked Sendable {
    private let defaults = UserDefaults.standard

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    var scanner: ScannerAddress? {
        get { decode("scanner") }
        set { encode(newValue, "scanner") }
    }

    var scannerCapabilities: ScannerCapabilities? {
        get { decode("scannerCapabilities") }
        set { encode(newValue, "scannerCapabilities") }
    }

    /// Nur für die Entwicklung ohne Drucker.
    var useTestScanner: Bool {
        get { defaults.bool(forKey: "useTestScanner") }
        set { defaults.set(newValue, forKey: "useTestScanner") }
    }

    var storageFolder: URL {
        get { defaults.string(forKey: "storageFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
              ?? StorageFolder.defaultURL }
        set { defaults.set(newValue.path, forKey: "storageFolder") }
    }

    var yearFormat: YearFormat {
        get { defaults.string(forKey: "yearFormat").flatMap(YearFormat.init(rawValue:)) ?? .twoDigit }
        set { defaults.set(newValue.rawValue, forKey: "yearFormat") }
    }

    /// Welches Schema gilt: die beiden festen oder die eigene Reihenfolge. Ohne Eintrag aus `yearFormat`.
    var nameMode: NameMode {
        get { defaults.string(forKey: "nameMode").flatMap(NameMode.init(rawValue:))
              ?? (yearFormat == .fourDigit ? .fourDigit : .twoDigit) }
        set { defaults.set(newValue.rawValue, forKey: "nameMode") }
    }

    /// Eigene Reihenfolge; bleibt gespeichert, auch wenn gerade ein festes Schema gewählt ist.
    var customNameScheme: FileNameScheme {
        get { decode("customNameScheme") ?? .standard }
        set { encode(newValue, "customNameScheme") }
    }

    /// Immer genau drei Freifelder, auch leere.
    var customTypeEntries: [CustomTypeEntry] {
        get {
            let saved: [CustomTypeEntry] = decode("customTypeEntries") ?? []
            return Array((saved + Array(repeating: CustomTypeEntry(), count: DocumentTypes.maxCustomTypes))
                .prefix(DocumentTypes.maxCustomTypes))
        }
        set { encode(newValue, "customTypeEntries") }
    }

    var setupCompleted: Bool {
        get { defaults.bool(forKey: "setupCompleted") }
        set { defaults.set(newValue, forKey: "setupCompleted") }
    }

    // Scaneinstellungen (Einstellungen → Scanner)

    var resolution: Int {
        get { let v = defaults.integer(forKey: "resolution"); return [200, 300].contains(v) ? v : 300 }
        set { defaults.set(newValue, forKey: "resolution") }
    }

    var color: Bool {
        get { defaults.object(forKey: "color") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "color") }
    }

    /// Leere Seiten im Einzug aussortieren (Standard an).
    var removeBlankPages: Bool {
        get { defaults.object(forKey: "removeBlankPages") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "removeBlankPages") }
    }

    // Wahl im Hauptfenster, wird gemerkt

    var scanSource: ScanSource {
        get { defaults.string(forKey: "scanSource").flatMap(ScanSource.init(rawValue:)) ?? .platen }
        set { defaults.set(newValue.rawValue, forKey: "scanSource") }
    }

    var recognizeContent: Bool {
        get { defaults.object(forKey: "recognizeContent") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recognizeContent") }
    }

    /// Aus, lokal (Apple) oder Claude. Ohne Eintrag aus dem früheren Schalter „Inhalt erkennen“.
    var recognitionMode: RecognitionMode {
        get { defaults.string(forKey: "recognitionMode").flatMap(RecognitionMode.init(rawValue:))
              ?? (recognizeContent ? .claude : .off) }
        set { defaults.set(newValue.rawValue, forKey: "recognitionMode") }
    }

    var splitBatch: Bool {
        get { defaults.bool(forKey: "splitBatch") }
        set { defaults.set(newValue, forKey: "splitBatch") }
    }

    /// Sprache der Oberfläche; ohne Wahl die Systemsprache.
    var language: AppLanguage {
        get { defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.systemDefault() }
        set { defaults.set(newValue.rawValue, forKey: "language") }
    }

    var hasScanner: Bool { useTestScanner || scanner != nil }
}

/// Auswahl unter „Aufbau des Dateinamens“.
enum NameMode: String, CaseIterable {
    case twoDigit, fourDigit, custom
}

/// Womit der Inhalt erkannt wird (M7).
enum RecognitionMode: String, CaseIterable {
    case off, local, claude

    var label: String {
        switch self {
        case .off: return loc("Aus", "Off")
        case .local: return loc("Lokal (Apple)", "Local (Apple)")
        case .claude: return "Claude"
        }
    }
}

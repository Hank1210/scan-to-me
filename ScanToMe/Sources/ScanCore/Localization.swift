import Foundation

/// Sprache der Oberfläche. Wählbar in den Einstellungen; ohne Wahl gilt die Systemsprache (Deutsch, sonst Englisch).
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case de, en

    /// Name der Sprache in ihrer eigenen Schreibweise (für die Auswahl).
    public var displayName: String { self == .de ? "Deutsch" : "English" }

    /// Aus den bevorzugten Sprachen des Systems: Deutsch, wenn es vorn steht, sonst Englisch.
    public static func systemDefault(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        (preferred.first ?? "").lowercased().hasPrefix("de") ? .de : .en
    }
}

/// Die aktuell gewählte Sprache. Wird beim Start und beim Umschalten von der App gesetzt.
/// Die Texte stehen direkt im Code als Paar (Deutsch, Englisch); `loc` wählt beim Anzeigen.
public enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: AppLanguage = .de

    public static var current: AppLanguage {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Text in der gewählten Sprache.
public func loc(_ de: String, _ en: String) -> String {
    Localization.current == .de ? de : en
}

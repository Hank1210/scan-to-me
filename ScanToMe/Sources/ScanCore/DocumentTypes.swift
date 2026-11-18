import DocKit
import Foundation

/// Ein Dokumenttyp mit zweistelligem Kürzel. Der Hinweis beschreibt, welche Dokumente dazugehören;
/// er geht später wörtlich an die Inhaltserkennung.
public struct DocumentType: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var code: String
    public var title: String
    public var hint: String
    public var isBuiltIn: Bool

    public var id: String { code }

    public init(code: String, title: String, hint: String, isBuiltIn: Bool) {
        self.code = code
        self.title = title
        self.hint = hint
        self.isBuiltIn = isBuiltIn
    }
}

/// Eingabe eines Freifelds in den Einstellungen, so wie getippt (wird erst bei der Prüfung normalisiert).
public struct CustomTypeEntry: Codable, Equatable, Sendable {
    public var code: String
    public var hint: String

    public init(code: String = "", hint: String = "") {
        self.code = code
        self.hint = hint
    }

    public var isEmpty: Bool {
        code.trimmingCharacters(in: .whitespaces).isEmpty && hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum DocumentTypeError: Error, LocalizedError, Equatable {
    case invalidCode
    case reservedCode(String)
    case duplicateCode(String)
    case missingHint
    case hintTooLong

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return loc("Das Kürzel muss aus genau zwei Buchstaben oder Ziffern bestehen.", "The code must consist of exactly two letters or digits.")
        case .reservedCode(let code): return loc("„\(code)“ ist bereits fest vergeben.", "“\(code)” is already used by a built-in type.")
        case .duplicateCode(let code): return loc("„\(code)“ ist schon in einem anderen Freifeld eingetragen.", "“\(code)” is already used in another custom field.")
        case .missingHint: return loc("Bitte beschreiben Sie, welche Dokumente zu diesem Typ gehören.", "Please describe which documents belong to this type.")
        case .hintTooLong: return loc("Der Hinweistext darf höchstens \(DocumentTypes.hintMaxLength) Zeichen lang sein.", "The description may be at most \(DocumentTypes.hintMaxLength) characters long.")
        }
    }
}

public enum DocumentTypes {
    public static let unknownCode = "UB"
    public static let maxCustomTypes = 3
    public static let hintMaxLength = 200

    /// Fest vorgegeben, nicht löschbar.
    public static let builtIn: [DocumentType] = [
        DocumentType(code: "BR", title: "Brief",
                     hint: "Briefe, Bescheide, Versicherungs- und Bankschreiben, Verträge – ohne Zahlungsaufforderung",
                     isBuiltIn: true),
        DocumentType(code: "RE", title: "Rechnung",
                     hint: "Rechnungen, Beitragsrechnungen (z. B. von Versicherungen), Abschlagsrechnungen, Mahnungen, "
                         + "Zahlungserinnerungen, Gutschriften", isBuiltIn: true),
        DocumentType(code: "AZ", title: "Arztbrief/Labor",
                     hint: "Arztbriefe, Befunde, Laborergebnisse, Rezepte, Überweisungen", isBuiltIn: true),
        DocumentType(code: unknownCode, title: "Unbekannt",
                     hint: "wenn nichts eindeutig passt", isBuiltIn: true),
    ]

    /// Bezeichnung und Beschreibung für die Anzeige in der gewählten Sprache. An Claude gehen immer die
    /// deutschen Texte aus `builtIn` (darauf ist der Prompt abgestimmt).
    public static func displayTitle(_ type: DocumentType) -> String {
        guard type.isBuiltIn, Localization.current == .en else { return type.title }
        return ["BR": "Letter", "RE": "Invoice", "AZ": "Medical letter/lab", unknownCode: "Unknown"][type.code] ?? type.title
    }

    public static func displayHint(_ type: DocumentType) -> String {
        guard type.isBuiltIn, Localization.current == .en else { return type.hint }
        return [
            "BR": "Letters, notices, insurance and bank letters, contracts – without a payment request",
            "RE": "Invoices, premium invoices (e.g. from insurers), instalment bills, reminders, payment reminders, credit notes",
            "AZ": "Medical letters, findings, lab results, prescriptions, referrals",
            unknownCode: "if nothing clearly fits",
        ][type.code] ?? type.hint
    }

    /// Kürzel der festen Typen in der englischen Fassung. Intern (im Auftrag, gegenüber Claude) gelten immer die
    /// deutschen Kürzel; übersetzt wird erst für Anzeige, Dateiname und Finder-Tag.
    static let englishCodes = ["BR": "LT", "RE": "IN", "AZ": "MD", unknownCode: "UN"]

    /// Kürzel, wie es angezeigt und in den Dateinamen geschrieben wird. Eigene Typen bleiben, wie eingegeben.
    public static func displayCode(_ code: String, language: AppLanguage = Localization.current) -> String {
        language == .en ? (englishCodes[code] ?? code) : code
    }

    /// Fest vergeben sind die Kürzel beider Sprachen, damit ein eigener Typ in keiner Sprache doppelt ist.
    public static var reservedCodes: Set<String> { Set(builtIn.map(\.code)).union(englishCodes.values) }

    public static func normalizeCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Genau zwei Zeichen aus `A-Z` und `0-9` (nach Umwandlung in Großbuchstaben).
    public static func isValidCode(_ code: String) -> Bool {
        let c = normalizeCode(code)
        return c.count == 2 && c.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Prüft die Freifelder. Ergebnis je Feld: `nil` = in Ordnung oder leer, sonst der erste Fehler.
    public static func validate(_ entries: [CustomTypeEntry]) -> [DocumentTypeError?] {
        var seen = Set<String>()
        return entries.map { entry in
            if entry.isEmpty { return nil }
            let code = normalizeCode(entry.code)
            let hint = entry.hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidCode(code) else { return .invalidCode }
            guard !reservedCodes.contains(code) else { return .reservedCode(code) }
            guard !seen.contains(code) else { return .duplicateCode(code) }
            seen.insert(code)
            guard !hint.isEmpty else { return .missingHint }
            guard hint.count <= hintMaxLength else { return .hintTooLong }
            return nil
        }
    }

    /// Die gültigen Freifelder als Dokumenttypen (leere und fehlerhafte Felder werden übergangen).
    public static func customTypes(from entries: [CustomTypeEntry]) -> [DocumentType] {
        let errors = validate(entries)
        return zip(entries, errors).prefix(maxCustomTypes).compactMap { entry, error in
            guard error == nil, !entry.isEmpty else { return nil }
            let hint = entry.hint.trimmingCharacters(in: .whitespacesAndNewlines)
            return DocumentType(code: normalizeCode(entry.code), title: hint, hint: hint, isBuiltIn: false)
        }
    }

    /// Reihenfolge für die Anzeige: feste Typen zuerst.
    public static func catalog(custom: [DocumentType]) -> [DocumentType] {
        builtIn + custom
    }

    /// Reihenfolge für die Erkennung: Freifelder vor den festen Typen, damit z. B. ein Steuerbescheid
    /// mit einem Freifeld „ST“ nicht als „BR“ erkannt wird.
    public static func recognitionOrder(custom: [DocumentType]) -> [DocumentType] {
        custom + builtIn
    }
}

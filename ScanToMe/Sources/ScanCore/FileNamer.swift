import Foundation

/// Jahresformat im Dateinamen: Standard `YY-MM-DD`, Option 1 `YYYY-MM-DD`.
public enum YearFormat: String, Codable, CaseIterable, Sendable {
    case twoDigit
    case fourDigit

    public var pattern: String { self == .twoDigit ? "YY-MM-DD" : "YYYY-MM-DD" }
}

/// Bestandteile eines Dateinamens nach Schema `Datum_Typ_Von_Name_ID`.
public struct FileNameParts: Equatable, Sendable {
    public var date: Date
    public var typeCode: String
    /// Absender
    public var sender: String
    /// Kurzbezeichnung, z. B. „Stromrechnung“
    public var title: String
    public var id: String

    public init(date: Date, typeCode: String, sender: String, title: String, id: String) {
        self.date = date
        self.typeCode = typeCode
        self.sender = sender
        self.title = title
        self.id = id
    }
}

/// Baut Dateinamen. Rein und ohne Dateisystem, damit alles testbar ist.
public enum FileNamer {
    /// Claude soll höchstens 20 Zeichen liefern; die Grenze hier ist nur die Sicherung
    /// (etwas Luft für Umlaute wie ü → ue und Orte wie „Finanzamt-Gelsenkirchen“).
    public static let senderMaxLength = 24
    public static let titleMaxLength = 40
    public static let idLength = 6
    public static let unknownSender = "Unbekannt"
    public static let unknownTitle = "Dokument"
    public static let scanWord = "Scan"

    /// Beispiel für die Vorschau in den Einstellungen.
    public static func exampleParts(calendar: Calendar = .current) -> FileNameParts {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        return FileNameParts(date: date, typeCode: DocumentTypes.displayCode("RE"), sender: "Stadtwerke München",
                             title: loc("Stromrechnung", "Electricity bill"), id: "a3f9c2")
    }

    public static func dateString(_ date: Date, year: YearFormat, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = year == .fourDigit ? String(format: "%04d", c.year ?? 0) : String(format: "%02d", (c.year ?? 0) % 100)
        return "\(y)-\(String(format: "%02d", c.month ?? 0))-\(String(format: "%02d", c.day ?? 0))"
    }

    /// `Datum_Typ_Von_Name_ID.pdf`, z. B. `26-11-12_RE_Stadtwerke-Muenchen_Stromrechnung_a3f9c2.pdf`.
    public static func fileName(_ parts: FileNameParts, year: YearFormat, calendar: Calendar = .current) -> String {
        FileNameScheme(year).fileName(parts, calendar: calendar)
    }

    /// Name ohne Inhaltserkennung: `Datum_Scan_ID.pdf` mit dem Scandatum.
    public static func scanFileName(date: Date, id: String, year: YearFormat, calendar: Calendar = .current) -> String {
        FileNameScheme(year).scanFileName(date: date, id: id, calendar: calendar)
    }

    /// Teil eines Dateinamens: Umlaute umschreiben, Akzente entfernen, nur `A-Z a-z 0-9` und Bindestrich,
    /// höchstens `maxLength` Zeichen.
    public static func namePart(_ text: String, maxLength: Int) -> String {
        var t = text
        for (from, to) in [("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"), ("ä", "ae"), ("ö", "oe"), ("ü", "ue"),
                           ("ß", "ss"), ("ẞ", "SS")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        var out = ""
        var lastWasDash = false
        for scalar in t.unicodeScalars {
            let isAllowed = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard trimmed.count > maxLength else { return trimmed }
        // Zu lang: an der letzten Wortgrenze kürzen („Deutsche-Rentenversicherung“ statt „…-Bu“).
        // Ohne brauchbare Wortgrenze (weniger als die Hälfte bliebe) hart kürzen.
        let cut = String(trimmed.prefix(maxLength))
        let nextIsBoundary = trimmed[trimmed.index(trimmed.startIndex, offsetBy: maxLength)] == "-"
        if !nextIsBoundary, let dash = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: dash) >= maxLength / 3 {
            return String(cut[..<dash])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Zufällige Kurz-ID aus 6 Kleinbuchstaben-Hexziffern.
    public static func newID<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<idLength).map { _ in digits[Int.random(in: 0..<16, using: &generator)] })
    }

    public static func newID() -> String {
        var generator = SystemRandomNumberGenerator()
        return newID(using: &generator)
    }

    public static func isValidID(_ id: String) -> Bool {
        id.count == idLength && id.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Würfelt die ID neu, solange es den Namen schon gibt. Nach `maxAttempts` Versuchen `nil`.
    public static func uniqueName(makeName: (String) -> String, exists: (String) -> Bool,
                                  newID: () -> String = { FileNamer.newID() }, maxAttempts: Int = 20) -> String? {
        for _ in 0..<maxAttempts {
            let name = makeName(newID())
            if !exists(name) { return name }
        }
        return nil
    }
}

import DocKit
import Foundation

/// Ein Baustein des Dateinamens.
public enum NameToken: String, Codable, CaseIterable, Sendable {
    case yy, yyyy, mm, dd, type, sender, title, id

    /// Anzeige in den Einstellungen.
    public var label: String {
        switch self {
        case .yy: return "YY"
        case .yyyy: return "YYYY"
        case .mm: return "MM"
        case .dd: return "DD"
        case .type: return loc("Typ", "Type")
        case .sender: return loc("Von", "From")
        case .title: return "Name"
        case .id: return "ID"
        }
    }

    public var isDate: Bool { [.yy, .yyyy, .mm, .dd].contains(self) }
    public var isYear: Bool { self == .yy || self == .yyyy }

    /// Bedeutung, für die Erklärung in den Einstellungen.
    public var meaning: String {
        switch self {
        case .yy: return loc("Jahr zweistellig, z. B. 26", "Year, two digits, e.g. 26")
        case .yyyy: return loc("Jahr vierstellig, z. B. 2026", "Year, four digits, e.g. 2026")
        case .mm: return loc("Monat, z. B. 11", "Month, e.g. 11")
        case .dd: return loc("Tag, z. B. 16", "Day, e.g. 16")
        case .type: return loc("Kürzel aus „Dokumenttypen“, z. B. RE", "Code from “Document types”, e.g. IN")
        case .sender: return loc("Absender, z. B. Telekom", "Sender, e.g. Telekom")
        case .title: return loc("kurze Bezeichnung, z. B. Stromrechnung", "short description, e.g. Electricity-bill")
        case .id: return loc("sechs zufällige Zeichen, damit kein Name doppelt vorkommt (Pflicht)",
                             "six random characters so that no name occurs twice (required)")
        }
    }
    /// Teile, die nur die Inhaltserkennung liefert.
    public var isContent: Bool { [.type, .sender, .title].contains(self) }
}

/// Aufbau des Dateinamens aus Bausteinen in frei gewählter Reihenfolge.
/// Regeln:
/// - Die ID ist Pflicht; jeder Baustein höchstens einmal; YY und YYYY schließen sich aus.
/// - Direkt benachbarte Datumsteile werden mit `-` verbunden, alles andere mit `_`.
/// - Nur die ID gewählt: immer `Scan_ID`.
/// - Ohne Inhaltserkennung ersetzt `Scan` die Inhaltsteile (Typ, Von, Name) an der Stelle des ersten; gibt es
///   keine, steht `Scan` vor der ID. So erkennt „Später erkennen“ diese Dateien wieder.
/// Die beiden festen Schemata sind Vorgaben davon (`YY-MM-DD_Typ_Von_Name_ID`, `YYYY-…`).
public struct FileNameScheme: Codable, Equatable, Sendable {
    public private(set) var tokens: [NameToken]
    /// Benachbarte Datumsteile mit `-` verbinden (`16-11-2026`) oder ohne Zeichen (`16112026`).
    public var dateDashes: Bool

    public init(tokens: [NameToken], dateDashes: Bool = true) {
        self.tokens = Self.normalized(tokens)
        self.dateDashes = dateDashes
    }

    // Eigene Dekodierung: gespeicherte Schemata von vor `dateDashes` bleiben lesbar.
    private enum CodingKeys: String, CodingKey { case tokens, dateDashes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tokens: try c.decode([NameToken].self, forKey: .tokens),
                  dateDashes: try c.decodeIfPresent(Bool.self, forKey: .dateDashes) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(dateDashes, forKey: .dateDashes)
    }

    /// Jahr im Schema: zwei- oder vierstellig; `nil`, wenn kein Jahr vorkommt.
    public var yearFormat: YearFormat? {
        tokens.contains(.yyyy) ? .fourDigit : tokens.contains(.yy) ? .twoDigit : nil
    }

    /// Tauscht YY und YYYY an derselben Stelle aus.
    public mutating func setYearFormat(_ format: YearFormat) {
        let wanted: NameToken = format == .fourDigit ? .yyyy : .yy
        tokens = tokens.map { $0.isYear ? wanted : $0 }
    }

    public init(_ year: YearFormat) {
        self.init(tokens: [year == .fourDigit ? .yyyy : .yy, .mm, .dd, .type, .sender, .title, .id])
    }

    public static let standard = FileNameScheme(.twoDigit)

    /// Doppelte entfernen, YY/YYYY nur einmal (der erste gewinnt), ID ergänzen, falls sie fehlt.
    static func normalized(_ tokens: [NameToken]) -> [NameToken] {
        var seen = Set<NameToken>()
        var result: [NameToken] = []
        for token in tokens where !seen.contains(token) {
            if (token == .yy && seen.contains(.yyyy)) || (token == .yyyy && seen.contains(.yy)) { continue }
            seen.insert(token)
            result.append(token)
        }
        if !seen.contains(.id) { result.append(.id) }
        return result
    }

    /// Darstellung wie `DD-MM-YYYY_Von_ID` (für die Einstellungen).
    public var pattern: String {
        join(tokens.map { ($0.label, $0.isDate) })
    }

    /// Welche Bausteine sich noch hinzufügen lassen.
    public var addable: [NameToken] {
        NameToken.allCases.filter { token in
            !tokens.contains(token)
                && !(token == .yy && tokens.contains(.yyyy)) && !(token == .yyyy && tokens.contains(.yy))
        }
    }

    public mutating func add(_ token: NameToken) { tokens = Self.normalized(tokens + [token]) }

    /// Entfernt einen Baustein; die ID bleibt immer.
    public mutating func remove(_ token: NameToken) {
        guard token != .id else { return }
        tokens = Self.normalized(tokens.filter { $0 != token })
    }

    /// Verschiebt einen Baustein um `offset` Stellen (−1 nach vorn, +1 nach hinten).
    public mutating func move(_ token: NameToken, by offset: Int) {
        guard let index = tokens.firstIndex(of: token) else { return }
        let target = index + offset
        guard tokens.indices.contains(target) else { return }
        tokens.swapAt(index, target)
    }

    // MARK: - Namen bauen

    /// Name mit Inhaltserkennung.
    public func fileName(_ parts: FileNameParts, calendar: Calendar = .current) -> String {
        guard tokens != [.id] else { return "\(FileNamer.scanWord)_\(parts.id).pdf" }
        let segments: [(String, Bool)] = tokens.map { token in
            switch token {
            case .type:
                return (DocumentTypes.isValidCode(parts.typeCode) ? DocumentTypes.normalizeCode(parts.typeCode)
                                                                  : DocumentTypes.unknownCode, false)
            case .sender:
                let s = FileNamer.namePart(parts.sender, maxLength: FileNamer.senderMaxLength)
                return (s.isEmpty ? FileNamer.unknownSender : s, false)
            case .title:
                let t = FileNamer.namePart(parts.title, maxLength: FileNamer.titleMaxLength)
                return (t.isEmpty ? FileNamer.unknownTitle : t, false)
            case .id: return (parts.id, false)
            default: return (Self.dateValue(token, parts.date, calendar: calendar), true)
            }
        }
        return join(segments) + ".pdf"
    }

    /// Name ohne Inhaltserkennung (Scandatum, „Scan“, ID).
    public func scanFileName(date: Date, id: String, calendar: Calendar = .current) -> String {
        join(scanTokens.map { token in
            switch token {
            case nil: return (FileNamer.scanWord, false)
            case .id?: return (id, false)
            case let date_?: return (Self.dateValue(date_, date, calendar: calendar), true)
            }
        }) + ".pdf"
    }

    /// Bausteine ohne Inhaltserkennung; `nil` steht für das Wort „Scan“.
    var scanTokens: [NameToken?] {
        var result: [NameToken?] = []
        var scanPlaced = false
        for token in tokens {
            if token.isContent {
                if !scanPlaced { result.append(nil); scanPlaced = true }
            } else {
                if token == .id && !scanPlaced { result.append(nil); scanPlaced = true }
                result.append(token)
            }
        }
        return result
    }

    static func dateValue(_ token: NameToken, _ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        switch token {
        case .yy: return String(format: "%02d", (c.year ?? 0) % 100)
        case .yyyy: return String(format: "%04d", c.year ?? 0)
        case .mm: return String(format: "%02d", c.month ?? 0)
        default: return String(format: "%02d", c.day ?? 0)
        }
    }

    /// Trennzeichen zwischen zwei Bausteinen: Datum–Datum `-` (oder nichts), sonst `_`.
    public func separator(between previousIsDate: Bool, and isDate: Bool) -> String {
        previousIsDate && isDate ? (dateDashes ? "-" : "") : "_"
    }

    /// Benachbarte Datumsteile mit `-` (bzw. ohne Zeichen), sonst `_`.
    func join(_ segments: [(String, Bool)]) -> String {
        var out = ""
        var previousIsDate: Bool?
        for (text, isDate) in segments {
            if let previous = previousIsDate { out += separator(between: previous, and: isDate) }
            out += text
            previousIsDate = isDate
        }
        return out
    }

    // MARK: - Namen lesen („Später erkennen“)

    /// Liest einen Namen ohne Inhaltserkennung nach diesem Schema. Datum nur, wenn Jahr, Monat und Tag darin
    /// stehen; sonst `nil` (dann gilt das Dateidatum).
    public func parseScanName(_ name: String, calendar: Calendar = .current) -> (date: Date?, id: String)? {
        var pattern = "^"
        var groups: [NameToken] = []
        var previousIsDate: Bool?
        for token in scanTokens {
            let isDate = token?.isDate ?? false
            if let previous = previousIsDate { pattern += separator(between: previous, and: isDate) }
            previousIsDate = isDate
            switch token {
            case nil: pattern += NSRegularExpression.escapedPattern(for: FileNamer.scanWord)
            case .id?: pattern += "([0-9a-f]{6})"; groups.append(.id)
            case .yyyy?: pattern += "(\\d{4})"; groups.append(.yyyy)
            case let t?: pattern += "(\\d{2})"; groups.append(t)
            }
        }
        pattern += "\\.pdf$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        var values: [NameToken: String] = [:]
        for (i, token) in groups.enumerated() {
            values[token] = String(name[Range(match.range(at: i + 1), in: name)!])
        }
        guard let id = values[.id] else { return nil }
        var date: Date?
        let year = values[.yyyy].flatMap(Int.init) ?? values[.yy].flatMap(Int.init).map { $0 + 2000 }
        if let year, let month = values[.mm].flatMap(Int.init), let day = values[.dd].flatMap(Int.init) {
            let components = DateComponents(year: year, month: month, day: day, hour: 12)
            guard components.isValidDate(in: calendar) else { return nil }
            date = calendar.date(from: components)
        }
        return (date, id)
    }
}

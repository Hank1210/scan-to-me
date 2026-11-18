import DocKit
import Foundation

/// Was ein eSCL-Scanner kann, ausgelesen aus `/eSCL/ScannerCapabilities`.
/// Alles Gerätespezifische kommt von hier, nicht aus fest eingebauten Annahmen über ein Modell.
public struct ScannerCapabilities: Codable, Equatable, Sendable {
    public var makeAndModel: String?
    public var hasPlaten: Bool
    public var hasFeeder: Bool
    public var feederDuplex: Bool
    /// Breite des Scanbereichs im Einzug in 1/300 Zoll (Epson WF-2960: 2550).
    public var feederMaxWidth: Int?
    /// Blätter, die in den Einzug passen (Epson WF-2960: 50).
    public var feederCapacity: Int?

    public init(makeAndModel: String? = nil, hasPlaten: Bool, hasFeeder: Bool, feederDuplex: Bool,
                feederMaxWidth: Int? = nil, feederCapacity: Int? = nil) {
        self.makeAndModel = makeAndModel
        self.hasPlaten = hasPlaten
        self.hasFeeder = hasFeeder
        self.feederDuplex = feederDuplex
        self.feederMaxWidth = feederMaxWidth
        self.feederCapacity = feederCapacity
    }

    public static func parse(_ xml: String) -> ScannerCapabilities {
        let feederPart = elementRange("Adf", in: xml).map { String(xml[$0.lowerBound...]) }
        return ScannerCapabilities(
            makeAndModel: ESCLScanner.firstTagValue("MakeAndModel", in: xml),
            hasPlaten: elementRange("Platen", in: xml) != nil,
            hasFeeder: feederPart != nil,
            feederDuplex: elementRange("AdfDuplexInputCaps", in: xml) != nil,
            feederMaxWidth: feederPart.flatMap { ESCLScanner.firstTagValue("MaxWidth", in: $0) }.flatMap { Int($0) },
            feederCapacity: feederPart.flatMap { ESCLScanner.firstTagValue("FeederCapacity", in: $0) }.flatMap { Int($0) })
    }

    /// Kurzbeschreibung für die Einrichtung, z. B. „Flachbett: ja · Einzug: ja (einseitig)“.
    public var summary: String {
        let yes = loc("ja", "yes"), no = loc("nein", "no")
        let feeder = hasFeeder ? (feederDuplex ? loc("ja (beidseitig)", "yes (double-sided)") : loc("ja (einseitig)", "yes (single-sided)")) : no
        return loc("Flachbett", "Flatbed") + ": \(hasPlaten ? yes : no) · " + loc("Einzug", "Feeder") + ": \(feeder)"
    }

    static func containsElement(_ name: String, in xml: String) -> Bool {
        elementRange(name, in: xml) != nil
    }

    /// Öffnendes Element mit beliebigem Namensraum-Präfix, z. B. `<scan:Adf>` (nicht `<scan:AdfSimplexInputCaps>`).
    static func elementRange(_ name: String, in xml: String) -> Range<String.Index>? {
        xml.range(of: "<(?:[A-Za-z0-9]+:)?\(name)[ >]", options: .regularExpression)
    }
}

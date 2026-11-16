import CoreGraphics
import Foundation
import ImageIO

/// Erkennt leere Seiten (z. B. leere Rückseiten) an der Menge dunkler Bildpunkte.
/// Durchscheinende Schrift der Rückseite ist hellgrau und zählt nicht; Ränder (Schatten, Kanten) werden ausgelassen.
public enum BlankPageDetector {
    /// Bildpunkte dunkler als dieser Grauwert (0–255) gelten als Schrift.
    public static let darkThreshold: UInt8 = 140
    /// Unterhalb dieses Anteils dunkler Punkte gilt die Seite als leer. Gemessen (15.11.2026): eine Zeile
    /// „Seite 2 von 2“ in 12 pt 0,05 %, ein Unterschriftsstrich 0,024 %, nur die Seitenzahl „2“ 0,004 %.
    /// Ein Unterschriftsstrich muss sicher als nicht leer gelten; eine Seite nur mit Seitenzahl darf leer sein.
    public static let blankCoverage = 0.0001
    /// Ausgelassener Rand je Seite (Anteil von Breite bzw. Höhe).
    public static let margin = 0.05
    static let analysisWidth = 620

    public static func isBlank(jpeg data: Data) -> Bool {
        guard let coverage = inkCoverage(jpeg: data) else { return false }
        return coverage < blankCoverage
    }

    /// Anteil dunkler Punkte im Innenbereich (0…1). `nil`, wenn das Bild nicht lesbar ist –
    /// dann gilt die Seite nie als leer.
    public static func inkCoverage(jpeg data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return inkCoverage(image)
    }

    public static func inkCoverage(_ image: CGImage) -> Double? {
        let width = min(analysisWidth, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Ohne Glättung: einzelne Striche bleiben dunkel statt zu grau verwaschen.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height) else { return nil }

        let x0 = Int(Double(width) * margin), x1 = width - x0
        let y0 = Int(Double(height) * margin), y1 = height - y0
        var dark = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 where pixels[row + x] < darkThreshold {
                dark += 1
            }
        }
        let total = (x1 - x0) * (y1 - y0)
        return total > 0 ? Double(dark) / Double(total) : nil
    }
}

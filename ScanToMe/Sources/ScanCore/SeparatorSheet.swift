import CoreGraphics
import CoreText
import Foundation

/// Trennblatt zum Ausdrucken. Zwischen zwei Dokumente gelegt, trennt die App dort sicher und nimmt
/// das Blatt aus dem Dokument heraus (es wird aussortiert, nicht gelöscht).
public enum SeparatorSheet {
    public static var headline: String { loc("TRENNBLATT", "SEPARATOR SHEET") }
    public static let appName = "Scan to me"

    /// Erkennung am lokal erkannten Text: „Trennblatt“ (oder „Separator sheet“) und „Scan to me“ auf einer Seite
    /// mit wenig Text. Beides zusammen kommt in normaler Post praktisch nicht vor. Beide Sprachfassungen gelten.
    public static func isSeparator(_ page: RecognizedPage) -> Bool {
        guard page.lines.count <= 12 else { return false }
        let squeezed = page.text.lowercased().filter { $0.isLetter }
        return (squeezed.contains("trennblatt") || squeezed.contains("separatorsheet")) && squeezed.contains("scantome")
    }

    /// Ein A4-Blatt mit großem Aufdruck.
    public static func pdf() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextCreator: appName, kCGPDFContextTitle: "Trennblatt"] as CFDictionary)
        else { throw PDFBuilderError.encodingFailed }
        context.beginPDFPage(nil)
        draw(headline, size: Localization.current == .de ? 76 : 60, bold: true, centerY: 560, in: context, width: box.width)
        draw(appName, size: 44, bold: false, centerY: 470, in: context, width: box.width)
        draw(loc("Zwischen zwei Dokumente legen.", "Place between two documents."),
             size: 16, bold: false, centerY: 330, in: context, width: box.width)
        draw(loc("Die App beginnt danach ein neues Dokument und lässt dieses Blatt weg.",
                 "The app starts a new document after it and leaves this sheet out."),
             size: 16, bold: false, centerY: 305, in: context, width: box.width)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    private static func draw(_ text: String, size: CGFloat, bold: Bool, centerY: CGFloat,
                             in context: CGContext, width: CGFloat) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (width - bounds.width) / 2, y: centerY)
        CTLineDraw(line, context)
    }
}

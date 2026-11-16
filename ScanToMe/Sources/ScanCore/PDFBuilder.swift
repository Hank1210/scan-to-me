import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum PDFBuilderError: Error, LocalizedError, Equatable {
    case noPages
    case unreadablePage(String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .noPages: return loc("Das Dokument hat keine Seiten.", "The document has no pages.")
        case .unreadablePage(let name): return loc("Seite \(name) ist nicht lesbar.", "Page \(name) cannot be read.")
        case .encodingFailed: return loc("PDF konnte nicht erzeugt werden.", "The PDF could not be created.")
        }
    }
}

/// Angaben im PDF selbst (sichtbar in Vorschau → Informationen und für Spotlight).
public struct PDFMetadata: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String]

    public init(title: String? = nil, author: String? = nil, subject: String? = nil, keywords: [String] = []) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
    }
}

/// Eine Seite für das PDF: das gescannte JPEG und optional der erkannte Text.
public struct PDFPageInput: Sendable {
    public var jpegURL: URL
    public var text: RecognizedPage?
    /// `nil` = Original unverändert. Sonst wird auf diese Kantenlänge verkleinert und neu komprimiert
    /// (für die kleine Fassung, die an die Inhaltserkennung geht).
    public var maxPixelSize: Int?
    /// Seite aus einer hinzugefügten PDF-Datei (Datei, 0-basierte Seite). Im endgültigen PDF wird sie unverändert
    /// übernommen (mit ihrem Text und ihrer Seitengröße); in der kleinen Fassung zählt weiter das JPEG.
    public var original: (url: URL, index: Int)?

    public init(jpegURL: URL, text: RecognizedPage?, maxPixelSize: Int? = nil, original: (url: URL, index: Int)? = nil) {
        self.jpegURL = jpegURL
        self.text = text
        self.maxPixelSize = maxPixelSize
        self.original = original
    }
}

/// Baut ein PDF aus gescannten Seiten (A4, eine Seite je Bild). Die JPEG-Daten des Scanners werden unverändert
/// übernommen (keine erneute Kompression). Darüber liegt der erkannte Text unsichtbar an seiner Stelle, damit
/// man im PDF suchen und markieren kann und Spotlight es findet.
public enum PDFBuilder {
    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    static let creator = "Scan to me"

    public static func build(pages: [PDFPageInput], metadata: PDFMetadata = PDFMetadata()) throws -> Data {
        guard !pages.isEmpty else { throw PDFBuilderError.noPages }
        let output = NSMutableData()
        var mediaBox = a4
        var info: [CFString: Any] = [kCGPDFContextCreator: creator]
        if let title = metadata.title { info[kCGPDFContextTitle] = title }
        if let author = metadata.author { info[kCGPDFContextAuthor] = author }
        if let subject = metadata.subject { info[kCGPDFContextSubject] = subject }
        if !metadata.keywords.isEmpty { info[kCGPDFContextKeywords] = metadata.keywords.joined(separator: ", ") }
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { throw PDFBuilderError.encodingFailed }

        var documents: [URL: CGPDFDocument] = [:]
        for page in pages {
            if page.maxPixelSize == nil, let original = page.original {
                let document = try documents[original.url] ?? {
                    guard let d = CGPDFDocument(original.url as CFURL) else {
                        throw PDFBuilderError.unreadablePage(original.url.lastPathComponent)
                    }
                    return d
                }()
                documents[original.url] = document
                guard let source = document.page(at: original.index + 1) else {
                    throw PDFBuilderError.unreadablePage("\(original.url.lastPathComponent) #\(original.index + 1)")
                }
                drawOriginal(source, in: context)
                continue
            }
            let image = try page.maxPixelSize.map { try scaledImage(url: page.jpegURL, maxPixelSize: $0) }
                ?? jpegImage(url: page.jpegURL)
            let imageRect = aspectFit(width: image.width, height: image.height, in: a4)
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(a4)
            context.draw(image, in: imageRect)
            if let text = page.text {
                drawInvisibleText(text, over: imageRect, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Übernimmt eine PDF-Seite unverändert (Vektoren und Text bleiben erhalten), in ihrer eigenen Größe und
    /// aufrecht gedreht.
    static func drawOriginal(_ page: CGPDFPage, in context: CGContext) {
        let box = page.getBoxRect(.mediaBox)
        let turned = page.rotationAngle % 180 != 0
        let target = CGRect(origin: .zero, size: turned ? CGSize(width: box.height, height: box.width) : box.size)
        var mediaBox = target
        let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.saveGState()
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.restoreGState()
        context.endPDFPage()
    }

    /// Jede Zeile wird unsichtbar (Text-Render-Modus 3) so gesetzt, dass sie ihren Kasten im Bild genau füllt.
    static func drawInvisibleText(_ page: RecognizedPage, over imageRect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in page.lines {
            let rect = CGRect(x: imageRect.minX + line.box.minX * imageRect.width,
                              y: imageRect.minY + line.box.minY * imageRect.height,
                              width: line.box.width * imageRect.width,
                              height: line.box.height * imageRect.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, &descent, nil))
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + descent * 0.5)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    /// JPEG-basiertes CGImage, damit Quartz die JPEG-Daten unverändert ins PDF übernimmt.
    static func jpegImage(url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { throw PDFBuilderError.unreadablePage(url.lastPathComponent) }
        return image
    }

    /// Verkleinert und neu als JPEG (Qualität 0,6) – wieder JPEG-basiert, damit das PDF klein bleibt.
    static func scaledImage(url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { throw PDFBuilderError.unreadablePage(url.lastPathComponent) }
        let jpeg = try ImageEncoding.jpeg(scaled, quality: 0.6)
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent)
        else { throw PDFBuilderError.encodingFailed }
        return image
    }

    static func aspectFit(width: Int, height: Int, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(width), rect.height / CGFloat(height))
        let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

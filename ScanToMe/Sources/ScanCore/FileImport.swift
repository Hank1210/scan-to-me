import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum FileImportError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case protectedPDF(String)
    case emptyPDF(String)
    case tooLarge(String)
    case tooManyPages(max: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return loc("Die Datei „\(name)“ kann nicht gelesen werden.", "The file “\(name)” cannot be read.")
        case .unsupported(let name):
            return loc("Die Datei „\(name)“ ist kein Bild und kein PDF.", "The file “\(name)” is neither an image nor a PDF.")
        case .protectedPDF(let name):
            return loc("Die PDF-Datei „\(name)“ ist mit einem Kennwort geschützt.", "The PDF file “\(name)” is password-protected.")
        case .emptyPDF(let name):
            return loc("Die PDF-Datei „\(name)“ hat keine Seiten.", "The PDF file “\(name)” has no pages.")
        case .tooLarge(let name):
            return loc("Die Datei „\(name)“ ist größer als 100 MB.", "The file “\(name)” is larger than 100 MB.")
        case .tooManyPages(let max):
            return loc("Ein Scan kann höchstens \(max) Seiten haben. Bitte die übrigen Dateien in einem neuen Scan hinzufügen.",
                       "A scan can have at most \(max) pages. Please add the remaining files in a new scan.")
        }
    }
}

/// Fügt Bilder und PDF-Dateien als Seiten zu einem Auftrag hinzu.
/// Danach laufen sie durch dieselbe Verarbeitung wie gescannte Seiten.
/// - Bilder: aufrecht gedreht (EXIF), höchstens A4 bei 300 dpi, JPEG.
/// - PDF-Seiten mit eigenem Text (z. B. Rechnung aus einem Kundenportal): kommen **unverändert** ins abgelegte PDF
///  . Für Vorschau, Texterkennung und Claude wird zusätzlich ein Bild erzeugt.
/// - PDF-Seiten ohne Text (eingescannte PDFs): werden wie ein Scan behandelt und bekommen eine Textebene.
public enum FileImport {
    public static let maxPixel = 3508
    public static let jpegQuality = 0.85
    public static let maxBytes = 100_000_000
    /// Ab so vielen Zeichen gilt eine PDF-Seite als „mit Text“.
    public static let minTextLength = 20

    public struct Added: Equatable, Sendable {
        public var job: ScanJob
        public var pagesAdded: Int
        /// Davon unverändert übernommene PDF-Seiten.
        public var originalPages: Int
    }

    /// Aus den angebotenen Formaten eines gezogenen Objekts (z. B. aus der Fotos-App, die statt einer Datei
    /// nur das Bild bzw. ein Dateiversprechen anbietet) das passende wählen: PDF vor Bild, beim Bild das
    /// Original (HEIC/JPEG/PNG …) vor Vorschauformaten wie TIFF.
    public static func preferredType(among identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if let pdf = types.first(where: { $0.conforms(to: .pdf) }) { return pdf }
        let images = types.filter { $0.conforms(to: .image) }
        return images.first(where: { !$0.conforms(to: .tiff) }) ?? images.first
    }

    /// Ist das eine Datei, die sich hinzufügen lässt (nach Endung)?
    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }

    /// Fügt die Dateien in dieser Reihenfolge hinzu. Prüft vorher alle Dateien, damit bei einem Fehler nichts
    /// halb übernommen ist.
    public static func add(_ urls: [URL], to jobID: UUID, store: JobStore, maxPages: Int = ScanRunner.maxPagesPerJob) throws -> Added {
        guard var job = store.job(jobID) else { throw JobStoreError.notFound }
        let files = try urls.map(load)
        let total = files.reduce(0) { $0 + $1.pageCount }
        guard job.pages.count + total <= maxPages else { throw FileImportError.tooManyPages(max: maxPages) }

        var originals = 0
        for file in files {
            switch file.content {
            case .image(let jpeg):
                job = try store.addImportedPage(to: jobID, jpeg: jpeg, importedFrom: file.name)
            case .pdf(let data, let document):
                let stored = try store.storeImportedPDF(data, in: jobID)
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { throw FileImportError.unreadable(file.name) }
                    let keep = hasText(page)
                    if keep { originals += 1 }
                    job = try store.addImportedPage(to: jobID, jpeg: try render(page, name: file.name), importedFrom: file.name,
                                                    original: keep ? OriginalPage(file: stored, index: index) : nil)
                }
            }
        }
        return Added(job: job, pagesAdded: total, originalPages: originals)
    }

    // MARK: - Laden und Prüfen

    struct Loaded {
        enum Content { case image(Data), pdf(Data, PDFDocument) }
        var name: String
        var content: Content
        var pageCount: Int
    }

    static func load(_ url: URL) throws -> Loaded {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw FileImportError.unreadable(name) }
        guard data.count <= maxBytes else { throw FileImportError.tooLarge(name) }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true || data.starts(with: Array("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { throw FileImportError.unreadable(name) }
            if document.isLocked { throw FileImportError.protectedPDF(name) }
            guard document.pageCount > 0 else { throw FileImportError.emptyPDF(name) }
            return Loaded(name: name, content: .pdf(data, document), pageCount: document.pageCount)
        }
        return Loaded(name: name, content: .image(try jpeg(fromImageData: data, name: name)), pageCount: 1)
    }

    static func hasText(_ page: PDFPage) -> Bool {
        (page.string ?? "").filter { !$0.isWhitespace }.count >= minTextLength
    }

    // MARK: - Bilder

    static func jpeg(fromImageData data: Data, name: String) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true
        else { throw FileImportError.unsupported(name) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF-Drehung anwenden
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw FileImportError.unreadable(name) }
        return try ImageEncoding.jpeg(onWhite(image), quality: jpegQuality)
    }

    /// Transparenz (z. B. PNG-Bildschirmfotos) auf Weiß legen, sonst wird sie im JPEG schwarz.
    static func onWhite(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    // MARK: - PDF-Seite als Bild

    /// Rendert eine PDF-Seite (mit Drehung) als JPEG, längste Kante höchstens A4 bei 300 dpi.
    static func render(_ page: PDFPage, name: String) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { throw FileImportError.unreadable(name) }
        let scale = min(300.0 / 72.0, CGFloat(maxPixel) / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw FileImportError.unreadable(name) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw FileImportError.unreadable(name) }
        return try ImageEncoding.jpeg(image, quality: jpegQuality)
    }
}

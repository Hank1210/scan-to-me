import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import ScanCore

final class FileImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// PDF mit echtem Text (wie eine Rechnung aus einem Kundenportal). `size` in Punkt.
    private func textPDF(_ name: String, pages: [String], size: CGSize = CGSize(width: 595.28, height: 841.89)) throws -> URL {
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: output)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
            context.textPosition = CGPoint(x: 50, y: size.height - 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = folder.appendingPathComponent(name)
        try (output as Data).write(to: url)
        return url
    }

    /// PDF nur aus einem Bild (wie ein eingescanntes PDF ohne Texterkennung).
    private func imagePDF(_ name: String, text: String) throws -> URL {
        let jpeg = try TestScanner.makePage(text: text)
        let jpegURL = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: jpegURL)
        let url = folder.appendingPathComponent(name)
        try PDFBuilder.build(pages: [PDFPageInput(jpegURL: jpegURL, text: nil)]).write(to: url)
        return url
    }

    private func store() -> (JobStore, ScanJob) {
        let store = JobStore(root: folder.appendingPathComponent("Auftraege"))
        return (store, try! store.create())
    }

    func testTextPdfPagesKeptAsOriginalImagePdfLikeScan() throws {
        let (store, job) = store()
        let text = try textPDF("Telekom-Rechnung.pdf", pages: ["Telekom Deutschland Rechnung November 2026 Seite eins",
                                                               "Telekom Deutschland Rechnung November 2026 Seite zwei"])
        let scanned = try imagePDF("Eingescannt.pdf", text: "Altes eingescanntes Schreiben")
        let added = try FileImport.add([text, scanned], to: job.id, store: store)
        XCTAssertEqual(added.pagesAdded, 3)
        XCTAssertEqual(added.originalPages, 2)
        let pages = added.job.pages
        XCTAssertEqual(pages.map(\.source), [.file, .file, .file])
        XCTAssertEqual(pages.map(\.importedFrom), ["Telekom-Rechnung.pdf", "Telekom-Rechnung.pdf", "Eingescannt.pdf"])
        XCTAssertEqual(pages[0].original, OriginalPage(file: "datei-001.pdf", index: 0))
        XCTAssertEqual(pages[1].original, OriginalPage(file: "datei-001.pdf", index: 1))
        XCTAssertNil(pages[2].original, "ohne eigenen Text: wie ein Scan")
        XCTAssertFalse(pages.contains { $0.excluded })
        // Jede Seite hat ein Bild für Vorschau und Texterkennung.
        for page in pages {
            XCTAssertNotNil(NSImage(contentsOf: store.pageURL(added.job, page)))
        }
    }

    func testPhotoWithTransparencyBecomesWhiteJpeg() throws {
        let (store, job) = store()
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        let png = NSMutableData()
        let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let url = folder.appendingPathComponent("Bildschirmfoto.png")
        try (png as Data).write(to: url)

        let added = try FileImport.add([url], to: job.id, store: store)
        let jpeg = try Data(contentsOf: store.pageURL(added.job, added.job.pages[0]))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
        XCTAssertEqual(image.width, 400)
    }

    func testRejectedFilesAddNothing() throws {
        let (store, job) = store()
        let good = try textPDF("gut.pdf", pages: ["Eine ganz normale Seite mit ausreichend Text darauf"])
        let note = folder.appendingPathComponent("notiz.txt")
        try Data("Hallo".utf8).write(to: note)
        XCTAssertThrowsError(try FileImport.add([good, note], to: job.id, store: store)) {
            XCTAssertEqual($0 as? FileImportError, .unsupported("notiz.txt"))
        }
        XCTAssertEqual(store.job(job.id)?.pages.count, 0, "alles oder nichts")

        let locked = folder.appendingPathComponent("geschuetzt.pdf")
        let document = PDFDocument(url: good)!
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "geheim", .ownerPasswordOption: "geheim"]))
        XCTAssertThrowsError(try FileImport.add([locked], to: job.id, store: store)) {
            XCTAssertEqual($0 as? FileImportError, .protectedPDF("geschuetzt.pdf"))
        }

        let many = try textPDF("viele.pdf", pages: Array(repeating: "Seite mit genug Text für die Erkennung", count: 6))
        XCTAssertThrowsError(try FileImport.add([many], to: job.id, store: store, maxPages: 5)) {
            XCTAssertEqual($0 as? FileImportError, .tooManyPages(max: 5))
        }
        XCTAssertTrue(FileImport.isSupported(good))
        XCTAssertFalse(FileImport.isSupported(note))
        XCTAssertTrue(FileImport.isSupported(URL(fileURLWithPath: "/x/Foto.HEIC")))
    }

    /// Gemischt: ein Scan, eine Text-PDF im Querformat, ein eingescanntes PDF. Abgelegt wird ein Dokument, in dem
    /// die Text-PDF-Seite unverändert steckt (Originaltext, Originalgröße) und die anderen wie Scans.
    func testMixedJobFilesOriginalPageUnchanged() async throws {
        try requireTextRecognition()
        let (store, job) = store()
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Gescannte Seite"), source: .platen, looksBlank: false)
        let landscape = try textPDF("quer.pdf", pages: ["Kontoauszug Musterbank Oktober 2026 mit Umsatzliste"],
                                    size: CGSize(width: 842, height: 595))
        let scanned = try imagePDF("alt.pdf", text: "Altes Schreiben")
        _ = try FileImport.add([landscape, scanned], to: job.id, store: store)
        var current = try store.update(job.id) { $0.state = .scanned; $0.shortID = "abc123" }
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: current)
        current = try store.update(job.id) { $0.state = .ready }

        let urls = try await BatchFiler(store: store, folder: folder.appendingPathComponent("Ablage"), year: .twoDigit,
                                        typeTitles: [:]).fileAll(job: current, text: text)
        let pdf = try XCTUnwrap(PDFDocument(url: urls[0]))
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Gescannte") ?? false, "Scan mit Textebene")
        let original = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertTrue(original.string?.contains("Kontoauszug Musterbank Oktober 2026") ?? false, "Originaltext erhalten")
        XCTAssertEqual(original.bounds(for: .mediaBox).size, CGSize(width: 842, height: 595), "Originalgröße erhalten")
        XCTAssertTrue(pdf.page(at: 2)?.string?.contains("Schreiben") ?? false, "Bild-PDF bekommt Textebene")

        // Die kleine Fassung für Claude besteht nur aus Bildern (wie bisher).
        let analysis = try await processor.analysisPDF(job: current, text: text)
        XCTAssertEqual(PDFDocument(data: analysis)?.page(at: 1)?.bounds(for: .mediaBox).size,
                       CGSize(width: 595.28, height: 841.89))
    }

    /// Fotos-App: bietet z. B. HEIC, JPEG und TIFF an. Genommen wird das Original, nicht die TIFF-Vorschau.
    func testPreferredTypeForDraggedPhotos() {
        XCTAssertEqual(FileImport.preferredType(among: ["public.tiff", "public.heic", "public.jpeg"])?.identifier, "public.heic")
        XCTAssertEqual(FileImport.preferredType(among: ["public.tiff"])?.identifier, "public.tiff")
        XCTAssertEqual(FileImport.preferredType(among: ["public.png", "com.adobe.pdf"])?.identifier, "com.adobe.pdf")
        XCTAssertNil(FileImport.preferredType(among: ["public.plain-text", "com.apple.NSFilePromiseItemMetaData"]))
    }
}

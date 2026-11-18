import DocKit
import PDFKit
import XCTest
@testable import ScanCore

// Die Tests von `TextRecognizer` liegen in DocKit.

final class PDFBuilderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testTextLayerIsSearchableAndMetadataSet() throws {
        try requireTextRecognition()
        let url = try jpeg("1.jpg", TestScanner.makePage(text: "Beitragsbescheid"))
        let text = try TextRecognizer.recognize(jpegURL: url)
        let pdf = try PDFBuilder.build(pages: [PDFPageInput(jpegURL: url, text: text),
                                               PDFPageInput(jpegURL: url, text: nil)],
                                       metadata: PDFMetadata(title: "Beitragsbescheid", author: "AOK Bayern",
                                                             subject: "BR", keywords: ["BR", "Scan to me"]))
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Beitragsbescheid") ?? false, document.page(at: 0)?.string ?? "")
        XCTAssertFalse(document.findString("Beitragsbescheid", withOptions: []).isEmpty)
        let attributes = try XCTUnwrap(document.documentAttributes)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Beitragsbescheid")
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "AOK Bayern")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "Scan to me")
        let bounds = try XCTUnwrap(document.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(bounds.width, 595.28, accuracy: 0.5)
    }

    func testInvisibleTextDoesNotShow() throws {
        let url = try jpeg("blank.jpg", TestScanner.render(width: 2480, height: 3508) { _ in })
        let text = RecognizedPage(lines: [RecognizedLine(text: "Geheimer unsichtbarer Text",
                                                         box: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.03))])
        let pdf = try PDFBuilder.build(pages: [PDFPageInput(jpegURL: url, text: text)])
        let page = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0))
        XCTAssertTrue(page.string?.contains("Geheimer unsichtbarer Text") ?? false)
        let rendered = try XCTUnwrap(page.thumbnail(of: CGSize(width: 620, height: 877), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(try XCTUnwrap(BlankPageDetector.inkCoverage(rendered)), 0, "Text darf nicht sichtbar sein")
    }

    func testJPEGIsEmbeddedWithoutRecompression() throws {
        var total = 0
        var inputs: [PDFPageInput] = []
        for i in 1...3 {
            let data = try TestScanner.makePage(text: "Seite \(i)")
            total += data.count
            inputs.append(PDFPageInput(jpegURL: try jpeg("p\(i).jpg", data), text: nil))
        }
        let pdf = try PDFBuilder.build(pages: inputs)
        let ratio = Double(pdf.count) / Double(total)
        XCTAssertGreaterThan(ratio, 0.9)
        XCTAssertLessThan(ratio, 1.2)
    }

    func testNoPages() {
        XCTAssertThrowsError(try PDFBuilder.build(pages: [])) { XCTAssertEqual($0 as? PDFBuilderError, .noPages) }
    }
}

final class DocumentFilerTests: XCTestCase {
    var dir: URL!
    var pdf: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpeg = dir.appendingPathComponent("p.jpg")
        try TestScanner.makePage(text: "x").write(to: jpeg)
        pdf = dir.appendingPathComponent("dokument.pdf")
        try PDFBuilder.build(pages: [PDFPageInput(jpegURL: jpeg, text: nil)]).write(to: pdf)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFilesAndVerifiesWithoutLeftovers() throws {
        let folder = dir.appendingPathComponent("Ablage")
        let filed = try DocumentFiler.file(pdfAt: pdf, name: "26-11-15_Scan_abcdef.pdf", in: folder, expectedPages: 1)
        XCTAssertEqual(filed.lastPathComponent, "26-11-15_Scan_abcdef.pdf")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["26-11-15_Scan_abcdef.pdf"])
    }

    func testNeverOverwrites() throws {
        let folder = dir.appendingPathComponent("Ablage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("a.pdf")
        try Data("alt".utf8).write(to: existing)
        XCTAssertThrowsError(try DocumentFiler.file(pdfAt: pdf, name: "a.pdf", in: folder, expectedPages: 1)) {
            XCTAssertEqual($0 as? DocumentFilerError, .nameTaken("a.pdf"))
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "alt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.pdf"], "keine Reste")
    }

    func testWrongPageCountFailsVerification() throws {
        XCTAssertThrowsError(try DocumentFiler.file(pdfAt: pdf, name: "b.pdf", in: dir, expectedPages: 2)) {
            XCTAssertEqual($0 as? DocumentFilerError, .verificationFailed("b.pdf"))
        }
    }

    func testFreeNameRerollsID() throws {
        try Data().write(to: dir.appendingPathComponent("x_aaaaaa.pdf"))
        XCTAssertEqual(DocumentFiler.freeName(in: dir, preferredID: "bbbbbb", makeName: { "x_\($0).pdf" }), "x_bbbbbb.pdf")
        var ids = ["aaaaaa", "cccccc"].makeIterator()
        XCTAssertEqual(DocumentFiler.freeName(in: dir, preferredID: "aaaaaa", makeName: { "x_\($0).pdf" },
                                              newID: { ids.next()! }), "x_cccccc.pdf")
    }
}

final class DocumentProcessorTests: XCTestCase {
    func testJobToSearchablePDF() async throws {
        try requireTextRecognition()
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let job = try store.create()
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Rechnung Nummer 4711"), source: .feeder, looksBlank: false)
        try store.addPage(to: job.id, jpeg: TestScanner.makeBlankPage(), source: .feeder, looksBlank: true)
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Anlage Zahlungsplan"), source: .feeder, looksBlank: false)
        let current = try XCTUnwrap(store.job(job.id))

        let processor = DocumentProcessor(store: store)
        let progress = ProgressRecorder()
        let text = try await processor.recognizeText(job: current) { done, total in await progress.add("\(done)/\(total)") }
        let steps = await progress.steps
        XCTAssertEqual(steps, ["1/2", "2/2"], "aussortierte Seite wird übersprungen")
        XCTAssertEqual(processor.savedText(job: current), text)

        let url = try await processor.buildPDF(job: current, text: text, metadata: PDFMetadata())
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.string?.contains("4711") ?? false)
        XCTAssertTrue(document.string?.contains("Zahlungsplan") ?? false)
    }
}

actor ProgressRecorder {
    var steps: [String] = []
    func add(_ step: String) { steps.append(step) }
}

final class EndToEndWithoutRecognitionTests: XCTestCase {
    func testScanProcessAndFile() async throws {
        try requireTextRecognition()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let folder = base.appendingPathComponent("Dokumente/Scan-to-me")

        let job = try store.create(now: Date(timeIntervalSince1970: 1_794_700_000)) // 15.11.2026
        let scanner = TestScanner(delay: 0, feeder: [.text("Kfz-Steuerbescheid"), .blank, .text("Seite zwei")])
        let run = await ScanRunner(scanner: scanner, store: store, removeBlankPages: true)
            .run(jobID: job.id, settings: ScanSettings().forFeeder(maxWidth: 2550))
        XCTAssertNil(run.error)

        let ready = try store.update(job.id) { $0.state = .scanned; $0.shortID = "c0ffee" }
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: ready)
        let pdf = try await processor.buildPDF(job: ready, text: text, metadata: PDFMetadata(keywords: ["Scan to me"]))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let name = try XCTUnwrap(DocumentFiler.freeName(in: folder, preferredID: "c0ffee") {
            FileNamer.scanFileName(date: ready.createdAt, id: $0, year: .twoDigit, calendar: calendar)
        })
        XCTAssertEqual(name, "26-11-15_Scan_c0ffee.pdf")
        let filed = try DocumentFiler.file(pdfAt: pdf, name: name, in: folder, expectedPages: 2)
        let document = try XCTUnwrap(PDFDocument(url: filed))
        XCTAssertEqual(document.pageCount, 2, "leere Seite nicht im PDF")
        XCTAssertTrue(document.string?.contains("Steuerbescheid") ?? false)
    }
}

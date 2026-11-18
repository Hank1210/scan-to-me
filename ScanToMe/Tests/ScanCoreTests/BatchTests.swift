import DocKit
import PDFKit
import XCTest
@testable import ScanCore

private func proposal(_ first: Int, _ last: Int, _ code: String = "BR", sender: String = "Absender",
                      title: String = "Brief", id: String? = nil) -> DocumentProposal {
    DocumentProposal(firstPage: first, lastPage: last, typeCode: code, sender: sender, title: title,
                     documentDate: nil, dateKind: nil, splitConfidence: "hoch", shortID: id)
}

final class DocumentRangesTests: XCTestCase {
    private var counter = 0
    private func nextID() -> String { counter += 1; return String(format: "id%04d", counter) }

    func testSplitInsideDocument() throws {
        let start = [proposal(1, 3, id: "aaaaaa"), proposal(4, 5, id: "bbbbbb")]
        let result = try XCTUnwrap(DocumentRanges.split(start, at: 3, newID: nextID))
        XCTAssertEqual(result.map(\.pages), [[1, 2], [3], [4, 5]])
        XCTAssertEqual(result.map(\.needsNaming), [true, true, nil])
        XCTAssertEqual(result[0].shortID, "aaaaaa")
        XCTAssertEqual(result[1].shortID, "id0001", "neues Dokument, neue Kurz-ID")
        XCTAssertNil(result[0].splitConfidence)
    }

    func testSplitAtExistingBoundaryOrOutsideIsRejected() {
        let start = [proposal(1, 3), proposal(4, 5)]
        XCTAssertNil(DocumentRanges.split(start, at: 4))
        XCTAssertNil(DocumentRanges.split(start, at: 1))
        XCTAssertNil(DocumentRanges.split(start, at: 6))
    }

    func testMergeKeepsFirstFieldsAndAsksForNaming() throws {
        let start = [proposal(1, 2, "RE", sender: "Stadtwerke"), proposal(3, 3, "BR"), proposal(4, 5)]
        let result = try XCTUnwrap(DocumentRanges.merge(start, 0, with: 1))
        XCTAssertEqual(result.map(\.pages), [[1, 2, 3], [4, 5]])
        XCTAssertNil(result[0].pageList, "zusammenhängend: keine Liste nötig")
        XCTAssertEqual(result[0].typeCode, "RE")
        XCTAssertEqual(result[0].needsNaming, true)
        XCTAssertNil(DocumentRanges.merge(result, 1, with: 2), "gibt es nicht")
        XCTAssertNil(DocumentRanges.merge(result, 1, with: 1))
    }

    func testFiledDocumentsCannotChange() {
        var start = [proposal(1, 2), proposal(3, 4)]
        start[0].filedName = "x.pdf"
        XCTAssertNil(DocumentRanges.merge(start, 0, with: 1))
        XCTAssertNil(DocumentRanges.merge(start, 1, with: 0))
        XCTAssertNil(DocumentRanges.split(start, at: 2))
        XCTAssertNotNil(DocumentRanges.split(start, at: 4))
    }

    func testEnforceStartsFromSeparators() {
        let result = DocumentRanges.enforce(starts: [3, 5], in: [proposal(1, 4), proposal(5, 6)], newID: nextID)
        XCTAssertEqual(result.map(\.pages), [[1, 2], [3, 4], [5, 6]], "Start 5 ist schon eine Grenze")
    }

    func testAssignIDsKeepsJobIDFirstAndAvoidsDuplicates() {
        var ids = ["aaaaaa", "cccccc"]
        let result = DocumentRanges.assignIDs([proposal(1, 1), proposal(2, 2), proposal(3, 3, id: "bbbbbb")],
                                              jobID: "aaaaaa", newID: { ids.removeFirst() })
        XCTAssertEqual(result.map(\.shortID), ["aaaaaa", "cccccc", "bbbbbb"])
    }

    /// Rechnung auf Seite 1 und 3, dazwischen ein fremdes Blatt.
    func testMergeAcrossAnotherDocument() throws {
        let start = [proposal(1, 1, "RE", sender: "MVV", title: "Beitragsrechnung", id: "aaaaaa"),
                     proposal(2, 2, "BR", sender: "DRV", id: "bbbbbb"), proposal(3, 3, "UB", id: "cccccc")]
        let result = try XCTUnwrap(DocumentRanges.merge(start, 2, with: 0), "auch von unten nach oben")
        XCTAssertEqual(result.map(\.pages), [[1, 3], [2]])
        XCTAssertEqual(result[0].sender, "MVV")
        XCTAssertEqual(result[0].shortID, "aaaaaa")
        XCTAssertEqual(result[0].pagesLabel, "Seiten 1, 3")
        XCTAssertEqual(result[1].pagesLabel, "Seite 2")
        XCTAssertTrue(DocumentRanges.coversAll(result, pageCount: 3))
        // Wieder trennen: Seite 3 wird eigenes Dokument, Reihenfolge nach erster Seite.
        let back = try XCTUnwrap(DocumentRanges.split(result, at: 3))
        XCTAssertEqual(back.map(\.pages), [[1], [2], [3]])
    }

    func testPagesLabel() {
        var p = proposal(1, 1)
        p.setPages([5, 1, 2, 7, 6])
        XCTAssertEqual(p.pagesLabel, "Seiten 1–2, 5–7")
        XCTAssertEqual(p.firstPage, 1)
        XCTAssertEqual(p.lastPage, 7)
        XCTAssertEqual(proposal(3, 4).pagesLabel, "Seiten 3–4")
    }

    func testEveryPageStaysInExactlyOneDocumentAfterRandomEdits() {
        var docs = [proposal(1, 20)]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            if Bool.random(using: &generator), docs.count > 1 {
                let a = Int.random(in: 0..<docs.count, using: &generator)
                let b = Int.random(in: 0..<docs.count, using: &generator)
                docs = DocumentRanges.merge(docs, a, with: b) ?? docs
            } else {
                docs = DocumentRanges.split(docs, at: Int.random(in: 1...20, using: &generator)) ?? docs
            }
            XCTAssertTrue(DocumentRanges.coversAll(docs, pageCount: 20))
            XCTAssertEqual(docs.map(\.firstPage), docs.map(\.firstPage).sorted())
        }
    }
}

final class SplitAnalysisTests: XCTestCase {
    func testSplitInstructionNamesSeparatorStarts() {
        let text = DocumentAnalysis.userInstruction(pageCount: 8, split: true, forcedStarts: [4, 1, 9, 7])
        XCTAssertTrue(text.contains("Seiten 4, 7 beginnt jeweils sicher ein neues Dokument"))
        XCTAssertTrue(text.contains("Jede Seite von 1 bis 8"))
        XCTAssertTrue(text.contains("ohne eigenen Briefkopf"))
        XCTAssertFalse(DocumentAnalysis.userInstruction(pageCount: 8, split: true).contains("Trennblatt"))
        XCTAssertTrue(DocumentAnalysis.userInstruction(pageCount: 3, split: false).contains("genau einen Eintrag"))
    }

    func testSplitResponseBecomesSeveralProposals() throws {
        let json = """
        {"dokumente":[
          {"von_seite":1,"bis_seite":2,"typ":"RE","von":"Stadtwerke","name":"Stromrechnung","dokumentdatum":"01.10.2026","datumsart":"Rechnungsdatum","sicherheit_trennung":"hoch"},
          {"von_seite":3,"bis_seite":3,"typ":"BR","von":"DRV","name":"Renteninformation","dokumentdatum":"","datumsart":"keins","sicherheit_trennung":"niedrig"}]}
        """
        let result = try DocumentAnalysis.proposals(fromJSON: json, pageCount: 3, split: true, knownCodes: ["RE", "BR", "UB"])
        XCTAssertEqual(result.map(\.pages), [[1, 2], [3]])
        XCTAssertEqual(result[1].splitConfidence, "niedrig")
        XCTAssertNil(result[1].documentDate)
    }
}

final class RangeRepairTests: XCTestCase {
    private func item(_ from: Int, _ to: Int, _ von: String) -> String {
        #"{"von_seite":\#(from),"bis_seite":\#(to),"typ":"RE","von":"\#(von)","name":"X","dokumentdatum":"","datumsart":"keins","sicherheit_trennung":"hoch"}"#
    }
    private func parse(_ items: [String], pages: Int) throws -> [DocumentProposal] {
        try DocumentAnalysis.proposals(fromJSON: #"{"dokumente":[\#(items.joined(separator: ","))]}"#, pageCount: pages,
                                       split: true, knownCodes: ["RE"])
    }

    /// Fremdes Blatt zwischen zwei AutoFix-Seiten: Claude listet AutoFix zuerst. Früher wurde daraus ein Dokument.
    func testOutOfOrderRangesAreSortedNotCollapsed() throws {
        let result = try parse([item(1, 1, "AutoFix"), item(3, 4, "AutoFix"), item(2, 2, "Prüfdienst")], pages: 4)
        XCTAssertEqual(result.map(\.pages), [[1], [2], [3, 4]])
        XCTAssertEqual(result.map(\.sender), ["AutoFix", "Prüfdienst", "AutoFix"])
        XCTAssertEqual(result.map(\.splitConfidence), ["hoch", "hoch", "hoch"])
    }

    /// So hat Claude am 16.11. geantwortet: AutoFix „1–3“, fremdes Blatt „2–2“, vier Seiten.
    func testNestedRangeBecomesDocumentWithGap() throws {
        let result = try parse([item(1, 3, "AutoFix"), item(2, 2, "Prüfdienst")], pages: 4)
        XCTAssertEqual(result.map(\.pages), [[1, 3, 4], [2]])
        XCTAssertEqual(result[0].pagesLabel, "Seiten 1, 3–4")
    }

    func testPageListsFromClaude() throws {
        let json = #"{"dokumente":[{"seiten":[1,3,4],"typ":"RE","von":"AutoFix","name":"Werkstattrechnung","dokumentdatum":"","datumsart":"keins","sicherheit_trennung":"hoch"},{"seiten":[2],"typ":"RE","von":"Prüfdienst","name":"Prüfbericht","dokumentdatum":"","datumsart":"keins","sicherheit_trennung":"hoch"}]}"#
        let result = try DocumentAnalysis.proposals(fromJSON: json, pageCount: 4, split: true, knownCodes: ["RE"])
        XCTAssertEqual(result.map(\.pages), [[1, 3, 4], [2]])
        XCTAssertEqual(result.map(\.splitConfidence), ["hoch", "hoch"])
        XCTAssertEqual(DocumentAnalysis.rangeSummary(fromJSON: json), "[1,3,4] [2]")
    }

    func testGapsAndOverlapsAreRepaired() throws {
        let result = try parse([item(1, 2, "A"), item(2, 3, "B"), item(5, 5, "C")], pages: 6)
        XCTAssertEqual(result.map(\.pages), [[1, 2], [3, 4], [5, 6]])
        XCTAssertEqual(result.map(\.splitConfidence), ["hoch", "niedrig", "niedrig"])
        XCTAssertTrue(DocumentRanges.coversAll(result, pageCount: 6))
    }

    func testDuplicateAndOutOfBoundsEntries() throws {
        let result = try parse([item(1, 4, "A"), item(2, 2, "B"), item(7, 9, "C")], pages: 4)
        XCTAssertEqual(result.map(\.pages), [[1, 3, 4], [2]])
        XCTAssertEqual(result.map(\.sender), ["A", "B"])
    }

    func testRandomAnswersAlwaysCoverAllPages() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let pages = Int.random(in: 1...12, using: &rng)
            let items = (0..<Int.random(in: 1...6, using: &rng)).map { _ -> String in
                let a = Int.random(in: -1...(pages + 2), using: &rng)
                return item(a, a + Int.random(in: -1...4, using: &rng), "X")
            }
            let result = try parse(items, pages: pages)
            XCTAssertTrue(DocumentRanges.coversAll(result, pageCount: pages), "\(items)")
        }
    }

    /// Claude füllt die Felder in Schema-Reihenfolge: Überblick und Seiten müssen vor dem Namen stehen.
    func testRequestFieldOrderPutsPagesBeforeNames() throws {
        let body = String(decoding: try DocumentAnalysis.requestBody(pdf: Data([1, 2]), pageCount: 4,
                                                                     types: DocumentTypes.recognitionOrder(custom: []), split: true), as: UTF8.self)
        func at(_ key: String) -> Int { body.range(of: "\"\(key)\":")!.lowerBound.utf16Offset(in: body) }
        XCTAssertLessThan(at("seitenueberblick"), at("dokumente"))
        XCTAssertLessThan(at("seiten"), at("von"))
        XCTAssertLessThan(at("von"), at("name"))
        XCTAssertLessThan(at("name"), at("sicherheit_trennung"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(body.utf8)))
    }

    func testUnclaimedPagesAreCounted() {
        XCTAssertEqual(DocumentAnalysis.unclaimedPageCount(fromJSON: #"{"dokumente":[\#(item(1, 2, "A"))]}"#, pageCount: 4), 2)
        XCTAssertEqual(DocumentAnalysis.unclaimedPageCount(fromJSON: #"{"dokumente":[\#(item(1, 3, "A")),\#(item(2, 2, "B"))]}"#, pageCount: 3), 0)
        XCTAssertEqual(DocumentAnalysis.unclaimedPageCount(fromJSON: "kaputt", pageCount: 3), 3)
    }

    func testRangeSummaryForLog() {
        XCTAssertEqual(DocumentAnalysis.rangeSummary(fromJSON: #"{"dokumente":[\#(item(1, 1, "A")),\#(item(3, 3, "B"))]}"#), "1–1 3–3")
        XCTAssertEqual(DocumentAnalysis.rangeSummary(fromJSON: "kaputt"), "?")
    }
}

final class SeparatorTests: XCTestCase {
    func testPrintedSheetIsRecognizedAfterScanning() throws {
        try requireTextRecognition()
        let pdf = try SeparatorSheet.pdf()
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestScanner.makeSeparatorPage().write(to: url)
        let page = try TextRecognizer.recognize(jpegURL: url)
        XCTAssertTrue(SeparatorSheet.isSeparator(page), page.text)
    }

    func testOrdinaryPagesAreNotSeparators() {
        let letter = RecognizedPage(lines: ["Stadtwerke Musterstadt", "Ihre Stromrechnung", "Seite 1 von 2"].map {
            RecognizedLine(text: $0, box: .zero)
        })
        XCTAssertFalse(SeparatorSheet.isSeparator(letter))
        let mention = RecognizedPage(lines: (0..<20).map { RecognizedLine(text: $0 == 3 ? "Trennblatt Scan to me" : "Text", box: .zero) })
        XCTAssertFalse(SeparatorSheet.isSeparator(mention), "viel Text: kein Trennblatt")
    }
}

final class BatchEndToEndTests: XCTestCase {
    func testSeparatorsSplitAndEachDocumentIsFiled() async throws {
        try requireTextRecognition()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let folder = base.appendingPathComponent("Ablage")

        let job = try store.create(now: Date(timeIntervalSince1970: 1_794_700_000))
        let scanner = TestScanner(delay: 0, feeder: [.separator, .text("Rechnung eins"), .text("Rechnung zwei"),
                                                     .separator, .blank, .text("Brief drei")])
        _ = await ScanRunner(scanner: scanner, store: store, removeBlankPages: true)
            .run(jobID: job.id, settings: ScanSettings().forFeeder(maxWidth: 2550))
        var current = try store.update(job.id) { $0.state = .scanned; $0.shortID = "c0ffee" }

        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: current)
        XCTAssertEqual(text.count, 5)
        let cleaned = try processor.removeSeparators(job: current, text: text)
        XCTAssertEqual(cleaned.removed, 2)
        current = cleaned.job
        XCTAssertEqual(current.includedPages.count, 3)
        XCTAssertEqual(current.forcedStarts, [3], "Trennblatt am Anfang ergibt keine Trennstelle")
        XCTAssertEqual(current.pages.filter { $0.isSeparator == true }.count, 2)
        XCTAssertTrue(current.pages[0].excluded, "Trennblatt aussortiert, nicht gelöscht")
        XCTAssertEqual(processor.savedText(job: current)?.count, 3)

        // Antwort von Claude nachgestellt: alles ein Dokument. Das Trennblatt erzwingt die Trennung.
        var proposals = DocumentRanges.enforce(starts: current.forcedStarts ?? [], in: [proposal(1, 3, "RE", sender: "Stadtwerke", title: "Stromrechnung")])
        proposals = DocumentRanges.assignIDs(proposals, jobID: current.shortID)
        proposals[1].typeCode = "BR"
        proposals[1].sender = "DRV"
        proposals[1].title = "Renteninformation"
        current = try store.update(job.id) { $0.proposals = proposals; $0.state = .ready }

        let filer = BatchFiler(store: store, folder: folder, year: .twoDigit, typeTitles: ["RE": "Rechnung"])
        let urls = try await filer.fileAll(job: current, text: cleaned.text)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map { PDFDocument(url: $0)?.pageCount }, [2, 1])
        XCTAssertTrue(urls[0].lastPathComponent.hasPrefix("26-11-15_RE_Stadtwerke_Stromrechnung_c0ffee"))
        XCTAssertTrue(urls[1].lastPathComponent.contains("_BR_DRV_Renteninformation_"))
        XCTAssertTrue(PDFDocument(url: urls[0])?.string?.contains("Rechnung zwei") ?? false)
        XCTAssertFalse(PDFDocument(url: urls[1])?.string?.contains("TRENNBLATT") ?? true)

        // Erneuter Aufruf legt nichts doppelt ab.
        let again = try await filer.fileAll(job: try XCTUnwrap(store.job(job.id)), text: cleaned.text)
        XCTAssertEqual(again, urls)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".pdf") }.count, 2)
    }

    func testNonContiguousDocumentKeepsScanOrder() async throws {
        try requireTextRecognition()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let job = try store.create()
        for text in ["MVV Seite eins", "Fremdes Blatt", "MVV Seite zwei"] {
            try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: text), source: .feeder, looksBlank: false)
        }
        var mvv = proposal(1, 1, "RE", sender: "MVV", title: "Beitragsrechnung", id: "aaaaaa")
        mvv.setPages([1, 3])
        let current = try store.update(job.id) { $0.proposals = [mvv, proposal(2, 2, id: "bbbbbb")]; $0.shortID = "aaaaaa" }
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: current)
        let urls = try await BatchFiler(store: store, folder: base.appendingPathComponent("Ablage"), year: .twoDigit,
                                        typeTitles: [:]).fileAll(job: current, text: text)
        let first = try XCTUnwrap(PDFDocument(url: urls[0]))
        XCTAssertEqual(first.pageCount, 2)
        XCTAssertTrue(first.page(at: 0)?.string?.contains("eins") ?? false)
        XCTAssertTrue(first.page(at: 1)?.string?.contains("zwei") ?? false)
        XCTAssertEqual(PDFDocument(url: urls[1])?.pageCount, 1)
    }

    func testWithoutRecognitionOneScanFile() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let job = try store.create(now: Date(timeIntervalSince1970: 1_794_700_000))
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Hallo"), source: .platen, looksBlank: false)
        let current = try store.update(job.id) { $0.shortID = "abcdef" }
        let urls = try await BatchFiler(store: store, folder: base.appendingPathComponent("Ablage"), year: .fourDigit,
                                        typeTitles: [:]).fileAll(job: current, text: nil)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["2026-11-15_Scan_abcdef.pdf"])
    }
}

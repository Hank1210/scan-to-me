import DocKit
import PDFKit
import XCTest
@testable import ScanCore

final class UsageLedgerTests: XCTestCase {
    private func ledger() -> UsageLedger {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return UsageLedger(url: url)
    }

    func testSumsPerMonth() {
        let l = ledger()
        let nov = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
        let oct = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        l.record(input: 12_000, output: 200, at: nov)
        l.record(input: 3_000, output: 100, at: nov)
        l.record(input: 1_000_000, output: 0, at: oct)
        XCTAssertEqual(l.month(containing: nov), .init(inputTokens: 15_000, outputTokens: 300, requests: 2))
        XCTAssertEqual(l.previousMonth(before: nov).requests, 1)
        XCTAssertEqual(l.previousMonth(before: nov).costUSD, 2.0, accuracy: 0.0001)
        XCTAssertEqual(l.month(containing: nov).costUSD, 0.033, accuracy: 0.0001, "15k × 2 $ + 300 × 10 $ je Million")
        // Bleibt nach Neustart erhalten.
        XCTAssertEqual(UsageLedger(url: l.url).month(containing: nov).requests, 2)
    }

    func testCostText() {
        XCTAssertEqual(formatCost(0.033), "ca. 3,3 Cent")
        XCTAssertEqual(formatCost(0.42), "ca. 42 Cent")
        XCTAssertEqual(formatCost(3.456), "ca. 3,46 $")
    }

    /// Jede Antwort wird gezählt, auch eine, die die App danach verwirft.
    func testClientRecordsEveryResponse() async throws {
        let l = ledger()
        SequenceProtocol.requests = 0
        SequenceProtocol.steps = [
            .http(200, #"{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"{}"}],"usage":{"input_tokens":100,"output_tokens":10}}"#),
            .http(200, #"{"model":"m","stop_reason":"max_tokens","content":[],"usage":{"input_tokens":50,"output_tokens":8000}}"#),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        let client = ClaudeClient(apiKey: "k", session: URLSession(configuration: config), ledger: l, sleep: { _ in })
        _ = try await client.send(body: Data())
        do { _ = try await client.send(body: Data()); XCTFail() } catch { XCTAssertEqual(error as? ClaudeError, .truncated) }
        XCTAssertEqual(l.month(containing: Date()), .init(inputTokens: 150, outputTokens: 8010, requests: 2))
    }
}

final class LaterRecognitionTests: XCTestCase {
    func testParseScanNames() throws {
        let short = try XCTUnwrap(LaterRecognition.parse("26-11-16_Scan_a3f9c2.pdf"))
        XCTAssertEqual(short.id, "a3f9c2")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(short.date)),
                       DateComponents(year: 2026, month: 11, day: 16))
        XCTAssertEqual(LaterRecognition.parse("2026-11-16_Scan_a3f9c2.pdf")?.id, "a3f9c2")
        XCTAssertNil(LaterRecognition.parse("26-11-16_RE_Telekom_Rechnung_a3f9c2.pdf"))
        XCTAssertNil(LaterRecognition.parse("26-13-40_Scan_a3f9c2.pdf"), "ungültiges Datum")
        XCTAssertNil(LaterRecognition.parse("26-11-16_Scan_a3f9c2.pdf.tmp"))
    }

    func testCandidatesAndRenameWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["26-11-16_Scan_a3f9c2.pdf", "26-11-10_Scan_bbbbbb.pdf", "26-11-16_RE_X_Y_cccccc.pdf", ".versteckt.pdf"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let found = LaterRecognition.candidates(in: folder)
        XCTAssertEqual(found.map(\.name), ["26-11-16_Scan_a3f9c2.pdf", "26-11-10_Scan_bbbbbb.pdf"])

        // Ohne Dokumentdatum gilt das Scandatum aus dem alten Namen; die ID bleibt.
        let proposal = DocumentProposal(firstPage: 1, lastPage: 1, typeCode: "RE", sender: "Telekom", title: "Rechnung",
                                        documentDate: nil, dateKind: nil)
        XCTAssertEqual(LaterRecognition.proposedName(found[0], proposal: proposal, scheme: .standard),
                       "26-11-16_RE_Telekom_Rechnung_a3f9c2.pdf")
        // Der Zielname ist schon belegt: neue ID statt Überschreiben.
        try Data("andere".utf8).write(to: folder.appendingPathComponent("26-11-16_RE_Telekom_Rechnung_a3f9c2.pdf"))
        let renamed = try LaterRecognition.rename(found[0], proposal: proposal, scheme: .standard)
        XCTAssertNotEqual(renamed.lastPathComponent, "26-11-16_RE_Telekom_Rechnung_a3f9c2.pdf")
        XCTAssertTrue(renamed.lastPathComponent.hasPrefix("26-11-16_RE_Telekom_Rechnung_"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("26-11-16_RE_Telekom_Rechnung_a3f9c2.pdf"), encoding: .utf8), "andere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: found[0].url.path))
        XCTAssertThrowsError(try LaterRecognition.rename(found[0], proposal: proposal, scheme: .standard)) {
            XCTAssertEqual($0 as? LaterRecognitionError, .gone)
        }
    }

    func testAnalyzeSendsFiledPdfAndKeepsID() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("26-11-16_Scan_a3f9c2.pdf")
        try SeparatorSheet.pdf().write(to: url)
        let scan = try XCTUnwrap(LaterRecognition.candidates(in: folder).first)
        let text = #"{\"seitenueberblick\":[],\"dokumente\":[{\"seiten\":[1],\"typ\":\"BR\",\"von\":\"DRV\",\"name\":\"Renteninformation\",\"dokumentdatum\":\"03.11.2026\",\"datumsart\":\"Briefdatum\",\"sicherheit_trennung\":\"hoch\"}]}"#
        SequenceProtocol.requests = 0
        SequenceProtocol.steps = [.http(200, #"{"model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}],"usage":{}}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        let client = ClaudeClient(apiKey: "k", session: URLSession(configuration: config), sleep: { _ in })
        let proposal = try await LaterRecognition.analyze(scan, client: client, types: DocumentTypes.recognitionOrder(custom: []))
        XCTAssertEqual(proposal.shortID, "a3f9c2")
        XCTAssertEqual(LaterRecognition.proposedName(scan, proposal: proposal, scheme: .standard),
                       "26-11-03_BR_DRV_Renteninformation_a3f9c2.pdf")
    }
}

final class LaterTrashTests: XCTestCase {
    func testMoveToTrashKeepsFileRecoverable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("26-11-16_Scan_a3f9c2.pdf"))
        let scan = try XCTUnwrap(LaterRecognition.candidates(in: folder).first)
        let inTrash = try LaterRecognition.moveToTrash(scan)
        defer { if let inTrash { try? FileManager.default.removeItem(at: inTrash) } }
        XCTAssertTrue(LaterRecognition.candidates(in: folder).isEmpty)
        XCTAssertTrue(inTrash.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "liegt im Papierkorb")
        XCTAssertThrowsError(try LaterRecognition.moveToTrash(scan)) { XCTAssertEqual($0 as? LaterRecognitionError, .gone) }
    }
}

final class CrashRecoveryTests: XCTestCase {
    /// Absturz nach dem Schreiben der Datei, aber vor dem Vermerk: kein zweites Exemplar beim nächsten Versuch.
    func testFileWrittenBeforeCrashIsNotFiledTwice() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let folder = base.appendingPathComponent("Ablage")
        let job = try store.create()
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Eins"), source: .feeder, looksBlank: false)
        try store.addPage(to: job.id, jpeg: TestScanner.makePage(text: "Zwei"), source: .feeder, looksBlank: false)
        let a = DocumentProposal(firstPage: 1, lastPage: 1, typeCode: "RE", sender: "A", title: "Eins", documentDate: nil,
                                 dateKind: nil, shortID: "aaaaaa")
        let b = DocumentProposal(firstPage: 2, lastPage: 2, typeCode: "BR", sender: "B", title: "Zwei", documentDate: nil,
                                 dateKind: nil, shortID: "bbbbbb")
        var current = try store.update(job.id) { $0.proposals = [a, b]; $0.shortID = "aaaaaa"; $0.state = .ready }
        let filer = BatchFiler(store: store, folder: folder, year: .twoDigit, typeTitles: [:])
        let text = try await DocumentProcessor(store: store).recognizeText(job: current)

        // Erster Durchgang komplett, dann den Absturz nachstellen: Vermerk des ersten Dokuments zurücknehmen.
        let urls = try await filer.fileAll(job: current, text: text)
        current = try store.update(job.id) { $0.proposals?[0].filedName = nil; $0.proposals?[1].filedName = nil
                                              $0.proposals?[1].filingName = nil }
        try FileManager.default.removeItem(at: urls[1])
        XCTAssertNotNil(current.proposals?[0].filingName)

        let again = try await filer.fileAll(job: current, text: text)
        XCTAssertEqual(again[0], urls[0], "erkannt statt neu abgelegt")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".pdf") }
        XCTAssertEqual(files.count, 2, "kein Doppel: \(files)")
        XCTAssertEqual(store.job(job.id)?.proposals?.map(\.filedName), again.map(\.lastPathComponent))
    }

    func testIncompleteFileIsNotTakenAsFiled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.pdf")
        try Data("kaputt".utf8).write(to: url)
        XCTAssertFalse(DocumentFiler.isComplete(url, expectedPages: 1))
        try SeparatorSheet.pdf().write(to: url)
        XCTAssertTrue(DocumentFiler.isComplete(url, expectedPages: 1))
        XCTAssertFalse(DocumentFiler.isComplete(url, expectedPages: 2))
    }

    func testStaleTemporaryFilesAreRemovedOthersKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [".26-11-16_RE_A_B_aaaaaa.pdf.1a2b3c4d.tmp", ".neu.pdf.99999999.tmp", "26-11-16_Scan_a3f9c2.pdf",
                     ".DS_Store", "notiz.tmp"]
        for name in names { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        let old = Date().addingTimeInterval(-7200)
        for name in [names[0], names[2], names[3], names[4]] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        XCTAssertEqual(DocumentFiler.removeStaleTemporaryFiles(in: folder), 1)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(left, Set(names.dropFirst()), "nur die alte Zwischendatei weg, die frische bleibt")
    }
}

// Die Tests von `runWithTimeout` liegen in DocKit.

final class FeederWatchTests: XCTestCase {
    private func status(_ jobs: [(String, String, Int)]) -> String {
        let infos = jobs.map { id, state, images in
            "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(id)</pwg:JobUri><pwg:JobUuid>\(id)</pwg:JobUuid>"
                + "<scan:Age>3</scan:Age><pwg:ImagesCompleted>\(images)</pwg:ImagesCompleted>"
                + "<pwg:JobState>\(state)</pwg:JobState></scan:JobInfo>"
        }.joined()
        return "<scan:ScannerStatus><pwg:State>Processing</pwg:State><scan:AdfState>ScannerAdfProcessing</scan:AdfState>"
            + "<scan:Jobs>\(infos)</scan:Jobs></scan:ScannerStatus>"
    }

    private let mine = "bf6cafc3-1111-2222-3333-444455556666"

    func testJobLookup() {
        let xml = status([("48556fba-0000-0000-0000-000000000000", "Completed", 1), (mine, "Processing", 1)])
        XCTAssertEqual(ScannerStatusInfo.job(mine, in: xml)?.state, "Processing")
        XCTAssertEqual(ScannerStatusInfo.job(mine, in: xml)?.images, 1)
        XCTAssertNil(ScannerStatusInfo.job("ffffffff-0000-0000-0000-000000000000", in: xml))
    }

    /// Lange Pausen des Epson (Auftrag läuft) werden weiter abgewartet; beendete Aufträge nicht.
    func testJudge() {
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([(mine, "Processing", 1)]), received: 1), .running)
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([(mine, "Aborted", 1)]), received: 1), .ended("Aborted"))
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([(mine, "Canceled", 1)]), received: 1), .ended("Canceled"))
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([("andere-id", "Processing", 0)]), received: 1), .ended("–"),
                       "Auftrag nicht mehr aufgeführt")
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([(mine, "Completed", 2)]), received: 1), .completedWithMissingImage)
        XCTAssertEqual(ESCLScanner.judge(jobID: mine, xml: status([(mine, "Completed", 1)]), received: 1), .ended("Completed"))
    }

    func testJobEndedMessageKeepsPagesHint() {
        let result = ScanRunResult(pagesAdded: 1, blankPages: 0, error: ScanError.jobEnded("Aborted"))
        let text = result.problemMessage ?? ""
        XCTAssertTrue(text.contains("von sich aus beendet"), text)
        XCTAssertTrue(text.contains("1 Seite wurde bereits übernommen"), text)
    }
}

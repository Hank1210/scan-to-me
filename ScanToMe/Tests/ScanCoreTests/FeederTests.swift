import CoreText
import XCTest
@testable import ScanCore

final class ScannerStatusTests: XCTestCase {
    func testParsesEpsonStatusWithEmptyFeeder() {
        // Wörtlich vom Epson WF-2960 am 15.11.2026.
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.9</pwg:Version><pwg:State>Idle</pwg:State><scan:AdfState>ScannerAdfEmpty</scan:AdfState></scan:ScannerStatus>"#
        let info = ScannerStatusInfo.parse(xml)
        XCTAssertEqual(info.state, .idle)
        XCTAssertTrue(info.feederEmpty)
        XCTAssertNil(info.feederProblem)
    }

    func testFeederProblems() {
        XCTAssertNil(ScannerStatusInfo(state: .idle, adfState: "ScannerAdfLoaded").feederProblem)
        XCTAssertNil(ScannerStatusInfo(state: .idle, adfState: nil).feederProblem)
        XCTAssertEqual(ScannerStatusInfo(state: .idle, adfState: "ScannerAdfJam").feederProblem, "ScannerAdfJam")
        XCTAssertEqual(ScanError.feederProblem("ScannerAdfJam").errorDescription,
                       "Papierstau im Einzug. Bitte das Papier vorsichtig herausziehen.")
        XCTAssertTrue(ScanError.feederProblem("ScannerAdfSomethingNew").errorDescription!.contains("ScannerAdfSomethingNew"))
    }

    func testFeederSettingsXMLUsesFullFeederWidth() {
        let feeder = ScanSettings(resolution: 200, color: false).forFeeder(maxWidth: 2550)
        XCTAssertTrue(feeder.xml.contains("<pwg:InputSource>Feeder</pwg:InputSource>"))
        XCTAssertTrue(feeder.xml.contains("<pwg:Width>2550</pwg:Width>"))
        XCTAssertTrue(feeder.xml.contains("<scan:XResolution>200</scan:XResolution>"))
        XCTAssertTrue(feeder.xml.contains("<scan:ColorMode>Grayscale8</scan:ColorMode>"))
        XCTAssertEqual(ScanSettings().forFeeder(maxWidth: nil).widthThreeHundredths, 2550)
        XCTAssertEqual(ScanSettings().forFeeder(maxWidth: 2600).widthThreeHundredths, 2550)
    }
}

final class BlankPageDetectorTests: XCTestCase {
    private func page(_ draw: (CGContext) -> Void) throws -> Data {
        try TestScanner.render(width: 2480, height: 3508, draw: draw)
    }

    private func text(_ string: String, size: CGFloat, gray: CGFloat, at y: CGFloat) -> (CGContext) -> Void {
        { context in
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: CGColor(gray: gray, alpha: 1)]))
            context.textPosition = CGPoint(x: 300, y: y)
            CTLineDraw(line, context)
        }
    }

    func testWhiteAndGreyishPagesAreBlank() throws {
        XCTAssertTrue(BlankPageDetector.isBlank(jpeg: try page { _ in }))
        XCTAssertTrue(BlankPageDetector.isBlank(jpeg: try TestScanner.makeBlankPage()), "Grauschleier und Randschatten")
    }

    func testBleedThroughIsBlank() throws {
        let bleed = try page { context in
            for row in 0..<40 {
                self.text("Durchscheinende Schrift der Vorderseite, nur hellgrau sichtbar",
                          size: 50, gray: 0.8, at: CGFloat(3200 - row * 75))(context)
            }
        }
        XCTAssertTrue(BlankPageDetector.isBlank(jpeg: bleed))
    }

    func testTextPagesAreNotBlank() throws {
        XCTAssertFalse(BlankPageDetector.isBlank(jpeg: try TestScanner.makePage(text: "Seite 1")))
        let oneShortLine = try page(text("Seite 2 von 2", size: 50, gray: 0, at: 1800))
        let coverage = try XCTUnwrap(BlankPageDetector.inkCoverage(jpeg: oneShortLine))
        XCTAssertFalse(BlankPageDetector.isBlank(jpeg: oneShortLine), "Abdeckung \(coverage)")
        let signature = try page(text("_______________", size: 50, gray: 0, at: 600))
        XCTAssertFalse(BlankPageDetector.isBlank(jpeg: signature), "Nur ein Unterschriftsstrich ist keine leere Seite")
    }

    func testUnreadableDataIsNeverBlank() {
        XCTAssertFalse(BlankPageDetector.isBlank(jpeg: Data([1, 2, 3])))
    }
}

final class JobStoreTests: XCTestCase {
    var store: JobStore!

    override func setUp() {
        store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.root)
    }

    func testPagesArePersistedImmediatelyAndBlankOnesExcluded() throws {
        let job = try store.create()
        try store.addPage(to: job.id, jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), source: .platen, looksBlank: false)
        let updated = try store.addPage(to: job.id, jpeg: Data([0xFF, 0xD8, 0, 0xFF, 0xD9]), source: .feeder, looksBlank: true)
        XCTAssertEqual(updated.pages.map(\.file), ["seite-001.jpg", "seite-002.jpg"])
        XCTAssertEqual(updated.includedPages.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pageURL(updated, updated.pages[1]).path))

        // Neu laden wie nach einem Neustart.
        let reloaded = try XCTUnwrap(JobStore(root: store.root).job(job.id))
        XCTAssertEqual(reloaded, updated)
    }

    func testExcludeAndRestorePage() throws {
        let job = try store.create()
        try store.addPage(to: job.id, jpeg: Data([1]), source: .feeder, looksBlank: true)
        XCTAssertEqual(try store.setExcluded(false, page: 0, in: job.id).includedPages.count, 1)
        XCTAssertThrowsError(try store.setExcluded(true, page: 5, in: job.id))
    }

    func testAllSortedNewestFirstAndDelete() throws {
        let old = try store.create(now: Date(timeIntervalSince1970: 1000))
        let new = try store.create(now: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.all().map(\.id), [new.id, old.id])
        try store.setState(.scanned, in: old.id)
        XCTAssertEqual(store.job(old.id)?.state, .scanned)
        try store.delete(old.id)
        XCTAssertEqual(store.all().map(\.id), [new.id])
    }
}

final class ScanRunnerTests: XCTestCase {
    var store: JobStore!

    override func setUp() {
        store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: store.root)
    }

    private func runner(_ scanner: TestScanner, blank: Bool = true) -> ScanRunner {
        ScanRunner(scanner: scanner, store: store, removeBlankPages: blank)
    }

    private let feeder = ScanSettings().forFeeder(maxWidth: 2550)

    func testFeederScansAllSheetsAndExcludesBlankOnes() async throws {
        let scanner = TestScanner(delay: 0, feeder: TestScanner.sampleFeeder)
        let job = try store.create()
        let result = await runner(scanner).run(jobID: job.id, settings: feeder)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pagesAdded, 6)
        XCTAssertEqual(result.blankPages, 1)
        let saved = try XCTUnwrap(store.job(job.id))
        XCTAssertEqual(saved.pages.map(\.looksBlank), [false, false, true, false, false, false], "Trennblatt ist nicht leer")
        XCTAssertEqual(saved.includedPages.count, 5)
    }

    func testBlankDetectionOffKeepsAll() async throws {
        let scanner = TestScanner(delay: 0, feeder: [.text("a"), .blank])
        let job = try store.create()
        _ = await runner(scanner, blank: false).run(jobID: job.id, settings: feeder)
        XCTAssertEqual(store.job(job.id)?.includedPages.count, 2)
    }

    func testPlatenNeverChecksForBlank() async throws {
        let job = try store.create()
        let result = await runner(TestScanner(delay: 0)).run(jobID: job.id, settings: ScanSettings())
        XCTAssertEqual(result.pagesAdded, 1)
        XCTAssertEqual(store.job(job.id)?.pages.first?.source, .platen)
    }

    func testJamKeepsPagesAndContinuesWithRest() async throws {
        let scanner = TestScanner(delay: 0, feeder: [.text("1"), .text("2"), .jam, .text("3")])
        let job = try store.create()
        let first = await runner(scanner).run(jobID: job.id, settings: feeder)
        XCTAssertEqual(first.error as? ScanError, .feederProblem("ScannerAdfJam"))
        XCTAssertEqual(first.pagesAdded, 2)
        XCTAssertEqual(first.problemMessage,
                       "Papierstau im Einzug. Bitte das Papier vorsichtig herausziehen. 2 Seiten wurden bereits übernommen. "
                       + "Legen Sie die übrigen Blätter erneut ein und wählen Sie „Weiter scannen“.")
        // Weiter scannen: der Rest kommt dazu.
        let second = await runner(scanner).run(jobID: job.id, settings: feeder)
        XCTAssertNil(second.error)
        XCTAssertEqual(store.job(job.id)?.pages.count, 3)
    }

    func testEmptyFeeder() async throws {
        let job = try store.create()
        let result = await runner(TestScanner(delay: 0)).run(jobID: job.id, settings: feeder)
        XCTAssertEqual(result.error as? ScanError, .feederEmpty)
        XCTAssertEqual(result.pagesAdded, 0)
        XCTAssertEqual(result.problemMessage, ScanError.feederEmpty.errorDescription)
    }

    func testPageLimitPerJob() async throws {
        let job = try store.create()
        for _ in 0..<(ScanRunner.maxPagesPerJob - 2) {
            try store.addPage(to: job.id, jpeg: Data([1]), source: .platen, looksBlank: false)
        }
        let scanner = TestScanner(delay: 0, feeder: [.text("a"), .text("b"), .text("c")])
        let result = await runner(scanner).run(jobID: job.id, settings: feeder)
        XCTAssertEqual(result.pagesAdded, 2)
        XCTAssertEqual(result.error as? ScanError, .pageLimitReached(2))
        XCTAssertEqual(store.job(job.id)?.pages.count, ScanRunner.maxPagesPerJob)

        let full = await runner(TestScanner(delay: 0)).run(jobID: job.id, settings: ScanSettings())
        XCTAssertEqual(full.error as? ScanError, .pageLimitReached(ScanRunner.maxPagesPerJob))
    }

    func testCancelKeepsPagesAlreadyScanned() async throws {
        let scanner = TestScanner(delay: 0.3, feeder: Array(repeating: .text("x"), count: 10))
        let job = try store.create()
        let runner = self.runner(scanner)
        let task = Task { await runner.run(jobID: job.id, settings: feeder) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertNil(result.problemMessage)
        XCTAssertGreaterThan(result.pagesAdded, 0)
        XCTAssertLessThan(result.pagesAdded, 10)
        XCTAssertEqual(store.job(job.id)?.pages.count, result.pagesAdded)
    }
}

final class ScanLogTests: XCTestCase {
    func testStatusSummaryWithJobs() {
        // Wörtlich vom Epson nach dem Neustart am 15.11.2026 (gekürzt auf zwei Aufträge).
        let xml = #"<scan:ScannerStatus><pwg:State>Idle</pwg:State><scan:AdfState>ScannerAdfEmpty</scan:AdfState><scan:Jobs><scan:JobInfo><pwg:JobUuid>1d638239-f554-4a72-acff-d93e70382ddf</pwg:JobUuid><pwg:ImagesCompleted>1</pwg:ImagesCompleted><pwg:JobState>Completed</pwg:JobState></scan:JobInfo><scan:JobInfo><pwg:JobUuid>dcfb2652-6d72-4573-a7a1-59d22dabcd21</pwg:JobUuid><pwg:ImagesCompleted>0</pwg:ImagesCompleted><pwg:JobState>Processing</pwg:JobState></scan:JobInfo></scan:Jobs></scan:ScannerStatus>"#
        XCTAssertEqual(ScanLog.summarizeStatus(xml),
                       "State=Idle Adf=ScannerAdfEmpty Jobs=[1d638239 Completed 1 Bilder, dcfb2652 Processing 0 Bilder]")
    }

    func testShortPathAndRotation() throws {
        let url = URL(string: "https://EPSON123456.local:443/eSCL/ScanJobs/1d638239-f554-4a72-acff-d93e70382ddf/NextDocument")!
        XCTAssertEqual(ScanLog.shortPath(url), "ScanJobs/1d638239/NextDocument")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ScanLog(url: dir.appendingPathComponent("scanner.log"), maxBytes: 100)
        for i in 0..<10 { log.write("Zeile \(i) mit etwas Text") }
        let current = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(current.contains("Zeile 9"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("scanner.1.log").path))
    }
}

final class TimeoutMessageTests: XCTestCase {
    func testTimeoutExplainsWhatToDo() {
        let none = ScanRunResult(pagesAdded: 0, blankPages: 0, error: ScanError.timeout)
        XCTAssertTrue(none.problemMessage!.hasPrefix("Der Drucker hat nach 5 Minuten noch keine Seite geliefert"))
        XCTAssertTrue(none.problemMessage!.contains("aus und wieder ein"), "Neustart empfehlen")
        let some = ScanRunResult(pagesAdded: 3, blankPages: 0, error: ScanError.timeout)
        XCTAssertTrue(some.problemMessage!.contains("3 Seiten wurden bereits übernommen"))
    }
}

import XCTest
@testable import ScanCore

final class DuplexTests: XCTestCase {
    func testInterleaveReversedBacks() {
        // Vorher gescannt: X, dann Vorderseiten V1–V3, dann Rückseiten (Stapel umgedreht: R3, R2, R1), dann Y.
        let items = ["X", "V1", "V2", "V3", "R3", "R2", "R1", "Y"]
        XCTAssertEqual(Duplex.interleave(items, start: 1, sheets: 3, backsReversed: true),
                       ["X", "V1", "R1", "V2", "R2", "V3", "R3", "Y"])
        XCTAssertEqual(Duplex.interleave(["V1", "V2", "R1", "R2"], start: 0, sheets: 2, backsReversed: false),
                       ["V1", "R1", "V2", "R2"])
        XCTAssertNil(Duplex.interleave(items, start: 3, sheets: 3, backsReversed: true), "zu wenige Seiten")
        XCTAssertNil(Duplex.interleave(items, start: 0, sheets: 0, backsReversed: true))
    }

    func testDeinterleaveIsInverse() {
        for _ in 0..<300 {
            let count = Int.random(in: 2...30)
            let items = Array(0..<count)
            let sheets = Int.random(in: 1...(count / 2))
            let start = Int.random(in: 0...(count - 2 * sheets))
            let reversed = Bool.random()
            let merged = Duplex.interleave(items, start: start, sheets: sheets, backsReversed: reversed)!
            XCTAssertEqual(Set(merged), Set(items), "keine Seite verloren")
            XCTAssertEqual(Duplex.deinterleave(merged, start: start, sheets: sheets, backsReversed: reversed), items)
        }
    }

    /// Mit dem Test-Scanner: drei Blätter, die Rückseite von Blatt 2 ist leer.
    func testFrontsThenBacksFromFeeder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(root: root)
        let job = try store.create()
        let settings = ScanSettings().forFeeder(maxWidth: 2550)

        let fronts = await ScanRunner(scanner: TestScanner(delay: 0, feeder: [.text("V1"), .text("V2"), .text("V3")]),
                                      store: store, removeBlankPages: true).run(jobID: job.id, settings: settings)
        XCTAssertEqual(fronts.pagesAdded, 3)
        let pass = FeederPass(start: 0, count: 3)
        let backs = await ScanRunner(scanner: TestScanner(delay: 0, feeder: [.text("R3"), .blank, .text("R1")]),
                                     store: store, removeBlankPages: true).run(jobID: job.id, settings: settings)
        XCTAssertEqual(backs.pagesAdded, 3)
        XCTAssertEqual(backs.blankPages, 1)

        let filesBefore = Set(try XCTUnwrap(store.job(job.id)).pages.map(\.file))
        var merged = try store.mergeDuplex(job.id, fronts: pass)
        XCTAssertEqual(Set(merged.pages.map(\.file)), filesBefore, "nur umsortiert")
        // Reihenfolge der Dateien: V1 (seite-001), R1 (seite-006), V2 (002), leer (005), V3 (003), R3 (004)
        XCTAssertEqual(merged.pages.map(\.file), ["seite-001.jpg", "seite-006.jpg", "seite-002.jpg", "seite-005.jpg",
                                                  "seite-003.jpg", "seite-004.jpg"])
        XCTAssertEqual(merged.pages.map(\.excluded), [false, false, false, true, false, false], "leere Rückseite aussortiert")
        XCTAssertEqual(merged.duplex, DuplexMerge(start: 0, sheets: 3, backsReversed: true))
        XCTAssertNil(merged.lastFeederPass)

        merged = try store.flipDuplexBacks(job.id)
        XCTAssertEqual(merged.pages.map(\.file), ["seite-001.jpg", "seite-004.jpg", "seite-002.jpg", "seite-005.jpg",
                                                  "seite-003.jpg", "seite-006.jpg"])
        merged = try store.flipDuplexBacks(job.id)
        XCTAssertEqual(merged.pages.map(\.file)[1], "seite-006.jpg", "zweimal umkehren = wie vorher")
    }
}

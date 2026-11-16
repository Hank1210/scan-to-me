import XCTest
@testable import ScanCore

/// Einzug am echten Scanner. Alle Tests brauchen LIVE_SCANNER_HOST=<host>.
/// - `testLiveStatus`: liest nur den Status (kein Auftrag).
/// - `testLiveEmptyFeeder` mit LIVE_FEEDER_EMPTY=1: Einzug muss leer sein; erwartet „kein Papier“ ohne Auftrag.
/// - `testLiveFeederScan` mit LIVE_FEEDER_PAGES=<Anzahl Blätter>: zieht alle Blätter ein und prüft die Anzahl.
final class LiveFeederTest: XCTestCase {
    private var host: String { ProcessInfo.processInfo.environment["LIVE_SCANNER_HOST"] ?? "" }
    private var scanner: ESCLScanner { ESCLScanner(address: ScannerAddress(name: "Live", host: host, port: 443, useTLS: true)) }

    func testLiveStatus() async throws {
        try XCTSkipIf(host.isEmpty, "Nur mit LIVE_SCANNER_HOST")
        let info = try await scanner.statusInfo()
        print("LIVE: Status \(info.state.rawValue), Einzug \(info.adfState ?? "–")")
    }

    func testLiveEmptyFeeder() async throws {
        try XCTSkipIf(host.isEmpty || ProcessInfo.processInfo.environment["LIVE_FEEDER_EMPTY"] == nil,
                      "Nur mit LIVE_SCANNER_HOST und LIVE_FEEDER_EMPTY=1")
        do {
            try await scanner.scanFeeder(settings: ScanSettings().forFeeder(maxWidth: 2550), maxPages: 50) { _ in
                XCTFail("Seite trotz leerem Einzug")
            }
            XCTFail("Kein Fehler bei leerem Einzug")
        } catch {
            print("LIVE: leerer Einzug → \(error)")
            XCTAssertEqual(error as? ScanError, .feederEmpty)
        }
        let after = try await scanner.statusInfo()
        print("LIVE: danach \(after.state.rawValue)")
        XCTAssertEqual(after.state, .idle, "Es darf kein Auftrag hängen bleiben")
    }

    func testLiveFeederScan() async throws {
        let expected = Int(ProcessInfo.processInfo.environment["LIVE_FEEDER_PAGES"] ?? "") ?? 0
        try XCTSkipIf(host.isEmpty || expected == 0, "Nur mit LIVE_SCANNER_HOST und LIVE_FEEDER_PAGES=<n>")
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("scan-to-me-live"))
        let job = try store.create()
        let start = Date()
        let runner = ScanRunner(scanner: scanner, store: store, removeBlankPages: true)
        let result = await runner.run(jobID: job.id, settings: ScanSettings().forFeeder(maxWidth: 2550)) { updated in
            let page = updated.pages.last!
            print("LIVE: Seite \(updated.pages.count) nach \(Int(Date().timeIntervalSince(start))) s, leer: \(page.looksBlank)")
        }
        let saved = try XCTUnwrap(store.job(job.id))
        print("LIVE: \(result.pagesAdded) Seiten, \(result.blankPages) leer, Fehler: \(String(describing: result.error)), "
              + "Dauer \(Int(Date().timeIntervalSince(start))) s, Ordner \(store.folder(job.id).path)")
        XCTAssertNil(result.error)
        XCTAssertEqual(saved.pages.count, expected)
    }
}

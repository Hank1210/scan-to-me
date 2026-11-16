import XCTest
@testable import ScanCore

/// Prüft die Zertifikatsbindung am echten Scanner. Läuft nur mit LIVE_SCANNER_HOST=<host>.
final class LiveScannerPinningTest: XCTestCase {
    func testPinnedFingerprintIsEnforced() async throws {
        let host = ProcessInfo.processInfo.environment["LIVE_SCANNER_HOST"] ?? ""
        try XCTSkipIf(host.isEmpty, "Nur mit LIVE_SCANNER_HOST")
        let base = ScannerAddress(name: "Live", host: host, port: 443, useTLS: true)

        let firstContact = ESCLScanner(address: base)
        let fingerprint = try await firstContact.fetchCertificateFingerprint()
        print("LIVE: Fingerabdruck \(fingerprint ?? "nil")")
        let pinned = try XCTUnwrap(fingerprint)

        var good = base
        good.certificateSHA256 = pinned
        let state = try await ESCLScanner(address: good).status()
        print("LIVE: mit richtigem Fingerabdruck: \(state)")
        let caps = try await ESCLScanner(address: good).capabilities()
        print("LIVE: Fähigkeiten: \(caps.makeAndModel ?? "?") · \(caps.summary)")
        XCTAssertTrue(caps.hasPlaten)

        var bad = base
        bad.certificateSHA256 = String(repeating: "0", count: 64)
        do {
            _ = try await ESCLScanner(address: bad).status()
            XCTFail("Falscher Fingerabdruck wurde akzeptiert")
        } catch {
            print("LIVE: mit falschem Fingerabdruck: \(error)")
            XCTAssertEqual(error as? ScanError, .certificateMismatch)
        }
    }
}

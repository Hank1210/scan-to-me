import XCTest
@testable import ScanCore

final class ESCLScannerTests: XCTestCase {
    func testParsesScannerState() {
        let xml = #"<?xml version="1.0"?><scan:ScannerStatus xmlns:scan="x" xmlns:pwg="y"><pwg:Version>2.9</pwg:Version><pwg:State>Idle</pwg:State><scan:AdfState>ScannerAdfEmpty</scan:AdfState></scan:ScannerStatus>"#
        XCTAssertEqual(ESCLScanner.firstTagValue("State", in: xml), "Idle")
        XCTAssertNil(ESCLScanner.firstTagValue("Missing", in: xml))
    }

    func testDetectsIncompleteJPEG() {
        XCTAssertTrue(ESCLScanner.isCompleteJPEG(Data([0xFF, 0xD8, 0x00, 0x11, 0xFF, 0xD9])))
        XCTAssertFalse(ESCLScanner.isCompleteJPEG(Data([0xFF, 0xD8, 0x00, 0x11, 0x00, 0x00])))
        XCTAssertFalse(ESCLScanner.isCompleteJPEG(Data()))
    }

    func testBaseURL() {
        let address = ScannerAddress(name: "Epson", host: "EPSON123456.local", port: 443, rootPath: "/eSCL", useTLS: true)
        XCTAssertEqual(address.baseURL.absoluteString, "https://EPSON123456.local:443/eSCL")
    }

    func testSettingsXMLContainsA4Platen300dpi() {
        let xml = ScanSettings().xml
        XCTAssertTrue(xml.contains("<pwg:InputSource>Platen</pwg:InputSource>"))
        XCTAssertTrue(xml.contains("<scan:XResolution>300</scan:XResolution>"))
        XCTAssertTrue(xml.contains("<pwg:Width>2480</pwg:Width>"))
        XCTAssertTrue(xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
    }
}

final class RetryPolicyTests: XCTestCase {
    func testOnlyStallsAreRetried() {
        XCTAssertTrue(ESCLScanner.isRetryable(.timeout))
        XCTAssertTrue(ESCLScanner.isRetryable(.incompleteImage(10)))
        XCTAssertFalse(ESCLScanner.isRetryable(.unreachable("x")))
        XCTAssertFalse(ESCLScanner.isRetryable(.busy("Processing")))
    }
}

final class CertificatePinningTests: XCTestCase {
    func testTrustOnFirstUseThenExactMatch() {
        XCTAssertTrue(ESCLScanner.certificateMatches(pinned: nil, actual: "abc"))
        XCTAssertTrue(ESCLScanner.certificateMatches(pinned: "", actual: nil))
        XCTAssertTrue(ESCLScanner.certificateMatches(pinned: "ABC", actual: "abc"))
        XCTAssertFalse(ESCLScanner.certificateMatches(pinned: "abc", actual: "abd"))
        XCTAssertFalse(ESCLScanner.certificateMatches(pinned: "abc", actual: nil))
        XCTAssertFalse(ESCLScanner.isRetryable(.certificateMismatch))
    }

    func testOldSavedAddressWithoutFingerprintStillDecodes() throws {
        let json = #"{"name":"Epson","host":"h.local","port":443,"rootPath":"eSCL","useTLS":true}"#
        let address = try JSONDecoder().decode(ScannerAddress.self, from: Data(json.utf8))
        XCTAssertNil(address.certificateSHA256)
    }
}

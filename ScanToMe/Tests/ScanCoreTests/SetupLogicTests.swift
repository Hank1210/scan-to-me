import XCTest
@testable import ScanCore

final class ScannerCapabilitiesTests: XCTestCase {
    /// Gekürzte Antwort im Aufbau eines Epson WF-2960 (Flachbett + einseitiger Einzug).
    let epsonLike = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
      <pwg:Version>2.6</pwg:Version>
      <pwg:MakeAndModel>EPSON WF-2960 Series</pwg:MakeAndModel>
      <scan:Platen><scan:PlatenInputCaps><scan:MinWidth>16</scan:MinWidth></scan:PlatenInputCaps></scan:Platen>
      <scan:Adf><scan:AdfSimplexInputCaps><scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth></scan:AdfSimplexInputCaps><scan:FeederCapacity>50</scan:FeederCapacity></scan:Adf>
    </scan:ScannerCapabilities>
    """

    func testEpsonLikeHasPlatenAndSimplexFeeder() {
        let caps = ScannerCapabilities.parse(epsonLike)
        XCTAssertEqual(caps, ScannerCapabilities(makeAndModel: "EPSON WF-2960 Series", hasPlaten: true,
                                                 hasFeeder: true, feederDuplex: false,
                                                 feederMaxWidth: 2550, feederCapacity: 50))
        XCTAssertEqual(caps.summary, "Flachbett: ja · Einzug: ja (einseitig)")
    }

    func testDuplexFeederAndPlatenOnly() {
        let duplex = epsonLike.replacingOccurrences(
            of: "</scan:Adf>", with: "<scan:AdfDuplexInputCaps></scan:AdfDuplexInputCaps></scan:Adf>")
        XCTAssertTrue(ScannerCapabilities.parse(duplex).feederDuplex)

        let platenOnly = "<scan:ScannerCapabilities><scan:Platen></scan:Platen></scan:ScannerCapabilities>"
        let caps = ScannerCapabilities.parse(platenOnly)
        XCTAssertFalse(caps.hasFeeder)
        XCTAssertEqual(caps.summary, "Flachbett: ja · Einzug: nein")
    }

    func testAdfSimplexAloneIsNotMistakenForElement() {
        XCTAssertFalse(ScannerCapabilities.containsElement("Adf", in: "<scan:AdfSimplexInputCaps>"))
        XCTAssertTrue(ScannerCapabilities.containsElement("Adf", in: "<Adf xmlns=\"x\">"))
    }
}

final class StorageFolderTests: XCTestCase {
    func testCreatesMissingFolderAndChecksWriteAccess() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Dokumente/Scan-to-me")
        try StorageFolder.prepare(folder)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "Probedatei bleibt nicht liegen")
    }

    func testFileInsteadOfFolderIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try StorageFolder.prepare(file)) { error in
            XCTAssertEqual(error as? StorageFolderError, .notADirectory(file.path))
        }
    }

    func testReadOnlyFolderIsRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertThrowsError(try StorageFolder.prepare(folder)) { error in
            XCTAssertEqual(error as? StorageFolderError, .notWritable(folder.path))
        }
    }

    func testDefaultIsInDocuments() {
        XCTAssertEqual(StorageFolder.defaultURL.lastPathComponent, "Scan-to-me")
        XCTAssertEqual(StorageFolder.defaultURL.deletingLastPathComponent().lastPathComponent, "Documents")
    }
}

/// Ersetzt die Netzwerkantwort für die Schlüsselprüfung.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var error: URLError?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AnthropicKeyCheckerTests: XCTestCase {
    private func checker() -> AnthropicKeyChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return AnthropicKeyChecker(session: URLSession(configuration: config))
    }

    override func setUp() {
        StubProtocol.status = 200
        StubProtocol.error = nil
        StubProtocol.lastRequest = nil
    }

    func testValidKeySendsHeadersAndTrimsWhitespace() async {
        let result = await checker().check("  sk-ant-test \n")
        XCTAssertEqual(result, .valid)
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/v1/models")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod ?? "GET", "GET")
    }

    func testRejectedKey() async {
        StubProtocol.status = 401
        let result = await checker().check("sk-ant-falsch")
        XCTAssertEqual(result, .invalid)
    }

    func testEmptyKeyIsInvalidWithoutRequest() async {
        let result = await checker().check("   ")
        XCTAssertEqual(result, .invalid)
        XCTAssertNil(StubProtocol.lastRequest)
    }

    func testServerErrorAndNoNetwork() async {
        StubProtocol.status = 529
        let overloaded = await checker().check("k")
        XCTAssertEqual(overloaded, .failed(529))
        StubProtocol.error = URLError(.notConnectedToInternet)
        let offline = await checker().check("k")
        guard case .unreachable = offline else { return XCTFail("\(offline)") }
    }
}

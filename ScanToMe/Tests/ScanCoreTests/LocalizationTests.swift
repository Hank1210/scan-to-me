import XCTest
@testable import ScanCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localization.current = .de
    }

    func testLocPicksCurrentLanguage() {
        Localization.current = .de
        XCTAssertEqual(loc("Seite", "Page"), "Seite")
        Localization.current = .en
        XCTAssertEqual(loc("Seite", "Page"), "Page")
    }

    func testSystemDefault() {
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["en-GB", "de-DE"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: ["fr-FR"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferred: []), .en)
    }

    func testMessagesAndLabelsInEnglish() {
        Localization.current = .en
        XCTAssertEqual(ScanError.timeout.errorDescription, "Timed out waiting for the image.")
        XCTAssertEqual(DocumentTypeError.invalidCode.errorDescription, "The code must consist of exactly two letters or digits.")
        var p = DocumentProposal(firstPage: 1, lastPage: 1, typeCode: "RE", sender: "", title: "", documentDate: nil, dateKind: nil)
        p.setPages([1, 3, 4])
        XCTAssertEqual(p.pagesLabel, "Pages 1, 3–4")
        let invoice = DocumentTypes.builtIn.first { $0.code == "RE" }!
        XCTAssertEqual(DocumentTypes.displayTitle(invoice), "Invoice")
        XCTAssertEqual(invoice.title, "Rechnung", "an Claude gehen die deutschen Texte")
        let custom = DocumentType(code: "ST", title: "ST", hint: "Steuer", isBuiltIn: false)
        XCTAssertEqual(DocumentTypes.displayHint(custom), "Steuer", "eigene Typen bleiben, wie eingegeben")
    }

    func testEnglishAsksClaudeForEnglishNames() {
        let types = DocumentTypes.recognitionOrder(custom: [])
        XCTAssertTrue(DocumentAnalysis.systemPrompt(types: types, language: .en).contains("Schreibe name auf Englisch"))
        XCTAssertFalse(DocumentAnalysis.systemPrompt(types: types, language: .de).contains("Englisch"))
    }

    func testEnglishSeparatorSheetIsRecognized() throws {
        Localization.current = .en
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestScanner.makeSeparatorPage().write(to: url)
        let page = try TextRecognizer.recognize(jpegURL: url)
        XCTAssertTrue(page.text.uppercased().contains("SEPARATOR"))
        XCTAssertTrue(SeparatorSheet.isSeparator(page))
    }

    func testEnglishCodesInFileNameButGermanInside() {
        Localization.current = .en
        let p = DocumentProposal(firstPage: 1, lastPage: 1, typeCode: "RE", sender: "Telekom", title: "Phone bill",
                                 documentDate: nil, dateKind: nil)
        let name = FileNamer.fileName(p.nameParts(scanDate: Date(timeIntervalSince1970: 1_790_000_000), id: "abc123"), year: .twoDigit)
        XCTAssertTrue(name.contains("_IN_Telekom_Phone-bill_abc123"), name)
        XCTAssertEqual(p.typeCode, "RE", "intern bleibt das deutsche Kürzel")
        XCTAssertEqual(["BR", "RE", "AZ", "UB", "XY"].map { DocumentTypes.displayCode($0) }, ["LT", "IN", "MD", "UN", "XY"])
        Localization.current = .de
        XCTAssertTrue(FileNamer.fileName(p.nameParts(scanDate: Date(), id: "abc123"), year: .twoDigit).contains("_RE_"))
    }

    func testCustomTypeCannotUseEnglishBuiltInCode() {
        let errors = DocumentTypes.validate([CustomTypeEntry(code: "IN", hint: "Irgendwas"), CustomTypeEntry(code: "ST", hint: "Steuer")])
        XCTAssertEqual(errors.first ?? nil, .reservedCode("IN"))
        XCTAssertNil(errors[1])
    }
}

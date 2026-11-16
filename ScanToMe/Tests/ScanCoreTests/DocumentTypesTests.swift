import XCTest
@testable import ScanCore

final class DocumentTypesTests: XCTestCase {
    func testBuiltInTypes() {
        XCTAssertEqual(DocumentTypes.builtIn.map(\.code), ["BR", "RE", "AZ", "UB"])
        XCTAssertTrue(DocumentTypes.builtIn.allSatisfy(\.isBuiltIn))
    }

    func testValidCustomTypeIsNormalized() {
        let entries = [CustomTypeEntry(code: " st", hint: " Steuerunterlagen: Steuerbescheide ")]
        XCTAssertEqual(DocumentTypes.validate(entries), [nil])
        let types = DocumentTypes.customTypes(from: entries)
        XCTAssertEqual(types, [DocumentType(code: "ST", title: "Steuerunterlagen: Steuerbescheide",
                                            hint: "Steuerunterlagen: Steuerbescheide", isBuiltIn: false)])
    }

    func testEmptySlotsAreIgnored() {
        let entries = [CustomTypeEntry(), CustomTypeEntry(code: "K1", hint: "Kita"), CustomTypeEntry(code: " ", hint: "")]
        XCTAssertEqual(DocumentTypes.validate(entries), [nil, nil, nil])
        XCTAssertEqual(DocumentTypes.customTypes(from: entries).map(\.code), ["K1"])
    }

    func testInvalidCodes() {
        for code in ["S", "STE", "S-", "Ä1", "", "  "] {
            let result = DocumentTypes.validate([CustomTypeEntry(code: code, hint: "Hinweis")])
            XCTAssertEqual(result, [.invalidCode], "Kürzel „\(code)“")
        }
    }

    func testReservedAndDuplicateCodes() {
        let entries = [CustomTypeEntry(code: "re", hint: "x"),
                       CustomTypeEntry(code: "ST", hint: "Steuer"),
                       CustomTypeEntry(code: "st", hint: "Nochmal Steuer")]
        XCTAssertEqual(DocumentTypes.validate(entries), [.reservedCode("RE"), nil, .duplicateCode("ST")])
        XCTAssertEqual(DocumentTypes.customTypes(from: entries).map(\.code), ["ST"])
    }

    func testHintRules() {
        XCTAssertEqual(DocumentTypes.validate([CustomTypeEntry(code: "ST", hint: "   ")]), [.missingHint])
        let long = String(repeating: "x", count: DocumentTypes.hintMaxLength + 1)
        XCTAssertEqual(DocumentTypes.validate([CustomTypeEntry(code: "ST", hint: long)]), [.hintTooLong])
        let exact = String(repeating: "x", count: DocumentTypes.hintMaxLength)
        XCTAssertEqual(DocumentTypes.validate([CustomTypeEntry(code: "ST", hint: exact)]), [nil])
    }

    func testOrderForDisplayAndRecognition() {
        let custom = DocumentTypes.customTypes(from: [CustomTypeEntry(code: "ST", hint: "Steuer")])
        XCTAssertEqual(DocumentTypes.catalog(custom: custom).map(\.code), ["BR", "RE", "AZ", "UB", "ST"])
        XCTAssertEqual(DocumentTypes.recognitionOrder(custom: custom).map(\.code), ["ST", "BR", "RE", "AZ", "UB"])
    }

    func testAtMostThreeCustomTypes() {
        let entries = ["A1", "A2", "A3", "A4"].map { CustomTypeEntry(code: $0, hint: "h") }
        XCTAssertEqual(DocumentTypes.customTypes(from: entries).count, 3)
    }
}

import XCTest
@testable import ScanCore

final class FileNameSchemeTests: XCTestCase {
    private let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
    private var parts: FileNameParts {
        FileNameParts(date: date, typeCode: "RE", sender: "Telekom", title: "Mobilfunkrechnung", id: "a3f9c2")
    }

    func testStandardSchemesUnchanged() {
        XCTAssertEqual(FileNameScheme(.twoDigit).fileName(parts), "26-11-16_RE_Telekom_Mobilfunkrechnung_a3f9c2.pdf")
        XCTAssertEqual(FileNameScheme(.fourDigit).fileName(parts), "2026-11-16_RE_Telekom_Mobilfunkrechnung_a3f9c2.pdf")
        XCTAssertEqual(FileNameScheme(.twoDigit).scanFileName(date: date, id: "a3f9c2"), "26-11-16_Scan_a3f9c2.pdf")
        XCTAssertEqual(FileNameScheme(.twoDigit).pattern, "YY-MM-DD_Typ_Von_Name_ID")
    }

    func testCustomOrderAndDateDashes() {
        let s = FileNameScheme(tokens: [.dd, .mm, .yyyy, .sender, .id])
        XCTAssertEqual(s.fileName(parts), "16-11-2026_Telekom_a3f9c2.pdf")
        XCTAssertEqual(s.scanFileName(date: date, id: "a3f9c2"), "16-11-2026_Scan_a3f9c2.pdf")
        // Datumsteile nicht nebeneinander: dann mit Unterstrich.
        XCTAssertEqual(FileNameScheme(tokens: [.yyyy, .type, .mm, .id]).fileName(parts), "2026_RE_11_a3f9c2.pdf")
        XCTAssertEqual(FileNameScheme(tokens: [.sender, .title, .yy, .mm, .id]).fileName(parts), "Telekom_Mobilfunkrechnung_26-11_a3f9c2.pdf")
        XCTAssertEqual(FileNameScheme(tokens: [.id, .type, .dd]).fileName(parts), "a3f9c2_RE_16.pdf", "ID darf vorn stehen")
    }

    func testOnlyIDGivesScanID() {
        let s = FileNameScheme(tokens: [.id])
        XCTAssertEqual(s.fileName(parts), "Scan_a3f9c2.pdf")
        XCTAssertEqual(s.scanFileName(date: date, id: "a3f9c2"), "Scan_a3f9c2.pdf")
    }

    func testRulesEnforced() {
        XCTAssertEqual(FileNameScheme(tokens: [.yy, .yyyy, .mm, .yy]).tokens, [.yy, .mm, .id], "doppelt/YY+YYYY, ID ergänzt")
        var s = FileNameScheme(tokens: [.yy, .mm, .id])
        s.remove(.id)
        XCTAssertEqual(s.tokens, [.yy, .mm, .id], "ID bleibt")
        XCTAssertFalse(s.addable.contains(.yyyy))
        XCTAssertTrue(s.addable.contains(.dd))
        s.add(.dd)
        XCTAssertEqual(s.tokens, [.yy, .mm, .id, .dd])
        s.move(.dd, by: -1)
        XCTAssertEqual(s.tokens, [.yy, .mm, .dd, .id])
        s.move(.yy, by: -1)
        XCTAssertEqual(s.tokens, [.yy, .mm, .dd, .id], "am Rand bleibt es")
        s.remove(.yy)
        XCTAssertTrue(s.addable.contains(.yyyy))
    }

    func testScanNamesFoundAgainForLaterRecognition() throws {
        let s = FileNameScheme(tokens: [.dd, .mm, .yyyy, .sender, .id])
        let parsed = try XCTUnwrap(s.parseScanName("16-11-2026_Scan_a3f9c2.pdf"))
        XCTAssertEqual(parsed.id, "a3f9c2")
        XCTAssertEqual(parsed.date, date)
        // Ohne vollständiges Datum im Namen: kein Datum (dann zählt das Dateidatum).
        let noYear = try XCTUnwrap(FileNameScheme(tokens: [.mm, .dd, .type, .id]).parseScanName("11-16_Scan_a3f9c2.pdf"))
        XCTAssertNil(noYear.date)
        XCTAssertEqual(FileNameScheme(tokens: [.id]).parseScanName("Scan_a3f9c2.pdf")?.id, "a3f9c2")
        XCTAssertNil(s.parseScanName("16-11-2026_Telekom_a3f9c2.pdf"), "erkannte Dateien nicht")
        // Dateien nach einem festen Schema werden nach einem Wechsel weiter gefunden.
        XCTAssertEqual(LaterRecognition.parse("26-11-16_Scan_bbbbbb.pdf", scheme: s)?.id, "bbbbbb")
        XCTAssertEqual(LaterRecognition.parse("16-11-2026_Scan_cccccc.pdf", scheme: s)?.id, "cccccc")
        XCTAssertNil(LaterRecognition.parse("16-11-2026_Scan_cccccc.pdf"), "nur mit dem eigenen Schema")
    }

    /// Jede zufällige Reihenfolge: Scan-Name wird wiedergefunden, Name endet auf .pdf, ID steckt drin.
    func testRandomSchemesRoundTrip() {
        for _ in 0..<300 {
            var tokens = NameToken.allCases.shuffled()
            tokens = Array(tokens.prefix(Int.random(in: 0...tokens.count)))
            let s = FileNameScheme(tokens: tokens, dateDashes: Bool.random())
            XCTAssertTrue(s.tokens.contains(.id))
            XCTAssertFalse(s.tokens.contains(.yy) && s.tokens.contains(.yyyy))
            let name = s.fileName(parts)
            XCTAssertTrue(name.hasSuffix(".pdf") && name.contains("a3f9c2"), name)
            let scan = s.scanFileName(date: date, id: "a3f9c2")
            XCTAssertEqual(s.parseScanName(scan)?.id, "a3f9c2", "\(s.pattern) → \(scan)")
        }
    }

    func testSwitchYearInPlace() {
        var s = FileNameScheme(tokens: [.dd, .mm, .yy, .sender, .id])
        XCTAssertEqual(s.yearFormat, .twoDigit)
        s.setYearFormat(.fourDigit)
        XCTAssertEqual(s.tokens, [.dd, .mm, .yyyy, .sender, .id], "an derselben Stelle")
        XCTAssertEqual(s.fileName(parts), "16-11-2026_Telekom_a3f9c2.pdf")
        XCTAssertNil(FileNameScheme(tokens: [.sender, .id]).yearFormat)
    }

    func testDatePartsWithoutDashes() throws {
        var s = FileNameScheme(tokens: [.yyyy, .mm, .dd, .type, .id])
        s.dateDashes = false
        XCTAssertEqual(s.fileName(parts), "20261116_RE_a3f9c2.pdf")
        XCTAssertEqual(s.scanFileName(date: date, id: "a3f9c2"), "20261116_Scan_a3f9c2.pdf")
        XCTAssertEqual(s.pattern, "YYYYMMDD_Typ_ID")
        let parsed = try XCTUnwrap(s.parseScanName("20261116_Scan_a3f9c2.pdf"))
        XCTAssertEqual(parsed.date, date)
        XCTAssertEqual(FileNameScheme(tokens: [.dd, .mm, .yy, .id], dateDashes: false).fileName(parts), "161126_a3f9c2.pdf")
    }

    /// Ein vor dieser Änderung gespeichertes eigenes Schema (ohne `dateDashes`) bleibt lesbar.
    func testOldSavedSchemeStillDecodes() throws {
        let old = Data(#"{"tokens":["dd","mm","yyyy","sender","id"]}"#.utf8)
        let s = try JSONDecoder().decode(FileNameScheme.self, from: old)
        XCTAssertEqual(s.tokens, [.dd, .mm, .yyyy, .sender, .id])
        XCTAssertTrue(s.dateDashes)
        let roundTrip = try JSONDecoder().decode(FileNameScheme.self, from: JSONEncoder().encode(FileNameScheme(tokens: [.id], dateDashes: false)))
        XCTAssertFalse(roundTrip.dateDashes)
    }
}

import XCTest
@testable import ScanCore

final class FileNamerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testStandardSchemeTwoDigitYear() {
        let parts = FileNameParts(date: date(2026, 11, 12), typeCode: "RE", sender: "Stadtwerke München",
                                  title: "Stromrechnung", id: "a3f9c2")
        XCTAssertEqual(FileNamer.fileName(parts, year: .twoDigit, calendar: calendar),
                       "26-11-12_RE_Stadtwerke-Muenchen_Stromrechnung_a3f9c2.pdf")
    }

    func testOptionOneFourDigitYear() {
        let parts = FileNameParts(date: date(2026, 1, 5), typeCode: "BR", sender: "AOK Bayern",
                                  title: "Beitragsbescheid", id: "7be01d")
        XCTAssertEqual(FileNamer.fileName(parts, year: .fourDigit, calendar: calendar),
                       "2026-01-05_BR_AOK-Bayern_Beitragsbescheid_7be01d.pdf")
    }

    func testExamplePreviewMatchesConcept() {
        let parts = FileNamer.exampleParts(calendar: calendar)
        XCTAssertEqual(FileNamer.fileName(parts, year: .twoDigit, calendar: calendar),
                       "26-11-12_RE_Stadtwerke-Muenchen_Stromrechnung_a3f9c2.pdf")
        XCTAssertEqual(FileNamer.fileName(parts, year: .fourDigit, calendar: calendar),
                       "2026-11-12_RE_Stadtwerke-Muenchen_Stromrechnung_a3f9c2.pdf")
    }

    func testScanNameWithoutRecognition() {
        XCTAssertEqual(FileNamer.scanFileName(date: date(2026, 11, 15), id: "0c1d2e", year: .twoDigit, calendar: calendar),
                       "26-11-15_Scan_0c1d2e.pdf")
        XCTAssertEqual(FileNamer.scanFileName(date: date(2026, 11, 15), id: "0c1d2e", year: .fourDigit, calendar: calendar),
                       "2026-11-15_Scan_0c1d2e.pdf")
    }

    func testMissingSenderAndTitleGetPlaceholders() {
        let parts = FileNameParts(date: date(2026, 3, 1), typeCode: "UB", sender: "  ", title: "§§§", id: "abcdef")
        XCTAssertEqual(FileNamer.fileName(parts, year: .twoDigit, calendar: calendar),
                       "26-03-01_UB_Unbekannt_Dokument_abcdef.pdf")
    }

    func testInvalidTypeFallsBackToUnknownAndCodeIsUppercased() {
        var parts = FileNameParts(date: date(2026, 3, 1), typeCode: "Rechnung", sender: "X", title: "Y", id: "abcdef")
        XCTAssertTrue(FileNamer.fileName(parts, year: .twoDigit, calendar: calendar).hasPrefix("26-03-01_UB_"))
        parts.typeCode = "st"
        XCTAssertTrue(FileNamer.fileName(parts, year: .twoDigit, calendar: calendar).hasPrefix("26-03-01_ST_"))
    }

    func testNamePartTransliterationAndCleanup() {
        XCTAssertEqual(FileNamer.namePart("Dr. Müller & Söhne GmbH", maxLength: 40), "Dr-Mueller-Soehne-GmbH")
        XCTAssertEqual(FileNamer.namePart("Straßenverkehrsamt", maxLength: 40), "Strassenverkehrsamt")
        XCTAssertEqual(FileNamer.namePart("Crédit Agricole / Société", maxLength: 40), "Credit-Agricole-Societe")
        XCTAssertEqual(FileNamer.namePart("ÄRZTEKAMMER", maxLength: 40), "AeRZTEKAMMER")
        XCTAssertEqual(FileNamer.namePart("  --a__b--  ", maxLength: 40), "a-b")
        XCTAssertEqual(FileNamer.namePart("../../etc/passwd", maxLength: 40), "etc-passwd")
        XCTAssertEqual(FileNamer.namePart("Zeile1\nZeile2\t", maxLength: 40), "Zeile1-Zeile2")
    }

    func testNamePartLengthLimitDoesNotEndWithDash() {
        XCTAssertEqual(FileNamer.namePart("Deutsche Rentenversicherung Bund Berlin", maxLength: 30),
                       "Deutsche-Rentenversicherung")
        XCTAssertEqual(FileNamer.namePart("abcd efgh", maxLength: 5), "abcd")
        XCTAssertEqual(FileNamer.namePart("abcd efgh", maxLength: 4), "abcd", "Grenze genau am Ende")
        XCTAssertEqual(FileNamer.namePart("Rentenversicherungsanstalt Bund", maxLength: 20), "Rentenversicherungsa",
                       "ohne brauchbare Wortgrenze hart kürzen")
        XCTAssertEqual(FileNamer.namePart("AOK Bayern", maxLength: 30), "AOK-Bayern")
    }

    func testSenderIsCappedAtTwentyCharactersAtWordBoundary() {
        let parts = FileNameParts(date: date(2026, 11, 12), typeCode: "BR",
                                  sender: "Volkswohl Bund Lebensversicherung a.G.", title: "Information", id: "a3f9c2")
        XCTAssertEqual(FileNamer.senderMaxLength, 24)
        XCTAssertEqual(FileNamer.fileName(parts, year: .twoDigit), "26-11-12_BR_Volkswohl-Bund_Information_a3f9c2.pdf")
        XCTAssertEqual(FileNamer.namePart("Finanzamt Musterstadt-Land", maxLength: 20), "Finanzamt",
                       "lieber an der Wortgrenze als mitten im Ortsnamen")
    }

    func testLongestPossibleNameStaysShort() {
        let parts = FileNameParts(date: date(2026, 12, 31), typeCode: "RE",
                                  sender: String(repeating: "A", count: 200), title: String(repeating: "B", count: 200),
                                  id: "ffffff")
        let name = FileNamer.fileName(parts, year: .fourDigit, calendar: calendar)
        XCTAssertLessThanOrEqual(name.count, 96)
        XCTAssertFalse(name.contains("/"))
    }

    func testNewIDIsSixLowercaseHex() {
        for _ in 0..<200 {
            let id = FileNamer.newID()
            XCTAssertTrue(FileNamer.isValidID(id), id)
        }
        XCTAssertFalse(FileNamer.isValidID("ABCDEF"))
        XCTAssertFalse(FileNamer.isValidID("abc"))
    }

    func testUniqueNameRerollsOnCollision() {
        var ids = ["aaaaaa", "bbbbbb", "cccccc"].makeIterator()
        let existing: Set<String> = ["x_aaaaaa.pdf", "x_bbbbbb.pdf"]
        let name = FileNamer.uniqueName(makeName: { "x_\($0).pdf" }, exists: { existing.contains($0) },
                                        newID: { ids.next()! })
        XCTAssertEqual(name, "x_cccccc.pdf")
        XCTAssertNil(FileNamer.uniqueName(makeName: { _ in "same.pdf" }, exists: { _ in true }, maxAttempts: 3))
    }
}

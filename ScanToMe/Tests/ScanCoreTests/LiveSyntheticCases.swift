import CoreText
import DocKit
import XCTest
@testable import ScanCore

/// Künstliche Grenzfälle für die Typwahl. Nur mit LIVE_ANTHROPIC_KEY; je Fall etwa 1 Cent.
final class LiveSyntheticCases: XCTestCase {
    private func page(_ lines: [String]) throws -> Data {
        try TestScanner.render(width: 2480, height: 3508) { context in
            for (i, text) in lines.enumerated() {
                let font = CTFontCreateWithName("Helvetica" as CFString, i == 2 ? 80 : 52, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
                context.textPosition = CGPoint(x: 220, y: 3200 - CGFloat(i) * 230)
                CTLineDraw(line, context)
            }
        }
    }

    private func recognize(_ lines: [String], key: String, types: [DocumentType]) async throws -> DocumentProposal {
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let job = try store.create()
        try store.addPage(to: job.id, jpeg: try page(lines), source: .platen, looksBlank: false)
        let current = try XCTUnwrap(store.job(job.id))
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: current)
        let analysis = try await processor.analyze(job: current, text: text, client: ClaudeClient(apiKey: key),
                                                   types: types, split: false)
        let p = try XCTUnwrap(analysis.proposals.first)
        print("LIVE: \(FileNamer.fileName(p.nameParts(scanDate: Date(), id: "xxxxxx"), year: .twoDigit)) (\(p.dateKind ?? "–"))")
        return p
    }

    func testPaymentDemandsAndCustomTypePrecedence() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let types = DocumentTypes.recognitionOrder(custom: DocumentTypes.customTypes(
            from: [CustomTypeEntry(code: "FA", hint: "Alle Schreiben, die vom Finanzamt kommen")]))

        let insurance = try await recognize([
            "Musterversicherung AG · Postfach 100 · 50000 Musterstadt",
            "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
            "Beitragsrechnung Kfz-Versicherung",
            "Datum: 02.11.2026",
            "Versicherungsjahr 01.01.2027 bis 31.12.2027",
            "Zu zahlender Jahresbeitrag: 412,30 EUR, fällig am 01.01.2027",
            "Der Betrag wird zum Fälligkeitstermin von Ihrem Konto abgebucht."], key: key, types: types)
        XCTAssertEqual(insurance.typeCode, "RE")

        let tax = try await recognize([
            "Finanzamt Musterstadt · Steuerstraße 5 · 12345 Musterstadt",
            "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
            "Bescheid über Vorauszahlungen zur Einkommensteuer",
            "Musterstadt, 11.04.2025",
            "Festgesetzte Vorauszahlungen: je 1.200,00 EUR zum 10.06., 10.09. und 10.12.2025",
            "Bitte zahlen Sie die Beträge fristgerecht."], key: key, types: types)
        XCTAssertEqual(tax.typeCode, "FA", "eigener Typ geht vor, auch bei Zahlungsaufforderung")

        let letter = try await recognize([
            "Musterversicherung AG · Postfach 100 · 50000 Musterstadt",
            "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
            "Änderung Ihrer Bankverbindung bestätigt",
            "Datum: 05.11.2026",
            "wir haben Ihre neue Bankverbindung gespeichert. Es ist nichts weiter zu tun."], key: key, types: types)
        XCTAssertEqual(letter.typeCode, "BR", "Versicherungsschreiben ohne Zahlung bleibt Brief")
    }

    func testLongSendersBecomeShortNames() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let types = DocumentTypes.recognitionOrder(custom: [])
        let cases: [[String]] = [
            ["Deutsche Rentenversicherung Bund · 10704 Berlin",
             "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
             "Renteninformation 2026", "Datum: 03.11.2026",
             "Ihre bisher erreichte Rentenanwartschaft ist in dieser Information aufgeführt."],
            ["Musterländische Kommunalversicherung Versicherungsverein auf Gegenseitigkeit · Kundenservice",
             "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
             "Ihr Vertrag zur Hausratversicherung", "Datum: 04.11.2026",
             "wir bestätigen die Änderung Ihrer Anschrift. Es ist nichts weiter zu tun."],
            ["Gemeinschaftspraxis Dr. med. Anna Beispiel und Dr. med. Bernd Muster · Fachärzte für Innere Medizin",
             "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
             "Terminbestätigung", "Datum: 06.11.2026",
             "hiermit bestätigen wir Ihren Termin am 20.11.2026 um 9:30 Uhr."],
        ]
        for lines in cases {
            let p = try await recognize(lines, key: key, types: types)
            let raw = FileNamer.namePart(p.sender, maxLength: 200)
            print("LIVE: von = \(p.sender) → \(raw)")
            XCTAssertFalse(raw.isEmpty)
            XCTAssertLessThanOrEqual(raw.count, 22, "Claude soll selbst kürzen: \(raw)")
        }
    }

    func testMixedBatchIsSplitAndRangeCanBeRenamed() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let address = "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt"
        let sheets: [[String]] = [
            ["Stadtwerke Musterstadt GmbH · Energieweg 1 · 12345 Musterstadt", address, "Jahresabrechnung Strom 2026",
             "Rechnungsdatum: 14.10.2026", "Verbrauch 01.10.2025 bis 30.09.2026: 2.840 kWh", "Seite 1 von 2"],
            ["Stadtwerke Musterstadt – Jahresabrechnung Strom 2026", "Zählerstände und Preisbestandteile",
             "Neuer Abschlag ab 01.11.2026: 78,00 EUR monatlich", "Seite 2 von 2"],
            ["Musterversicherung AG · Postfach 100 · 50000 Musterstadt", address, "Änderung Ihrer Anschrift",
             "Datum: 03.09.2026", "wir haben Ihre neue Anschrift gespeichert. Es ist nichts weiter zu tun."],
            ["Musterversicherung AG · Postfach 100 · 50000 Musterstadt", address, "Beitragsrechnung Hausrat",
             "Datum: 01.10.2026", "Jahresbeitrag 2027: 96,40 EUR, fällig am 01.01.2027"],
            ["Praxis Dr. med. Anna Beispiel · Hausärztin · Gesundheitsweg 3 · 12345 Musterstadt", address,
             "Arztbrief", "Musterstadt, 22.09.2026", "Sehr geehrter Herr Kollege, wir berichten über Ihren Patienten ...",
             "Seite 1 von 2"],
            ["Arztbrief Dr. Beispiel vom 22.09.2026 – Fortsetzung", "Empfehlung: Kontrolle in drei Monaten.",
             "Mit freundlichen kollegialen Grüßen", "Seite 2 von 2"],
            ["Finanzamt Musterstadt · Steuerstraße 5 · 12345 Musterstadt", address,
             "Bescheid für 2025 über Einkommensteuer", "Musterstadt, 08.08.2026", "Festgesetzt werden: siehe Anlage"],
            ["Anlage zum Bescheid für 2025 über Einkommensteuer vom 08.08.2026", "Berechnung der Einkommensteuer",
             "Zu versteuerndes Einkommen ...", "Finanzamt Musterstadt"],
        ]
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let created = try store.create()
        for sheet in sheets {
            try store.addPage(to: created.id, jpeg: try page(sheet), source: .feeder, looksBlank: false)
        }
        let job = try store.update(created.id) { $0.shortID = "aaaaaa" }
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: job)
        let types = DocumentTypes.recognitionOrder(custom: DocumentTypes.customTypes(
            from: [CustomTypeEntry(code: "FA", hint: "Alle Schreiben, die vom Finanzamt kommen")]))
        let client = ClaudeClient(apiKey: key)
        let analysis = try await processor.analyze(job: job, text: text, client: client, types: types, split: true)
        for p in analysis.proposals {
            print("LIVE: S. \(p.firstPage)-\(p.lastPage) \(FileNamer.fileName(p.nameParts(scanDate: Date(), id: p.shortID ?? "-"), year: .twoDigit)) [\(p.splitConfidence ?? "-")]")
        }
        print("LIVE: Token \(analysis.inputTokens) ein / \(analysis.outputTokens) aus")
        XCTAssertEqual(analysis.proposals.map(\.pages), [[1, 2], [3], [4], [5, 6], [7, 8]])
        XCTAssertEqual(analysis.proposals.map(\.typeCode), ["RE", "BR", "RE", "AZ", "FA"])
        XCTAssertEqual(Set(analysis.proposals.compactMap(\.shortID)).count, 5, "jedes Dokument eigene Kurz-ID")

        // Trennstelle von Hand falsch gesetzt (Arztbrief zerteilt) und Seite 6 allein neu benennen.
        let wrong = try XCTUnwrap(DocumentRanges.split(analysis.proposals, at: 6))
        let renamed = try await processor.rename(wrong[4], job: job, text: text, client: client, types: types)
        print("LIVE: neu benannt S. 6: \(renamed.proposal.typeCode) \(renamed.proposal.sender) \(renamed.proposal.title)")
        XCTAssertEqual(renamed.proposal.pages, [6])
        XCTAssertEqual(renamed.proposal.typeCode, "AZ")
        XCTAssertNil(renamed.proposal.needsNaming)
    }

    /// Fremdes Blatt zwischen zwei Seiten einer Rechnung (künstliche Seiten).
    func testInterleavedForeignSheetBecomesGapDocument() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let address = "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt"
        let sheets: [[String]] = [
            ["Autoservice Beispiel GmbH · Werkstattweg 9 · 12345 Musterstadt", address, "Rechnung Nr. 4711",
             "Rechnungsdatum: 11.08.2026", "Inspektion und Ölwechsel, Kennzeichen MS-XY 123", "Seite 1 von 2"],
            ["Musterversicherung AG · Postfach 100 · 50000 Musterstadt", address, "Änderung Ihrer Anschrift",
             "Datum: 03.09.2026", "wir haben Ihre neue Anschrift gespeichert. Es ist nichts weiter zu tun."],
            ["Autoservice Beispiel – Rechnung Nr. 4711 – Fortsetzung", "Summe netto 312,00 EUR, MwSt. 59,28 EUR",
             "Gesamtbetrag 371,28 EUR, zahlbar bis 25.08.2026", "Seite 2 von 2"],
        ]
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let created = try store.create()
        for sheet in sheets {
            try store.addPage(to: created.id, jpeg: try page(sheet), source: .feeder, looksBlank: false)
        }
        let job = try XCTUnwrap(store.job(created.id))
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: job)
        let analysis = try await processor.analyze(job: job, text: text, client: ClaudeClient(apiKey: key),
                                                   types: DocumentTypes.recognitionOrder(custom: []), split: true)
        for p in analysis.proposals {
            print("LIVE: \(p.pagesLabel) \(p.typeCode) \(p.sender) \(p.title) [\(p.splitConfidence ?? "-")]")
        }
        XCTAssertEqual(analysis.proposals.map(\.pages), [[1, 3], [2]])
    }

    /// Zwei Werkstattrechnungen, jede mit einem Fehlerprotokoll ohne Briefkopf (künstlich).
    func testAttachmentWithoutLetterheadBelongsToLetterBefore() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let address = "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt"
        let sheets: [[String]] = [
            ["Autoservice Beispiel GmbH · Werkstattweg 9 · 12345 Musterstadt", address, "Rechnung Nr. 4711",
             "Rechnungsdatum: 11.08.2026", "Fehlerspeicher auslesen, Kennzeichen MS-XY 123", "Gesamtbetrag 59,50 EUR"],
            ["DiagnoseTec Prüfprotokoll", "Fahrzeug: MS-XY 123", "Fehlercode P0420 Katalysator Wirkungsgrad",
             "Fehlercode P0171 Gemisch zu mager", "Ausgedruckt am 11.08.2026"],
            ["Autoservice Beispiel GmbH · Werkstattweg 9 · 12345 Musterstadt", address, "Rechnung Nr. 4790",
             "Rechnungsdatum: 02.09.2026", "Fehlerspeicher auslesen, Kennzeichen MS-XY 123", "Gesamtbetrag 59,50 EUR"],
            ["DiagnoseTec Prüfprotokoll", "Fahrzeug: MS-XY 123", "Fehlercode P0420 Katalysator Wirkungsgrad",
             "Keine weiteren Fehler gespeichert", "Ausgedruckt am 02.09.2026"],
        ]
        let store = JobStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let created = try store.create()
        for sheet in sheets {
            try store.addPage(to: created.id, jpeg: try page(sheet), source: .feeder, looksBlank: false)
        }
        let job = try XCTUnwrap(store.job(created.id))
        let processor = DocumentProcessor(store: store)
        let text = try await processor.recognizeText(job: job)
        let analysis = try await processor.analyze(job: job, text: text, client: ClaudeClient(apiKey: key),
                                                   types: DocumentTypes.recognitionOrder(custom: []), split: true)
        for p in analysis.proposals {
            print("LIVE: \(p.pagesLabel) \(p.typeCode) \(p.sender) \(p.title) [\(p.splitConfidence ?? "-")]")
        }
        XCTAssertEqual(analysis.proposals.map(\.pages), [[1, 2], [3, 4]])
    }

    /// Englische Oberfläche: Claude schlägt die Bezeichnung auf Englisch vor, der Absender bleibt.
    func testEnglishNames() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        Localization.current = .en
        defer { Localization.current = .de }
        let p = try await recognize(["Stadtwerke Musterstadt GmbH · Energieweg 1 · 12345 Musterstadt",
                                     "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
                                     "Jahresabrechnung Strom 2026", "Rechnungsdatum: 14.10.2026",
                                     "Verbrauch: 2.840 kWh, Nachzahlung: 112,40 EUR"],
                                    key: key, types: DocumentTypes.recognitionOrder(custom: []))
        XCTAssertEqual(p.typeCode, "RE")
        XCTAssertTrue(p.sender.contains("Stadtwerke"))
        XCTAssertFalse(p.title.lowercased().contains("rechnung"), p.title)
    }

    /// „Später erkennen“: erst ohne Erkennung ablegen, dann das abgelegte PDF erkennen und umbenennen.
    func testRecognizeLaterRenamesFiledScan() async throws {
        let key = ProcessInfo.processInfo.environment["LIVE_ANTHROPIC_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Nur mit LIVE_ANTHROPIC_KEY")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = JobStore(root: base.appendingPathComponent("Auftraege"))
        let folder = base.appendingPathComponent("Ablage")
        let created = try store.create()
        try store.addPage(to: created.id, jpeg: try page(["Deutsche Rentenversicherung Bund · 10704 Berlin",
                                                           "Herrn Max Mustermann, Beispielstraße 2, 12345 Musterstadt",
                                                           "Renteninformation 2026", "Datum: 03.11.2026",
                                                           "Ihre bisher erreichte Rentenanwartschaft ..."]),
                          source: .platen, looksBlank: false)
        let job = try store.update(created.id) { $0.state = .ready; $0.shortID = "abcdef" }
        let text = try await DocumentProcessor(store: store).recognizeText(job: job)
        let urls = try await BatchFiler(store: store, folder: folder, year: .twoDigit, typeTitles: [:]).fileAll(job: job, text: text)
        XCTAssertTrue(urls[0].lastPathComponent.contains("_Scan_abcdef"))

        let scan = try XCTUnwrap(LaterRecognition.candidates(in: folder).first)
        let proposal = try await LaterRecognition.analyze(scan, client: ClaudeClient(apiKey: key),
                                                          types: DocumentTypes.recognitionOrder(custom: []))
        let renamed = try LaterRecognition.rename(scan, proposal: proposal, scheme: .standard)
        print("LIVE: später erkannt: \(renamed.lastPathComponent)")
        XCTAssertEqual(renamed.lastPathComponent, "26-11-03_BR_DRV_Renteninformation_abcdef.pdf")
        XCTAssertTrue(LaterRecognition.candidates(in: folder).isEmpty)
    }
}

import DocKit
import Foundation

/// Macht aus den übernommenen Seiten eines Auftrags ein durchsuchbares PDF im Auftragsordner.
/// Der erkannte Text wird zusätzlich als `text.json` gespeichert (für die Inhaltserkennung in M4).
public struct DocumentProcessor: Sendable {
    public static let pdfFileName = "dokument.pdf"
    public static let textFileName = "text.json"

    public let store: JobStore

    public init(store: JobStore) {
        self.store = store
    }

    /// Texterkennung für alle übernommenen Seiten. `progress(fertig, gesamt)` nach jeder Seite.
    public func recognizeText(job: ScanJob,
                              progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [RecognizedPage] {
        let pages = job.includedPages
        var result: [RecognizedPage] = []
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let url = store.pageURL(job, page)
            let recognized: RecognizedPage
            do {
                recognized = try await TextRecognizer.recognize(jpegURL: url, timeout: TextRecognizer.pageTimeout)
            } catch TextRecognizerError.timedOut {
                ScanLog.shared.write("== Texterkennung: Seite \(index + 1) nach \(Int(TextRecognizer.pageTimeout)) s ohne Ergebnis")
                throw TextRecognitionTimedOut()
            }
            result.append(recognized)
            await progress(index + 1, pages.count)
        }
        try saveText(result, job: job)
        return result
    }

    public func savedText(job: ScanJob) -> [RecognizedPage]? {
        let url = store.folder(job.id).appendingPathComponent(Self.textFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([RecognizedPage].self, from: data)
    }

    /// Kantenlänge der Seiten in der Fassung für die Inhaltserkennung (A4-Höhe bei 150 dpi).
    public static let analysisPixelSize = 1754

    /// Trennblätter erkennen: Sie werden aussortiert (nicht gelöscht) und als feste Dokumentanfänge
    /// im Auftrag vermerkt. Der Text wird passend gekürzt und neu gespeichert.
    /// Besteht der Scan nur aus Trennblättern, bleibt alles, wie es ist.
    public func removeSeparators(job: ScanJob, text: [RecognizedPage]) throws
        -> (job: ScanJob, text: [RecognizedPage], removed: Int) {
        let included = job.pages.indices.filter { !job.pages[$0].excluded }
        guard included.count == text.count else { return (job, text, 0) }
        let isSeparator = text.map(SeparatorSheet.isSeparator)
        guard isSeparator.contains(true), isSeparator.contains(false) else { return (job, text, 0) }

        var keptText: [RecognizedPage] = []
        var starts: [Int] = []
        var pendingStart = false
        for position in included.indices {
            if isSeparator[position] {
                pendingStart = true
            } else {
                keptText.append(text[position])
                if pendingStart && keptText.count > 1 { starts.append(keptText.count) }
                pendingStart = false
            }
        }
        let updated = try store.update(job.id) { job in
            for (position, pageIndex) in included.enumerated() where isSeparator[position] {
                job.pages[pageIndex].excluded = true
                job.pages[pageIndex].isSeparator = true
            }
            job.forcedStarts = starts
        }
        try saveText(keptText, job: updated)
        return (updated, keptText, isSeparator.filter { $0 }.count)
    }

    private func saveText(_ text: [RecognizedPage], job: ScanJob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(text).write(to: store.folder(job.id).appendingPathComponent(Self.textFileName), options: .atomic)
    }

    /// Bestimmte Seiten (1-basiert innerhalb der übernommenen Seiten, `nil` = alle) mit ihrem Text.
    func inputs(job: ScanJob, text: [RecognizedPage]?, pages wanted: [Int]?, maxPixelSize: Int?) -> [PDFPageInput] {
        let pages = job.includedPages
        let wanted = wanted ?? Array(pages.indices.map { $0 + 1 })
        return wanted.compactMap { number in
            let index = number - 1
            guard pages.indices.contains(index) else { return nil }
            let page = pages[index]
            return PDFPageInput(jpegURL: store.pageURL(job, page),
                                text: text.flatMap { index < $0.count ? $0[index] : nil }, maxPixelSize: maxPixelSize,
                                original: page.original.map { (store.folder(job.id).appendingPathComponent($0.file), $0.index) })
        }
    }

    /// Kleine Fassung (150 dpi, mit Textebene) für die Inhaltserkennung, optional nur bestimmte Seiten.
    public func analysisPDF(job: ScanJob, text: [RecognizedPage]?, pages: [Int]? = nil) async throws -> Data {
        let inputs = inputs(job: job, text: text, pages: pages, maxPixelSize: Self.analysisPixelSize)
        return try await Task.detached(priority: .userInitiated) {
            try PDFBuilder.build(pages: inputs)
        }.value
    }

    /// Ergebnis der Inhaltserkennung.
    public struct Analysis: Sendable {
        public var proposals: [DocumentProposal]
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
    }

    /// Schickt die kleine Fassung an Claude und wertet die Antwort aus. Beim Trennen gelten die Trennblätter
    /// des Auftrags als feste Dokumentanfänge.
    public func analyze(job: ScanJob, text: [RecognizedPage]?, client: ClaudeClient, types: [DocumentType],
                        split: Bool) async throws -> Analysis {
        let pdf = try await analysisPDF(job: job, text: text)
        let pageCount = job.includedPages.count
        let starts = split ? (job.forcedStarts ?? []) : []
        let body = try DocumentAnalysis.requestBody(pdf: pdf, pageCount: pageCount, types: types, split: split,
                                                    forcedStarts: starts)
        var response = try await client.send(body: body)
        var inputTokens = response.inputTokens
        var outputTokens = response.outputTokens
        // Fehlen Seiten in der Aufteilung, war die Antwort ein Ausreißer: einmal nachfragen, die vollständigere nehmen.
        let missing = split ? DocumentAnalysis.unclaimedPageCount(fromJSON: response.text, pageCount: pageCount) : 0
        if missing > 0 {
            ScanLog.shared.write("== Claude: \(missing) von \(pageCount) Seiten ohne Dokument "
                + "(\(DocumentAnalysis.rangeSummary(fromJSON: response.text))), frage erneut")
            if let second = try? await client.send(body: body) {
                inputTokens += second.inputTokens
                outputTokens += second.outputTokens
                if DocumentAnalysis.unclaimedPageCount(fromJSON: second.text, pageCount: pageCount) < missing {
                    response = second
                }
            }
        }
        var proposals = try DocumentAnalysis.proposals(fromJSON: response.text, pageCount: pageCount, split: split,
                                                       knownCodes: Set(types.map(\.code)))
        proposals = DocumentRanges.enforce(starts: starts, in: proposals)
        proposals = DocumentRanges.assignIDs(proposals, jobID: job.shortID)
        if split {
            ScanLog.shared.write("== Claude: \(pageCount) Seiten, Aufteilung \(DocumentAnalysis.rangeSummary(fromJSON: response.text))"
                + " → \(proposals.map { $0.pagesLabel }.joined(separator: " | "))")
        }
        return Analysis(proposals: proposals, model: response.model,
                        inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Lokale Erkennung mit Apples Modell (M7): ein Dokument über alle Seiten, ohne Internet und ohne Kosten.
    public func analyzeLocally(job: ScanJob, text: [RecognizedPage]?, types: [DocumentType]) async throws -> Analysis {
        let pages = job.includedPages
        guard let first = pages.first else { throw PDFBuilderError.noPages }
        var proposal = try await LocalRecognizer.propose(imageURL: store.pageURL(job, first),
                                                         pageTexts: LocalRecognizer.pageTexts(text ?? []),
                                                         pageCount: pages.count, types: types)
        proposal.splitConfidence = nil
        let proposals = DocumentRanges.assignIDs([proposal], jobID: job.shortID)
        ScanLog.shared.write("== Lokal (Apple): \(pages.count) Seiten → \(proposals[0].pagesLabel)")
        return Analysis(proposals: proposals, model: "apple-local", inputTokens: 0, outputTokens: 0)
    }

    /// Benennt einen Seitenbereich lokal neu (nach Schere oder Verbinden), Seiten und Kurz-ID bleiben.
    public func renameLocally(_ proposal: DocumentProposal, job: ScanJob, text: [RecognizedPage]?,
                              types: [DocumentType]) async throws -> DocumentProposal {
        let pages = job.includedPages
        guard let firstIndex = proposal.pages.first.map({ $0 - 1 }), pages.indices.contains(firstIndex) else {
            throw PDFBuilderError.noPages
        }
        let texts = LocalRecognizer.pageTexts(proposal.pages.compactMap { n in text.flatMap { n - 1 < $0.count ? $0[n - 1] : nil } })
        var named = try await LocalRecognizer.propose(imageURL: store.pageURL(job, pages[firstIndex]), pageTexts: texts,
                                                      pageCount: proposal.pageCount, types: types)
        named.setPages(proposal.pages)
        named.shortID = proposal.shortID
        named.splitConfidence = nil
        named.needsNaming = nil
        return named
    }

    /// Benennt einen Seitenbereich neu (nach dem Verschieben einer Trennstelle). Der Bereich und die Kurz-ID
    /// des Vorschlags bleiben, die übrigen Angaben kommen von Claude.
    public func rename(_ proposal: DocumentProposal, job: ScanJob, text: [RecognizedPage]?, client: ClaudeClient,
                       types: [DocumentType]) async throws -> (proposal: DocumentProposal, inputTokens: Int, outputTokens: Int) {
        let pdf = try await analysisPDF(job: job, text: text, pages: proposal.pages)
        let body = try DocumentAnalysis.requestBody(pdf: pdf, pageCount: proposal.pageCount, types: types, split: false)
        let response = try await client.send(body: body)
        guard let named = try DocumentAnalysis.proposals(fromJSON: response.text, pageCount: proposal.pageCount,
                                                         split: false, knownCodes: Set(types.map(\.code))).first
        else { throw ClaudeError.badResponse }
        var result = named
        result.firstPage = proposal.firstPage
        result.lastPage = proposal.lastPage
        result.pageList = proposal.pageList
        result.shortID = proposal.shortID
        result.needsNaming = nil
        return (result, response.inputTokens, response.outputTokens)
    }

    /// Baut das PDF im Auftragsordner und liefert seine Adresse. `pages` = nur diese Seiten (ein Dokument eines Stapels).
    public func buildPDF(job: ScanJob, text: [RecognizedPage]?, metadata: PDFMetadata,
                         pages: [Int]? = nil) async throws -> URL {
        let inputs = inputs(job: job, text: text, pages: pages, maxPixelSize: nil)
        let name = pages.flatMap(\.first).map { "dokument-\($0).pdf" } ?? Self.pdfFileName
        let target = store.folder(job.id).appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) {
            try PDFBuilder.build(pages: inputs, metadata: metadata).write(to: target, options: .atomic)
        }.value
        return target
    }
}

/// Die Texterkennung hat bei der Verarbeitung eines Scans nicht reagiert. DocKit meldet das neutral;
/// Scan to me ergänzt, was der Nutzer hier tun kann.
public struct TextRecognitionTimedOut: Error, LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? {
        (TextRecognizerError.timedOut.errorDescription ?? "") + " "
            + loc("Warten Sie eine Minute und wählen Sie „Jetzt verarbeiten“. Klappt es dann noch nicht, "
                  + "beenden Sie die App (⌘Q) und öffnen Sie sie neu.",
                  "Wait a minute and choose “Process now”. If it still fails, quit the app (⌘Q) and open it again.")
    }
}

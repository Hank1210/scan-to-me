import DocKit
import Foundation

/// Legt alle Dokumente eines Auftrags ab: je Vorschlag ein PDF mit seinen Seiten, ohne Vorschläge eines
/// mit allen Seiten und dem Scandatum als Namen. Jedes abgelegte Dokument wird sofort im Auftrag vermerkt,
/// damit ein erneuter Versuch nach einem Fehler nichts doppelt ablegt.
public struct BatchFiler: Sendable {
    public let store: JobStore
    public let folder: URL
    public let scheme: FileNameScheme
    /// Kürzel → Bezeichnung des Typs (für die PDF-Angaben), z. B. „RE“ → „Rechnung“.
    public let typeTitles: [String: String]

    public init(store: JobStore, folder: URL, year: YearFormat, typeTitles: [String: String]) {
        self.init(store: store, folder: folder, scheme: FileNameScheme(year), typeTitles: typeTitles)
    }

    public init(store: JobStore, folder: URL, scheme: FileNameScheme, typeTitles: [String: String]) {
        self.store = store
        self.folder = folder
        self.scheme = scheme
        self.typeTitles = typeTitles
    }

    /// Vorgeschlagener Name je Dokument (vor der Prüfung auf freie Namen im Ordner).
    public func name(job: ScanJob, proposal: DocumentProposal?, id: String? = nil) -> String {
        let id = id ?? proposal?.shortID ?? job.shortID ?? "000000"
        if let proposal {
            return scheme.fileName(proposal.nameParts(scanDate: job.createdAt, id: id))
        }
        return scheme.scanFileName(date: job.createdAt, id: id)
    }

    public func metadata(_ proposal: DocumentProposal?, name: String) -> PDFMetadata {
        guard let proposal else { return PDFMetadata(title: name, keywords: ["Scan to me"]) }
        return PDFMetadata(title: proposal.title.isEmpty ? name : proposal.title,
                           author: proposal.sender.isEmpty ? nil : proposal.sender,
                           subject: typeTitles[proposal.typeCode],
                           keywords: [DocumentTypes.displayCode(proposal.typeCode), "Scan to me"])
    }

    /// Legt alles ab, was noch nicht abgelegt ist, und liefert alle Dateien des Auftrags in Reihenfolge.
    /// `progress(nummer, gesamt)` vor jedem Dokument.
    public func fileAll(job: ScanJob, text: [RecognizedPage]?,
                        progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [URL] {
        let processor = DocumentProcessor(store: store)
        guard let proposals = job.proposals, !proposals.isEmpty else {
            await progress(1, 1)
            let expected = job.includedPages.count
            if let pending = job.filingName, DocumentFiler.isComplete(folder.appendingPathComponent(pending), expectedPages: expected) {
                return [folder.appendingPathComponent(pending)]
            }
            let name = try freeName(job: job, proposal: nil)
            try store.update(job.id) { $0.filingName = name }
            let pdf = try await processor.buildPDF(job: job, text: text, metadata: metadata(nil, name: name))
            return [try DocumentFiler.file(pdfAt: pdf, name: name, in: folder, expectedPages: expected)]
        }

        var urls: [URL] = []
        for (index, proposal) in proposals.enumerated() {
            if let done = proposal.filedName {
                urls.append(folder.appendingPathComponent(done))
                continue
            }
            // Absturz nach dem Schreiben, vor dem Vermerk: Datei liegt schon vollständig da.
            if let pending = proposal.filingName,
               DocumentFiler.isComplete(folder.appendingPathComponent(pending), expectedPages: proposal.pageCount) {
                try store.update(job.id) { job in
                    if job.proposals?.indices.contains(index) == true { job.proposals?[index].filedName = pending }
                }
                urls.append(folder.appendingPathComponent(pending))
                continue
            }
            await progress(index + 1, proposals.count)
            let name = try freeName(job: job, proposal: proposal)
            try store.update(job.id) { job in
                if job.proposals?.indices.contains(index) == true { job.proposals?[index].filingName = name }
            }
            let pdf = try await processor.buildPDF(job: job, text: text, metadata: metadata(proposal, name: name),
                                                   pages: proposal.pages)
            let url = try DocumentFiler.file(pdfAt: pdf, name: name, in: folder, expectedPages: proposal.pageCount,
                                             tags: [DocumentTypes.displayCode(proposal.typeCode)])
            try? FileManager.default.removeItem(at: pdf)
            try store.update(job.id) { job in
                if job.proposals?.indices.contains(index) == true { job.proposals?[index].filedName = name }
            }
            urls.append(url)
        }
        return urls
    }

    private func freeName(job: ScanJob, proposal: DocumentProposal?) throws -> String {
        let preferred = proposal?.shortID ?? job.shortID ?? FileNamer.newID()
        guard let name = DocumentFiler.freeName(in: folder, preferredID: preferred,
                                                makeName: { self.name(job: job, proposal: proposal, id: $0) })
        else { throw DocumentFilerError.noFreeName }
        return name
    }
}

import Foundation

/// Trennstellen in einem Stapel bearbeiten. Rein und ohne Dateisystem.
/// Seiten zählen 1-basiert innerhalb der übernommenen Seiten. Jede Seite gehört zu genau einem Dokument;
/// ein Dokument darf nach „Verbinden“ auch nicht aufeinanderfolgende Seiten haben (z. B. 1 und 3).
/// Die Dokumente stehen nach ihrer ersten Seite sortiert. Geänderte Dokumente bekommen `needsNaming`,
/// damit ihre Benennung neu angefragt wird.
public enum DocumentRanges {
    /// Neues Dokument ab Seite `page` (sie und alle folgenden Seiten desselben Dokuments). `nil`, wenn
    /// dort schon eines beginnt, die Seite nicht vorkommt oder das Dokument schon abgelegt ist.
    public static func split(_ proposals: [DocumentProposal], at page: Int,
                             newID: () -> String = { FileNamer.newID() }) -> [DocumentProposal]? {
        guard let index = proposals.firstIndex(where: { $0.pages.dropFirst().contains(page) }),
              proposals[index].filedName == nil else { return nil }
        let pages = proposals[index].pages
        var result = proposals
        var second = result[index]
        result[index].setPages(pages.filter { $0 < page })
        result[index].needsNaming = true
        result[index].splitConfidence = nil
        result[index].filingName = nil
        second.filingName = nil
        second.setPages(pages.filter { $0 >= page })
        second.needsNaming = true
        second.splitConfidence = nil
        second.shortID = newID()
        result.append(second)
        return sorted(result)
    }

    /// Dokument `index` mit Dokument `other` verbinden (beliebige zwei, auch nicht benachbarte). Die Seiten
    /// kommen in Scanreihenfolge zusammen, die Angaben des vorderen Dokuments bleiben, die Benennung wird neu
    /// angefragt. `nil`, wenn es eines nicht gibt, beide dasselbe sind oder eines schon abgelegt ist.
    public static func merge(_ proposals: [DocumentProposal], _ index: Int, with other: Int) -> [DocumentProposal]? {
        guard index != other, proposals.indices.contains(index), proposals.indices.contains(other),
              proposals[index].filedName == nil, proposals[other].filedName == nil else { return nil }
        let keep = min(index, other)
        let drop = max(index, other)
        var result = proposals
        result[keep].setPages(result[keep].pages + result[drop].pages)
        result[keep].needsNaming = true
        result[keep].splitConfidence = nil
        result[keep].filingName = nil
        result.remove(at: drop)
        return sorted(result)
    }

    /// Sorgt dafür, dass an jeder vorgegebenen Seite (Trennblatt) ein Dokument beginnt.
    public static func enforce(starts: [Int], in proposals: [DocumentProposal],
                               newID: () -> String = { FileNamer.newID() }) -> [DocumentProposal] {
        var result = proposals
        for page in starts.sorted() {
            if let split = split(result, at: page, newID: newID) { result = split }
        }
        return result
    }

    /// Jede Seite von 1 bis `pageCount` genau einmal.
    public static func coversAll(_ proposals: [DocumentProposal], pageCount: Int) -> Bool {
        let all = proposals.flatMap(\.pages)
        return all.count == pageCount && Set(all) == Set(1...max(pageCount, 1))
    }

    /// Jedes Dokument bekommt eine eigene Kurz-ID; das erste behält die des Auftrags.
    public static func assignIDs(_ proposals: [DocumentProposal], jobID: String?,
                                 newID: () -> String = { FileNamer.newID() }) -> [DocumentProposal] {
        var used = Set<String>()
        return proposals.enumerated().map { index, proposal in
            var p = proposal
            if p.shortID == nil { p.shortID = index == 0 ? jobID : nil }
            while p.shortID == nil || used.contains(p.shortID!) { p.shortID = newID() }
            used.insert(p.shortID!)
            return p
        }
    }

    private static func sorted(_ proposals: [DocumentProposal]) -> [DocumentProposal] {
        proposals.sorted { $0.firstPage < $1.firstPage }
    }
}

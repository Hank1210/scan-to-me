import Foundation

/// Ein Einzug-Durchgang innerhalb eines Auftrags: ab Seite `start` (0-basiert im Seiten-Array) `count` Seiten.
public struct FeederPass: Codable, Equatable, Sendable {
    public var start: Int
    public var count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }
}

/// Zusammengeführte Vorder- und Rückseiten (manuell beidseitig): ab `start` liegen `sheets` Blätter, je Vorder-
/// und Rückseite. `backsReversed`: die Rückseiten kamen in umgekehrter Reihenfolge (Stapel umgedreht).
public struct DuplexMerge: Codable, Equatable, Sendable {
    public var start: Int
    public var sheets: Int
    public var backsReversed: Bool

    public init(start: Int, sheets: Int, backsReversed: Bool) {
        self.start = start
        self.sheets = sheets
        self.backsReversed = backsReversed
    }
}

/// „Manuell beidseitig“ für Einzüge, die nur einseitig scannen (wie der WF-2960): erst alle Vorderseiten, dann
/// den Stapel umdrehen und die Rückseiten scannen. Hier werden die Seiten wieder blattweise sortiert.
/// Rein und ohne Dateisystem; es werden nur Einträge umsortiert, nie Seiten entfernt.
public enum Duplex {
    /// Fronten stehen bei `start` (n Seiten), direkt dahinter die Rückseiten in Scanreihenfolge (n Seiten).
    /// Ergebnis: V1, R1, V2, R2, … `nil`, wenn die Bereiche nicht passen.
    public static func interleave<T>(_ items: [T], start: Int, sheets: Int, backsReversed: Bool) -> [T]? {
        guard sheets > 0, start >= 0, start + 2 * sheets <= items.count else { return nil }
        let fronts = Array(items[start..<start + sheets])
        var backs = Array(items[(start + sheets)..<(start + 2 * sheets)])
        if backsReversed { backs.reverse() }
        var merged: [T] = []
        for i in 0..<sheets { merged += [fronts[i], backs[i]] }
        return Array(items[..<start]) + merged + Array(items[(start + 2 * sheets)...])
    }

    /// Macht `interleave` rückgängig (zurück zu: alle Vorderseiten, dann Rückseiten in Scanreihenfolge).
    public static func deinterleave<T>(_ items: [T], start: Int, sheets: Int, backsReversed: Bool) -> [T]? {
        guard sheets > 0, start >= 0, start + 2 * sheets <= items.count else { return nil }
        let block = Array(items[start..<start + 2 * sheets])
        let fronts = stride(from: 0, to: block.count, by: 2).map { block[$0] }
        var backs = stride(from: 1, to: block.count, by: 2).map { block[$0] }
        if backsReversed { backs.reverse() }
        return Array(items[..<start]) + fronts + backs + Array(items[(start + 2 * sheets)...])
    }
}

extension JobStore {
    /// Führt den letzten Vorderseiten-Durchgang mit den direkt danach gescannten Rückseiten zusammen.
    /// Standard: Rückseiten in umgekehrter Reihenfolge (so liegen sie, wenn man den Stapel umdreht).
    @discardableResult
    public func mergeDuplex(_ jobID: UUID, fronts: FeederPass, backsReversed: Bool = true) throws -> ScanJob {
        try update(jobID) { job in
            guard let merged = Duplex.interleave(job.pages, start: fronts.start, sheets: fronts.count,
                                                 backsReversed: backsReversed)
            else { throw JobStoreError.pageIndexOutOfRange }
            job.pages = merged
            job.duplex = DuplexMerge(start: fronts.start, sheets: fronts.count, backsReversed: backsReversed)
            job.lastFeederPass = nil
        }
    }

    /// Kehrt die Reihenfolge der Rückseiten um (falls sie beim Gerät andersherum ankommen).
    @discardableResult
    public func flipDuplexBacks(_ jobID: UUID) throws -> ScanJob {
        try update(jobID) { job in
            guard let duplex = job.duplex,
                  let original = Duplex.deinterleave(job.pages, start: duplex.start, sheets: duplex.sheets,
                                                     backsReversed: duplex.backsReversed),
                  let merged = Duplex.interleave(original, start: duplex.start, sheets: duplex.sheets,
                                                 backsReversed: !duplex.backsReversed)
            else { throw JobStoreError.pageIndexOutOfRange }
            job.pages = merged
            job.duplex?.backsReversed.toggle()
        }
    }
}

import Foundation

/// Verbrauch der Inhaltserkennung je Monat, für die Kostenanzeige. Gezählt wird jede Antwort von Anthropic
/// (auch Wiederholungen und Neubenennungen). Datei: `~/Library/Application Support/Scan-to-me/verbrauch.json`.
/// Enthält nur Zahlen, keine Inhalte.
public final class UsageLedger: @unchecked Sendable {
    public struct Month: Codable, Equatable, Sendable {
        public var inputTokens = 0
        public var outputTokens = 0
        public var requests = 0

        public init(inputTokens: Int = 0, outputTokens: Int = 0, requests: Int = 0) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.requests = requests
        }

        /// Geschätzte Kosten in US-Dollar.
        public var costUSD: Double { UsageLedger.costUSD(input: inputTokens, output: outputTokens) }
    }

    /// Preise von Claude Sonnet 5.5 (Stand November 2026): 2 $ je Million Eingabe-, 10 $ je Million Ausgabe-Token.
    public static let inputPricePerMillion = 2.0
    public static let outputPricePerMillion = 10.0

    public static func costUSD(input: Int, output: Int) -> Double {
        Double(input) / 1_000_000 * inputPricePerMillion + Double(output) / 1_000_000 * outputPricePerMillion
    }

    public static let shared = UsageLedger()

    public let url: URL
    private let lock = NSLock()
    private let calendar: Calendar

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Scan-to-me/verbrauch.json"),
                calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
    }

    /// Schlüssel wie „2026-11“.
    public func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public func record(input: Int, output: Int, at date: Date = Date()) {
        lock.withLock {
            var all = load()
            var month = all[key(for: date)] ?? Month()
            month.inputTokens += input
            month.outputTokens += output
            month.requests += 1
            all[key(for: date)] = month
            save(all)
        }
    }

    public func month(containing date: Date = Date()) -> Month {
        lock.withLock { load()[key(for: date)] ?? Month() }
    }

    public func previousMonth(before date: Date = Date()) -> Month {
        guard let earlier = calendar.date(byAdding: .month, value: -1, to: date) else { return Month() }
        return month(containing: earlier)
    }

    private func load() -> [String: Month] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Month].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: Month]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) { try? data.write(to: url, options: .atomic) }
    }
}

/// Betrag für die Anzeige: unter 1 $ in Cent, sonst in Dollar.
public func formatCost(_ usd: Double) -> String {
    if usd < 1 {
        let cents = usd * 100
        let text = cents < 10 ? String(format: "%.1f", cents) : String(format: "%.0f", cents)
        return loc("ca. \(text.replacingOccurrences(of: ".", with: ",")) Cent", "about \(text) cents")
    }
    let text = String(format: "%.2f", usd)
    return loc("ca. \(text.replacingOccurrences(of: ".", with: ",")) $", "about $\(text)")
}

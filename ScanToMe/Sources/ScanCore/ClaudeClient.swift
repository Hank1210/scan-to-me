import DocKit
import Foundation

/// Antwort der Messages-API, auf das Nötige reduziert.
public struct ClaudeResponse: Equatable, Sendable {
    /// Der Text des letzten `text`-Blocks (bei strukturierter Ausgabe: das JSON).
    public var text: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case invalidKey
    case refusal(String?)
    case truncated
    case emptyResponse
    case badResponse
    case http(Int, String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return loc("Der API-Schlüssel wurde abgelehnt.", "The API key was rejected.")
        case .refusal(let category): return loc("Claude hat die Auswertung abgelehnt", "Claude declined to analyse the document") + (category.map { " (\($0))" } ?? "") + "."
        case .truncated: return loc("Die Antwort war unvollständig.", "The response was incomplete.")
        case .emptyResponse: return loc("Die Antwort enthielt keinen Text.", "The response contained no text.")
        case .badResponse: return loc("Die Antwort war nicht lesbar.", "The response could not be read.")
        case .http(let code, let message): return loc("Anthropic meldet einen Fehler", "Anthropic reports an error") + " (HTTP \(code)\(message.isEmpty ? "" : ": \(message)"))."
        case .unreachable(let detail): return loc("Keine Verbindung zu Anthropic (\(detail)).", "No connection to Anthropic (\(detail)).")
        }
    }

    /// Überlastung, Ratenlimit und Netzfehler lohnen eine Wiederholung; alles andere nicht.
    var isRetryable: Bool {
        switch self {
        case .unreachable: return true
        case .http(let code, _): return code == 408 || code == 409 || code == 429 || code >= 500
        default: return false
        }
    }
}

/// Ruft die Claude-API direkt per URLSession auf (es gibt kein offizielles Swift-SDK).
public struct ClaudeClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Fest nach Entscheidung vom 15.11.2026.
    public static let model = "claude-sonnet-5-5"
    /// Beta für `fallbacks: "default"` (bei Ablehnung übernimmt automatisch ein anderes Modell).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let apiKey: String
    public let session: URLSession
    /// Wartezeiten vor der 2. und 3. Anfrage (Konzept 5.5: 5 s, 30 s).
    public let retryDelays: [TimeInterval]
    public let timeout: TimeInterval
    /// Zählt den Verbrauch jeder Antwort mit (Kostenanzeige). `nil` in Tests.
    public let ledger: UsageLedger?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(apiKey: String, session: URLSession = .shared, retryDelays: [TimeInterval] = [5, 30],
                timeout: TimeInterval = 180, ledger: UsageLedger? = nil,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.apiKey = apiKey
        self.session = session
        self.retryDelays = retryDelays
        self.timeout = timeout
        self.ledger = ledger
        self.sleep = sleep
    }

    func request(body: Data) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }

    /// Sendet die Anfrage; bei Überlastung, Ratenlimit oder Netzfehler bis zu zweimal erneut.
    public func send(body: Data) async throws -> ClaudeResponse {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(body: body)
            } catch let error as ClaudeError where error.isRetryable && attempt < retryDelays.count {
                try await sleep(retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private func sendOnce(body: Data) async throws -> ClaudeResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(body: body))
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ClaudeError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        switch http.statusCode {
        case 200:
            // Auch abgelehnte oder abgeschnittene Antworten kosten: Verbrauch vor der Auswertung zählen.
            if let ledger, let usage = Self.usage(data) { ledger.record(input: usage.input, output: usage.output) }
            return try Self.parse(data)
        case 401, 403: throw ClaudeError.invalidKey
        default: throw ClaudeError.http(http.statusCode, Self.errorMessage(data))
        }
    }

    /// Liest eine erfolgreiche Antwort. Inhalt nur, wenn das Modell regulär fertig wurde.
    static func parse(_ data: Data) throws -> ClaudeResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse
        }
        switch json["stop_reason"] as? String {
        case "end_turn": break
        case "refusal":
            let details = json["stop_details"] as? [String: Any]
            throw ClaudeError.refusal(details?["category"] as? String)
        case "max_tokens": throw ClaudeError.truncated
        default: throw ClaudeError.badResponse
        }
        // Blöcke nach Typ lesen, nicht nach Position (vorn können thinking- oder fallback-Blöcke stehen).
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String, !text.isEmpty else {
            throw ClaudeError.emptyResponse
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return ClaudeResponse(text: text, model: json["model"] as? String ?? "",
                              inputTokens: usage["input_tokens"] as? Int ?? 0,
                              outputTokens: usage["output_tokens"] as? Int ?? 0)
    }

    static func usage(_ data: Data) -> (input: Int, output: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return nil }
        return (usage["input_tokens"] as? Int ?? 0, usage["output_tokens"] as? Int ?? 0)
    }

    static func errorMessage(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any], let message = error["message"] as? String else { return "" }
        return String(message.prefix(200))
    }
}

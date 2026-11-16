import Foundation

public enum APIKeyCheckResult: Equatable, Sendable {
    case valid
    case invalid
    case unreachable(String)
    case failed(Int)

    public var message: String {
        switch self {
        case .valid: return loc("Der Schlüssel funktioniert.", "The key works.")
        case .invalid: return loc("Der Schlüssel wurde abgelehnt. Bitte prüfen Sie, ob er vollständig kopiert wurde.", "The key was rejected. Please check that it was copied completely.")
        case .unreachable(let detail): return loc("Keine Verbindung zu Anthropic (\(detail)). Bitte Internetverbindung prüfen.", "No connection to Anthropic (\(detail)). Please check your internet connection.")
        case .failed(let code): return loc("Anthropic hat unerwartet geantwortet (HTTP \(code)). Bitte später erneut versuchen.", "Anthropic sent an unexpected response (HTTP \(code)). Please try again later.")
        }
    }
}

/// Prüft einen API-Schlüssel mit einem kostenlosen Aufruf (`GET /v1/models`), ohne ein Dokument zu senden.
public struct AnthropicKeyChecker: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    public static let apiVersion = "2026-10-21"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func request(key: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    public func check(_ key: String) async -> APIKeyCheckResult {
        let key = Self.normalize(key)
        guard !key.isEmpty else { return .invalid }
        do {
            let (_, response) = try await session.data(for: Self.request(key: key))
            guard let http = response as? HTTPURLResponse else { return .failed(-1) }
            switch http.statusCode {
            case 200: return .valid
            case 401, 403: return .invalid
            default: return .failed(http.statusCode)
            }
        } catch let error as URLError {
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

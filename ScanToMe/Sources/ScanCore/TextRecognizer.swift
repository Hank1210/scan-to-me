import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Eine erkannte Textzeile. `box` ist normalisiert (0…1) mit Ursprung unten links, wie Vision sie liefert.
public struct RecognizedLine: Codable, Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Der erkannte Text einer Seite.
public struct RecognizedPage: Codable, Equatable, Sendable {
    public var lines: [RecognizedLine]

    public init(lines: [RecognizedLine]) {
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public enum TextRecognizerError: Error, LocalizedError, Equatable {
    case unreadableImage(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): return loc("Seite \(name) ist nicht lesbar.", "Page \(name) cannot be read.")
        case .timedOut:
            return loc("Die Texterkennung von macOS hat nicht reagiert. Warten Sie eine Minute und wählen Sie "
                       + "„Jetzt verarbeiten“. Klappt es dann noch nicht, beenden Sie die App (⌘Q) und öffnen Sie sie neu.",
                       "The macOS text recognition did not respond. Wait a minute and choose “Process now”. "
                       + "If it still fails, quit the app (⌘Q) and open it again.")
        }
    }
}

/// Lässt genau einen Aufrufer durch (Ergebnis oder Zeitablauf, je nachdem, was zuerst kommt).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    init() {}
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Führt blockierende Arbeit auf einem eigenen Thread aus und gibt nach `seconds` auf. Gebraucht für Vision:
/// Am 16.11.2026 blieb `VNImageRequestHandler.perform` einmal unbegrenzt in einem internen Semaphor hängen.
/// Der hängende Thread lässt sich nicht abbrechen; die App meldet den Fehler aber und bleibt bedienbar.
public func runWithTimeout<T: Sendable>(seconds: TimeInterval, timeoutError: Error,
                                        _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let once = OnceFlag()
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            if once.claim() { continuation.resume(with: result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if once.claim() { continuation.resume(throwing: timeoutError) }
        }
    }
}

/// Lokale Texterkennung mit Apple Vision. Läuft auf dem Mac, ohne Netz und ohne Kosten.
public enum TextRecognizer {
    public static let languages = ["de-DE", "en-US"]
    /// Normal dauert eine Seite unter 2 Sekunden.
    public static let pageTimeout: TimeInterval = 60

    /// Wie `recognize(jpegURL:)`, aber mit Zeitgrenze (siehe `runWithTimeout`).
    public static func recognize(jpegURL url: URL, timeout: TimeInterval) async throws -> RecognizedPage {
        try await runWithTimeout(seconds: timeout, timeoutError: TextRecognizerError.timedOut) {
            try recognize(jpegURL: url)
        }
    }

    public static func recognize(jpegURL url: URL) throws -> RecognizedPage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TextRecognizerError.unreadableImage(url.lastPathComponent) }
        return try recognize(image)
    }

    public static func recognize(_ image: CGImage) throws -> RecognizedPage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : RecognizedLine(text: text, box: observation.boundingBox)
        }
        return RecognizedPage(lines: sortedInReadingOrder(lines))
    }

    /// Von oben nach unten, innerhalb einer Zeile von links nach rechts.
    static func sortedInReadingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) / 2
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }
    }
}

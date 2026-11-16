import AppKit
import CoreText
import Foundation

/// Gemeinsame Schnittstelle für echten Scanner und Test-Scanner.
public protocol ScannerService: Sendable {
    /// Scannt eine Seite vom Flachbett und liefert JPEG-Daten.
    func scanOnePage(settings: ScanSettings) async throws -> Data
    /// Zieht alle Blätter aus dem Einzug ein; jede Seite geht sofort an `onPage`. Liefert die Anzahl.
    func scanFeeder(settings: ScanSettings, maxPages: Int, onPage: @Sendable (Data) async throws -> Void) async throws -> Int
}

extension ScannerService {
    public func scanOnePage() async throws -> Data {
        try await scanOnePage(settings: ScanSettings())
    }
}

extension ESCLScanner: ScannerService {
    public func scanOnePage(settings: ScanSettings) async throws -> Data {
        try await scanPage(settings: settings)
    }
}

/// Liefert künstliche A4-Seiten (300 dpi) ohne Hardware – für Entwicklung und Tests.
public final class TestScanner: ScannerService, @unchecked Sendable {
    /// Ein Blatt im simulierten Einzug.
    public enum Sheet: Sendable, Equatable {
        case text(String)
        case blank
        /// Papierstau an dieser Stelle.
        case jam
        /// Das ausgedruckte Trennblatt.
        case separator
    }

    private let delay: TimeInterval
    private let lock = NSLock()
    private var counter = 0
    private var _failNext: ScanError?
    private var _feeder: [Sheet]

    public var failNext: ScanError? {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }

    /// Blätter im simulierten Einzug. Ein Durchgang leert ihn.
    public var feeder: [Sheet] {
        get { lock.withLock { _feeder } }
        set { lock.withLock { _feeder = newValue } }
    }

    public init(delay: TimeInterval = 2, feeder: [Sheet] = []) {
        self.delay = delay
        self._feeder = feeder
    }

    /// Ein gemischter Stapel für die Entwicklung: Text, eine leere Rückseite, Text.
    public static let sampleFeeder: [Sheet] = [.text("Brief Seite 1"), .text("Brief Seite 2"), .blank, .separator,
                                               .text("Rechnung Seite 1"), .text("Rechnung Seite 2")]

    public func scanOnePage(settings: ScanSettings) async throws -> Data {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let (number, failure): (Int, ScanError?) = lock.withLock {
            counter += 1
            let failure = _failNext
            _failNext = nil
            return (counter, failure)
        }
        if let failure { throw failure }
        return try Self.makePage(text: "Testseite \(number)")
    }

    public func scanFeeder(settings: ScanSettings, maxPages: Int,
                           onPage: @Sendable (Data) async throws -> Void) async throws -> Int {
        let sheets: [Sheet] = lock.withLock {
            let s = _feeder
            _feeder = []
            return s
        }
        guard !sheets.isEmpty else { throw ScanError.feederEmpty }
        var count = 0
        for (index, sheet) in sheets.enumerated() {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if count >= maxPages {
                lock.withLock { _feeder = Array(sheets[index...]) }
                throw ScanError.pageLimitReached(maxPages)
            }
            switch sheet {
            case .jam:
                lock.withLock { _feeder = Array(sheets[(index + 1)...]) }
                throw ScanError.feederProblem("ScannerAdfJam")
            case .blank:
                try await onPage(try Self.makeBlankPage())
            case .text(let text):
                try await onPage(try Self.makePage(text: text))
            case .separator:
                try await onPage(try Self.makeSeparatorPage())
            }
            count += 1
        }
        return count
    }

    /// Das Trennblatt, wie der Scanner es liefern würde (300 dpi).
    public static func makeSeparatorPage() throws -> Data {
        guard let provider = CGDataProvider(data: try SeparatorSheet.pdf() as CFData),
              let page = CGPDFDocument(provider)?.page(at: 1) else { throw ScanError.badResponse(-2) }
        return try render(width: 2480, height: 3508) { context in
            context.scaleBy(x: 2480 / 595.28, y: 3508 / 841.89)
            context.drawPDFPage(page)
        }
    }

    public static func makePage(text: String, width: Int = 2480, height: Int = 3508) throws -> Data {
        try render(width: width, height: height) { context in
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 160, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 200, y: height - 500)
            CTLineDraw(line, context)

            let small = CTFontCreateWithName("Helvetica" as CFString, 60, nil)
            let body = "Erstellt \(Date().formatted(date: .numeric, time: .standard)) vom Test-Scanner."
            let bodyLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: body, attributes: [.font: small, .foregroundColor: CGColor(gray: 0.2, alpha: 1)]))
            context.textPosition = CGPoint(x: 200, y: height - 700)
            CTLineDraw(bodyLine, context)
        }
    }

    /// Leeres Blatt mit leichtem Grauschleier und Rand-Schatten, wie es ein Einzug liefert.
    public static func makeBlankPage(width: Int = 2480, height: Int = 3508) throws -> Data {
        try render(width: width, height: height, background: 0.97) { context in
            context.setFillColor(CGColor(gray: 0.35, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: height))
        }
    }

    static func render(width: Int, height: Int, background: CGFloat = 1, draw: (CGContext) -> Void) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ScanError.badResponse(-2) }
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        guard let image = context.makeImage() else { throw ScanError.badResponse(-3) }
        return try ImageEncoding.jpeg(image, quality: 0.8)
    }
}

enum ImageEncoding {
    static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        else { throw ScanError.badResponse(-4) }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScanError.badResponse(-4) }
        return output as Data
    }
}

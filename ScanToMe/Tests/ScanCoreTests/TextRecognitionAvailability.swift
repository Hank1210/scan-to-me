import DocKit
import Foundation
import ImageIO
import ScanCore
import XCTest

/// Auf den virtuellen Macs von GitHub Actions scheitert die Texterkennung von Vision sofort („nilError“, keine
/// Neural Engine). Dort werden Tests, die sie brauchen, übersprungen, nachdem eine Probe das bestätigt hat.
/// Lokal laufen sie immer und schlagen fehl, wenn die Texterkennung nicht geht.
func requireTextRecognition() throws {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
    try XCTSkipUnless(TextRecognitionProbe.works, "Die Texterkennung von Vision ist auf diesem Runner nicht verfügbar.")
}

private enum TextRecognitionProbe {
    static let works: Bool = {
        guard let data = try? TestScanner.makePage(text: "Probe", width: 620, height: 877),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        return (try? TextRecognizer.recognize(image)) != nil
    }()
}

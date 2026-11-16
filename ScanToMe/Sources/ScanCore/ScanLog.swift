import Foundation

/// Protokoll der Gespräche mit dem Scanner, zur Fehlersuche bei Hängern.
/// Enthält nur Zeit, Anfrage, Antwortcode, Dauer, Größe und Scannerstatus – nie Bildinhalte oder Schlüssel.
/// Datei: `~/Library/Logs/Scan-to-me/scanner.log`, ab 2 MB wird die alte Datei zu `scanner.1.log`.
public final class ScanLog: @unchecked Sendable {
    /// In Unit-Tests schweigt das gemeinsame Protokoll, damit das `scanner.log` der Nutzer nur echte Abläufe enthält
    /// (außer bei Live-Tests am Drucker).
    public static let shared = ScanLog(enabled: !isUnitTestWithoutScanner)

    static var isUnitTestWithoutScanner: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.processName == "xctest"
            ? env["LIVE_SCANNER_HOST"] == nil : false
    }

    private let enabled: Bool

    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(url: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Logs/Scan-to-me/scanner.log"),
                maxBytes: Int = 2_000_000, enabled: Bool = true) {
        self.url = url
        self.maxBytes = maxBytes
        self.enabled = enabled
    }

    public func write(_ message: String) {
        guard enabled else { return }
        lock.withLock {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Kurzfassung eines Statusdokuments: Zustand, Einzug und die Aufträge mit Zustand.
    public static func summarizeStatus(_ xml: String) -> String {
        let info = ScannerStatusInfo.parse(xml)
        var parts = ["State=\(info.state.rawValue)"]
        if let adf = info.adfState { parts.append("Adf=\(adf)") }
        let jobs = jobStates(in: xml)
        if !jobs.isEmpty { parts.append("Jobs=[\(jobs.joined(separator: ", "))]") }
        return parts.joined(separator: " ")
    }

    /// `<JobUuid>` (gekürzt) und `<JobState>` je `<JobInfo>`.
    static func jobStates(in xml: String) -> [String] {
        xml.components(separatedBy: "JobInfo>").compactMap { chunk in
            guard let state = ESCLScanner.firstTagValue("JobState", in: chunk) else { return nil }
            let id = ESCLScanner.firstTagValue("JobUuid", in: chunk).map { String($0.prefix(8)) } ?? "?"
            let images = ESCLScanner.firstTagValue("ImagesCompleted", in: chunk).map { " \($0) Bilder" } ?? ""
            return "\(id) \(state)\(images)"
        }
    }

    /// Pfad ohne Rechnernamen, Auftrags-ID gekürzt: `GET ScanJobs/1d638239/NextDocument`.
    public static func shortPath(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").dropFirst()   // „eSCL“ weglassen
        return parts.map { $0.count == 36 ? String($0.prefix(8)) : String($0) }.joined(separator: "/")
    }
}

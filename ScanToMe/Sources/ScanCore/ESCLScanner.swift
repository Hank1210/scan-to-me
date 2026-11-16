import CryptoKit
import Foundation
import Security

/// Adresse eines eSCL/AirScan-Scanners im lokalen Netz.
public struct ScannerAddress: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var rootPath: String
    public var useTLS: Bool
    /// SHA-256 des Scanner-Zertifikats (Hex). `nil` = noch nicht festgehalten.
    public var certificateSHA256: String?

    public init(name: String, host: String, port: Int, rootPath: String = "eSCL", useTLS: Bool,
                certificateSHA256: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.rootPath = rootPath
        self.useTLS = useTLS
        self.certificateSHA256 = certificateSHA256
    }

    public var baseURL: URL {
        let root = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(useTLS ? "https" : "http")://\(host):\(port)/\(root)")!
    }
}

public enum ScannerState: String, Sendable {
    case idle = "Idle"
    case processing = "Processing"
    case testing = "Testing"
    case stopped = "Stopped"
    case down = "Down"
    case unknown = "Unknown"
}

/// Antwort von `/eSCL/ScannerStatus`.
public struct ScannerStatusInfo: Equatable, Sendable {
    public var state: ScannerState
    /// z. B. `ScannerAdfEmpty`, `ScannerAdfLoaded`, `ScannerAdfJam`. `nil`, wenn der Scanner keinen Einzug meldet.
    public var adfState: String?

    public init(state: ScannerState, adfState: String?) {
        self.state = state
        self.adfState = adfState
    }

    public static func parse(_ xml: String) -> ScannerStatusInfo {
        let state = ESCLScanner.firstTagValue("State", in: xml).flatMap(ScannerState.init(rawValue:)) ?? .unknown
        return ScannerStatusInfo(state: state, adfState: ESCLScanner.firstTagValue("AdfState", in: xml))
    }

    public var feederEmpty: Bool { adfState == "ScannerAdfEmpty" }

    /// Zustand eines Auftrags laut `ScannerStatus` (`<JobInfo>` mit passender `JobUuid`). `nil`, wenn der
    /// Scanner den Auftrag nicht (mehr) aufführt.
    public static func job(_ jobID: String, in xml: String) -> (state: String, images: Int?)? {
        for chunk in xml.components(separatedBy: "JobInfo>") {
            guard let uuid = ESCLScanner.firstTagValue("JobUuid", in: chunk),
                  uuid.lowercased().contains(jobID.lowercased()) || jobID.lowercased().contains(uuid.lowercased()),
                  let state = ESCLScanner.firstTagValue("JobState", in: chunk) else { continue }
            return (state, ESCLScanner.firstTagValue("ImagesCompleted", in: chunk).flatMap(Int.init))
        }
        return nil
    }

    /// Ein Zustand des Einzugs, der ein Eingreifen am Gerät verlangt (Stau, Klappe offen …).
    public var feederProblem: String? {
        guard let adfState else { return nil }
        let harmless: Set<String> = ["ScannerAdfEmpty", "ScannerAdfLoaded", "ScannerAdfProcessing"]
        return harmless.contains(adfState) ? nil : adfState
    }
}

public enum ScanSource: String, Codable, CaseIterable, Sendable {
    case platen
    case feeder
    /// Hinzugefügte Datei (PDF oder Bild), nicht gescannt.
    case file

    var esclName: String { self == .platen ? "Platen" : "Feeder" }
}

public struct ScanSettings: Sendable, Equatable {
    public var source: ScanSource = .platen
    public var resolution: Int = 300
    public var color: Bool = true
    /// A4 in 1/300 Zoll. Im Einzug wird die volle Breite gescannt (siehe `forFeeder`).
    public var widthThreeHundredths: Int = 2480
    public var heightThreeHundredths: Int = 3508

    public init(source: ScanSource = .platen, resolution: Int = 300, color: Bool = true) {
        self.source = source
        self.resolution = resolution
        self.color = color
    }

    /// Der Epson legt das Papier im Einzug rechtsbündig in einen 2550 breiten Bereich. Mit Breite 2480 ab
    /// Versatz 0 fehlte rechts ein Streifen; deshalb die volle Breite des Einzugs (höchstens 2550).
    public func forFeeder(maxWidth: Int?) -> ScanSettings {
        var copy = self
        copy.source = .feeder
        copy.widthThreeHundredths = min(maxWidth ?? 2550, 2550)
        return copy
    }

    var xml: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version>
          <scan:Intent>Document</scan:Intent>
          <pwg:ScanRegions>
            <pwg:ScanRegion>
              <pwg:Height>\(heightThreeHundredths)</pwg:Height>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
              <pwg:Width>\(widthThreeHundredths)</pwg:Width>
              <pwg:XOffset>0</pwg:XOffset>
              <pwg:YOffset>0</pwg:YOffset>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>\(source.esclName)</pwg:InputSource>
          <scan:ColorMode>\(color ? "RGB24" : "Grayscale8")</scan:ColorMode>
          <scan:XResolution>\(resolution)</scan:XResolution>
          <scan:YResolution>\(resolution)</scan:YResolution>
          <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        </scan:ScanSettings>
        """
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case busy(String)
    case jobRejected(Int)
    case noJobLocation
    case timeout
    case badResponse(Int)
    case incompleteImage(Int)
    case certificateMismatch
    case feederEmpty
    case feederProblem(String)
    case pageLimitReached(Int)
    /// Der Scanner hat den Auftrag selbst beendet, während die App noch auf ein Bild wartete.
    case jobEnded(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return loc("Scanner nicht erreichbar (\(detail)).", "Scanner not reachable (\(detail)).")
        case .busy(let state): return loc("Scanner ist beschäftigt (Status: \(state)).", "Scanner is busy (status: \(state)).")
        case .jobRejected(let code): return loc("Scanner hat den Auftrag abgelehnt (HTTP \(code)).", "Scanner rejected the job (HTTP \(code)).")
        case .noJobLocation: return loc("Scanner hat keine Auftragsadresse geliefert.", "Scanner did not return a job address.")
        case .timeout: return loc("Zeitüberschreitung beim Warten auf das Bild.", "Timed out waiting for the image.")
        case .badResponse(let code): return loc("Unerwartete Antwort vom Scanner (HTTP \(code)).", "Unexpected response from the scanner (HTTP \(code)).")
        case .incompleteImage(let bytes): return loc("Bild unvollständig (\(bytes) Bytes).", "Image incomplete (\(bytes) bytes).")
        case .certificateMismatch: return loc("Das Zertifikat des Scanners stimmt nicht mit der Einrichtung überein.", "The scanner’s certificate does not match the one saved during setup.")
        case .feederEmpty:
            return loc("Im Einzug liegt kein Papier. Bitte Blätter in den Einzug oben am Drucker legen oder „Flachbett“ wählen.", "There is no paper in the feeder. Please put sheets in the feeder on top of the printer or choose “Flatbed”.")
        case .feederProblem(let state): return Self.feederText(state)
        case .jobEnded(let state):
            return loc("Der Drucker hat den Auftrag von sich aus beendet (Status: \(state)), bevor die nächste Seite kam. "
                       + "Prüfen Sie, ob ein Blatt im Einzug steckt.",
                       "The printer ended the job by itself (status: \(state)) before the next page arrived. "
                       + "Check whether a sheet is stuck in the feeder.")
        case .pageLimitReached(let max):
            return loc("Ein Scan kann höchstens \(max) Seiten haben. Bitte die restlichen Blätter in einem neuen Scan erfassen.", "A scan can have at most \(max) pages. Please scan the remaining sheets in a new scan.")
        }
    }

    static func feederText(_ state: String) -> String {
        switch state {
        case "ScannerAdfJam":
            return loc("Papierstau im Einzug. Bitte das Papier vorsichtig herausziehen.", "Paper jam in the feeder. Please pull the paper out carefully.")
        case "ScannerAdfHatchOpen":
            return loc("Die Abdeckung des Einzugs ist offen. Bitte schließen.", "The feeder cover is open. Please close it.")
        case "ScannerAdfMispick":
            return loc("Ein Blatt wurde nicht richtig eingezogen.", "A sheet was not fed correctly.")
        case "ScannerAdfMultipickDetected":
            return loc("Es wurden mehrere Blätter auf einmal eingezogen.", "Several sheets were fed at once.")
        case "ScannerAdfInputTrayOverloaded":
            return loc("Im Einzug liegen zu viele Blätter (höchstens 50).", "There are too many sheets in the feeder (at most 50).")
        default:
            return loc("Der Einzug meldet ein Problem (\(state)).", "The feeder reports a problem (\(state)).")
        }
    }
}

/// Steuert einen Scanner über eSCL (AirScan): einzelne Seiten vom Flachbett oder alle Blätter aus dem Einzug.
public final class ESCLScanner: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let address: ScannerAddress

    /// Wartezeit auf ein Bild je Versuch bzw. je Blatt. Normal sind 16–45 s. Der Epson WF-2960 legt aber
    /// gelegentlich mitten im Einzug eine Pause von etwa 2 Minuten ein und liefert dann doch (gemessen 15.11.2026:
    /// 119 s; Vorgängerprojekt: über 120 s, Empfehlung mindestens 5 Minuten). Erst danach wird der Auftrag gelöscht
    /// (Flachbett: einmal automatisch neu gestartet).
    public var imageTimeout: TimeInterval = 300
    public var automaticRetries = 1
    /// So lange wird auf „Idle“ gewartet, wenn der Scanner gerade noch einen Auftrag abschließt.
    public var busyWait: TimeInterval = 20
    /// Protokoll für die Fehlersuche (`nil` = keins).
    public var log: ScanLog? = .shared

    private let certificateLock = NSLock()
    private var _observedCertificateSHA256: String?
    private var _certificateRejected = false

    /// Fingerabdruck des Zertifikats, das der Scanner bei der letzten Verbindung vorgelegt hat.
    public var observedCertificateSHA256: String? { certificateLock.withLock { _observedCertificateSHA256 } }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 330
        config.timeoutIntervalForResource = 360
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(address: ScannerAddress) {
        self.address = address
    }

    /// Schließt die Verbindungen zum Scanner, sobald laufende Anfragen fertig sind. Wichtig: Eine URLSession
    /// hält ihren Delegate (diesen Scanner) fest und gibt ihre offenen Verbindungen erst danach frei. Ohne diesen
    /// Aufruf bleiben je Instanz Verbindungen zum Drucker offen; Druckerserver haben nur wenige davon.
    public func invalidate() {
        log?.write("== Verbindung geschlossen")
        session.finishTasksAndInvalidate()
    }

    // MARK: - Status

    public func status() async throws -> ScannerState {
        try await statusInfo().state
    }

    public func statusInfo() async throws -> ScannerStatusInfo {
        var request = URLRequest(url: address.baseURL.appendingPathComponent("ScannerStatus"))
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw ScanError.badResponse(response.statusCode) }
        return ScannerStatusInfo.parse(String(decoding: data, as: UTF8.self))
    }

    /// Status vor einem Auftrag: wartet kurz, falls der Scanner noch beschäftigt ist.
    private func readyStatus() async throws -> ScannerStatusInfo {
        let deadline = Date().addingTimeInterval(busyWait)
        while true {
            let info: ScannerStatusInfo
            do {
                info = try await statusInfo()
            } catch ScanError.timeout {
                // Keine Antwort auf die Statusabfrage = Scanner aus, im Ruhezustand oder kein Netz.
                throw ScanError.unreachable("keine Antwort")
            } catch ScanError.badResponse(let code) {
                throw ScanError.unreachable("HTTP \(code)")
            }
            if info.state == .idle { return info }
            guard info.state == .processing, Date() < deadline else { throw ScanError.busy(info.state.rawValue) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Flachbett

    /// Scannt eine Seite vom Flachbett und liefert die JPEG-Daten.
    /// Bei Fehler oder Abbruch wird der Auftrag am Scanner gelöscht, damit er nicht hängen bleibt.
    public func scanPage(settings: ScanSettings = ScanSettings()) async throws -> Data {
        var platen = settings
        platen.source = .platen
        var attempt = 0
        while true {
            do {
                return try await scanPageOnce(settings: platen)
            } catch let error as ScanError where Self.isRetryable(error) && attempt < automaticRetries {
                attempt += 1
                // Der hängende Auftrag ist bereits gelöscht; warten, bis der Scanner wieder frei ist.
                try await waitUntilIdle(maxWait: 60)
            }
        }
    }

    private func scanPageOnce(settings: ScanSettings) async throws -> Data {
        log?.write("== Flachbett: Start")
        _ = try await readyStatus()
        let jobURL = try await createJob(settings: settings)
        do {
            guard let data = try await fetchNextDocument(jobURL: jobURL) else { throw ScanError.badResponse(404) }
            guard Self.isCompleteJPEG(data) else { throw ScanError.incompleteImage(data.count) }
            await finishJob(jobURL: jobURL)
            return data
        } catch {
            log?.write("== Flachbett: Abbruch: \(error is CancellationError ? "vom Nutzer" : String(describing: error))")
            await cancelJob(jobURL: jobURL)
            throw error
        }
    }

    static func isRetryable(_ error: ScanError) -> Bool {
        switch error {
        case .timeout, .incompleteImage: return true
        default: return false
        }
    }

    private func waitUntilIdle(maxWait: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try Task.checkCancellation()
            if (try? await status()) == .idle { return }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - Einzug

    /// Zieht alle Blätter aus dem Einzug ein. Jede Seite wird sofort an `onPage` übergeben, damit sie
    /// gespeichert ist, bevor die nächste kommt. Ein Blatt, das schon durch den Einzug gelaufen ist, lässt sich
    /// nicht wiederholen; deshalb gibt es hier keine automatische Wiederholung. Bei Fehler oder Abbruch wird der
    /// Auftrag gelöscht; bereits übergebene Seiten bleiben gültig.
    /// - Returns: Anzahl der eingezogenen Seiten.
    @discardableResult
    public func scanFeeder(settings: ScanSettings, maxPages: Int,
                           onPage: @Sendable (Data) async throws -> Void) async throws -> Int {
        guard maxPages > 0 else { throw ScanError.pageLimitReached(0) }
        log?.write("== Einzug: Start (höchstens \(maxPages) Seiten)")
        let info = try await readyStatus()
        if let problem = info.feederProblem { throw ScanError.feederProblem(problem) }
        if info.feederEmpty { throw ScanError.feederEmpty }

        let jobURL: URL
        do {
            jobURL = try await createJob(settings: settings)
        } catch ScanError.jobRejected(let code) {
            // Manche Geräte lehnen den Auftrag ab statt „leer“ zu melden.
            let after = try? await statusInfo()
            if let problem = after?.feederProblem { throw ScanError.feederProblem(problem) }
            if after?.feederEmpty == true { throw ScanError.feederEmpty }
            throw ScanError.jobRejected(code)
        }

        var count = 0
        do {
            while true {
                guard let data = try await fetchNextDocument(jobURL: jobURL, received: count) else { break }
                guard Self.isCompleteJPEG(data) else { throw ScanError.incompleteImage(data.count) }
                try await onPage(data)
                count += 1
                if count >= maxPages {
                    let rest = try? await statusInfo()
                    if rest?.feederEmpty == true {
                        await finishJob(jobURL: jobURL)
                        break
                    }
                    throw ScanError.pageLimitReached(maxPages)
                }
            }
        } catch {
            log?.write("== Einzug: Abbruch nach \(count) Seiten: \(error is CancellationError ? "vom Nutzer" : String(describing: error))")
            await cancelJob(jobURL: jobURL)
            throw error
        }
        log?.write("== Einzug: Ende nach \(count) Seiten")

        // Ende des Auftrags (404): normal, wenn der Einzug leer ist. Sonst Stau o. Ä.
        let after = try? await statusInfo()
        if let problem = after?.feederProblem {
            await cancelJob(jobURL: jobURL)
            throw ScanError.feederProblem(problem)
        }
        if count == 0 { throw ScanError.feederEmpty }
        return count
    }

    // MARK: - Ablauf

    private func createJob(settings: ScanSettings) async throws -> URL {
        var request = URLRequest(url: address.baseURL.appendingPathComponent("ScanJobs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(settings.xml.utf8)
        let (_, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else { throw ScanError.jobRejected(response.statusCode) }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: address.baseURL)?.absoluteURL
        else { throw ScanError.noJobLocation }
        return url
    }

    /// Nächstes Bild des Auftrags. `nil` = keine weiteren Bilder (HTTP 404).
    /// Wie oft während des Wartens auf ein Bild der Auftragsstatus abgefragt wird.
    static let jobWatchInterval: TimeInterval = 20

    /// Was die Statusabfrage über den eigenen Auftrag ergibt.
    enum JobWatch: Equatable {
        /// Läuft noch (auch bei langen Pausen des Epson).
        case running
        /// Fertig, aber mehr Bilder als bei der App angekommen: eine Antwort ging unterwegs verloren.
        case completedWithMissingImage
        /// Abgebrochen, fertig ohne fehlendes Bild oder nicht mehr aufgeführt.
        case ended(String)
    }

    static func judge(jobID: String, xml: String, received: Int) -> JobWatch {
        guard let job = ScannerStatusInfo.job(jobID, in: xml) else { return .ended("–") }
        switch job.state {
        case "Processing", "Pending": return .running
        case "Completed":
            if let images = job.images, images > received { return .completedWithMissingImage }
            return .ended(job.state)
        default: return .ended(job.state)
        }
    }

    /// Holt das nächste Bild. Parallel dazu wird alle 20 s der Status des Auftrags abgefragt: Hat der Scanner den
    /// Auftrag selbst beendet (am 16.11.2026 beobachtet: Anfrage hing 5 Minuten, danach kannte der Epson den
    /// Auftrag nicht mehr), wird sofort abgebrochen statt bis zur Zeitgrenze zu warten. Ist der Auftrag fertig,
    /// obwohl ein Bild fehlt, wird das Bild einmal neu angefragt.
    private func fetchNextDocument(jobURL: URL, received: Int = 0) async throws -> Data? {
        let deadline = Date().addingTimeInterval(imageTimeout)
        var askedAgain = false
        while Date() < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: jobURL.appendingPathComponent("NextDocument"))
            request.timeoutInterval = max(10, deadline.timeIntervalSinceNow)
            let outcome = try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
                group.addTask { .response(try await self.send(request)) }
                group.addTask { try await self.watchJob(jobURL: jobURL, received: received) }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let data: Data, response: HTTPURLResponse
            switch outcome {
            case .response(let r):
                (data, response) = r
            case .watch(.ended(let state)):
                log?.write("== Einzug: Scanner hat den Auftrag beendet (\(state)), Anfrage abgebrochen")
                throw ScanError.jobEnded(state)
            case .watch(_):
                guard !askedAgain else { throw ScanError.jobEnded("Completed") }
                askedAgain = true
                log?.write("== Einzug: Auftrag fertig, aber ein Bild fehlt – frage neu an")
                continue
            }
            switch response.statusCode {
            case 200 where !data.isEmpty:
                return data
            case 404:
                return nil
            case 503:
                // Scanner noch nicht bereit – kurz warten und erneut fragen.
                try await Task.sleep(nanoseconds: 2_000_000_000)
            default:
                throw ScanError.badResponse(response.statusCode)
            }
        }
        throw ScanError.timeout
    }

    private enum FetchOutcome: Sendable {
        case response((Data, HTTPURLResponse))
        case watch(JobWatch)
    }

    /// Fragt regelmäßig den Status ab, bis der Auftrag nicht mehr läuft. Fehler der Statusabfrage werden
    /// übergangen (dann zählt weiter die Zeitgrenze der Bildanfrage).
    private func watchJob(jobURL: URL, received: Int) async throws -> FetchOutcome {
        let jobID = jobURL.lastPathComponent
        while true {
            try await Task.sleep(nanoseconds: UInt64(Self.jobWatchInterval * 1_000_000_000))
            var request = URLRequest(url: address.baseURL.appendingPathComponent("ScannerStatus"))
            request.timeoutInterval = 15
            guard let (data, response) = try? await send(request), response.statusCode == 200 else {
                try Task.checkCancellation()
                continue
            }
            let verdict = Self.judge(jobID: jobID, xml: String(decoding: data, as: UTF8.self), received: received)
            if verdict != .running { return .watch(verdict) }
        }
    }

    /// Nach dem letzten Bild meldet NextDocument 404; erst dann ist der Auftrag abgeschlossen.
    private func finishJob(jobURL: URL) async {
        var request = URLRequest(url: jobURL.appendingPathComponent("NextDocument"))
        request.timeoutInterval = 30
        _ = try? await send(request)
    }

    /// Löscht den Auftrag am Scanner, sonst bleibt er auf „Processing“ stehen. Läuft losgelöst von der
    /// aufrufenden Aufgabe, damit das Löschen auch nach „Abbrechen“ (Task-Abbruch) noch gesendet wird.
    private func cancelJob(jobURL: URL) async {
        var request = URLRequest(url: jobURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        await Task.detached { [self] in _ = try? await self.send(request) }.value
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        let label = "\(request.httpMethod ?? "GET") \(ScanLog.shortPath(request.url!))"
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScanError.badResponse(-1) }
            var detail = "\(http.statusCode) \(ms()) ms \(data.count) B"
            if request.url!.lastPathComponent == "ScannerStatus", http.statusCode == 200 {
                detail += " " + ScanLog.summarizeStatus(String(decoding: data, as: UTF8.self))
            }
            if let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location) {
                detail += " → \(ScanLog.shortPath(url))"
            }
            log?.write("\(label) \(detail)")
            return (data, http)
        } catch let error as URLError {
            log?.write("\(label) Fehler \(error.code.rawValue) nach \(ms()) ms: \(error.localizedDescription)")
            if certificateLock.withLock({ _certificateRejected }) { throw ScanError.certificateMismatch }
            switch error.code {
            case .timedOut: throw ScanError.timeout
            case .cancelled: throw CancellationError()
            default: throw ScanError.unreachable(error.localizedDescription)
            }
        }
    }

    // MARK: - TLS

    /// Scanner nutzen selbst signierte Zertifikate. Vertraut wird nur dem konfigurierten Host, und –
    /// sobald festgehalten – nur dem Zertifikat mit dem gespeicherten SHA-256-Fingerabdruck.
    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == address.host.lowercased(),
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }

        let actual = Self.leafCertificateSHA256(trust)
        guard Self.certificateMatches(pinned: address.certificateSHA256, actual: actual) else {
            certificateLock.withLock { _certificateRejected = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        certificateLock.withLock { _observedCertificateSHA256 = actual }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Ohne gespeicherten Fingerabdruck wird beim ersten Kontakt vertraut; danach muss er exakt passen.
    static func certificateMatches(pinned: String?, actual: String?) -> Bool {
        guard let pinned, !pinned.isEmpty else { return true }
        guard let actual else { return false }
        return pinned.lowercased() == actual.lowercased()
    }

    static func leafCertificateSHA256(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Fragt den Status ab und liefert den dabei gesehenen Zertifikats-Fingerabdruck (für die Einrichtung).
    public func fetchCertificateFingerprint() async throws -> String? {
        _ = try await status()
        return observedCertificateSHA256
    }

    // MARK: - Fähigkeiten

    /// Liest `/eSCL/ScannerCapabilities`: Flachbett, Einzug, beidseitiger Einzug.
    public func capabilities() async throws -> ScannerCapabilities {
        var request = URLRequest(url: address.baseURL.appendingPathComponent("ScannerCapabilities"))
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw ScanError.badResponse(response.statusCode) }
        return ScannerCapabilities.parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Hilfsfunktionen

    static func firstTagValue(_ tag: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9]+:)?\(tag)>([^<]*)</") else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[valueRange])
    }

    /// Ein vollständiges JPEG beginnt mit FFD8 und endet mit FFD9.
    public static func isCompleteJPEG(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        let bytes = [UInt8](data.prefix(2)) + [UInt8](data.suffix(2))
        return bytes == [0xFF, 0xD8, 0xFF, 0xD9]
    }
}

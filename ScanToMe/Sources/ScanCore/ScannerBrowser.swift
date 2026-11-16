import Foundation

/// Sucht eSCL-Scanner per Bonjour (`_uscan._tcp`, `_uscans._tcp`) und löst Hostname, Port und Pfad auf.
/// Muss auf dem Main-Thread benutzt werden (NetService arbeitet mit dem Main-RunLoop).
@MainActor
public final class ScannerBrowser: NSObject, ObservableObject {
    @Published public private(set) var found: [ScannerAddress] = []
    @Published public private(set) var isSearching = false

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []

    public override init() {}

    public func start() {
        stop()
        found = []
        isSearching = true
        for type in ["_uscan._tcp.", "_uscans._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    public func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        pending.forEach { $0.stop() }
        pending = []
        isSearching = false
    }

    fileprivate func add(service: NetService) {
        guard let host = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return }
        var root = "eSCL"
        if let txtData = service.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: txtData)
            if let rs = txt["rs"], let value = String(data: rs, encoding: .utf8), !value.isEmpty {
                root = value
            }
        }
        let tls = service.type.hasPrefix("_uscans") || service.port == 443
        let address = ScannerAddress(name: service.name, host: host, port: service.port, rootPath: root, useTLS: tls)
        // Gleicher Scanner kann unter beiden Diensttypen erscheinen – TLS-Variante bevorzugen.
        if let index = found.firstIndex(where: { $0.host == address.host }) {
            if address.useTLS && !found[index].useTLS { found[index] = address }
        } else {
            found.append(address)
        }
    }
}

extension ScannerBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            pending.append(service)
            service.resolve(withTimeout: 10)
        }
    }

    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            add(service: sender)
        }
    }

    nonisolated public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        MainActor.assumeIsolated {
            isSearching = !browsers.isEmpty && browsers.contains { $0 !== browser }
        }
    }
}

import Foundation

/// A Mac on the local network that is advertising Screen Sharing.
struct NearbyMac: Identifiable, Equatable {
    var name: String
    var host: String
    var id: String { host.lowercased() }
}

/// Finds Macs with Screen Sharing turned on by browsing Bonjour for the
/// service they advertise, and resolves each one to a host name.
@MainActor
final class NearbyMacs: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published private(set) var macs: [NearbyMac] = []

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var found: [String: NearbyMac] = [:]   // by Bonjour service name

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found[service.name] = nil
        publish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if var host = sender.hostName {
            if host.hasSuffix(".") { host.removeLast() }
            found[sender.name] = NearbyMac(name: sender.name, host: host)
            publish()
        }
        finish(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(sender)
    }

    private func finish(_ service: NetService) {
        service.stop()
        resolving.removeAll { $0 === service }
    }

    private func publish() {
        macs = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

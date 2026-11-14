import Foundation
import ScreenShareKit

// HomeKit camera: publishes a Mac's screen as an IP camera in the Home app.
// It speaks the HomeKit Accessory Protocol itself, signs in to the Mac's Screen
// Sharing when a stream or snapshot is wanted, and re-encodes the HEVC video as
// the H.264 that HomeKit requires.
//
//   sscamera <host> <user> [--password-file path] [--name text] [--setup-code 123-45-678]
//            [--port n] [--state dir] [--streams n] [--linger seconds] [--always-on]
//            [--virtual-display WxH] [--aspect W:H] [--reset] [--verbose]
//   sscamera --local [same options]        this Mac's own screen
//   sscamera --test-pattern [same options]

setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func fail(_ message: String) -> Never {
    print(message)
    exit(2)
}

let usage = """
    usage: sscamera <host> <user> [--password-file path] [--name text] [--setup-code 123-45-678]
                    [--port n] [--state dir] [--streams n] [--linger seconds] [--always-on]
                    [--virtual-display WxH] [--aspect W:H] [--reset] [--verbose]
           sscamera --local [same options]
           sscamera --test-pattern [--name text] [--setup-code 123-45-678] [--port n] [--state dir] [--reset] [--verbose]
    """

let testPattern = flag("--test-pattern")
let local = flag("--local")
let verbose = flag("--verbose")
let alwaysOn = flag("--always-on")
let reset = flag("--reset")
let passwordFile = option("--password-file")
let name = option("--name") ?? (testPattern ? "Test Pattern" : local ? (Host.current().localizedName ?? "Mac Screen") : "Mac Screen")
let requestedCode = option("--setup-code")
let port: UInt16 = option("--port").map { UInt16($0) ?? 0 } ?? 51828
guard port > 0 else { fail("--port expects a number from 1 to 65535") }
let streamCount = option("--streams").map { Int($0) ?? 0 } ?? 2
let linger = option("--linger").map { TimeInterval($0) ?? -1 } ?? 30
let virtualDisplay = option("--virtual-display")
let aspect = option("--aspect")
let stateDirectory = option("--state").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sscamera")

guard (1...4).contains(streamCount) else { fail("--streams expects 1 to 4") }
guard linger >= 0 else { fail("--linger expects a number of seconds") }
let contentAspect: Double? = aspect.map { text in
    let parts = text.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--aspect expects W:H, such as 1:1 or 4:3") }
    return parts[0] / parts[1]
}
if let requestedCode, !AccessoryStore.isAcceptable(requestedCode) {
    fail("--setup-code must look like 123-45-678 and not be all one digit or 12345678")
}

/// This machine's IPv4 addresses.
func localAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var addresses: [String] = []
    var entry = list
    while let current = entry {
        defer { entry = current.pointee.ifa_next }
        guard let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.append(String(cString: host))
        }
    }
    return addresses
}

func isThisMac(_ host: String) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return false }
    defer { freeaddrinfo(result) }
    var resolved = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    getnameinfo(result.pointee.ai_addr, result.pointee.ai_addrlen, &resolved, socklen_t(resolved.count), nil, 0, NI_NUMERICHOST)
    return localAddresses().contains(String(cString: resolved))
}

let upstream: FrameSource.Upstream
if testPattern || local {
    guard arguments.isEmpty, !(testPattern && local) else { fail(usage) }
    upstream = testPattern ? .testPattern : .localDisplay
} else {
    guard arguments.count == 2 else { fail(usage) }
    if isThisMac(arguments[0]) {
        fail("""
            \(arguments[0]) is this Mac. Screen Sharing cannot connect to the Mac it runs on (its ports are
            taken by the Mac's own Screen Sharing service). To show this Mac's screen, use:
              sscamera --local
            """)
    }
    var password = ProcessInfo.processInfo.environment["SS_PASSWORD"] ?? ""
    if let passwordFile {
        guard let contents = try? String(contentsOfFile: passwordFile, encoding: .utf8) else { fail("cannot read \(passwordFile)") }
        password = contents.trimmingCharacters(in: .newlines)
    }
    if password.isEmpty, isatty(STDIN_FILENO) != 0, let typed = getpass("Password for \(arguments[1]) on \(arguments[0]): ") {
        password = String(cString: typed)
    }
    guard !password.isEmpty else { fail("no password: use --password-file or SS_PASSWORD") }
    var display: VirtualDisplay?
    if let virtualDisplay {
        let parts = virtualDisplay.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 >= 320 && $0 <= 4096 }) else { fail("--virtual-display expects WxH, such as 1280x720") }
        display = VirtualDisplay(width: parts[0], height: parts[1], scale: 1)
    }
    upstream = .mac(host: arguments[0], username: arguments[1], password: password, display: display)
}

if verbose {
    let started = Date()
    ScreenShareLog.sink = { print(String(format: "[%7.2fs] %@", Date().timeIntervalSince(started), $0)) }
}

if reset {
    // A fresh identity: controllers forget anything cached about the old one.
    try? FileManager.default.removeItem(at: stateDirectory.appendingPathComponent("accessory.json"))
    print("Forgot the previous identity and pairings")
}

let store: AccessoryStore
do {
    store = try AccessoryStore(directory: stateDirectory, setupCode: requestedCode)
} catch {
    fail("cannot open \(stateDirectory.path): \(error)")
}

let source = FrameSource(upstream: upstream)
source.linger = linger
source.alwaysOn = alwaysOn
source.contentAspect = contentAspect
let server = HAPServer(store: store, name: name, model: CameraAccessory.model, port: port)
server.verbose = verbose
let accessory = CameraAccessory(name: name, serial: store.deviceID, source: source, server: server, streamCount: streamCount)
server.accessory = accessory

do {
    try server.start(onReady: { port in
        print("HomeKit camera \"\(name)\" is on the network (port \(port), id \(store.deviceID)).")
        if store.isPaired {
            print("Already paired with \(store.pairings.count) controller(s).")
        } else {
            print("""
                To add it: Home app → + → Add Accessory → More options… → \(name),
                then enter the setup code \(store.setupCode)
                """)
        }
    }, onFailure: { error in
        fail("cannot listen: \(error)")
    })
} catch {
    fail("cannot start: \(error)")
}
source.start()
dispatchMain()

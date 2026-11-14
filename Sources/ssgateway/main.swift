import Foundation
import ScreenShareKit

// Web gateway: lets a browser view and control a Mac through this machine.
// The gateway signs in to the Mac's Screen Sharing, passes the HEVC video
// through to the page untouched, and relays the page's pointer and keyboard.
//
//   ssgateway <host> <user> [--password-file path] [--port n] [--listen ip]
//             [--code text] [--mirror] [--verbose]
//   ssgateway --test-pattern [--port n] [--listen ip] [--code text] [--verbose]
//
// The password comes from --password-file, the SS_PASSWORD environment
// variable, or a prompt. It stays on this machine; browsers only need the
// access code this command prints.

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
    usage: ssgateway <host> <user> [--password-file path] [--port n] [--listen ip] [--code text] [--mirror] [--verbose]
           ssgateway --test-pattern [--port n] [--listen ip] [--code text] [--verbose]
    """

var options = GatewayOptions()
let testPattern = flag("--test-pattern")
options.mirror = flag("--mirror")
options.verbose = flag("--verbose")
options.listenAddress = option("--listen")
let passwordFile = option("--password-file")
if let port = option("--port") {
    guard let number = UInt16(port), number > 0, number < UInt16.max else { fail("--port expects a number from 1 to 65534") }
    options.port = number
}

/// Easy to read aloud and to type on a touch keyboard: no look-alike characters.
func randomCode() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    var generator = SystemRandomNumberGenerator()
    return String((0..<8).map { _ in alphabet.randomElement(using: &generator)! })
}
options.accessCode = option("--code") ?? randomCode()
guard options.accessCode.count >= 6 else { fail("--code must be at least 6 characters") }

if testPattern {
    guard arguments.isEmpty else { fail(usage) }
} else {
    guard arguments.count == 2 else { fail(usage) }
    var password = ProcessInfo.processInfo.environment["SS_PASSWORD"] ?? ""
    if let passwordFile {
        guard let contents = try? String(contentsOfFile: passwordFile, encoding: .utf8) else {
            fail("cannot read \(passwordFile)")
        }
        password = contents.trimmingCharacters(in: .newlines)
    }
    if password.isEmpty, isatty(STDIN_FILENO) != 0, let typed = getpass("Password for \(arguments[1]) on \(arguments[0]): ") {
        password = String(cString: typed)
    }
    guard !password.isEmpty else { fail("no password: use --password-file or SS_PASSWORD") }
    options.mac = (arguments[0], arguments[1], password)
}

if options.verbose {
    let started = Date()
    ScreenShareLog.sink = { print(String(format: "[%7.2fs] %@", Date().timeIntervalSince(started), $0)) }
}

/// This machine's IPv4 addresses on the local network.
func localAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var addresses: [String] = []
    var entry = list
    while let current = entry {
        defer { entry = current.pointee.ifa_next }
        let flags = Int32(current.pointee.ifa_flags)
        guard let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            addresses.append(String(cString: host))
        }
    }
    return addresses
}

let gateway = Gateway(options: options)
do {
    try gateway.start()
} catch {
    fail("cannot start: \(error)")
}

let hosts = options.listenAddress.map { [$0] } ?? (localAddresses() + ["localhost"])
print(testPattern ? "Showing a test pattern (no Mac involved)." : "Gateway to \(arguments[1])@\(arguments[0]).")
print("Open one of these in a browser:")
for host in hosts {
    print("  http://\(host):\(options.port)/#\(options.accessCode)")
}
print("Access code: \(options.accessCode)   (ports \(options.port) and \(options.port + 1), Ctrl-C to stop)")
dispatchMain()

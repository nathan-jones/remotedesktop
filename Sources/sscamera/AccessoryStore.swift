import CryptoKit
import Foundation

/// The accessory's lasting identity and the controllers paired with it, kept in
/// a JSON file readable only by this user. Losing the file means pairing again.
final class AccessoryStore {
    struct Pairing: Codable {
        var identifier: String
        var publicKey: Data
        var isAdmin: Bool
    }

    private struct Contents: Codable {
        var deviceID: String
        var setupCode: String
        var signingKey: Data
        var configurationNumber: Int
        var databaseDigest: String
        var pairings: [Pairing]
    }

    private let url: URL
    private var contents: Contents

    let signingKey: Curve25519.Signing.PrivateKey

    var deviceID: String { contents.deviceID }
    var setupCode: String { contents.setupCode }
    var configurationNumber: Int { contents.configurationNumber }
    var pairings: [Pairing] { contents.pairings }
    var isPaired: Bool { !contents.pairings.isEmpty }

    init(directory: URL, setupCode requestedCode: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("accessory.json")
        if let data = try? Data(contentsOf: url) {
            contents = try JSONDecoder().decode(Contents.self, from: data)
            if let requestedCode, requestedCode != contents.setupCode {
                guard contents.pairings.isEmpty else {
                    throw StoreError("already paired with setup code \(contents.setupCode); remove it from the Home app (or delete \(url.path)) before changing the code")
                }
                contents.setupCode = requestedCode
            }
        } else {
            let id = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
            contents = Contents(
                deviceID: id, setupCode: requestedCode ?? AccessoryStore.randomSetupCode(),
                signingKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                configurationNumber: 1, databaseDigest: "", pairings: [])
        }
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: contents.signingKey)
        try save()
    }

    /// Controllers cache the attribute database; the configuration number tells
    /// them when it has changed.
    func noteDatabase(_ database: Data) throws {
        let digest = SHA256.hash(data: database).map { String(format: "%02x", $0) }.joined()
        guard digest != contents.databaseDigest else { return }
        if !contents.databaseDigest.isEmpty { contents.configurationNumber = contents.configurationNumber % 65535 + 1 }
        contents.databaseDigest = digest
        try save()
    }

    func pairing(_ identifier: String) -> Pairing? {
        contents.pairings.first { $0.identifier == identifier }
    }

    func addPairing(_ pairing: Pairing) throws {
        if let index = contents.pairings.firstIndex(where: { $0.identifier == pairing.identifier }) {
            contents.pairings[index].isAdmin = pairing.isAdmin
        } else {
            contents.pairings.append(pairing)
        }
        try save()
    }

    func removePairing(_ identifier: String) throws {
        contents.pairings.removeAll { $0.identifier == identifier }
        // With no administrator left nobody could manage the rest.
        if !contents.pairings.contains(where: \.isAdmin) { contents.pairings.removeAll() }
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(contents).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Eight digits shown as XXX-XX-XXX, avoiding the codes HomeKit refuses.
    static func randomSetupCode() -> String {
        while true {
            let digits = (0..<8).map { _ in Character(String(Int.random(in: 0...9))) }
            let code = String(digits[0..<3]) + "-" + String(digits[3..<5]) + "-" + String(digits[5..<8])
            if isAcceptable(code) { return code }
        }
    }

    static func isAcceptable(_ code: String) -> Bool {
        let digits = code.filter(\.isNumber)
        guard code.count == 10, digits.count == 8, code.split(separator: "-").map(\.count) == [3, 2, 3] else { return false }
        if Set(digits).count == 1 { return false }
        return !["12345678", "87654321"].contains(digits)
    }
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

import CryptoKit
import Foundation
import ScreenShareKit

enum HAPCrypto {
    /// HKDF-SHA512 with string salt and info, as every HAP key derivation uses.
    static func hkdf(_ secret: Data, salt: String, info: String, length: Int = 32) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8),
                               info: Data(info.utf8), outputByteCount: length)
    }

    /// Pairing messages use 12-byte nonces made of four zero bytes and an 8-byte label.
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + Data(label.utf8))
    }

    /// Session frames count upwards: four zero bytes then a little-endian 64-bit counter.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: counter.littleEndian) { Data($0) })
    }

    /// Ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) -> Data {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) -> Data? {
        guard sealed.count >= 16 else { return nil }
        let sealed = Data(sealed)
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

/// The accessory side of SRP-6a as RFC 5054 describes it, which HomeKit's Pair
/// Setup uses with the 3072-bit group, SHA-512 and the user name "Pair-Setup".
struct SRPServer {
    struct Group {
        let modulus: BigUInt
        let generator: BigUInt
        let hash: (Data) -> Data

        static let rfc5054_3072 = Group(modulus: BigUInt(hex: """
            FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1 29024E08
            8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD EF9519B3 CD3A431B
            302B0A6D F25F1437 4FE1356D 6D51C245 E485B576 625E7EC6 F44C42E9
            A637ED6B 0BFF5CB6 F406B7ED EE386BFB 5A899FA5 AE9F2411 7C4B1FE6
            49286651 ECE45B3D C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8
            FD24CF5F 83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
            670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B E39E772C
            180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9 DE2BCBF6 95581718
            3995497C EA956AE5 15D22618 98FA0510 15728E5A 8AAAC42D AD33170D
            04507A33 A85521AB DF1CBA64 ECFB8504 58DBEF0A 8AEA7157 5D060C7D
            B3970F85 A6E1E4C7 ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226
            1AD2EE6B F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
            BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31 43DB5BFC
            E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF
            """), generator: BigUInt(5), hash: { Data(SHA512.hash(data: $0)) })
    }

    let group: Group
    let username: Data
    let salt: Data
    let verifier: BigUInt
    let serverPublic: BigUInt
    private let privateValue: BigUInt
    private let field: MontgomeryModulus
    private let length: Int

    init(group: Group = .rfc5054_3072, username: String, password: String,
         salt: Data = Crypto.randomBytes(16), privateValue: Data = Crypto.randomBytes(32)) {
        self.group = group
        self.username = Data(username.utf8)
        self.salt = salt
        field = MontgomeryModulus(group.modulus)
        length = group.modulus.bytes().count
        let h = group.hash
        let x = BigUInt(bytes: h(salt + h(Data("\(username):\(password)".utf8))))
        verifier = field.power(group.generator, x)
        self.privateValue = BigUInt(bytes: privateValue)
        let k = BigUInt(bytes: h(group.modulus.bytes() + group.generator.bytes(paddedTo: length)))
        let sum = field.multiply(k, verifier) + field.power(group.generator, self.privateValue)
        serverPublic = sum >= group.modulus ? sum - group.modulus : sum
    }

    var serverPublicBytes: Data { serverPublic.bytes(paddedTo: length) }

    /// The shared secret S for the controller's public value A, or nil if A is unusable.
    func premasterSecret(clientPublic: Data) -> BigUInt? {
        let a = BigUInt(bytes: clientPublic)
        guard a < group.modulus, !a.isZero, a != group.modulus - .one else { return nil }
        let h = group.hash
        let u = BigUInt(bytes: h(a.bytes(paddedTo: length) + serverPublicBytes))
        guard !u.isZero else { return nil }
        return field.power(field.multiply(a, field.power(verifier, u)), privateValue)
    }

    /// Checks the controller's proof M1. Implementations disagree on whether S is
    /// hashed at full length or with leading zeros dropped, so both are tried; the
    /// one that matches is the session key. Returns (K, M2) on success.
    func verify(clientPublic: Data, clientProof: Data) -> (sessionKey: Data, serverProof: Data)? {
        guard let secret = premasterSecret(clientPublic: clientPublic) else { return nil }
        let h = group.hash
        let groupHash = Data(zip(h(group.modulus.bytes()), h(group.generator.bytes())).map { $0 ^ $1 })
        let a = BigUInt(bytes: clientPublic)
        var candidates: [Data] = []
        for key in [h(secret.bytes(paddedTo: length)), h(secret.bytes())] where !candidates.contains(key) {
            candidates.append(key)
        }
        for key in candidates {
            for aBytes in [clientPublic, a.bytes(paddedTo: length)] {
                let m1 = h(groupHash + h(username) + salt + aBytes + serverPublicBytes + key)
                if constantTimeEqual(m1, clientProof) {
                    return (key, h(aBytes + m1 + key))
                }
            }
        }
        return nil
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension BigUInt {
    /// Hexadecimal with any whitespace ignored.
    init(hex: String) {
        let digits = Array(hex.filter { !$0.isWhitespace })
        var bytes = Data()
        var index = digits.count % 2 == 1 ? -1 : 0
        while index < digits.count {
            let high = index < 0 ? "0" : String(digits[index])
            bytes.append(UInt8(high + String(digits[index + 1]), radix: 16)!)
            index += 2
        }
        self.init(bytes: bytes)
    }
}

import Foundation

/// The server's SRP challenge: group, salt, public value and password-stretching cost.
struct SRPChallenge {
    var modulus: Data        // N, big-endian, minimal length
    var generator: Data      // g, big-endian
    var salt: Data
    var serverPublic: Data   // B
    var iterations: UInt64
    var options: Data        // echoed back verbatim

    /// Parses `control(u8) N(u16-prefixed) g(u16) salt(u8) B(u16) iterations(u64) options(u16)`.
    init(body: Data) throws {
        var reader = ByteReader(body)
        _ = try reader.u8()
        modulus = SRPChallenge.stripLeadingZeros(try reader.bytes(Int(try reader.u16())))
        generator = SRPChallenge.stripLeadingZeros(try reader.bytes(Int(try reader.u16())))
        salt = try reader.bytes(Int(try reader.u8()))
        serverPublic = try reader.bytes(Int(try reader.u16()))
        iterations = try reader.u64()
        options = try reader.bytes(Int(try reader.u16()))
    }

    init(modulus: Data, generator: Data, salt: Data, serverPublic: Data, iterations: UInt64, options: Data) {
        self.modulus = modulus
        self.generator = generator
        self.salt = salt
        self.serverPublic = serverPublic
        self.iterations = iterations
        self.options = options
    }

    private static func stripLeadingZeros(_ data: Data) -> Data {
        let start = data.firstIndex(where: { $0 != 0 }) ?? data.endIndex
        return data.subdata(in: start..<data.endIndex)
    }
}

/// Client side of SRP-6a with SHA-512 and a PBKDF2-stretched password, as used by
/// macOS Screen Sharing. The identity hashed into the proof is empty; the user
/// name travels separately in the RSA-wrapped envelope.
struct SRPClient {
    struct Proof {
        var clientPublic: Data   // A, padded to the modulus length
        var clientProof: Data    // M1
        var sessionKey: Data     // K = H(S)
        var expectedServerProof: Data // M2
    }

    /// Upper bound on the stretching cost a server may demand, so a hostile
    /// server cannot stall the client indefinitely.
    static let maximumIterations: UInt64 = 2_000_000

    static func respond(to challenge: SRPChallenge, password: String, privateValue: Data? = nil) throws -> Proof {
        guard challenge.modulus.count >= 256, (challenge.modulus.last ?? 0) & 1 == 1 else {
            throw ScreenShareError.authenticationFailed("server offered an unusable SRP group")
        }
        guard challenge.iterations >= 1, challenge.iterations <= maximumIterations else {
            throw ScreenShareError.authenticationFailed("unreasonable PBKDF2 iteration count \(challenge.iterations)")
        }

        let length = challenge.modulus.count
        let n = BigUInt(bytes: challenge.modulus)
        let g = BigUInt(bytes: challenge.generator)
        let b = BigUInt(bytes: challenge.serverPublic)
        guard !b.isZero, b < n else {
            throw ScreenShareError.authenticationFailed("server sent an invalid SRP public value")
        }
        let field = MontgomeryModulus(n)

        let nBytes = n.bytes(paddedTo: length)
        let gPadded = g.bytes(paddedTo: length)
        let bPadded = b.bytes(paddedTo: length)

        let a = BigUInt(bytes: privateValue ?? Crypto.randomBytes(64))
        let aPublic = field.power(g, a)
        let aPadded = aPublic.bytes(paddedTo: length)

        let k = BigUInt(bytes: Crypto.sha512(nBytes + gPadded))
        let u = BigUInt(bytes: Crypto.sha512(aPadded + bPadded))

        let stretched = try Crypto.pbkdf2SHA512(
            password: Data(password.utf8), salt: challenge.salt,
            iterations: Int(challenge.iterations), length: 128)
        let inner = Crypto.sha512(Data(":".utf8) + stretched)
        let x = BigUInt(bytes: Crypto.sha512(challenge.salt + inner))

        // S = (B - k * g^x) ^ (a + u * x) mod N
        let kgx = field.multiply(k, field.power(g, x))
        let base = field.subtract(b, kgx)
        let secret = field.power(base, a + u * x)
        let sessionKey = Crypto.sha512(secret.bytes(paddedTo: length))

        let hN = Crypto.sha512(nBytes)
        let hG = Crypto.sha512(gPadded)
        let groupHash = Data(zip(hN, hG).map { $0 ^ $1 })
        let m1 = Crypto.sha512(groupHash + Crypto.sha512(Data()) + challenge.salt + aPadded + bPadded + sessionKey)
        let m2 = Crypto.sha512(aPadded + m1 + sessionKey)

        return Proof(clientPublic: aPadded, clientProof: m1, sessionKey: sessionKey, expectedServerProof: m2)
    }
}

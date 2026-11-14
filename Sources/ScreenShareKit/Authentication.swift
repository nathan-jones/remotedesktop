import Foundation

/// The RFB version/security preamble plus Apple's RSA-wrapped SRP login
/// (security type 33). Returns the 16-byte key that unwraps the first rekey.
enum Authentication {
    static let protocolVersion = Data("RFB 003.889\n".utf8)
    private static let securityTypeRSASRP: UInt8 = 33
    private static let envelopeMagic = Data("RSA1".utf8)

    /// Thrown when the host answers the SRP identity with something other than
    /// a challenge. It has then already switched to the password login, so the
    /// caller must reconnect and use `.password`.
    struct SRPUnavailable: Error {}

    enum Method {
        /// SRP: the password never leaves this device.
        case srp
        /// The older login: user name and password sent under a one-time AES
        /// key that is RSA-encrypted to the host. For accounts with no SRP verifier.
        case password
    }

    static func run(on stream: TCPStream, username: String, password: String, method: Method = .srp) throws -> Data {
        let banner = try stream.read(12)
        guard banner.starts(with: Data("RFB ".utf8)) else {
            throw ScreenShareError.protocolViolation("host is not speaking RFB")
        }
        try stream.write(protocolVersion)

        let count = Int(try stream.read(1)[0])
        guard count > 0 else {
            throw ScreenShareError.authenticationFailed("host refused the connection (it may be rate-limiting; wait a few seconds)")
        }
        let types = [UInt8](try stream.read(count))
        guard types.contains(securityTypeRSASRP) else {
            throw ScreenShareError.unsupported("host does not offer SRP login (types \(types))")
        }

        let publicKey = try requestPublicKey(stream)
        switch method {
        case .srp:
            try sendIdentity(stream, username: username, publicKey: publicKey)
            let challenge = try readChallenge(stream)
            ScreenShareLog.log("SRP challenge: \(challenge.modulus.count * 8)-bit group, \(challenge.iterations) iterations")
            let proof = try SRPClient.respond(to: challenge, password: password)
            try sendProof(stream, proof: proof, options: challenge.options)
            try readResult(stream, proof: proof)
            return Crypto.sha256(proof.sessionKey).prefix(16)
        case .password:
            let key = Crypto.randomBytes(16)
            try sendCredentials(stream, username: username, password: password, key: key, publicKey: publicKey)
            _ = try stream.read(4)
            let result = try stream.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard result == 0 else {
                throw ScreenShareError.authenticationFailed("wrong user name or password")
            }
            return key
        }
    }

    /// Envelope kind 1: two 64-byte credential slots under AES-128-ECB, then
    /// the AES key encrypted to the host's RSA key.
    private static func sendCredentials(_ stream: TCPStream, username: String, password: String, key: Data, publicKey: Data) throws {
        func slot(_ text: String) -> Data {
            // NUL-terminated, with the unused tail randomised so equal
            // credentials do not produce equal ciphertext.
            var field = Data(text.utf8.prefix(63))
            field.append(0)
            field.append(Crypto.randomBytes(64 - field.count))
            return field
        }
        let credentials = try Crypto.aesECB(slot(username) + slot(password), key: key, encrypt: true)
        let wrappedKey = try Crypto.rsaEncryptPKCS1(key, publicKeyDER: publicKey)

        var body = ByteWriter()
        body.bytes([0x01, 0x00])
        body.bytes(envelopeMagic)
        body.u16(1)
        body.bytes(credentials)
        body.u16(1)
        body.bytes(wrappedKey)

        var message = ByteWriter()
        message.u32(UInt32(body.data.count))
        message.bytes(body.data)
        try stream.write(message.data)
    }

    /// Selects security type 33 with an empty envelope, which makes the host
    /// return its RSA public key.
    private static func requestPublicKey(_ stream: TCPStream) throws -> Data {
        var request = ByteWriter()
        request.u8(securityTypeRSASRP)
        request.u32(10)                 // bytes that follow
        request.bytes([0x01, 0x00])     // envelope version
        request.bytes(envelopeMagic)
        request.u16(0)                  // envelope kind 0: key request
        request.u16(0)
        try stream.write(request.data)

        let length = Int(try stream.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length > 6, length < 8192 else {
            throw ScreenShareError.protocolViolation("unexpected RSA key response length \(length)")
        }
        var reader = ByteReader(try stream.read(length))
        try reader.skip(2)
        let keyLength = Int(try reader.u32())
        return try reader.bytes(keyLength)
    }

    /// Envelope kind 2 carrying the user name, RSA-encrypted to the host key.
    private static func sendIdentity(_ stream: TCPStream, username: String, publicKey: Data) throws {
        let name = Data(username.utf8)
        var identity = ByteWriter()
        identity.u32(UInt32(name.count + 7))
        identity.u32(UInt32(name.count))
        identity.bytes(name)
        identity.zeros(3)

        let encrypted = try Crypto.rsaEncryptPKCS1(identity.data, publicKeyDER: publicKey)
        guard encrypted.count == 256 else {
            throw ScreenShareError.unsupported("host RSA key is \(encrypted.count * 8) bits, expected 2048")
        }

        var body = ByteWriter()
        body.bytes([0x01, 0x00])
        body.bytes(envelopeMagic)
        body.u16(2)
        body.u16(UInt16(encrypted.count))
        body.bytes(encrypted)
        body.zeros(384)

        var message = ByteWriter()
        message.u32(UInt32(body.data.count))
        message.bytes(body.data)
        try stream.write(message.data)
    }

    private static func readChallenge(_ stream: TCPStream) throws -> SRPChallenge {
        let length = Int(try stream.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length >= 600, length < 16384 else {
            let body = (try? stream.read(min(length, 64))) ?? Data()
            ScreenShareLog.log("host did not start SRP; answered \(length) bytes: \(body.map { String(format: "%02x", $0) }.joined())")
            throw SRPUnavailable()
        }
        var reader = ByteReader(try stream.read(length))
        try reader.skip(10)  // step(u32), remaining length(u16), payload length(u32)
        return try SRPChallenge(body: reader.rest())
    }

    private static func sendProof(_ stream: TCPStream, proof: SRPClient.Proof, options: Data) throws {
        let clientRandom = Crypto.randomBytes(16)
        var inner = ByteWriter()
        inner.u16(UInt16(proof.clientPublic.count))
        inner.bytes(proof.clientPublic)
        inner.u8(UInt8(proof.clientProof.count))
        inner.bytes(proof.clientProof)
        inner.u16(UInt16(options.count))
        inner.bytes(options)
        inner.u8(UInt8(clientRandom.count))
        inner.bytes(clientRandom)

        var body = ByteWriter()
        body.bytes([0x01, 0x00])
        body.bytes(envelopeMagic)
        body.u16(2)
        body.u16(UInt16(inner.data.count + 4))
        body.u32(UInt32(inner.data.count))
        body.bytes(inner.data)
        let fixedLength = 1076
        if body.data.count < fixedLength { body.zeros(fixedLength - body.data.count) }

        var message = ByteWriter()
        message.u32(UInt32(body.data.count))
        message.bytes(body.data)
        try stream.write(message.data)
    }

    private static func readResult(_ stream: TCPStream, proof: SRPClient.Proof) throws {
        let length = Int(try stream.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length < 4096 else {
            throw ScreenShareError.protocolViolation("oversized SRP result (\(length) bytes)")
        }
        let body = try stream.read(length)
        let result = try stream.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard result == 0 else {
            throw ScreenShareError.authenticationFailed("wrong user name or password")
        }
        // The server proof shows the host knew the password verifier. A mismatch
        // is logged rather than fatal because its exact framing is unconfirmed.
        if body.range(of: proof.expectedServerProof) == nil {
            ScreenShareLog.log("warning: could not verify the host's SRP proof")
        }
    }
}

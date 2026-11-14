import CommonCrypto
import CryptoKit
import Foundation
import Security

enum Crypto {
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "system random generator failed")
        return Data(bytes)
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func sha512(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }

    static func hmacSHA1(key: Data, _ data: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var derived = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    UInt32(iterations),
                    &derived, length)
            }
        }
        guard status == kCCSuccess else { throw ScreenShareError.crypto("PBKDF2 failed (\(status))") }
        return Data(derived)
    }

    /// AES in ECB mode over whole blocks, no padding.
    static func aesECB(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        precondition(data.count % kCCBlockSizeAES128 == 0)
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, key.count, nil,
                        input.baseAddress, data.count,
                        &out, out.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else {
            throw ScreenShareError.crypto("AES-ECB failed (\(status))")
        }
        return Data(out)
    }

    /// AES in counter mode with a 16-byte big-endian counter block (encrypt == decrypt).
    static func aesCTR(_ data: Data, key: Data, counterBlock: Data) throws -> Data {
        precondition(counterBlock.count == kCCBlockSizeAES128)
        if data.isEmpty { return data }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            counterBlock.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), iv.baseAddress, keyBytes.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else {
            throw ScreenShareError.crypto("AES-CTR setup failed (\(created))")
        }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess, moved == data.count else {
            throw ScreenShareError.crypto("AES-CTR failed (\(status))")
        }
        return Data(out)
    }

    /// RSA PKCS#1 v1.5 encryption to a DER SubjectPublicKeyInfo (or bare PKCS#1) public key.
    static func rsaEncryptPKCS1(_ plaintext: Data, publicKeyDER: Data) throws -> Data {
        let pkcs1 = stripSubjectPublicKeyInfo(publicKeyDER) ?? publicKeyDER
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw ScreenShareError.crypto("server RSA key rejected: \(describe(error))")
        }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &error) else {
            throw ScreenShareError.crypto("RSA encryption failed: \(describe(error))")
        }
        return encrypted as Data
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown error" }
        return String(describing: error.takeRetainedValue())
    }

    /// Unwraps SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } } to the inner key.
    static func stripSubjectPublicKeyInfo(_ der: Data) -> Data? {
        var reader = DERReader(Data(der))
        guard let outer = reader.read(tag: 0x30) else { return nil }
        var inner = DERReader(outer)
        guard inner.read(tag: 0x30) != nil, let bitString = inner.read(tag: 0x03),
              let unusedBits = bitString.first, unusedBits == 0 else { return nil }
        return bitString.dropFirst().withUnsafeBytes { Data($0) }
    }
}

/// Just enough DER to walk definite-length TLVs.
private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    mutating func read(tag expected: UInt8) -> Data? {
        guard offset + 2 <= data.count, data[offset] == expected else { return nil }
        var length = Int(data[offset + 1])
        var cursor = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count >= 1, count <= 4, cursor + count <= data.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[cursor])
                cursor += 1
            }
        }
        guard cursor + length <= data.count else { return nil }
        offset = cursor + length
        return data.subdata(in: cursor..<cursor + length)
    }
}

/// A CBC cipher whose chaining state persists across calls, one instance per direction.
final class AESCBCStream {
    private var cryptor: CCCryptorRef?

    init(key: Data, iv: Data, encrypt: Bool) throws {
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, &cryptor)
            }
        }
        guard status == kCCSuccess, cryptor != nil else {
            throw ScreenShareError.crypto("AES-CBC setup failed (\(status))")
        }
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func process(_ data: Data) throws -> Data {
        precondition(data.count % kCCBlockSizeAES128 == 0)
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess, moved == data.count else {
            throw ScreenShareError.crypto("AES-CBC failed (\(status))")
        }
        return Data(out)
    }
}

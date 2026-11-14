import Foundation

/// The encrypted control channel that takes over once the host sends its rekey.
///
/// Wire form per record: `u16 length || AES-128-CBC ciphertext`. The plaintext is
/// `u16 bodyLength || body || filler || SHA-1(u32 sequence || everything before)`.
/// Each direction is one continuous CBC stream with its own sequence counter.
final class RecordLayer {
    static let rekeyBodyLength = 36
    private static let tagLength = 20
    private static let blockLength = 16

    /// The key records are encrypted under; also used for per-event input wrapping.
    let contentKey: Data

    private let encryptor: AESCBCStream
    private let decryptor: AESCBCStream
    private var sendSequence: UInt32 = 0
    private var receiveSequence: UInt32 = 0
    private let sendLock = NSLock()

    /// - Parameters:
    ///   - rekeyBody: `u32 generation || wrapped key (16) || wrapped IV (16)`.
    ///   - wrapKey: key derived from authentication, used to unwrap both halves.
    init(rekeyBody: Data, wrapKey: Data) throws {
        guard rekeyBody.count == RecordLayer.rekeyBodyLength else {
            throw ScreenShareError.protocolViolation("rekey body is \(rekeyBody.count) bytes")
        }
        let body = Data(rekeyBody)
        contentKey = try Crypto.aesECB(body.subdata(in: 4..<20), key: wrapKey, encrypt: false)
        let iv = try Crypto.aesECB(body.subdata(in: 20..<36), key: wrapKey, encrypt: false)
        encryptor = try AESCBCStream(key: contentKey, iv: iv, encrypt: true)
        decryptor = try AESCBCStream(key: contentKey, iv: iv, encrypt: false)
    }

    /// Test hook: build directly from a content key and IV.
    init(contentKey: Data, iv: Data) throws {
        self.contentKey = contentKey
        encryptor = try AESCBCStream(key: contentKey, iv: iv, encrypt: true)
        decryptor = try AESCBCStream(key: contentKey, iv: iv, encrypt: false)
    }

    /// Encrypts one message and hands the framed record to `transmit` while still
    /// holding the lock, so sequence order always matches wire order.
    func send(_ body: Data, transmit: (Data) throws -> Void) throws {
        precondition(body.count <= 0xFFFF - 64, "control message too large for one record")
        sendLock.lock()
        defer { sendLock.unlock() }

        var plaintext = ByteWriter()
        plaintext.u16(UInt16(body.count))
        plaintext.bytes(body)
        let unpadded = 2 + body.count + RecordLayer.tagLength
        plaintext.zeros((RecordLayer.blockLength - unpadded % RecordLayer.blockLength) % RecordLayer.blockLength)

        var tagInput = ByteWriter()
        tagInput.u32(sendSequence)
        tagInput.bytes(plaintext.data)
        plaintext.bytes(Crypto.sha1(tagInput.data))

        let ciphertext = try encryptor.process(plaintext.data)
        sendSequence &+= 1

        var record = ByteWriter()
        record.u16(UInt16(ciphertext.count))
        record.bytes(ciphertext)
        try transmit(record.data)
    }

    /// Decrypts one record's ciphertext (without the length prefix) and returns its body.
    func open(_ ciphertext: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext.count % RecordLayer.blockLength == 0,
              ciphertext.count >= 32 else {
            throw ScreenShareError.protocolViolation("bad record length \(ciphertext.count)")
        }
        let plaintext = try decryptor.process(ciphertext)
        let covered = plaintext.prefix(plaintext.count - RecordLayer.tagLength)
        let tag = plaintext.suffix(RecordLayer.tagLength)

        var tagInput = ByteWriter()
        tagInput.u32(receiveSequence)
        tagInput.bytes(Data(covered))
        guard Crypto.sha1(tagInput.data) == Data(tag) else {
            throw ScreenShareError.protocolViolation("control channel integrity check failed")
        }
        receiveSequence &+= 1

        var reader = ByteReader(Data(covered))
        let length = Int(try reader.u16())
        return try reader.bytes(length)
    }
}

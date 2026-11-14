import Foundation

/// SRTP/SRTCP with AES-256 counter mode and HMAC-SHA1-80 (RFC 3711 / RFC 6188).
struct SRTPKeys {
    static let tagLength = 10

    let cipherKey: Data
    let authKey: Data
    let salt: Data

    /// - Parameter blob: 32-byte master key followed by 14-byte master salt.
    /// - Parameter control: derive the SRTCP keys instead of the SRTP keys.
    init(blob: Data, control: Bool) throws {
        precondition(blob.count == MediaKeys.blobLength)
        let blob = Data(blob)
        let masterKey = blob.prefix(32)
        let masterSalt = blob.suffix(14)
        let base: UInt8 = control ? 3 : 0
        cipherKey = try SRTPKeys.derive(masterKey, masterSalt, label: base, length: 32)
        authKey = try SRTPKeys.derive(masterKey, masterSalt, label: base + 1, length: 20)
        salt = try SRTPKeys.derive(masterKey, masterSalt, label: base + 2, length: 14)
    }

    /// RFC 3711 section 4.3.1 key derivation with a zero key-derivation rate.
    static func derive(_ masterKey: Data, _ masterSalt: Data, label: UInt8, length: Int) throws -> Data {
        var block = [UInt8](masterSalt) + [0, 0]
        block[7] ^= label
        return try Crypto.aesCTR(Data(count: length), key: masterKey, counterBlock: Data(block))
    }

    /// Counter block for a packet: salt XOR (SSRC << 64) XOR (index << 16).
    func counterBlock(ssrc: UInt32, index: UInt64) -> Data {
        var block = [UInt8](salt) + [0, 0]
        for i in 0..<4 { block[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(8 * (3 - i))) }
        for i in 0..<6 { block[8 + i] ^= UInt8(truncatingIfNeeded: index >> UInt64(8 * (5 - i))) }
        return Data(block)
    }
}

struct RTPPacket {
    var payloadType: UInt8
    var marker: Bool
    /// Sequence number extended with the rollover counter, so it never wraps.
    var extendedSequence: UInt64
    var timestamp: UInt32
    var ssrc: UInt32
    var payload: Data
}

/// Verifies and decrypts incoming SRTP, tracking the rollover counter per source.
final class SRTPReceiver {
    private let keys: SRTPKeys
    private var highest: [UInt32: UInt64] = [:]   // per-SSRC highest extended sequence

    init(blob: Data) throws {
        keys = try SRTPKeys(blob: blob, control: false)
    }

    func unprotect(_ packet: Data) -> RTPPacket? {
        let packet = Data(packet)
        guard packet.count >= 12 + SRTPKeys.tagLength, packet[0] >> 6 == 2 else { return nil }
        let bodyLength = packet.count - SRTPKeys.tagLength
        let sequence = UInt16(packet[2]) << 8 | UInt16(packet[3])
        let timestamp = packet[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let ssrc = packet[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        var headerLength = 12 + Int(packet[0] & 0x0F) * 4
        if packet[0] & 0x10 != 0 {
            guard headerLength + 4 <= bodyLength else { return nil }
            let words = Int(packet[headerLength + 2]) << 8 | Int(packet[headerLength + 3])
            headerLength += 4 + words * 4
        }
        guard headerLength <= bodyLength else { return nil }

        let body = packet.prefix(bodyLength)
        let tag = packet.suffix(SRTPKeys.tagLength)
        for rollover in rolloverCandidates(ssrc: ssrc, sequence: sequence) {
            var authenticated = Data(body)
            withUnsafeBytes(of: rollover.bigEndian) { authenticated.append(contentsOf: $0) }
            guard Crypto.hmacSHA1(key: keys.authKey, authenticated).prefix(SRTPKeys.tagLength) == Data(tag) else {
                continue
            }
            let index = UInt64(rollover) << 16 | UInt64(sequence)
            guard let payload = try? Crypto.aesCTR(
                packet.subdata(in: headerLength..<bodyLength), key: keys.cipherKey,
                counterBlock: keys.counterBlock(ssrc: ssrc, index: index)) else { return nil }
            highest[ssrc] = max(highest[ssrc] ?? 0, index)
            return RTPPacket(payloadType: packet[1] & 0x7F, marker: packet[1] & 0x80 != 0,
                             extendedSequence: index, timestamp: timestamp, ssrc: ssrc, payload: payload)
        }
        return nil
    }

    /// Most likely rollover counter first, then its neighbours.
    private func rolloverCandidates(ssrc: UInt32, sequence: UInt16) -> [UInt32] {
        guard let top = highest[ssrc] else { return [0] }
        let rollover = UInt32(truncatingIfNeeded: top >> 16)
        let difference = Int(sequence) - Int(top & 0xFFFF)
        var guess = rollover
        if difference > 0x7FFF { guess = rollover > 0 ? rollover - 1 : 0 }
        if difference < -0x7FFF { guess = rollover &+ 1 }
        var candidates = [guess]
        for other in [rollover, guess &+ 1, guess > 0 ? guess - 1 : 0] where !candidates.contains(other) {
            candidates.append(other)
        }
        return candidates
    }

    /// Highest extended sequence number seen for a source, for receiver reports.
    func highestSequence(for ssrc: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: highest[ssrc] ?? 0)
    }
}

/// Encrypts the small outgoing RTP keepalive.
final class SRTPSender {
    private let keys: SRTPKeys
    private let ssrc: UInt32
    private var index: UInt64 = 0
    private var timestamp: UInt32 = 0

    init(blob: Data, ssrc: UInt32) throws {
        keys = try SRTPKeys(blob: blob, control: false)
        self.ssrc = ssrc
    }

    func protect(payload: Data, payloadType: UInt8) throws -> Data {
        var w = ByteWriter()
        w.u8(0x80)
        w.u8(payloadType & 0x7F)
        w.u16(UInt16(truncatingIfNeeded: index))
        w.u32(timestamp)
        w.u32(ssrc)
        w.bytes(try Crypto.aesCTR(payload, key: keys.cipherKey, counterBlock: keys.counterBlock(ssrc: ssrc, index: index)))

        var authenticated = w.data
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: index >> 16).bigEndian) { authenticated.append(contentsOf: $0) }
        w.bytes(Crypto.hmacSHA1(key: keys.authKey, authenticated).prefix(SRTPKeys.tagLength))

        index += 1
        timestamp &+= 480
        return w.data
    }
}

/// Encrypts outgoing RTCP feedback.
final class SRTCPSender {
    private let keys: SRTPKeys
    private var index: UInt32 = 0
    private let lock = NSLock()

    init(blob: Data) throws {
        keys = try SRTPKeys(blob: blob, control: true)
    }

    /// `packet` is a (possibly compound) RTCP packet; the first 8 bytes stay in the clear.
    func protect(_ packet: Data) throws -> Data {
        let packet = Data(packet)
        precondition(packet.count >= 8)
        lock.lock()
        let current = index
        index = (index + 1) & 0x7FFF_FFFF
        lock.unlock()

        let ssrc = packet[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var w = ByteWriter()
        w.bytes(packet.prefix(8))
        w.bytes(try Crypto.aesCTR(packet.subdata(in: 8..<packet.count), key: keys.cipherKey,
                                  counterBlock: keys.counterBlock(ssrc: ssrc, index: UInt64(current))))
        w.u32(0x8000_0000 | current)   // encrypted flag plus SRTCP index
        w.bytes(Crypto.hmacSHA1(key: keys.authKey, w.data).prefix(SRTPKeys.tagLength))
        return w.data
    }
}

/// Builders for the RTCP packets a receive-only viewer needs.
enum RTCP {
    static func receiverReport(sender: UInt32, sources: [(ssrc: UInt32, highestSequence: UInt32)]) -> Data {
        let blocks = sources.prefix(31)
        var w = ByteWriter()
        w.u8(0x80 | UInt8(blocks.count))
        w.u8(201)
        w.u16(UInt16(1 + blocks.count * 6))
        w.u32(sender)
        for block in blocks {
            w.u32(block.ssrc)
            w.u32(0)                     // fraction lost, cumulative lost
            w.u32(block.highestSequence)
            w.u32(0)                     // jitter
            w.u32(0)                     // last sender report
            w.u32(0)                     // delay since last sender report
        }
        return w.data
    }

    /// Sender report with no report blocks, so the host counts us as a live peer.
    static func emptySenderReport(sender: UInt32, now: Date = Date()) -> Data {
        let seconds = now.timeIntervalSince1970
        var w = ByteWriter()
        w.u8(0x80)
        w.u8(200)
        w.u16(6)
        w.u32(sender)
        w.u32(UInt32(truncatingIfNeeded: UInt64(seconds) + 2_208_988_800))
        w.u32(UInt32(truncatingIfNeeded: UInt64((seconds - floor(seconds)) * 4_294_967_296)))
        w.u32(UInt32(truncatingIfNeeded: UInt64(seconds * 90_000)))
        w.u32(0)
        w.u32(0)
        return w.data
    }

    /// Asks for a fresh keyframe three ways (AVPF full-intra request, picture-loss
    /// indication, and the legacy full-intra request); the host honours at least one.
    static func keyframeRequest(sender: UInt32, media: UInt32, counter: UInt8) -> Data {
        var w = ByteWriter()
        w.u8(0x80 | 4); w.u8(206); w.u16(4)
        w.u32(sender); w.u32(0)
        w.u32(media); w.u8(counter); w.zeros(3)

        w.u8(0x80 | 1); w.u8(206); w.u16(2)
        w.u32(sender); w.u32(media)

        w.u8(0x80); w.u8(192); w.u16(1)
        w.u32(media)
        return w.data
    }
}

import XCTest
@testable import ScreenShareKit

final class BigUIntTests: XCTestCase {
    func testByteRoundTripAndPadding() {
        let value = BigUInt(bytes: Data(hex: "0001ff00aa")!)
        XCTAssertEqual(value.bytes().hex, "01ff00aa")
        XCTAssertEqual(value.bytes(paddedTo: 6).hex, "000001ff00aa")
        XCTAssertTrue(BigUInt(bytes: Data([0, 0])).isZero)
    }

    func testMultiplicationMatchesReference() {
        let a = BigUInt(bytes: Data(hex: Fixtures.powBase)!)
        let b = BigUInt(bytes: Data(hex: Fixtures.powExponent)!)
        XCTAssertEqual((a * b).bytes(paddedTo: 625).hex, Fixtures.product)
    }

    func testModularExponentiationMatchesReference() {
        let field = MontgomeryModulus(BigUInt(bytes: Data(hex: Fixtures.modulus)!))
        let result = field.power(BigUInt(bytes: Data(hex: Fixtures.powBase)!),
                                 BigUInt(bytes: Data(hex: Fixtures.powExponent)!))
        XCTAssertEqual(result.bytes(paddedTo: 512).hex, Fixtures.powResult)
    }

    func testSmallModularArithmetic() {
        let field = MontgomeryModulus(BigUInt(97))
        XCTAssertEqual(field.power(BigUInt(5), BigUInt(20)), BigUInt(93))   // 5^20 mod 97
        XCTAssertEqual(field.multiply(BigUInt(50), BigUInt(60)), BigUInt(90))
        XCTAssertEqual(field.subtract(BigUInt(3), BigUInt(10)), BigUInt(90))
    }
}

final class SRPTests: XCTestCase {
    func testProofMatchesIndependentImplementation() throws {
        let challenge = SRPChallenge(
            modulus: Data(hex: Fixtures.modulus)!, generator: Data([5]),
            salt: Data(hex: Fixtures.salt)!, serverPublic: Data(hex: Fixtures.serverPublic)!,
            iterations: Fixtures.iterations, options: Data())
        let proof = try SRPClient.respond(
            to: challenge, password: Fixtures.password, privateValue: Data(hex: Fixtures.privateValue)!)
        XCTAssertEqual(proof.clientPublic.hex, Fixtures.clientPublic)
        XCTAssertEqual(proof.sessionKey.hex, Fixtures.sessionKey)
        XCTAssertEqual(proof.clientProof.hex, Fixtures.clientProof)
        XCTAssertEqual(proof.expectedServerProof.hex, Fixtures.serverProof)
    }

    func testChallengeParsing() throws {
        var w = ByteWriter()
        w.u8(0)
        w.u16(3); w.bytes([0x00, 0xAB, 0xCD])   // modulus with a leading zero
        w.u16(1); w.u8(5)
        w.u8(2); w.bytes([1, 2])
        w.u16(2); w.bytes([9, 8])
        w.u64(12345)
        w.u16(3); w.bytes(Data("abc".utf8))
        let challenge = try SRPChallenge(body: w.data)
        XCTAssertEqual(challenge.modulus.hex, "abcd")
        XCTAssertEqual(challenge.generator.hex, "05")
        XCTAssertEqual(challenge.salt.hex, "0102")
        XCTAssertEqual(challenge.serverPublic.hex, "0908")
        XCTAssertEqual(challenge.iterations, 12345)
        XCTAssertEqual(String(decoding: challenge.options, as: UTF8.self), "abc")
    }

    func testRejectsAbsurdIterationCount() {
        let challenge = SRPChallenge(
            modulus: Data(hex: Fixtures.modulus)!, generator: Data([5]), salt: Data([1]),
            serverPublic: Data([2]), iterations: 50_000_000, options: Data())
        XCTAssertThrowsError(try SRPClient.respond(to: challenge, password: "x"))
    }
}

final class RecordLayerTests: XCTestCase {
    private func pair() throws -> (RecordLayer, RecordLayer) {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data((16..<32).map { UInt8($0) })
        return (try RecordLayer(contentKey: key, iv: iv), try RecordLayer(contentKey: key, iv: iv))
    }

    func testRoundTripAcrossSeveralRecords() throws {
        let (sender, receiver) = try pair()
        for length in [0, 1, 9, 10, 11, 26, 300, 4000] {
            let body = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            var wire = Data()
            try sender.send(body) { wire = $0 }
            XCTAssertEqual(wire.count % 16, 2)
            XCTAssertEqual(Int(wire[0]) << 8 | Int(wire[1]), wire.count - 2)
            XCTAssertEqual(try receiver.open(wire.dropFirst(2)), body)
        }
    }

    func testTamperingAndReplayAreRejected() throws {
        let (sender, receiver) = try pair()
        var first = Data(), second = Data()
        try sender.send(Data("one".utf8)) { first = $0 }
        try sender.send(Data("two".utf8)) { second = $0 }
        XCTAssertEqual(try receiver.open(first.dropFirst(2)), Data("one".utf8))
        // Replaying the first record must fail: both the chaining and sequence differ.
        XCTAssertThrowsError(try receiver.open(first.dropFirst(2)))

        let (sender2, receiver2) = try pair()
        var record = Data()
        try sender2.send(Data("hello".utf8)) { record = $0 }
        record[10] ^= 0x01
        XCTAssertThrowsError(try receiver2.open(record.dropFirst(2)))
        _ = second
    }

    func testRekeyUnwrap() throws {
        let wrapKey = Data(hex: "000102030405060708090a0b0c0d0e0f")!
        let contentKey = Data(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")!
        let iv = Data(hex: "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf")!
        let body = Data([0, 0, 0, 1])
            + (try Crypto.aesECB(contentKey, key: wrapKey, encrypt: true))
            + (try Crypto.aesECB(iv, key: wrapKey, encrypt: true))
        let viaRekey = try RecordLayer(rekeyBody: body, wrapKey: wrapKey)
        XCTAssertEqual(viaRekey.contentKey, contentKey)
        let direct = try RecordLayer(contentKey: contentKey, iv: iv)
        var wire = Data()
        try direct.send(Data("ping".utf8)) { wire = $0 }
        XCTAssertEqual(try viaRekey.open(wire.dropFirst(2)), Data("ping".utf8))
    }
}

final class SRTPTests: XCTestCase {
    /// AES-256 counter-mode key derivation vectors from RFC 6188 section 7.4.
    func testKeyDerivationMatchesRFC6188() throws {
        let key = Data(hex: "f0f04914b513f2763a1b1fa130f10e2998f6f6e43e4309d1e622a0e332b9f1b6")!
        let salt = Data(hex: "3b04803de51ee7c96423ab5b78d2")!
        XCTAssertEqual(try SRTPKeys.derive(key, salt, label: 0, length: 32).hex,
                       "5ba1064e30ec51613cad926c5a28ef731ec7fb397f70a960653caf06554cd8c4")
        XCTAssertEqual(try SRTPKeys.derive(key, salt, label: 2, length: 14).hex,
                       "fa31791685ca444a9e07c6c64e93")
        XCTAssertEqual(try SRTPKeys.derive(key, salt, label: 1, length: 20).hex,
                       "fd9c32d39ed5fbb5a9dc96b30818454d1313dc05")
    }

    func testKeepaliveProtectedBySenderIsAcceptedByReceiver() throws {
        let blob = Data((0..<46).map { UInt8($0 &* 5 &+ 3) })
        let sender = try SRTPSender(blob: blob, ssrc: 0xDEADBEEF)
        let receiver = try SRTPReceiver(blob: blob)
        for expected in 0..<3 {
            let wire = try sender.protect(payload: Data([1, 2, 3, 4, 5]), payloadType: 101)
            let packet = try XCTUnwrap(receiver.unprotect(wire))
            XCTAssertEqual(packet.payload, Data([1, 2, 3, 4, 5]))
            XCTAssertEqual(packet.ssrc, 0xDEADBEEF)
            XCTAssertEqual(packet.payloadType, 101)
            XCTAssertEqual(packet.extendedSequence, UInt64(expected))
        }
        var corrupted = try sender.protect(payload: Data([9]), payloadType: 101)
        corrupted[12] ^= 0xFF
        XCTAssertNil(receiver.unprotect(corrupted))
    }

    func testFeedbackFraming() throws {
        let sender = try SRTCPSender(blob: Data(repeating: 7, count: 46))
        let report = RTCP.receiverReport(sender: 0x01020304, sources: [(ssrc: 0x0A0B0C0D, highestSequence: 99)])
        XCTAssertEqual(report.count, 32)
        let protected = try sender.protect(report)
        XCTAssertEqual(protected.count, report.count + 4 + 10)
        XCTAssertEqual(protected.prefix(8), report.prefix(8))
        XCTAssertNotEqual(protected.subdata(in: 8..<32), report.subdata(in: 8..<32))
        XCTAssertEqual(protected.subdata(in: 32..<36).hex, "80000000")

        let request = RTCP.keyframeRequest(sender: 1, media: 2, counter: 3)
        XCTAssertEqual(request.count, 20 + 12 + 8)
    }
}

final class HEVCTests: XCTestCase {
    private func packet(_ sequence: UInt64, _ timestamp: UInt32, marker: Bool, _ payload: [UInt8]) -> RTPPacket {
        RTPPacket(payloadType: 100, marker: marker, extendedSequence: sequence,
                  timestamp: timestamp, ssrc: 1, payload: Data(payload))
    }

    private func header(type: UInt8) -> [UInt8] { [type << 1, 0x01] }

    func testSingleAggregatedAndFragmentedUnits() {
        let single = header(type: 1) + [0, 7] + [0xAA, 0xBB]
        let aggregate = header(type: 48) + [0, 8]
            + [0, 3] + header(type: 32) + [0x11]
            + [0, 4] + header(type: 33) + [0x22, 0x23]
        let start = header(type: 49) + [0x80 | 19] + [0, 9] + [0xC1, 0xC2]
        let middle = header(type: 49) + [19] + [0, 9] + [0xC3]
        let end = header(type: 49) + [0x40 | 19] + [0, 9] + [0xC4]

        let units = HEVCDepacketizer.nalUnits(from: [single, aggregate, start, middle, end].map { Data($0) })
        XCTAssertEqual(units.map { $0.hex }, [
            "0201aabb",
            "400111",
            "42012223",
            "2601c1c2c3c4",
        ])
        XCTAssertTrue(HEVCNAL.isKeyframe(HEVCNAL.type(units[3])))
    }

    func testReorderedPacketsFormOneAccessUnit() {
        let depacketizer = HEVCDepacketizer()
        XCTAssertEqual(depacketizer.add(packet(9, 800, marker: true, header(type: 1) + [0, 0, 0x90])).count, 1)
        let a = packet(10, 900, marker: false, header(type: 1) + [0, 1, 0xA0])
        let b = packet(11, 900, marker: true, header(type: 1) + [0, 1, 0xB0])
        XCTAssertTrue(depacketizer.add(b).isEmpty)       // marker first: still waiting for 10
        let units = depacketizer.add(a)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.nalUnits.count, 2)
        XCTAssertEqual(units.first?.continuous, true)
        XCTAssertEqual(units.first?.isKeyframe, false)
    }

    func testLossIsReportedAsDiscontinuity() {
        let depacketizer = HEVCDepacketizer()
        XCTAssertEqual(depacketizer.add(packet(1, 100, marker: true, header(type: 1) + [0, 1, 1])).count, 1)
        // Sequence 2 (a whole access unit) never arrives. The unit after the hole
        // is held until newer data proves the hole is a loss, not reordering.
        XCTAssertTrue(depacketizer.add(packet(3, 300, marker: true, header(type: 1) + [0, 3, 1])).isEmpty)
        let afterHole = depacketizer.add(packet(4, 400, marker: false, header(type: 1) + [0, 4, 1]))
        XCTAssertEqual(afterHole.count, 1)
        XCTAssertEqual(afterHole.first?.continuous, false)
        XCTAssertEqual(afterHole.first?.rtpTimestamp, 300)

        // The unit at timestamp 400 loses its middle packet and is never delivered;
        // the one after it is flagged as discontinuous.
        XCTAssertTrue(depacketizer.add(packet(6, 400, marker: true, header(type: 1) + [0, 4, 1])).isEmpty)
        let next = depacketizer.add(packet(7, 500, marker: true, header(type: 1) + [0, 5, 1]))
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.continuous, false)
        XCTAssertEqual(next.first?.rtpTimestamp, 500)
        // Normal service resumes.
        let resumed = depacketizer.add(packet(8, 600, marker: true, header(type: 1) + [0, 6, 1]))
        XCTAssertEqual(resumed.first?.continuous, true)
    }

    func testParameterSetTracking() {
        var sets = HEVCParameterSets()
        let vps = Data(header(type: 32) + [1]), sps = Data(header(type: 33) + [2])
        let pps0 = Data(header(type: 34) + [0b1000_0000]), pps1 = Data(header(type: 34) + [0b0100_0000])
        XCTAssertTrue(sets.absorb([vps, sps]))
        XCTAssertFalse(sets.isComplete)
        XCTAssertTrue(sets.absorb([pps0, pps1]))
        XCTAssertTrue(sets.isComplete)
        XCTAssertEqual(sets.all.count, 4)
        XCTAssertFalse(sets.absorb([vps, sps, pps0, pps1]))
        let pps1b = Data(header(type: 34) + [0b0100_0001])
        XCTAssertTrue(sets.absorb([pps1b]))
        XCTAssertEqual(sets.pps, [pps0, pps1b])
    }
}

final class NegotiationTests: XCTestCase {
    func testProtobufRoundTrip() {
        var w = ProtobufWriter()
        w.varint(1, 300)
        w.message(5) { nested in
            nested.varint(4, 3840)
            nested.varint(5, 2160)
        }
        w.bytes(6, Data("name".utf8))
        let fields = parseProtobuf(w.data)
        XCTAssertEqual(fields.count, 3)
        guard case .varint(300) = fields[0].value, case .bytes(let nested) = fields[1].value else {
            return XCTFail("unexpected field shapes")
        }
        XCTAssertEqual(fields[1].field, 5)
        XCTAssertEqual(parseProtobuf(nested).count, 2)
    }

    func testZlibRoundTrip() {
        let input = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        XCTAssertEqual(Zlib.decompress(Zlib.compress(input)), input)
        XCTAssertNil(Zlib.decompress(Data([1, 2, 3])))
    }

    func testOfferMessageLayout() throws {
        let offer = MediaOffer()
        let message = offer.message()
        XCTAssertEqual(message[0], 0x1C)
        let size = Int(message[2]) << 8 | Int(message[3])
        XCTAssertEqual(size, message.count - 4)
        let audioLength = Int(message[0x0A]) << 8 | Int(message[0x0B])
        let videoLength = Int(message[0x0C]) << 8 | Int(message[0x0D])
        XCTAssertEqual(message.count, 0x80 + audioLength + 92 + videoLength)
        XCTAssertEqual(message.subdata(in: 0x52..<0x80), offer.keys.audioFromHost)
        let videoStart = 0x80 + audioLength
        XCTAssertEqual(message.subdata(in: videoStart + 46..<videoStart + 92), offer.keys.videoFromHost)

        // The embedded video offer must describe our own source identifier.
        let plistData = message.subdata(in: videoStart + 92..<message.count)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["avcMediaStreamNegotiatorMode"] as? Int, 7)
        let blob = try XCTUnwrap(Zlib.decompress(try XCTUnwrap(plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)))
        let video = parseProtobuf(blob).first { $0.field == 5 }
        guard case .bytes(let description)? = video?.value,
              case .varint(let ssrc)? = parseProtobuf(description).first(where: { $0.field == 1 })?.value else {
            return XCTFail("video description missing")
        }
        XCTAssertEqual(UInt32(ssrc), offer.videoSSRC)
    }

    func testAnswerParsing() throws {
        func answer(width: UInt64, height: UInt64) throws -> Data {
            var description = ProtobufWriter()
            description.varint(1, 1)
            description.message(5) { video in
                video.varint(1, 42)
                video.varint(4, width)
                video.varint(5, height)
                video.varint(6, 1)
            }
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["avcMediaStreamNegotiatorMediaBlob": Zlib.compress(description.data)],
                format: .binary, options: 0)
            return Data([0x00, 0x00, 0x00, 0x01]) + Data(count: 20) + plist + Data([0xEE, 0xEE, 0xEE])
        }
        XCTAssertEqual(MediaOffer.parseAnswer(in: try answer(width: 3024, height: 1964)),
                       MediaAnswer(canvasWidth: 3024, canvasHeight: 1964, tiles: 1))
        XCTAssertEqual(MediaOffer.parseAnswer(in: try answer(width: 0, height: 0))?.isUsable, false)
        XCTAssertNil(MediaOffer.parseAnswer(in: Data([0x00, 0x00, 0x00, 0x00, 1, 2, 3])))
    }

    func testControlMessageShapes() {
        XCTAssertEqual(ControlMessage.viewerInfo().count, 66)
        XCTAssertEqual(ControlMessage.beginEncryption().hex, "120000010001000100000001")
        XCTAssertEqual(ControlMessage.confirmEncryption().hex, "1200000200010000")
        XCTAssertEqual(ControlMessage.pointerEvent(buttons: [.left], x: 258, y: 70000).hex, "05010102ffff")
        XCTAssertEqual(ControlMessage.keyEvent(keysym: 0xFF0D, down: true).hex, "040100000000ff0d")
        XCTAssertEqual(ControlMessage.setEncodings([1103, -223]).hex, "020000020000044fffffff21")

        let display = ControlMessage.setDisplayConfiguration(VirtualDisplay(width: 1440, height: 900))
        XCTAssertEqual(display.count, 12 + 0x9C + 28)
        XCTAssertEqual(Int(display[2]) << 8 | Int(display[3]), display.count - 4)
        XCTAssertEqual(display.subdata(in: 12 + 0x9C..<12 + 0x9C + 16).hex,
                       "00000b4000000708000005a000000384")
    }

    func testFramebufferUpdateWalk() {
        var w = ByteWriter()
        w.u8(0); w.u8(0); w.u16(2)
        w.zeros(8); w.i32(1105)
        var layout = ByteWriter()
        layout.u16(5); layout.u16(1512); layout.u16(982); layout.u16(3024); layout.u16(1964)
        w.u16(UInt16(layout.data.count)); w.bytes(layout.data)
        w.zeros(8); w.i32(1104)
        w.u32(1000); w.u32(2); w.bytes([9, 9])
        let update = FramebufferUpdate(message: w.data)
        XCTAssertEqual(update.rectangles.map(\.encoding), [1105, 1104])
        let parsed = DisplayLayout(payload: update.rectangles[0].payload)
        XCTAssertEqual(parsed?.scaledWidth, 1512)
        XCTAssertEqual(parsed?.backingHeight, 1964)
    }

    /// First packets of a macOS 27 stream: parameter sets aggregated with no
    /// order number, which switches the rest of the stream to plain RFC 7798.
    func testStreamWithoutOrderNumbers() {
        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x04, 0x08])
        var aggregate = Data([0x60, 0x01])
        for unit in [vps, sps] {
            aggregate.append(contentsOf: [0, UInt8(unit.count)])
            aggregate.append(unit)
        }
        let start = Data([0x62, 0x01, 0x94, 0xAF, 0x08, 0x58])
        let end = Data([0x62, 0x01, 0x54, 0xEC, 0xCC])
        let single = Data([0x02, 0x01, 0xAA, 0xBB])

        var hasOrderNumbers = true
        let units = HEVCDepacketizer.nalUnits(from: [aggregate, start, end, single], hasOrderNumbers: &hasOrderNumbers)
        XCTAssertFalse(hasOrderNumbers)
        XCTAssertEqual(units, [vps, sps, Data([0x28, 0x01, 0xAF, 0x08, 0x58, 0xEC, 0xCC]), single])
    }

    /// A cursor shape arrives as BGRA pixels plus a separate alpha plane, in a
    /// zlib stream that is flushed but has no trailer.
    func testCursorShapeDecoding() throws {
        let bgra: [UInt8] = [10, 20, 30, 0, 40, 50, 60, 0]   // two pixels
        let alpha: [UInt8] = [255, 128]
        let unfinished = Zlib.compress(Data(bgra + alpha)).dropLast(4)

        let raw = try XCTUnwrap(Zlib.inflateUnfinished(Data(unfinished), expectedLength: 10))
        let cursor = try XCTUnwrap(CursorImage(width: 2, height: 1, hotspotX: 1, hotspotY: 0, raw: raw))
        XCTAssertEqual([UInt8](cursor.rgba), [30, 20, 10, 255, 60, 50, 40, 128])
        XCTAssertNil(CursorImage(width: 3, height: 1, hotspotX: 0, hotspotY: 0, raw: raw))
    }
}

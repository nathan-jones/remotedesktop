import Foundation
import zlib

/// Minimal protobuf wire-format writer/reader (varint and length-delimited fields).
struct ProtobufWriter {
    private(set) var data = Data()

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        rawVarint(UInt64(field) << 3)
        rawVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        rawVarint(UInt64(field) << 3 | 2)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(_ field: Int, _ build: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
        build(&nested)
        bytes(field, nested.data)
    }
}

enum ProtobufValue {
    case varint(UInt64)
    case bytes(Data)
}

func parseProtobuf(_ data: Data) -> [(field: Int, value: ProtobufValue)] {
    let bytes = [UInt8](data)
    var position = 0
    var fields: [(Int, ProtobufValue)] = []

    func varint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count, shift < 64 {
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    while position < bytes.count {
        guard let tag = varint() else { break }
        let field = Int(tag >> 3)
        switch tag & 7 {
        case 0:
            guard let value = varint() else { return fields }
            fields.append((field, .varint(value)))
        case 2:
            guard let length = varint(), position + Int(length) <= bytes.count else { return fields }
            fields.append((field, .bytes(Data(bytes[position..<position + Int(length)]))))
            position += Int(length)
        case 1: position += 8
        case 5: position += 4
        default: return fields
        }
    }
    return fields
}

enum Zlib {
    static func compress(_ input: Data) -> Data {
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = input.withUnsafeBytes { raw in
            compress2(&output, &length, raw.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
        }
        precondition(status == Z_OK, "zlib compression failed")
        return Data(output[0..<Int(length)])
    }

    /// Inflates a stream that was flushed but never finished (as cursor images
    /// are), which the one-shot `uncompress` rejects as truncated.
    static func inflateUnfinished(_ input: Data, expectedLength: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: expectedLength)
        let status: Int32 = input.withUnsafeBytes { raw in
            output.withUnsafeMutableBufferPointer { out in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(expectedLength)
                return inflate(&stream, Z_SYNC_FLUSH)
            }
        }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR,
              Int(stream.total_out) == expectedLength else { return nil }
        return Data(output)
    }

    static func decompress(_ input: Data, limit: Int = 1 << 20) -> Data? {
        var capacity = max(input.count * 8, 4096)
        while capacity <= limit {
            var length = uLong(capacity)
            var output = [UInt8](repeating: 0, count: capacity)
            let status = input.withUnsafeBytes { raw in
                uncompress(&output, &length, raw.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
            }
            if status == Z_OK { return Data(output[0..<Int(length)]) }
            if status != Z_BUF_ERROR { return nil }
            capacity *= 4
        }
        return nil
    }
}

/// The four SRTP key blobs carried in the media offer (32-byte key + 14-byte salt each).
struct MediaKeys {
    static let blobLength = 46

    var audioToHost = Crypto.randomBytes(blobLength)
    var audioFromHost = Crypto.randomBytes(blobLength)
    var videoToHost = Crypto.randomBytes(blobLength)
    var videoFromHost = Crypto.randomBytes(blobLength)
}

/// What the host says it will encode.
struct MediaAnswer: Equatable {
    var canvasWidth: Int
    var canvasHeight: Int
    var tiles: Int

    var isUsable: Bool { canvasWidth > 0 && canvasHeight > 0 }
}

/// Builds the media-stream offer and reads the host's answer. The offer mirrors
/// what Apple's conferencing stack produces: one property list per stream, each
/// wrapping a zlib-compressed protobuf description.
struct MediaOffer {
    static let clientName = "RemoteDesktopPOC 0.1"

    let keys = MediaKeys()
    /// Our RTP source identifiers; the host only accepts feedback from these.
    let videoSSRC = UInt32.random(in: 1...UInt32.max)
    let audioSSRC = UInt32.random(in: 1...UInt32.max)
    /// Number of independent strips the host should split each frame into.
    let tilesPerFrame: Int
    /// When false the host's cursor is drawn into the video itself.
    let hideCursorInVideo: Bool

    private let audioPlist: Data
    private let videoPlist: Data

    init(tilesPerFrame: Int = 1, hideCursorInVideo: Bool = false) {
        self.tilesPerFrame = tilesPerFrame
        self.hideCursorInVideo = hideCursorInVideo
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        audioPlist = MediaOffer.propertyList(
            mode: 8, blob: MediaOffer.audioDescription(ssrc: audioSSRC, timestamp: timestamp))
        videoPlist = MediaOffer.propertyList(
            mode: 7, blob: MediaOffer.videoDescription(ssrc: videoSSRC, tiles: tilesPerFrame, timestamp: timestamp))
    }

    // MARK: Stream descriptions

    /// Fields shared by both stream descriptions, written around the stream-specific part.
    private static func description(timestamp: UInt64, stream: (inout ProtobufWriter) -> Void) -> Data {
        // Bitrate tiers the host may choose between: (kind, rate, buffer size).
        let tiers: [(UInt64, UInt64, UInt64?)] = [
            (0, 40_000_000, 12288), (0, 6_000_000, 131072), (4074, 0, 16384),
            (16, 4100, nil), (0, 75_000_000, 524288), (0, 20_000_000, 98304),
            (4, 6500, nil), (0, 60_000_000, 262144), (1, 299, nil),
            (0, 100_000_000, 1048576),
        ]
        var w = ProtobufWriter()
        w.varint(1, 1)
        w.varint(2, 1)
        stream(&w)
        w.bytes(6, Data(clientName.utf8))
        w.varint(8, 0)
        for (kind, rate, buffer) in tiers {
            w.message(9) { tier in
                tier.varint(1, kind)
                tier.varint(2, rate)
                if let buffer { tier.varint(3, buffer) }
            }
        }
        w.varint(13, timestamp)
        w.varint(14, 2)
        w.varint(16, 0)
        w.varint(18, 1)
        return w.data
    }

    private static func videoDescription(ssrc: UInt32, tiles: Int, timestamp: UInt64) -> Data {
        func resolution(_ writer: inout ProtobufWriter, variant: UInt64) {
            writer.message(2) { r in
                r.varint(1, 1)
                r.varint(2, variant)
                r.varint(3, 50115)
                r.varint(4, 0)
            }
        }
        return description(timestamp: timestamp) { w in
            w.message(5) { video in
                video.varint(1, UInt64(ssrc))
                video.varint(2, 0)   // long-term reference feedback: off
                // Two codec capability sets, in the order Apple's viewer lists them.
                // Offered together, the host picks HEVC 4:4:4.
                video.message(3) { codec in
                    codec.varint(1, 123)
                    resolution(&codec, variant: 1)
                    resolution(&codec, variant: 2)
                    resolution(&codec, variant: 1)
                    resolution(&codec, variant: 2)
                    codec.bytes(3, Data("FLS;MS:-1;LF:-1;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;".utf8))
                    codec.varint(4, 1)
                }
                video.message(3) { codec in
                    codec.varint(1, 100)
                    resolution(&codec, variant: 1)
                    resolution(&codec, variant: 2)
                    codec.bytes(3, Data("FLS;LF:-1;POS:5;EOD:1;HTS:2;RR:3;POSE:4;AR:16/9,5/8;XR:16/9,5/8;".utf8))
                    codec.varint(4, 14)
                }
                video.varint(6, UInt64(tiles))
                video.varint(7, 0)   // long-term reference pictures: off
                video.varint(8, 63)
                video.varint(9, 1)
                video.varint(12, 1)
            }
        }
    }

    private static func audioDescription(ssrc: UInt32, timestamp: UInt64) -> Data {
        description(timestamp: timestamp) { w in
            w.message(3) { audio in
                audio.varint(1, UInt64(ssrc))
                audio.varint(2, 0)
                audio.varint(3, 0)
                // Requested bitrate. A value below the lowest tier makes the host
                // send no audio, which is what this video-only client wants. The
                // audio section itself must still be present.
                audio.varint(4, 1000)
                audio.varint(5, 0)
                audio.varint(6, 0)
            }
        }
    }

    private static func endpointInfo() -> Data {
        var w = ProtobufWriter()
        w.varint(1, 0)
        w.varint(2, 1)
        w.bytes(3, Data("Generic".utf8))
        w.bytes(4, Data("1.0.0".utf8))
        w.bytes(5, Data("0".utf8))
        return w.data
    }

    private static func propertyList(mode: Int, blob: Data) -> Data {
        let dictionary: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": endpointInfo(),
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": Zlib.compress(blob),
            "avcMediaStreamOptionCallID": UUID().uuidString,
        ]
        // Serialising a dictionary of plist-safe values cannot fail.
        return try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    // MARK: Wire message

    /// The media-stream-options control message: fixed header, session id, then
    /// per-stream key blobs followed by that stream's offer.
    func message() -> Data {
        let audioOffset = 0x80
        let videoOffset = audioOffset + audioPlist.count
        let messageSize = audioPlist.count + videoPlist.count + 0xD8

        var w = ByteWriter(zeroFilled: messageSize + 4)
        w.put(UInt8(0x1C), at: 0)
        w.put(UInt16(messageSize), at: 2)
        w.put(UInt16(3), at: 4)                 // message version
        // Stream flags: 60 fps on both video streams, optionally no baked-in cursor.
        w.put(UInt32(hideCursorInVideo ? 7 : 3), at: 6)
        w.put(UInt16(audioPlist.count), at: 0x0A)
        w.put(UInt16(videoPlist.count), at: 0x0C)
        w.put(withUnsafeBytes(of: UUID().uuid) { Data($0) }, at: 0x14)
        w.put(keys.audioToHost, at: 0x24)
        w.put(keys.audioFromHost, at: 0x52)
        w.put(audioPlist, at: audioOffset)
        w.put(keys.videoToHost, at: videoOffset)
        w.put(keys.videoFromHost, at: videoOffset + MediaKeys.blobLength)
        w.put(videoPlist, at: videoOffset + 2 * MediaKeys.blobLength)
        return w.data
    }

    // MARK: Answer

    /// Looks for the video answer inside a control message from the host. Returns
    /// nil if the message holds no media answer at all, and an unusable answer
    /// (zero canvas) if the host's encoder is not ready yet.
    static func parseAnswer(in message: Data) -> MediaAnswer? {
        let data = Data(message)
        let marker = Data("bplist00".utf8)
        var found: MediaAnswer?
        var searchStart = 0

        while let range = data.range(of: marker, in: searchStart..<data.count) {
            searchStart = range.lowerBound + marker.count
            guard let plist = propertyList(startingAt: range.lowerBound, in: data),
                  let blob = plist["avcMediaStreamNegotiatorMediaBlob"] as? Data else { continue }
            found = found ?? MediaAnswer(canvasWidth: 0, canvasHeight: 0, tiles: 0)
            guard let description = Zlib.decompress(blob) else { continue }
            for case (5, .bytes(let video)) in parseProtobuf(description) {
                var answer = MediaAnswer(canvasWidth: 0, canvasHeight: 0, tiles: 0)
                for case (let field, .varint(let value)) in parseProtobuf(video) {
                    switch field {
                    case 4: answer.canvasWidth = Int(value)
                    case 5: answer.canvasHeight = Int(value)
                    case 6: answer.tiles = Int(value)
                    default: break
                    }
                }
                if answer.isUsable { return answer }
            }
        }
        return found
    }

    /// A binary property list has no length in its header, so try successive end
    /// offsets until one parses.
    private static func propertyList(startingAt start: Int, in data: Data) -> [String: Any]? {
        guard data.count - start > 40 else { return nil }
        for end in stride(from: start + 40, through: data.count, by: 1) {
            let candidate = data.subdata(in: start..<end)
            if let object = try? PropertyListSerialization.propertyList(from: candidate, format: nil),
               let dictionary = object as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }
}

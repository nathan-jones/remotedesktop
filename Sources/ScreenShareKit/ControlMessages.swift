import Foundation

/// A virtual display the host creates for the session instead of mirroring its
/// physical screen. While one is active the host's own screen is curtained.
public struct VirtualDisplay: Equatable {
    /// Logical size in points.
    public var width: Int
    public var height: Int
    /// Backing pixels per point (2 = Retina).
    public var scale: Double

    public init(width: Int, height: Int, scale: Double = 2) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// Encoding numbers that appear in framebuffer-update rectangles.
enum Encoding {
    static let mediaStreamAnnouncement: Int32 = 1010
    static let tileCodec: Int32 = 1011
    static let rekey: Int32 = 1103
    static let cursor: Int32 = 1104
    static let displayLayout: Int32 = 1105

    /// The set a High Performance viewer advertises.
    static let highPerformance: [Int32] = [
        1010, 1011, 1002, 6, 16, 1104, 1100, -223, 1101, 1105, 1107, 1109, 1110,
    ]
}

public struct PointerButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = PointerButtons(rawValue: 1 << 0)
    /// Apple swaps the usual RFB positions of the right and middle buttons.
    public static let right = PointerButtons(rawValue: 1 << 1)
    public static let middle = PointerButtons(rawValue: 1 << 2)
    public static let scrollUp = PointerButtons(rawValue: 1 << 3)
    public static let scrollDown = PointerButtons(rawValue: 1 << 4)
}

/// Builders for the client-to-host control messages this client sends.
enum ControlMessage {
    /// Client initialisation byte: shared session plus Apple capability bits.
    static let clientInit = Data([0xC1])

    /// Introduces the viewer and the optional features it understands.
    static func viewerInfo() -> Data {
        var features = [UInt8](repeating: 0, count: 32)
        features[0] = 0xB0
        features[2] = 0x0C
        features[3] = 0x03
        features[4] = 0x90
        features[10] = 0x40

        var w = ByteWriter()
        w.u8(0x21)
        w.u8(0)
        w.u16(62)                    // bytes after this field
        w.u16(1)                     // message version
        w.u32(2)                     // viewer application id
        w.u32(6); w.u32(1); w.u32(0) // viewer application version
        w.u32(15); w.u32(3); w.u32(0) // viewer OS version
        w.bytes(features)
        return w.data
    }

    /// Asks the host to start encrypting; it answers with the rekey rectangle.
    static func beginEncryption() -> Data {
        var w = ByteWriter()
        w.u8(0x12)
        w.u8(0)
        w.u16(1)      // command: start
        w.u16(1)      // method count
        w.u16(1)      // method: AES-128
        w.u32(1)
        return w.data
    }

    /// Sent in the clear after the rekey arrives; everything after it is encrypted.
    static func confirmEncryption() -> Data {
        var w = ByteWriter()
        w.u8(0x12)
        w.u8(0)
        w.u16(2)
        w.u16(1)
        w.u16(0)
        return w.data
    }

    static func setEncodings(_ encodings: [Int32] = Encoding.highPerformance) -> Data {
        var w = ByteWriter()
        w.u8(0x02)
        w.u8(0)
        w.u16(UInt16(encodings.count))
        encodings.forEach { w.i32($0) }
        return w.data
    }

    static func framebufferUpdateRequest(incremental: Bool) -> Data {
        var w = ByteWriter()
        w.u8(0x03)
        w.u8(incremental ? 1 : 0)
        w.u16(0); w.u16(0)
        w.u16(0xFFFF); w.u16(0xFFFF)
        return w.data
    }

    /// Switches the host to sending updates unprompted, which is what keeps
    /// cursor-shape changes flowing. Must be repeated after every layout change.
    static func autoFramebufferUpdate(width: Int, height: Int) -> Data {
        var w = ByteWriter()
        w.u8(0x09)
        w.u8(0)
        w.u16(1)
        w.u32(0xFFFF_FFFF)               // all displays
        w.u16(0); w.u16(0)
        w.u16(UInt16(clamping: width)); w.u16(UInt16(clamping: height))
        return w.data
    }

    static func pointerEvent(buttons: PointerButtons, x: Int, y: Int) -> Data {
        var w = ByteWriter()
        w.u8(0x05)
        w.u8(buttons.rawValue)
        w.u16(UInt16(clamping: max(0, x)))
        w.u16(UInt16(clamping: max(0, y)))
        return w.data
    }

    /// Key press or release identified by an X11 keysym.
    static func keyEvent(keysym: UInt32, down: Bool) -> Data {
        var w = ByteWriter()
        w.u8(0x04)
        w.u8(down ? 1 : 0)
        w.u16(0)
        w.u32(keysym)
        return w.data
    }

    /// Requests a virtual display. The descriptor is always the "dynamic" form,
    /// which is also what a later resize request must look like.
    static func setDisplayConfiguration(_ display: VirtualDisplay, name: String = "Remote Viewer") -> Data {
        let modeCount = 1
        let modeLength = 28
        let descriptorLength = 0x9C + modeLength * modeCount

        var d = ByteWriter(zeroFilled: descriptorLength)
        d.put(UInt16(descriptorLength), at: 0x00)
        d.put(Data(name.utf8.prefix(119)), at: 0x02)
        d.put(UInt32(1), at: 0x7A)                       // dynamic resolution
        d.put(UInt32(4), at: 0x7E)                       // display type: virtual
        // Physical size in millimetres, assuming roughly 132 points per inch.
        d.put((Float(display.width) * 0.1924).bitPattern, at: 0x82)
        d.put((Float(display.height) * 0.1924).bitPattern, at: 0x86)
        // The limits given when the display is created also bound every later
        // resize (a larger request drops the display to 800x600), so allow
        // either orientation from the start.
        d.put(UInt32(3840), at: 0x8A)                    // maximum backing width
        d.put(UInt32(3840), at: 0x8E)                    // maximum backing height
        d.put(UInt16(0), at: 0x92)                       // current mode index
        d.put(UInt16(0), at: 0x94)                       // preferred mode index
        d.put(UInt32(7), at: 0x96)
        d.put(UInt16(modeCount), at: 0x9A)

        let mode = 0x9C
        d.put(UInt32((Double(display.width) * display.scale).rounded()), at: mode + 0x00)
        d.put(UInt32((Double(display.height) * display.scale).rounded()), at: mode + 0x04)
        d.put(UInt32(display.width), at: mode + 0x08)
        d.put(UInt32(display.height), at: mode + 0x0C)
        d.put(Double(60).bitPattern, at: mode + 0x10)
        d.put(UInt32(0), at: mode + 0x18)

        var w = ByteWriter()
        w.u8(0x1D)
        w.u8(0)
        w.u16(UInt16(8 + descriptorLength))  // bytes after this field
        w.u16(1)                             // version
        w.u16(1)                             // display count
        w.u32(0)                             // flags
        w.bytes(d.data)
        return w.data
    }
}

/// A pointer shape sent by the host, for a viewer that draws the pointer itself.
public struct CursorImage {
    public var width: Int
    public var height: Int
    /// The pixel within the image that sits on the pointer position.
    public var hotspotX: Int
    public var hotspotY: Int
    /// Row-major RGBA, 8 bits per channel, alpha not premultiplied.
    public var rgba: Data

    /// - Parameter raw: BGRA pixels followed by a separate one-byte-per-pixel alpha plane.
    init?(width: Int, height: Int, hotspotX: Int, hotspotY: Int, raw: Data) {
        let pixels = width * height
        guard pixels > 0, raw.count == pixels * 5 else { return nil }
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        raw.withUnsafeBytes { source in
            for i in 0..<pixels {
                rgba[i * 4] = source[i * 4 + 2]
                rgba[i * 4 + 1] = source[i * 4 + 1]
                rgba[i * 4 + 2] = source[i * 4]
                rgba[i * 4 + 3] = source[pixels * 4 + i]
            }
        }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgba = Data(rgba)
    }
}

/// Geometry announced by the host in a display-layout rectangle.
public struct DisplayLayout: Equatable {
    /// Logical size in points.
    public var scaledWidth: Int
    public var scaledHeight: Int
    /// Pixel size of the encoded picture; pointer coordinates are in this space.
    public var backingWidth: Int
    public var backingHeight: Int

    init?(payload: Data) {
        var reader = ByteReader(payload)
        guard let _ = try? reader.u16(),
              let sw = try? reader.u16(), let sh = try? reader.u16(),
              let bw = try? reader.u16(), let bh = try? reader.u16(),
              sw > 0, sh > 0 else { return nil }
        scaledWidth = Int(sw)
        scaledHeight = Int(sh)
        backingWidth = Int(bw)
        backingHeight = Int(bh)
    }
}

/// Walks the rectangles of a framebuffer-update message far enough to pull out
/// the pieces this client acts on.
struct FramebufferUpdate {
    struct Rectangle {
        var x = 0, y = 0, width = 0, height = 0
        var encoding: Int32
        var payload: Data
    }

    var rectangles: [Rectangle] = []

    /// `message` starts at the message-type byte (0x00). Parsing stops quietly at
    /// the first rectangle whose size cannot be determined.
    init(message: Data) {
        var reader = ByteReader(message)
        guard (try? reader.u8()) == 0, (try? reader.u8()) != nil,
              let count = try? reader.u16() else { return }
        for _ in 0..<count {
            guard let x = try? reader.u16(), let y = try? reader.u16(),
                  let width = try? reader.u16(), let height = try? reader.u16(),
                  let encoding = try? reader.i32(),
                  let payload = FramebufferUpdate.payload(for: encoding, from: &reader) else { return }
            rectangles.append(Rectangle(x: Int(x), y: Int(y), width: Int(width), height: Int(height),
                                        encoding: encoding, payload: payload))
        }
    }

    /// Reads one rectangle body from a reader positioned just after its header.
    static func payload(for encoding: Int32, from reader: inout ByteReader) -> Data? {
        switch encoding {
        case Encoding.rekey:
            return try? reader.bytes(RecordLayer.rekeyBodyLength)
        case Encoding.cursor:
            guard let head = try? reader.bytes(8) else { return nil }
            let compressed = head.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard let body = try? reader.bytes(compressed) else { return nil }
            return head + body
        case 1010, 1011, 1100, 1101, 1105, 1107, 1109, 1110:
            // Metadata rectangles carry a 16-bit length followed by that many bytes.
            guard let length = try? reader.u16() else { return nil }
            return try? reader.bytes(Int(length))
        default:
            return nil
        }
    }
}

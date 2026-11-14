import Foundation

public enum ScreenShareError: Error, CustomStringConvertible {
    case truncated(String)
    case protocolViolation(String)
    case authenticationFailed(String)
    case unsupported(String)
    case network(String)
    case crypto(String)
    case timeout(String)

    public var description: String {
        switch self {
        case .truncated(let m): return "Truncated data: \(m)"
        case .protocolViolation(let m): return "Protocol error: \(m)"
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .crypto(let m): return "Crypto error: \(m)"
        case .timeout(let m): return "Timed out: \(m)"
        }
    }
}

/// Appends big-endian integers and raw bytes to a growing buffer.
struct ByteWriter {
    private(set) var data = Data()

    init() {}
    init(zeroFilled count: Int) { data = Data(count: count) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v) }
    mutating func u32(_ v: UInt32) { append(v) }
    mutating func u64(_ v: UInt64) { append(v) }
    mutating func i32(_ v: Int32) { append(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { append(v.bitPattern) }
    mutating func f64(_ v: Double) { append(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func zeros(_ n: Int) { data.append(Data(count: n)) }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Overwrites bytes at an absolute offset (the buffer must already cover it).
    mutating func put<T: FixedWidthInteger>(_ v: T, at offset: Int) {
        withUnsafeBytes(of: v.bigEndian) { raw in
            data.replaceSubrange(offset..<offset + raw.count, with: raw)
        }
    }

    mutating func put(_ d: Data, at offset: Int) {
        data.replaceSubrange(offset..<offset + d.count, with: d)
    }
}

/// Reads big-endian integers and raw bytes, throwing on underflow.
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        // Rebase so indices start at zero regardless of how the Data was sliced.
        self.data = Data(data)
        self.offset = 0
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining <= 0 }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 { try integer() }
    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ n: Int) throws -> Data {
        try need(n)
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        offset += n
    }

    mutating func rest() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        try need(size)
        var value: T = 0
        for i in 0..<size {
            value = (value << 8) | T(data[offset + i])
        }
        offset += size
        return value
    }

    private func need(_ n: Int) throws {
        guard n >= 0, remaining >= n else {
            throw ScreenShareError.truncated("wanted \(n) bytes, \(remaining) left")
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }
}

/// Minimal logging hook so the host app or CLI decides where messages go.
public enum ScreenShareLog {
    public static var sink: (String) -> Void = { _ in }
    static func log(_ message: @autoclosure () -> String) { sink(message()) }
}

import Foundation

/// HomeKit's type-length-value encoding. Values longer than 255 bytes are split
/// into consecutive items of the same type; a zero-length separator (0xFF)
/// divides repeated groups.
struct TLV8 {
    private(set) var items: [(type: UInt8, value: Data)] = []

    init() {}

    init(_ pairs: [(UInt8, Data)]) {
        for (type, value) in pairs { append(type, value) }
    }

    /// Parses an encoding, joining fragments of one long value back together.
    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        var previous: UInt8?
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else { return nil }
            let type = bytes[offset], length = Int(bytes[offset + 1])
            offset += 2
            guard offset + length <= bytes.count else { return nil }
            let value = Data(bytes[offset..<offset + length])
            offset += length
            // A full-length item followed by one of the same type continues it.
            if previous == type, let last = items.last, last.value.count % 255 == 0, !last.value.isEmpty {
                items[items.count - 1].value.append(value)
            } else {
                items.append((type, value))
            }
            previous = type
        }
    }

    mutating func append(_ type: UInt8, _ value: Data) { items.append((type, value)) }
    mutating func append(_ type: UInt8, _ value: UInt8) { append(type, Data([value])) }
    mutating func append(_ type: UInt8, _ value: String) { append(type, Data(value.utf8)) }
    mutating func append(_ type: UInt8, _ value: TLV8) { append(type, value.encoded) }
    mutating func append(_ type: UInt8, littleEndian value: some FixedWidthInteger) {
        append(type, withUnsafeBytes(of: value.littleEndian) { Data($0) })
    }
    mutating func separator() { append(0xFF, Data()) }

    subscript(type: UInt8) -> Data? { items.first { $0.type == type }?.value }

    func all(_ type: UInt8) -> [Data] { items.filter { $0.type == type }.map(\.value) }

    func byte(_ type: UInt8) -> UInt8? { self[type]?.first }

    func integer<T: FixedWidthInteger>(_ type: UInt8, as: T.Type = T.self) -> T? {
        guard let value = self[type], !value.isEmpty, value.count <= MemoryLayout<T>.size else { return nil }
        return value.reversed().reduce(T(0)) { ($0 << 8) | T($1) }
    }

    func nested(_ type: UInt8) -> TLV8? { self[type].flatMap { TLV8(decoding: $0) } }

    var encoded: Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(contentsOf: [type, 0])
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let end = min(offset + 255, value.endIndex)
                out.append(contentsOf: [type, UInt8(end - offset)])
                out.append(value[offset..<end])
                offset = end
            }
        }
        return out
    }
}

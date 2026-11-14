import Foundation

/// Unsigned multi-precision integer with just enough arithmetic for SRP.
/// Limbs are little-endian 64-bit words with no trailing zero limbs.
///
/// Not constant-time; fine for a proof of concept, not for production secrets.
struct BigUInt: Equatable, Comparable {
    private(set) var limbs: [UInt64]

    static let zero = BigUInt(limbs: [])
    static let one = BigUInt(limbs: [1])

    init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) { self.init(limbs: [value]) }

    /// Big-endian bytes, as used on the wire.
    init(bytes: Data) {
        var out: [UInt64] = []
        out.reserveCapacity(bytes.count / 8 + 1)
        var limb: UInt64 = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            limb |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                out.append(limb)
                limb = 0
                shift = 0
            }
        }
        if shift > 0 { out.append(limb) }
        self.init(limbs: out)
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// Big-endian bytes, left-padded with zeros to `length` (or minimal if nil).
    func bytes(paddedTo length: Int? = nil) -> Data {
        var out = Data()
        for limb in limbs.reversed() {
            withUnsafeBytes(of: limb.bigEndian) { out.append(contentsOf: $0) }
        }
        let firstNonZero = out.firstIndex(where: { $0 != 0 }) ?? out.endIndex
        out = out.subdata(in: firstNonZero..<out.endIndex)
        guard let length else { return out }
        precondition(out.count <= length, "value does not fit in \(length) bytes")
        return Data(count: length - out.count) + out
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out: [UInt64] = []
        let count = max(a.limbs.count, b.limbs.count)
        out.reserveCapacity(count + 1)
        var carry = false
        for i in 0..<count {
            let x = i < a.limbs.count ? a.limbs[i] : 0
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry ? 1 : 0)
            out.append(s2)
            carry = o1 || o2
        }
        if carry { out.append(1) }
        return BigUInt(limbs: out)
    }

    /// Requires `a >= b`.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt subtraction would underflow")
        var out = a.limbs
        var borrow = false
        for i in 0..<out.count {
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (d1, o1) = out[i].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow ? 1 : 0)
            out[i] = d2
            borrow = o1 || o2
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return .zero }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                (out[i + j], carry) = multiplyAdd(out[i + j], a.limbs[i], b.limbs[j], carry)
            }
            out[i + b.limbs.count] = carry
        }
        return BigUInt(limbs: out)
    }
}

/// Returns `acc + x * y + carry` as (low word, high word). Cannot overflow 128 bits.
@inline(__always)
private func multiplyAdd(_ acc: UInt64, _ x: UInt64, _ y: UInt64, _ carry: UInt64) -> (UInt64, UInt64) {
    var (high, low) = x.multipliedFullWidth(by: y)
    let (s1, o1) = low.addingReportingOverflow(acc)
    if o1 { high &+= 1 }
    let (s2, o2) = s1.addingReportingOverflow(carry)
    if o2 { high &+= 1 }
    low = s2
    return (low, high)
}

/// Montgomery arithmetic modulo a fixed odd modulus, used for modular exponentiation.
struct MontgomeryModulus {
    let modulus: BigUInt
    private let n: [UInt64]
    private let k: Int
    private let nPrime: UInt64     // -n^-1 mod 2^64
    private let rSquared: [UInt64] // R^2 mod n, R = 2^(64k)

    init(_ modulus: BigUInt) {
        precondition(!modulus.isZero && modulus.limbs[0] & 1 == 1, "modulus must be odd")
        self.modulus = modulus
        n = modulus.limbs
        k = n.count

        // Newton iteration for the inverse of n[0] modulo 2^64.
        var inverse = n[0]
        for _ in 0..<6 { inverse = inverse &* (2 &- n[0] &* inverse) }
        nPrime = 0 &- inverse

        // R^2 mod n by doubling 1 a total of 2*64*k times.
        var acc = BigUInt.one
        for _ in 0..<(2 * 64 * k) {
            acc = acc + acc
            if acc >= modulus { acc = acc - modulus }
        }
        rSquared = MontgomeryModulus.padded(acc.limbs, to: k)
    }

    private static func padded(_ limbs: [UInt64], to count: Int) -> [UInt64] {
        limbs + [UInt64](repeating: 0, count: count - limbs.count)
    }

    /// Montgomery product a * b * R^-1 mod n (coarsely integrated operand scanning).
    /// Works on raw buffers so that unoptimised builds stay usable.
    private func montgomeryMultiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: k + 2)
        let k = self.k
        let nPrime = self.nPrime
        t.withUnsafeMutableBufferPointer { t in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    n.withUnsafeBufferPointer { n in
                        for i in 0..<k {
                            var carry: UInt64 = 0
                            let bi = b[i]
                            for j in 0..<k {
                                (t[j], carry) = multiplyAdd(t[j], a[j], bi, carry)
                            }
                            let (sum, overflow) = t[k].addingReportingOverflow(carry)
                            t[k] = sum
                            t[k + 1] = overflow ? 1 : 0

                            let m = t[0] &* nPrime
                            (_, carry) = multiplyAdd(t[0], m, n[0], 0)
                            for j in 1..<k {
                                (t[j - 1], carry) = multiplyAdd(t[j], m, n[j], carry)
                            }
                            let (sum2, overflow2) = t[k].addingReportingOverflow(carry)
                            t[k - 1] = sum2
                            t[k] = t[k + 1] &+ (overflow2 ? 1 : 0)
                        }
                    }
                }
            }
        }
        var result = BigUInt(limbs: Array(t[0..<k]))
        if t[k] != 0 {
            // Value is result + 2^(64k); subtracting n once brings it back in range.
            result = BigUInt(limbs: Array(t[0..<k]) + [t[k]]) - modulus
        } else if result >= modulus {
            result = result - modulus
        }
        return MontgomeryModulus.padded(result.limbs, to: k)
    }

    private func reduced(_ value: BigUInt) -> BigUInt {
        precondition(value.bitWidth <= modulus.bitWidth + 1, "operand too large to reduce cheaply")
        var v = value
        while v >= modulus { v = v - modulus }
        return v
    }

    func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let x = MontgomeryModulus.padded(reduced(a).limbs, to: k)
        let y = MontgomeryModulus.padded(reduced(b).limbs, to: k)
        let product = montgomeryMultiply(x, y)            // a*b*R^-1
        return BigUInt(limbs: montgomeryMultiply(product, rSquared))
    }

    func power(_ base: BigUInt, _ exponent: BigUInt) -> BigUInt {
        let one = MontgomeryModulus.padded([1], to: k)
        let baseM = montgomeryMultiply(MontgomeryModulus.padded(reduced(base).limbs, to: k), rSquared)
        var acc = montgomeryMultiply(one, rSquared)
        for i in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            acc = montgomeryMultiply(acc, acc)
            if exponent.bit(i) { acc = montgomeryMultiply(acc, baseM) }
        }
        return BigUInt(limbs: montgomeryMultiply(acc, one))
    }

    /// (a - b) mod n for operands already below n.
    func subtract(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        a >= b ? a - b : (a + modulus) - b
    }
}

import Foundation

enum HEVCNAL {
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let aggregation: UInt8 = 48
    static let fragmentation: UInt8 = 49

    static func type(_ nal: Data) -> UInt8 { (nal[nal.startIndex] >> 1) & 0x3F }
    /// Slice data (as opposed to parameter sets and other metadata).
    static func isSlice(_ type: UInt8) -> Bool { type < 32 }
    /// Random-access pictures a decoder can start from.
    static func isKeyframe(_ type: UInt8) -> Bool { (16...21).contains(type) }
}

/// One coded picture: every NAL unit that shared an RTP timestamp.
public struct VideoAccessUnit {
    public var nalUnits: [Data]
    public var rtpTimestamp: UInt32
    public var ssrc: UInt32
    /// False if packets were lost since the previous access unit of this stream.
    public var continuous: Bool

    public var isKeyframe: Bool {
        nalUnits.contains { HEVCNAL.isKeyframe(HEVCNAL.type($0)) }
    }

    public var sliceUnits: [Data] {
        nalUnits.filter { HEVCNAL.isSlice(HEVCNAL.type($0)) }
    }
}

/// Reassembles one RTP source's packets into access units.
///
/// The payload format is RFC 7798. Older hosts add a 16-bit decoding-order
/// number after the header of every single-NAL packet, every aggregation packet
/// (once, not per unit) and every fragment; macOS 27 sends none. Which one a
/// stream uses is read off its aggregation packets, which open every keyframe.
final class HEVCDepacketizer {
    private var hasOrderNumbers = true
    private var pending: [UInt32: [RTPPacket]] = [:]
    private var lastSequence: UInt64?
    private static let maximumPendingGroups = 8

    /// Feeds one packet; returns any access units it completed, in order.
    func add(_ packet: RTPPacket) -> [VideoAccessUnit] {
        if let lastSequence, packet.extendedSequence <= lastSequence { return [] }   // late or duplicate
        pending[packet.timestamp, default: []].append(packet)

        var completed: [VideoAccessUnit] = []
        var droppedOlder = false
        while true {
            // Oldest group first, by its lowest sequence number.
            let groups = pending.values
                .map { $0.sorted { $0.extendedSequence < $1.extendedSequence } }
                .sorted { $0[0].extendedSequence < $1[0].extendedSequence }
            guard let oldest = groups.first else { break }
            let newerDataExists = groups.count > 1
            let whole = oldest.last?.marker == true && isGapFree(oldest)

            if whole {
                let follows = lastSequence.map { oldest[0].extendedSequence == $0 + 1 } ?? true
                // A unit that does not directly follow the previous one may just be
                // missing its first packets, so wait until newer data shows they are lost.
                guard follows || newerDataExists || droppedOlder else { break }
                pending[oldest[0].timestamp] = nil
                lastSequence = oldest[oldest.count - 1].extendedSequence
                let units = HEVCDepacketizer.nalUnits(from: oldest.map(\.payload), hasOrderNumbers: &hasOrderNumbers)
                if !units.isEmpty {
                    completed.append(VideoAccessUnit(
                        nalUnits: units, rtpTimestamp: oldest[0].timestamp,
                        ssrc: oldest[0].ssrc, continuous: follows && !droppedOlder))
                }
                droppedOlder = false
            } else {
                // Incomplete. Give up on it once a newer unit is whole, or too much has piled up.
                let newerWhole = groups.dropFirst().contains { $0.last?.marker == true && isGapFree($0) }
                guard newerWhole || groups.count > HEVCDepacketizer.maximumPendingGroups else { break }
                pending[oldest[0].timestamp] = nil
                droppedOlder = true
            }
        }
        return completed
    }

    private func isGapFree(_ ordered: [RTPPacket]) -> Bool {
        zip(ordered, ordered.dropFirst()).allSatisfy { $1.extendedSequence == $0.extendedSequence + 1 }
    }

    /// Splits an aggregation packet: header(2), an optional order number(2), then
    /// repeated [size(2) unit]. Whichever layout fits the packet exactly wins, and
    /// tells the caller whether this stream carries order numbers at all.
    static func aggregatedUnits(_ payload: Data, hasOrderNumbers: inout Bool) -> [Data] {
        for withOrder in [hasOrderNumbers, !hasOrderNumbers] {
            var units: [Data] = []
            var offset = withOrder ? 4 : 2
            var fits = true
            while offset < payload.count {
                guard offset + 2 <= payload.count else { fits = false; break }
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size >= 2, offset + size <= payload.count, payload[offset] & 0x80 == 0 else { fits = false; break }
                units.append(payload.subdata(in: offset..<offset + size))
                offset += size
            }
            if fits, !units.isEmpty {
                if withOrder != hasOrderNumbers {
                    ScreenShareLog.log("video stream \(withOrder ? "carries" : "has no") decoding-order numbers")
                    hasOrderNumbers = withOrder
                }
                return units
            }
        }
        ScreenShareLog.log("unreadable aggregation packet, \(payload.count) bytes: \(payload.prefix(48).hex)")
        return []
    }

    static func nalUnits(from payloads: [Data]) -> [Data] {
        var hasOrderNumbers = true
        return nalUnits(from: payloads, hasOrderNumbers: &hasOrderNumbers)
    }

    static func nalUnits(from payloads: [Data], hasOrderNumbers: inout Bool) -> [Data] {
        var units: [Data] = []
        var fragment: Data?

        for raw in payloads {
            let payload = Data(raw)
            guard payload.count >= 4 else { continue }
            switch HEVCNAL.type(payload) {
            case HEVCNAL.aggregation:
                units.append(contentsOf: aggregatedUnits(payload, hasOrderNumbers: &hasOrderNumbers))
            case HEVCNAL.fragmentation:
                // header(2) fragment-header(1) [order(2)] data
                let dataStart = hasOrderNumbers ? 5 : 3
                guard payload.count > dataStart else { continue }
                let header = payload[2]
                if header & 0x80 != 0 {
                    // Rebuild the original NAL header from the fragment's type bits.
                    var start = Data([(payload[0] & 0x81) | ((header & 0x3F) << 1), payload[1]])
                    start.append(payload.subdata(in: dataStart..<payload.count))
                    fragment = start
                } else if fragment != nil {
                    fragment!.append(payload.subdata(in: dataStart..<payload.count))
                }
                if header & 0x40 != 0, let complete = fragment {
                    units.append(complete)
                    fragment = nil
                }
            default:
                // header(2) [order(2)] data
                units.append(hasOrderNumbers
                    ? payload.subdata(in: 0..<2) + payload.subdata(in: 4..<payload.count)
                    : payload)
            }
        }
        return units
    }
}

/// Tracks the stream's parameter sets and reports when they change.
struct HEVCParameterSets: Equatable {
    public var vps: Data?
    public var sps: Data?
    public var pps: [Data] = []

    var isComplete: Bool { vps != nil && sps != nil && !pps.isEmpty }
    var all: [Data] { [vps, sps].compactMap { $0 } + pps }

    /// Returns true if anything changed.
    mutating func absorb(_ units: [Data]) -> Bool {
        let before = self
        for unit in units {
            switch HEVCNAL.type(unit) {
            case HEVCNAL.vps: vps = unit
            case HEVCNAL.sps: sps = unit
            case HEVCNAL.pps:
                // The picture-parameter-set id is the first Exp-Golomb value after the
                // 2-byte header; ids up to 6 fit in the first byte, which covers real streams.
                let id = HEVCParameterSets.ppsID(unit)
                if let index = pps.firstIndex(where: { HEVCParameterSets.ppsID($0) == id }) {
                    pps[index] = unit
                } else {
                    pps.append(unit)
                }
            default: break
            }
        }
        return self != before
    }

    private static func ppsID(_ unit: Data) -> Int {
        let unit = Data(unit)
        guard unit.count > 2 else { return 0 }
        let byte = unit[2]
        let zeros = byte.leadingZeroBitCount
        guard zeros < 4 else { return -1 }
        let width = zeros + 1
        let value = Int(byte >> UInt8(8 - 2 * zeros - 1)) & ((1 << width) - 1)
        return value - 1
    }
}

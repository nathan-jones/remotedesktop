import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware HEVC decoding through VideoToolbox. Feed it parameter sets, then
/// access units in decode order; decoded pictures arrive on `onFrame`.
public final class HEVCDecoder {
    /// Called on a VideoToolbox thread for every decoded picture.
    public var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called when decoding fails and a fresh keyframe is needed.
    public var onNeedsKeyframe: (() -> Void)?

    private let outputPixelFormat: OSType?
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var awaitingKeyframe = true

    /// - Parameter outputPixelFormat: request a specific pixel format (for
    ///   example `kCVPixelFormatType_32BGRA`); nil keeps the decoder's native one.
    public init(outputPixelFormat: OSType? = nil) {
        self.outputPixelFormat = outputPixelFormat
    }

    deinit { invalidate() }

    public var dimensions: CMVideoDimensions? {
        lock.lock()
        defer { lock.unlock() }
        return format.map { CMVideoFormatDescriptionGetDimensions($0) }
    }

    /// Installs new VPS/SPS/PPS units (raw NAL units, no start codes).
    public func setParameterSets(_ sets: [Data]) throws {
        let copies = sets.map { [UInt8]($0) }
        let pointers = copies.map { UnsafeMutablePointer<UInt8>.allocate(capacity: $0.count) }
        defer { pointers.forEach { $0.deallocate() } }
        for (pointer, bytes) in zip(pointers, copies) {
            pointer.update(from: bytes, count: bytes.count)
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: copies.count,
            parameterSetPointers: pointers.map { UnsafePointer($0) },
            parameterSetSizes: copies.map(\.count),
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw ScreenShareError.unsupported("video parameter sets rejected (\(status))")
        }

        lock.lock()
        defer { lock.unlock() }
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            format = description
            return
        }
        teardownLocked()

        var attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        if let outputPixelFormat { attributes[kCVPixelBufferPixelFormatTypeKey] = outputPixelFormat }

        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created)
        guard createStatus == noErr, let created else {
            throw ScreenShareError.unsupported("this device cannot decode the host's video format (\(createStatus))")
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        format = description
        session = created
        awaitingKeyframe = true
        let size = CMVideoFormatDescriptionGetDimensions(description)
        ScreenShareLog.log("decoder ready for \(size.width)x\(size.height)")
    }

    /// Decodes one access unit. Non-keyframes are skipped until a keyframe has been seen.
    public func decode(_ unit: VideoAccessUnit) {
        let slices = unit.sliceUnits
        guard !slices.isEmpty else { return }

        lock.lock()
        if unit.isKeyframe {
            awaitingKeyframe = false
        } else if awaitingKeyframe || !unit.continuous {
            awaitingKeyframe = true
            lock.unlock()
            onNeedsKeyframe?()
            return
        }
        guard let session, let format else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let sample = HEVCDecoder.sampleBuffer(slices: slices, format: format, timestamp: unit.rtpTimestamp) else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if status == noErr, let imageBuffer {
                self.onFrame?(imageBuffer)
            } else if status != noErr {
                self.failed(status)
            }
        }
        if status != noErr { failed(status) }
    }

    private func failed(_ status: OSStatus) {
        ScreenShareLog.log("decode failed (\(status))")
        lock.lock()
        let alreadyWaiting = awaitingKeyframe
        awaitingKeyframe = true
        lock.unlock()
        if !alreadyWaiting { onNeedsKeyframe?() }
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    /// Packs slices as 4-byte-length-prefixed NAL units in a single sample.
    private static func sampleBuffer(slices: [Data], format: CMVideoFormatDescription, timestamp: UInt32) -> CMSampleBuffer? {
        var payload = Data(capacity: slices.reduce(0) { $0 + $1.count + 4 })
        for slice in slices {
            withUnsafeBytes(of: UInt32(slice.count).bigEndian) { payload.append(contentsOf: $0) }
            payload.append(slice)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

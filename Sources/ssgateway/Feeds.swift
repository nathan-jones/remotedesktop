import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ScreenShareKit
import VideoToolbox

/// One coded picture on its way to the browser.
struct EncodedFrame {
    var isKeyframe: Bool
    /// False if pictures were lost since the previous one.
    var continuous: Bool
    var timestamp: UInt32
    /// Slice NAL units, without start codes or length prefixes.
    var slices: [Data]
}

/// What a WebCodecs decoder needs before the first picture.
struct DecoderConfiguration {
    /// An `hvcC` record (HEVCDecoderConfigurationRecord).
    var record: Data
    var width: Int
    var height: Int

    /// Builds the record from raw VPS/SPS/PPS units by letting CoreMedia write it.
    init?(parameterSets: [Data]) {
        let copies = parameterSets.map { [UInt8]($0) }
        let pointers = copies.map { UnsafeMutablePointer<UInt8>.allocate(capacity: $0.count) }
        defer { pointers.forEach { $0.deallocate() } }
        for (pointer, bytes) in zip(pointers, copies) { pointer.update(from: bytes, count: bytes.count) }

        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: copies.count,
            parameterSetPointers: pointers.map { UnsafePointer($0) }, parameterSetSizes: copies.map(\.count),
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description) == noErr,
            let description else { return nil }
        self.init(format: description)
    }

    init?(format: CMFormatDescription) {
        guard let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
            let record = atoms["hvcC"] as? Data else { return nil }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        self.record = record
        width = Int(size.width)
        height = Int(size.height)
    }
}

/// A source of video for one viewer, and the place its input goes.
/// Callbacks arrive on background threads.
protocol VideoFeed: AnyObject {
    /// State name ("connecting", "authenticating", "negotiating", "streaming",
    /// "closed") and, for "closed", why.
    var onState: ((String, String?) -> Void)? { get set }
    var onConfiguration: ((DecoderConfiguration) -> Void)? { get set }
    var onFrame: ((EncodedFrame) -> Void)? { get set }
    var onCursor: ((CursorImage) -> Void)? { get set }
    /// Size of the space pointer coordinates are expressed in.
    var onPointerSpace: ((Int, Int) -> Void)? { get set }

    func start()
    func stop()
    func pointer(x: Int, y: Int, buttons: UInt8)
    func key(keysym: UInt32, down: Bool)
    func resize(to display: VirtualDisplay)
    func requestKeyframe()
    /// Why no picture may have arrived yet, in a sentence, if the feed can tell.
    func diagnosis() -> String?
}

/// A screen-sharing session with a real Mac.
final class MacFeed: VideoFeed {
    var onState: ((String, String?) -> Void)?
    var onConfiguration: ((DecoderConfiguration) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?
    var onCursor: ((CursorImage) -> Void)?
    var onPointerSpace: ((Int, Int) -> Void)?

    private let session: ScreenShareSession

    init(host: String, username: String, password: String, display: VirtualDisplay?) {
        var configuration = ScreenShareSession.Configuration(
            host: host, username: username, password: password, virtualDisplay: display)
        configuration.drawsCursorLocally = true
        session = ScreenShareSession(configuration: configuration)

        session.onParameterSets = { [weak self] sets in
            guard let configuration = DecoderConfiguration(parameterSets: sets) else {
                print("could not describe the host's video format to the browser")
                return
            }
            self?.onConfiguration?(configuration)
        }
        session.onAccessUnit = { [weak self] unit in
            let slices = unit.sliceUnits
            guard !slices.isEmpty else { return }
            self?.onFrame?(EncodedFrame(
                isKeyframe: unit.isKeyframe, continuous: unit.continuous,
                timestamp: unit.rtpTimestamp, slices: slices))
        }
        session.onCursorChange = { [weak self] in self?.onCursor?($0) }
        session.onLayoutChange = { [weak self] _ in self?.reportPointerSpace() }
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: break
            case .connecting: self.onState?("connecting", nil)
            case .authenticating: self.onState?("authenticating", nil)
            case .negotiating: self.onState?("negotiating", nil)
            case .streaming:
                self.reportPointerSpace()
                self.onState?("streaming", nil)
            case .closed(let reason): self.onState?("closed", reason)
            }
        }
    }

    private func reportPointerSpace() {
        let size = session.pointerSize
        if size.width > 0, size.height > 0 { onPointerSpace?(size.width, size.height) }
    }

    func start() { session.start() }
    func stop() { session.stop() }
    func pointer(x: Int, y: Int, buttons: UInt8) {
        session.sendPointer(x: x, y: y, buttons: PointerButtons(rawValue: buttons))
    }
    func key(keysym: UInt32, down: Bool) { session.sendKey(keysym: keysym, down: down) }
    func resize(to display: VirtualDisplay) { session.resize(to: display) }
    func requestKeyframe() { session.requestKeyframe() }

    func diagnosis() -> String? {
        let stats = session.statistics
        if stats.videoDatagrams == 0 {
            return "No video packets have reached the gateway from the Mac (UDP port 5901). "
                + "A firewall, VPN or router between them may be dropping them."
        }
        if stats.packetsReceived == 0 {
            return "\(stats.videoDatagrams) video packets arrived but none could be decrypted (\(stats.packetsRejected) rejected)."
        }
        if stats.accessUnits == 0 {
            return "\(stats.packetsReceived) video packets arrived but no complete picture was assembled."
        }
        if stats.keyframes == 0 {
            return "\(stats.accessUnits) pictures arrived but no keyframe, after asking the Mac \(stats.keyframeRequests) times."
        }
        return nil
    }
}

/// A locally generated moving picture that echoes the viewer's input, for
/// trying the browser side without a Mac to connect to.
final class TestPatternFeed: VideoFeed {
    var onState: ((String, String?) -> Void)?
    var onConfiguration: ((DecoderConfiguration) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?
    var onCursor: ((CursorImage) -> Void)?
    var onPointerSpace: ((Int, Int) -> Void)?

    private static let framesPerSecond: Int32 = 30
    private let queue = DispatchQueue(label: "ssgateway.testpattern")
    private var timer: DispatchSourceTimer?
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var canvas: CVPixelBuffer?
    private var width: Int
    private var height: Int
    private var frameNumber = 0
    private var wantsKeyframe = true
    private var pointer = (x: 0, y: 0, buttons: UInt8(0))
    private var lastKey = "none yet"
    private var keyCount = 0

    private let formatLock = NSLock()
    private var announcedFormat: CMFormatDescription?

    init(display: VirtualDisplay?) {
        (width, height) = TestPatternFeed.pixelSize(display ?? VirtualDisplay(width: 640, height: 400))
    }

    private static func pixelSize(_ display: VirtualDisplay) -> (Int, Int) {
        (Int(Double(display.width) * display.scale) & ~1, Int(Double(display.height) * display.scale) & ~1)
    }

    func start() {
        queue.async { [self] in
            onState?("connecting", nil)
            guard makeEncoder() else {
                onState?("closed", "this Mac could not start an HEVC encoder for the test pattern")
                return
            }
            onPointerSpace?(width, height)
            onState?("streaming", nil)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(TestPatternFeed.framesPerSecond))
            timer.setEventHandler { [weak self] in self?.encodeNext() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            closeEncoder()
        }
    }

    func pointer(x: Int, y: Int, buttons: UInt8) {
        queue.async { self.pointer = (x, y, buttons) }
    }

    func key(keysym: UInt32, down: Bool) {
        queue.async { [self] in
            if down { keyCount += 1 }
            lastKey = String(format: "0x%04X %@", keysym, down ? "down" : "up")
        }
    }

    func resize(to display: VirtualDisplay) {
        queue.async { [self] in
            let size = TestPatternFeed.pixelSize(display)
            guard size != (width, height), timer != nil else { return }
            closeEncoder()
            (width, height) = size
            guard makeEncoder() else { return }
            onPointerSpace?(width, height)
        }
    }

    func requestKeyframe() {
        queue.async { self.wantsKeyframe = true }
    }

    func diagnosis() -> String? { nil }

    private func closeEncoder() {
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
    }

    private func makeBuffer(_ format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer)
        return buffer
    }

    private func makeEncoder() -> Bool {
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created) == noErr, let created else { return false }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: TestPatternFeed.framesPerSecond as CFNumber)
        encoder = created
        if transfer == nil { VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) }
        canvas = makeBuffer(kCVPixelFormatType_32BGRA)
        wantsKeyframe = true
        return canvas != nil && transfer != nil
    }

    private func encodeNext() {
        // 4:4:4, like the Mac's own stream.
        guard let encoder, let transfer, let canvas,
              let source = makeBuffer(kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange) else { return }
        draw(into: canvas)
        guard VTPixelTransferSessionTransferImage(transfer, from: canvas, to: source) == noErr else { return }
        let properties = wantsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        wantsKeyframe = false
        let rate = TestPatternFeed.framesPerSecond
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: source,
            presentationTimeStamp: CMTime(value: CMTimeValue(frameNumber), timescale: rate),
            duration: CMTime(value: 1, timescale: rate), frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.emit(sample)
        }
        frameNumber += 1
    }

    private func emit(_ sample: CMSampleBuffer) {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return }
        formatLock.lock()
        let changed = announcedFormat.map { !CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? true
        announcedFormat = format
        formatLock.unlock()
        if changed, let configuration = DecoderConfiguration(format: format) { onConfiguration?(configuration) }

        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard !bytes.isEmpty,
              CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == kCMBlockBufferNoErr
        else { return }
        var slices: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            if (bytes[offset] >> 1) & 0x3F < 32 { slices.append(Data(bytes[offset..<offset + length])) }
            offset += length
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let ticks = sample.presentationTimeStamp.value * 90_000 / CMTimeValue(TestPatternFeed.framesPerSecond)
        guard !slices.isEmpty else { return }
        onFrame?(EncodedFrame(isKeyframe: !notSync, continuous: true,
                              timestamp: UInt32(truncatingIfNeeded: ticks), slices: slices))
    }

    private func draw(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        let w = CGFloat(width), h = CGFloat(height)
        let unit = max(min(w, h) / 40, 8)
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

        context.setFillColor(colour(0.11, 0.12, 0.15))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Corner markers show whether the whole picture is visible.
        context.setFillColor(colour(1, 0.8, 0))
        for (x, y) in [(0, 0), (w - unit, 0), (0, h - unit), (w - unit, h - unit)] {
            context.fill(CGRect(x: x, y: y, width: unit, height: unit))
        }
        // A bar that sweeps across once every two seconds.
        let period = CGFloat(TestPatternFeed.framesPerSecond * 2)
        let sweep = CGFloat(frameNumber).truncatingRemainder(dividingBy: period) / period
        context.setFillColor(colour(0.04, 0.52, 1))
        context.fill(CGRect(x: sweep * (w - unit * 2), y: h * 0.12, width: unit * 2, height: unit))

        func text(_ string: String, size: CGFloat, _ fill: CGColor, x: CGFloat, y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        let white = colour(1, 1, 1)
        text("Test pattern", size: unit * 3, white, x: unit * 2, y: h - unit * 6)
        text("\(width) × \(height) pixels, frame \(frameNumber)", size: unit * 1.4, white, x: unit * 2, y: h - unit * 9)
        text("Pointer \(pointer.x), \(pointer.y)   buttons \(pointer.buttons)", size: unit * 1.4,
             colour(0.35, 0.85, 0.9), x: unit * 2, y: h - unit * 12)
        text("Keys pressed \(keyCount)   last \(lastKey)", size: unit * 1.4,
             colour(0.2, 0.78, 0.35), x: unit * 2, y: h - unit * 15)

        // Where the gateway thinks the pointer is; it turns red while a button is held.
        let centre = CGPoint(x: CGFloat(pointer.x), y: h - CGFloat(pointer.y))
        context.setStrokeColor(pointer.buttons == 0 ? white : colour(1, 0.23, 0.19))
        context.setLineWidth(max(unit / 6, 2))
        context.strokeEllipse(in: CGRect(x: centre.x - unit, y: centre.y - unit, width: unit * 2, height: unit * 2))
    }
}

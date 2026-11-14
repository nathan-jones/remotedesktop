import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import ScreenShareKit
import UniformTypeIdentifiers
import VideoToolbox

/// One Screen Sharing session shared by every HomeKit stream and snapshot. It
/// connects when first needed, keeps the latest decoded picture, and disconnects
/// a while after the last user goes away.
final class FrameSource {
    enum Upstream {
        case mac(host: String, username: String, password: String, display: VirtualDisplay?)
        case testPattern
        /// This Mac's own display, through ScreenCaptureKit.
        case localDisplay
    }

    /// How long to stay connected after the last stream or snapshot.
    var linger: TimeInterval = 30
    var alwaysOn = false
    /// Shape of the region the picture is fitted into within each frame; nil uses the whole frame.
    var contentAspect: Double?

    private let upstream: Upstream
    private let queue = DispatchQueue(label: "sscamera.source")
    private var users = 0
    private var stopWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var session: ScreenShareSession?
    private var decoder: HEVCDecoder?
    private var testPattern: TestPattern?
    private var capture: LocalCapture?
    /// Frames from the Mac so far, to notice a session that never delivers any.
    private var framesThisSession = 0
    private var waiters: [(CVPixelBuffer?) -> Void] = []

    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var generation = 0

    init(upstream: Upstream) {
        self.upstream = upstream
    }

    /// The newest picture and a number that changes whenever it does.
    var latest: (buffer: CVPixelBuffer, generation: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return frame.map { ($0, generation) }
    }

    func start() {
        queue.async { [self] in
            if alwaysOn { connect() }
        }
    }

    func acquire() {
        queue.async { [self] in
            users += 1
            stopWork?.cancel()
            stopWork = nil
            connect()
        }
    }

    func release() {
        queue.async { [self] in
            users = max(users - 1, 0)
            guard users == 0, !alwaysOn else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.users == 0 else { return }
                print("Idle; disconnecting from the Mac")
                self.disconnect()
            }
            stopWork = work
            queue.asyncAfter(deadline: .now() + linger, execute: work)
        }
    }

    func requestKeyframe() {
        queue.async { self.session?.requestKeyframe() }
    }

    /// Calls back with the current picture, connecting and waiting for one if needed.
    func nextFrame(timeout: TimeInterval, _ completion: @escaping (CVPixelBuffer?) -> Void) {
        if let current = latest?.buffer { return completion(current) }
        acquire()
        queue.async { [self] in
            var finished = false
            let finish: (CVPixelBuffer?) -> Void = { [weak self] buffer in
                guard !finished else { return }
                finished = true
                completion(buffer)
                self?.release()
            }
            waiters.append(finish)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Connecting

    private func connect() {
        retryWork?.cancel()
        retryWork = nil
        guard session == nil, testPattern == nil, capture == nil else { return }
        framesThisSession = 0
        switch upstream {
        case .localDisplay:
            let capture = LocalCapture()
            capture.onFrame = { [weak self] in self?.received($0) }
            capture.onStopped = { [weak self, weak capture] reason in
                self?.queue.async {
                    guard let self, self.capture === capture else { return }
                    print(reason)
                    self.disconnect()
                }
            }
            capture.start()
            self.capture = capture

        case .testPattern:
            let pattern = TestPattern()
            pattern.onFrame = { [weak self] in self?.received($0) }
            pattern.start()
            testPattern = pattern

        case .mac(let host, let username, let password, let display):
            print("Connecting to \(username)@\(host)")
            let configuration = ScreenShareSession.Configuration(
                host: host, username: username, password: password, virtualDisplay: display)
            let session = ScreenShareSession(configuration: configuration)
            let decoder = HEVCDecoder()
            decoder.onFrame = { [weak self] in self?.received($0) }
            decoder.onNeedsKeyframe = { [weak session] in session?.requestKeyframe() }
            session.onParameterSets = { [weak decoder] sets in
                do { try decoder?.setParameterSets(sets) } catch { print("cannot decode the Mac's video: \(error)") }
            }
            session.onAccessUnit = { [weak decoder] in decoder?.decode($0) }
            session.onStateChange = { [weak self, weak session] state in
                guard let self else { return }
                switch state {
                case .streaming:
                    print("Connected; waiting for the Mac's video")
                    self.queue.asyncAfter(deadline: .now() + 8) {
                        guard self.session === session, self.framesThisSession == 0, let session else { return }
                        print("No video from the Mac after 8 seconds. Its video reaches this machine on UDP "
                            + "ports 5900 and 5901; check that nothing else here uses them (Screen Sharing, the app, "
                            + "ssgateway) and that no firewall drops them. Statistics: \(session.statistics)")
                    }
                case .closed(let reason):
                    self.queue.async {
                        guard self.session === session else { return }
                        print("Mac session ended\(reason.map { ": \($0)" } ?? "")")
                        self.disconnect()
                        self.scheduleRetry()
                    }
                default: break
                }
            }
            self.session = session
            self.decoder = decoder
            session.start()
        }
    }

    private func scheduleRetry() {
        guard users > 0 || alwaysOn else { return }
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func disconnect() {
        session?.stop()
        session = nil
        decoder?.invalidate()
        decoder = nil
        testPattern?.stop()
        testPattern = nil
        capture?.stop()
        capture = nil
        lock.lock()
        frame = nil
        lock.unlock()
        // Nothing is coming; answer pending snapshots now rather than at their timeout.
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(nil) }
    }

    private func received(_ buffer: CVPixelBuffer) {
        lock.lock()
        frame = buffer
        generation += 1
        lock.unlock()
        queue.async { [self] in
            framesThisSession += 1
            if framesThisSession == 1, case .mac = upstream { print("Receiving the Mac's screen") }
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0(buffer) }
        }
    }

    // MARK: Snapshots

    func snapshot(width: Int, height: Int, _ reply: @escaping (Data?) -> Void) {
        let aspect = contentAspect
        nextFrame(timeout: 10) { buffer in
            reply(buffer.flatMap { FrameSource.jpeg(from: $0, width: width, height: height, contentAspect: aspect) })
        }
    }

    /// Scales into a picture of exactly the requested size, letterboxed, and compresses it.
    static func jpeg(from source: CVPixelBuffer, width: Int, height: Int, contentAspect: Double? = nil) -> Data? {
        let width = max(16, min(width, 3840)) & ~1, height = max(16, min(height, 2160)) & ~1
        guard let scaled = Scaler(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA,
                                  contentAspect: contentAspect)?.scale(source)
        else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(scaled, options: nil, imageOut: &image)
        guard let image else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Scales any picture into a fixed size and pixel format, keeping its shape and
/// filling the rest with black. With a content aspect ratio, the picture is fitted
/// into a centred region of that shape instead of the whole frame, for viewers
/// that crop the frame to fill their screen (a square display shows only the
/// middle square of a 16:9 stream).
final class Scaler {
    let width: Int
    let height: Int
    private let session: VTPixelTransferSession
    private var pool: CVPixelBufferPool?
    private let region: Scaler?

    init?(width: Int, height: Int, pixelFormat: OSType, pool: CVPixelBufferPool? = nil, contentAspect: Double? = nil) {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session else { return nil }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        self.width = width
        self.height = height
        self.session = session
        if let contentAspect, contentAspect > 0 {
            // Even sizes keep 4:2:0 chroma aligned.
            let regionWidth = min(width, Int(Double(height) * contentAspect)) & ~1
            let regionHeight = min(height, Int(Double(width) / contentAspect)) & ~1
            if regionWidth < width - 1 || regionHeight < height - 1 {
                region = Scaler(width: regionWidth, height: regionHeight, pixelFormat: pixelFormat)
                guard region != nil else { return nil }
            } else {
                region = nil
            }
        } else {
            region = nil
        }
        if let pool {
            self.pool = pool
        } else {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &self.pool)
        }
        guard self.pool != nil else { return nil }
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var target: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target)
        guard let target else { return nil }
        if let region {
            guard let inner = region.scale(source) else { return nil }
            return Scaler.place(inner, centredIn: target) ? target : nil
        }
        return VTPixelTransferSessionTransferImage(session, from: source, to: target) == noErr ? target : nil
    }

    /// Fills `target` with black and copies `inner` (same pixel format) into its middle.
    private static func place(_ inner: CVPixelBuffer, centredIn target: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(target)
        guard format == CVPixelBufferGetPixelFormatType(inner) else { return false }
        CVPixelBufferLockBaseAddress(target, [])
        CVPixelBufferLockBaseAddress(inner, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(inner, .readOnly)
            CVPixelBufferUnlockBaseAddress(target, [])
        }
        let planar = CVPixelBufferIsPlanar(target)
        let planes = planar ? CVPixelBufferGetPlaneCount(target) : 1
        for plane in 0..<planes {
            func info(_ buffer: CVPixelBuffer) -> (UnsafeMutableRawPointer?, Int, Int, Int) {
                planar ? (CVPixelBufferGetBaseAddressOfPlane(buffer, plane), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane),
                          CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane))
                       : (CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer),
                          CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
            }
            let (outBase, outRow, outWidth, outHeight) = info(target)
            let (inBase, inRow, inWidth, inHeight) = info(inner)
            guard let outBase, let inBase else { return false }
            // Black: video-range luma 16 and neutral chroma 128 for 4:2:0; opaque black for BGRA.
            let bytesPerPixel = planar ? (plane == 0 ? 1 : 2) : 4
            if planar {
                memset(outBase, plane == 0 ? 16 : 128, outRow * outHeight)
            } else {
                var black: [UInt8] = [0, 0, 0, 255]
                memset_pattern4(outBase, &black, outRow * outHeight)
            }
            let x = (outWidth - inWidth) / 2, y = (outHeight - inHeight) / 2
            for row in 0..<min(inHeight, outHeight - y) {
                memcpy(outBase + (y + row) * outRow + x * bytesPerPixel, inBase + row * inRow,
                       min(inWidth, outWidth - x) * bytesPerPixel)
            }
        }
        return true
    }
}

/// A moving picture with a clock, for trying the camera without a Mac to connect to.
final class TestPattern {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "sscamera.testpattern")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameNumber = 0
    private let width = 1440, height = 900

    func start() {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 10)
        timer.setEventHandler { [weak self] in self?.draw() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func draw() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        let w = CGFloat(width), h = CGFloat(height), unit: CGFloat = 24
        context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        for (x, y) in [(0, 0), (w - unit, 0), (0, h - unit), (w - unit, h - unit)] {
            context.fill(CGRect(x: x, y: y, width: unit, height: unit))
        }
        let sweep = CGFloat(frameNumber % 40) / 40
        context.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        context.fill(CGRect(x: sweep * (w - unit * 4), y: h * 0.2, width: unit * 4, height: unit * 2))

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for (text, size, y) in [("sscamera test pattern", unit * 2.5, h - unit * 5),
                                (formatter.string(from: Date()), unit * 5, h / 2)] {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: unit * 2, y: y)
            CTLineDraw(line, context)
        }
        frameNumber += 1
        onFrame?(buffer)
    }
}

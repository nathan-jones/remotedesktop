import CoreMedia
import Foundation
import QuartzCore
import ScreenShareKit
import VideoToolbox

/// What the controller chose for one stream (Selected RTP Stream Configuration).
struct StreamParameters: Equatable {
    var width = 1280
    var height = 720
    var framesPerSecond = 30
    var profile: UInt8 = 1          // 0 constrained baseline, 1 main, 2 high
    var payloadType: UInt8 = 99
    var maxBitrate = 1000           // kbit/s
    var rtcpInterval: Double = 0.5  // seconds
    var mtu = 1378
}

/// SRTP and SRTCP with AES-CM and HMAC-SHA1-80 for one direction-agnostic master
/// key (RFC 3711). HomeKit offers 128- and 256-bit keys, or no encryption.
final class SRTPContext {
    private struct Keys {
        let cipher: Data, auth: Data, salt: Data
    }
    private let rtp: Keys?
    private let rtcp: Keys?

    /// Pass a nil key for unencrypted RTP.
    init(masterKey: Data?, masterSalt: Data) throws {
        guard let masterKey else {
            rtp = nil
            rtcp = nil
            return
        }
        func derive(_ label: UInt8, _ length: Int) throws -> Data {
            var block = [UInt8](masterSalt) + [0, 0]
            block[7] ^= label
            return try Crypto.aesCTR(Data(count: length), key: masterKey, counterBlock: Data(block))
        }
        rtp = Keys(cipher: try derive(0, masterKey.count), auth: try derive(1, 20), salt: try derive(2, 14))
        rtcp = Keys(cipher: try derive(3, masterKey.count), auth: try derive(4, 20), salt: try derive(5, 14))
    }

    private static func counterBlock(_ keys: Keys, ssrc: UInt32, index: UInt64) -> Data {
        var block = [UInt8](keys.salt) + [0, 0]
        for i in 0..<4 { block[4 + i] ^= UInt8(truncatingIfNeeded: ssrc >> UInt32(8 * (3 - i))) }
        for i in 0..<6 { block[8 + i] ^= UInt8(truncatingIfNeeded: index >> UInt64(8 * (5 - i))) }
        return Data(block)
    }

    /// `index` is the 48-bit packet index: rollover counter and sequence number.
    func protectRTP(header: Data, payload: Data, ssrc: UInt32, index: UInt64) -> Data {
        guard let keys = rtp else { return header + payload }
        var packet = header + ((try? Crypto.aesCTR(payload, key: keys.cipher,
                                                   counterBlock: SRTPContext.counterBlock(keys, ssrc: ssrc, index: index))) ?? payload)
        var authenticated = packet
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: index >> 16).bigEndian) { authenticated.append(contentsOf: $0) }
        packet.append(Crypto.hmacSHA1(key: keys.auth, authenticated).prefix(10))
        return packet
    }

    func protectRTCP(_ packet: Data, index: UInt32) -> Data {
        guard let keys = rtcp else { return packet }
        let ssrc = packet[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var out = packet.prefix(8)
        out += (try? Crypto.aesCTR(packet.subdata(in: 8..<packet.count), key: keys.cipher,
                                   counterBlock: SRTPContext.counterBlock(keys, ssrc: ssrc, index: UInt64(index)))) ?? Data()
        withUnsafeBytes(of: (0x8000_0000 | index).bigEndian) { out.append(contentsOf: $0) }
        out.append(Crypto.hmacSHA1(key: keys.auth, out).prefix(10))
        return Data(out)
    }

    /// The plain compound RTCP packet, or nil if it does not authenticate.
    func unprotectRTCP(_ packet: Data) -> Data? {
        let packet = Data(packet)
        guard let keys = rtcp else { return packet }
        guard packet.count >= 8 + 4 + 10 else { return nil }
        let body = packet.prefix(packet.count - 10)
        guard Crypto.hmacSHA1(key: keys.auth, body).prefix(10) == packet.suffix(10) else { return nil }
        let trailer = body.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let encrypted = body.subdata(in: 8..<body.count - 4)
        guard trailer & 0x8000_0000 != 0 else { return packet.prefix(8) + encrypted }
        let ssrc = packet[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let plain = try? Crypto.aesCTR(encrypted, key: keys.cipher, counterBlock: SRTPContext.counterBlock(
            keys, ssrc: ssrc, index: UInt64(trailer & 0x7FFF_FFFF))) else { return nil }
        return packet.prefix(8) + plain
    }
}

/// A UDP socket bound to a local address and connected to the controller.
final class UDPSocket {
    let port: UInt16
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private var closed = false
    private let lock = NSLock()
    var onReceive: ((Data) -> Void)?

    init(localAddress: String, isIPv6: Bool) throws {
        let descriptor = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw StoreError("cannot create a UDP socket") }
        var bound: Int32 = -1
        var storage = sockaddr_storage()
        if isIPv6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            inet_pton(AF_INET, localAddress, &address.sin_addr)
            bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw StoreError("cannot bind a UDP port on \(localAddress)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length) } }
        port = withUnsafePointer(to: &storage) { pointer in
            isIPv6 ? pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                   : pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        var size: Int32 = 1 << 20
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        self.descriptor = descriptor
    }

    deinit { close() }

    /// Connects to the controller's address (with `%interface` for link-local IPv6).
    func connect(to host: String, port: UInt16) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else { return false }
        defer { freeaddrinfo(result) }
        return Darwin.connect(descriptor, result.pointee.ai_addr, result.pointee.ai_addrlen) == 0
    }

    func startReceiving(on queue: DispatchQueue) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = recv(self.descriptor, &buffer, buffer.count, 0)
            if count > 0 { self.onReceive?(Data(buffer[0..<count])) }
        }
        source.resume()
        self.source = source
    }

    func send(_ data: Data) {
        guard !closed else { return }
        _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, data.count, 0) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let source {
            let descriptor = self.descriptor
            source.setCancelHandler { Darwin.close(descriptor) }
            source.cancel()
            self.source = nil
        } else {
            Darwin.close(descriptor)
        }
    }
}

/// One live video stream to a controller: scales the shared picture, encodes it as
/// H.264 and sends it as SRTP, with sender reports and keyframes on request.
final class CameraStream {
    var onTimeout: (() -> Void)?

    private let queue = DispatchQueue(label: "sscamera.stream")
    private let source: FrameSource
    private let socket: UDPSocket
    private let srtp: SRTPContext
    private let ssrc: UInt32
    private var parameters: StreamParameters
    private var encoder: VTCompressionSession?
    private var scaler: Scaler?
    private var timer: DispatchSourceTimer?
    private var reportTimer: DispatchSourceTimer?
    private var lastGeneration = -1
    private var lastEncode: CFTimeInterval = 0
    private var lastHeard = CACurrentMediaTime()
    private var forceKeyframe = true
    private var suspended = false
    private var sequence = UInt64(UInt16.random(in: 0...0x7FFF))
    private var rtcpIndex: UInt32 = 0
    private let timestampOffset = UInt32.random(in: 0...UInt32.max)
    private var lastTimestamp: UInt32 = 0
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0

    init(source: FrameSource, socket: UDPSocket, srtp: SRTPContext, ssrc: UInt32, parameters: StreamParameters) {
        self.source = source
        self.socket = socket
        self.srtp = srtp
        self.ssrc = ssrc
        self.parameters = parameters
    }

    func start() {
        source.acquire()
        socket.onReceive = { [weak self] in self?.receivedControl($0) }
        socket.startReceiving(on: queue)
        queue.async { [self] in
            lastHeard = CACurrentMediaTime()
            configure()
            let reports = DispatchSource.makeTimerSource(queue: queue)
            reports.schedule(deadline: .now() + 0.5, repeating: max(parameters.rtcpInterval, 0.5))
            reports.setEventHandler { [weak self] in self?.sendReport() }
            reports.resume()
            reportTimer = reports
        }
    }

    func reconfigure(_ parameters: StreamParameters) {
        queue.async { [self] in
            guard parameters != self.parameters else { return }
            self.parameters = parameters
            configure()
        }
    }

    func setSuspended(_ suspended: Bool) {
        queue.async { [self] in
            self.suspended = suspended
            if !suspended {
                forceKeyframe = true
                lastHeard = CACurrentMediaTime()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            reportTimer?.cancel()
            reportTimer = nil
            closeEncoder()
            socket.close()
            source.release()
        }
    }

    // MARK: Encoding

    private func configure() {
        closeEncoder()
        let width = parameters.width & ~1, height = parameters.height & ~1
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr, let created else {
            print("cannot start an H.264 encoder for \(width)x\(height)")
            return
        }
        let profile = [kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel,
                       kVTProfileLevel_H264_High_AutoLevel][Int(min(parameters.profile, 2))]
        let bitsPerSecond = max(parameters.maxBitrate, 100) * 1000
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond * 9 / 10 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [bitsPerSecond / 8, 1] as CFArray)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: parameters.framesPerSecond as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        encoder = created
        scaler = Scaler(width: width, height: height, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        pool: VTCompressionSessionGetPixelBufferPool(created), contentAspect: source.contentAspect)
        forceKeyframe = true
        lastGeneration = -1

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(parameters.framesPerSecond, 1)))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        print("Streaming \(width)x\(height) at \(parameters.framesPerSecond) fps, up to \(parameters.maxBitrate) kbit/s")
    }

    private func closeEncoder() {
        timer?.cancel()
        timer = nil
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        scaler = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastHeard > 30 {
            print("No word from the controller for 30 seconds; ending the stream")
            timer?.cancel()
            onTimeout?()
            return
        }
        guard !suspended, let encoder, let scaler, let (frame, generation) = source.latest.map({ ($0.buffer, $0.generation) })
        else { return }
        // A still screen sends nothing new, so repeat the picture now and then
        // to keep the controller's view alive.
        guard generation != lastGeneration || now - lastEncode >= 0.5 else { return }
        guard let scaled = scaler.scale(frame) else { return }
        lastGeneration = generation
        lastEncode = now
        let options = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        let timestamp = timestampOffset &+ UInt32(truncatingIfNeeded: Int64(now * 90_000))
        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: scaled, presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 90_000),
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.queue.async { self?.send(sample, timestamp: timestamp) }
        }
    }

    // MARK: RTP

    private func send(_ sample: CMSampleBuffer, timestamp: UInt32) {
        guard encoder != nil, let block = sample.dataBuffer, let format = sample.formatDescription else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var units: [Data] = []
        if isKeyframe {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    units.append(Data(bytes: pointer, count: size))
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == kCMBlockBufferNoErr
        else { return }
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            units.append(Data(bytes[offset..<offset + length]))
            offset += length
        }

        lastTimestamp = timestamp
        let maximum = max(parameters.mtu, 400) - 12 - 10
        for (unitIndex, unit) in units.enumerated() {
            let lastUnit = unitIndex == units.count - 1
            if unit.count <= maximum {
                sendPacket(unit, marker: lastUnit, timestamp: timestamp)
                continue
            }
            // FU-A fragments (RFC 6184 section 5.8).
            let header = unit[unit.startIndex]
            let indicator = (header & 0xE0) | 28
            var position = unit.startIndex + 1
            while position < unit.endIndex {
                let end = min(position + maximum - 2, unit.endIndex)
                var flags = header & 0x1F
                if position == unit.startIndex + 1 { flags |= 0x80 }
                if end == unit.endIndex { flags |= 0x40 }
                sendPacket(Data([indicator, flags]) + unit[position..<end], marker: lastUnit && end == unit.endIndex,
                           timestamp: timestamp)
                position = end
            }
        }
    }

    private func sendPacket(_ payload: Data, marker: Bool, timestamp: UInt32) {
        var header = Data(count: 12)
        header[0] = 0x80
        header[1] = (marker ? 0x80 : 0) | (parameters.payloadType & 0x7F)
        header[2] = UInt8(truncatingIfNeeded: sequence >> 8)
        header[3] = UInt8(truncatingIfNeeded: sequence)
        for i in 0..<4 {
            header[4 + i] = UInt8(truncatingIfNeeded: timestamp >> UInt32(24 - 8 * i))
            header[8 + i] = UInt8(truncatingIfNeeded: ssrc >> UInt32(24 - 8 * i))
        }
        socket.send(srtp.protectRTP(header: header, payload: payload, ssrc: ssrc, index: sequence))
        sequence += 1
        packetsSent &+= 1
        octetsSent &+= UInt32(payload.count)
    }

    // MARK: RTCP

    private func sendReport() {
        guard packetsSent > 0 else { return }
        let now = Date().timeIntervalSince1970
        var report = Data([0x80, 200, 0, 6])
        for value in [ssrc, UInt32(truncatingIfNeeded: UInt64(now) + 2_208_988_800),
                      UInt32(truncatingIfNeeded: UInt64((now - floor(now)) * 4_294_967_296)),
                      lastTimestamp, packetsSent, octetsSent] {
            withUnsafeBytes(of: value.bigEndian) { report.append(contentsOf: $0) }
        }
        socket.send(srtp.protectRTCP(report, index: rtcpIndex))
        rtcpIndex = (rtcpIndex + 1) & 0x7FFF_FFFF
    }

    private func receivedControl(_ packet: Data) {
        lastHeard = CACurrentMediaTime()
        guard let plain = srtp.unprotectRTCP(packet) else { return }
        var offset = plain.startIndex
        while offset + 4 <= plain.endIndex {
            let first = plain[offset], type = plain[offset + 1]
            let words = Int(plain[offset + 2]) << 8 | Int(plain[offset + 3])
            // Picture loss indication, full intra request, or the old FIR.
            if (type == 206 && (first & 0x1F == 1 || first & 0x1F == 4)) || type == 192 {
                forceKeyframe = true
                lastGeneration = -1
            }
            offset += 4 + words * 4
        }
    }
}

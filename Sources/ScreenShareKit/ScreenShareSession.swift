import Foundation

/// A High Performance screen-sharing session with a Mac.
///
/// `start()` returns immediately; progress, video and errors are reported through
/// the callbacks, which are invoked on background threads.
public final class ScreenShareSession {
    public struct Configuration {
        public var host: String
        public var port: UInt16
        public var username: String
        public var password: String
        /// Ask the host for a virtual display of this size. When nil the host's
        /// physical display is mirrored and stays visible to anyone at the Mac.
        public var virtualDisplay: VirtualDisplay?
        /// Local IPv4 address to bind to; nil lets the system choose.
        public var localAddress: String?
        /// Leave the pointer out of the video and report its shape through
        /// `onCursorChange` instead, so the viewer can draw it without video delay.
        public var drawsCursorLocally = false

        public init(host: String, port: UInt16 = 5900, username: String, password: String,
                    virtualDisplay: VirtualDisplay? = nil, localAddress: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.virtualDisplay = virtualDisplay
            self.localAddress = localAddress
        }
    }

    public enum State: Equatable {
        case idle
        case connecting
        case authenticating
        case negotiating
        case streaming
        case closed(reason: String?)
    }

    public struct Statistics {
        public var packetsReceived = 0
        public var packetsRejected = 0
        public var accessUnits = 0
        public var keyframes = 0
        public var keyframeRequests = 0
        public var canvasWidth = 0
        public var canvasHeight = 0
        /// Raw datagrams seen on each UDP port, before any filtering.
        public var videoDatagrams = 0
        public var controlDatagrams = 0
    }

    public var onStateChange: ((State) -> Void)?
    /// New VPS/SPS/PPS units; always delivered before the access units that need them.
    public var onParameterSets: (([Data]) -> Void)?
    public var onAccessUnit: ((VideoAccessUnit) -> Void)?
    public var onLayoutChange: ((DisplayLayout) -> Void)?
    /// The pointer's shape changed; only called when `drawsCursorLocally` is set.
    public var onCursorChange: ((CursorImage) -> Void)?

    private let configuration: Configuration
    private let offer: MediaOffer
    /// Pointer shapes the host has sent, by its cache identifier.
    private var cursorCache: [UInt32: CursorImage] = [:]
    private let lock = NSLock()
    private let sendQueue = DispatchQueue(label: "screenshare.control.send")

    private var state: State = .idle
    private var stopping = false
    private var stream: TCPStream?
    private var records: RecordLayer?
    private var controlSocket: UDPSocket?
    private var videoSocket: UDPSocket?
    private var controlRemote = sockaddr_in()
    private var videoRemote = sockaddr_in()
    private var feedbackEncryptor: SRTCPSender?
    private var keepaliveEncryptor: SRTPSender?
    private var stats = Statistics()
    private var pointerSpace = (width: 0, height: 0)

    private let answerCondition = NSCondition()
    private var latestAnswer: MediaAnswer?

    // Video receive state; touched only by the video thread.
    private var videoReceiver: SRTPReceiver?
    private var sources: [UInt32: VideoSource] = [:]
    private var activeSource: UInt32?
    private var firstPacketTime: TimeInterval?
    private var parameterSets = HEVCParameterSets()
    private var lastKeyframeRequest: TimeInterval = 0
    private var keyframeRequestCounter: UInt8 = 0
    /// Mirror of `activeSource` readable from other threads.
    private var activeSourceShared: UInt32?
    private var activeSourceHighestSequence: UInt32 = 0
    private var resizePending = false
    /// Set after a resize: the next unseen source replaces the current one at once.
    private var adoptNextNewSource = false
    /// Streams from before a resize; touched only by the video thread.
    private var retiredSources: Set<UInt32> = []

    private final class VideoSource {
        let depacketizer = HEVCDepacketizer()
        var bytes = 0
        var lastPacket: TimeInterval = 0
        /// Access units held back until this source becomes the active one,
        /// starting from its most recent keyframe.
        var backlog: [VideoAccessUnit] = []
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        offer = MediaOffer(hideCursorInVideo: configuration.drawsCursorLocally)
    }

    deinit { stop() }

    // MARK: Public API

    public func start() {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return
        }
        lock.unlock()
        Thread.detachNewThread { [self] in
            do {
                try connect()
            } catch {
                close(reason: (error as? ScreenShareError)?.description ?? error.localizedDescription)
            }
        }
    }

    public func stop() {
        close(reason: nil)
    }

    public var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Size of the coordinate space pointer events are expressed in: the pixel
    /// size of the encoded picture.
    public var pointerSize: (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return pointerSpace
    }

    public func sendPointer(x: Int, y: Int, buttons: PointerButtons) {
        sendControl(ControlMessage.pointerEvent(buttons: buttons, x: x, y: y))
    }

    public func sendKey(keysym: UInt32, down: Bool) {
        sendControl(ControlMessage.keyEvent(keysym: keysym, down: down))
    }

    /// Changes the size of the virtual display mid-session. Only meaningful when
    /// the session was started with one; the new geometry arrives through
    /// `onLayoutChange` and the video restarts at the new size.
    public func resize(to display: VirtualDisplay) {
        guard configuration.virtualDisplay != nil else { return }
        lock.lock()
        resizePending = true
        lock.unlock()
        ScreenShareLog.log("requesting display \(display.width)x\(display.height) points")
        sendControl(ControlMessage.setDisplayConfiguration(display))
        // The host normally announces the new layout first; re-offer regardless if it stays silent.
        sendQueue.asyncAfter(deadline: .now() + 1) { [self] in renegotiateMediaIfPending() }
    }

    /// The host only restarts its encoder at the new size once the media offer is repeated.
    private func renegotiateMediaIfPending() {
        lock.lock()
        let pending = resizePending
        resizePending = false
        if pending { adoptNextNewSource = true }
        lock.unlock()
        guard pending else { return }
        sendControl(offer.message())
        sendControl(ControlMessage.framebufferUpdateRequest(incremental: false))
    }

    /// Asks the host for a fresh keyframe (rate-limited).
    public func requestKeyframe() {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        guard now - lastKeyframeRequest > 0.3, let target = activeSourceShared,
              let encryptor = feedbackEncryptor, let socket = controlSocket else {
            lock.unlock()
            return
        }
        lastKeyframeRequest = now
        keyframeRequestCounter &+= 1
        let counter = keyframeRequestCounter
        stats.keyframeRequests += 1
        let remote = controlRemote
        lock.unlock()

        let packet = RTCP.receiverReport(sender: offer.videoSSRC, sources: [])
            + RTCP.keyframeRequest(sender: offer.videoSSRC, media: target, counter: counter)
        if let protected = try? encryptor.protect(packet) {
            socket.send(protected, to: remote)
        }
    }

    // MARK: Connection

    private func connect() throws {
        setState(.connecting)
        let port = configuration.port
        controlRemote = try resolveIPv4(configuration.host, port: port)
        videoRemote = controlRemote
        videoRemote.sin_port = (port + 1).bigEndian

        // Media sockets must exist before negotiation: the first keyframe is sent
        // within moments of the host accepting the offer, to these same port numbers.
        let control = try UDPSocket(localAddress: configuration.localAddress, port: port)
        let video = try UDPSocket(localAddress: configuration.localAddress, port: port + 1)
        let receiver = try SRTPReceiver(blob: offer.keys.videoFromHost)
        let feedback = try SRTCPSender(blob: offer.keys.videoToHost)
        let keepalive = try SRTPSender(blob: offer.keys.audioToHost, ssrc: offer.audioSSRC)
        lock.lock()
        controlSocket = control
        videoSocket = video
        feedbackEncryptor = feedback
        keepaliveEncryptor = keepalive
        lock.unlock()
        videoReceiver = receiver

        Thread.detachNewThread { [self] in videoLoop(video) }
        Thread.detachNewThread { [self] in drainLoop(control) }
        Thread.detachNewThread { [self] in openFirewallPath(control: control, video: video) }

        var tcp = try TCPStream(remote: controlRemote, localAddress: configuration.localAddress, timeout: 15)
        lock.lock()
        stream = tcp
        lock.unlock()

        setState(.authenticating)
        let wrapKey: Data
        do {
            wrapKey = try Authentication.run(on: tcp, username: configuration.username, password: configuration.password)
        } catch is Authentication.SRPUnavailable {
            // The account has no SRP verifier on this host. The connection is
            // already committed to the other login, so start a fresh one.
            ScreenShareLog.log("retrying with the password login")
            tcp.close()
            tcp = try TCPStream(remote: controlRemote, localAddress: configuration.localAddress, timeout: 15)
            lock.lock()
            stream = tcp
            lock.unlock()
            do {
                wrapKey = try Authentication.run(on: tcp, username: configuration.username,
                                                 password: configuration.password, method: .password)
            } catch is ScreenShareError {
                throw ScreenShareError.authenticationFailed("wrong user name or password")
            }
        }
        ScreenShareLog.log("authenticated")

        setState(.negotiating)
        try tcp.write(ControlMessage.clientInit)
        var serverInit = ByteReader(try tcp.read(24))
        let width = Int(try serverInit.u16())
        let height = Int(try serverInit.u16())
        try serverInit.skip(16)
        _ = try tcp.read(Int(try serverInit.u32()))
        ScreenShareLog.log("host framebuffer \(width)x\(height)")
        lock.lock()
        pointerSpace = (width, height)
        lock.unlock()

        // When someone else is logged in at the Mac, the host asks which session to join.
        if tcp.peek(4, wait: 0.3) == Data([0x00, 0x4A, 0x00, 0x01]) {
            throw ScreenShareError.unsupported("another user is logged in at the Mac; choosing a session is not implemented yet")
        }

        try tcp.write(ControlMessage.viewerInfo() + ControlMessage.beginEncryption())
        Thread.sleep(forTimeInterval: 0.1)
        if let display = configuration.virtualDisplay {
            try tcp.write(ControlMessage.setDisplayConfiguration(display))
        }
        try tcp.write(ControlMessage.setEncodings())

        let layer = try readUntilRekey(tcp, wrapKey: wrapKey)
        lock.lock()
        records = layer
        lock.unlock()
        ScreenShareLog.log("control channel encrypted")

        try tcp.write(ControlMessage.confirmEncryption())
        Thread.sleep(forTimeInterval: 0.2)

        tcp.setReadTimeout(0)
        Thread.detachNewThread { [self] in controlLoop(tcp, layer) }

        let offerMessage = offer.message()
        try layer.send(ControlMessage.setEncodings(), transmit: tcp.write)
        try layer.send(offerMessage, transmit: tcp.write)
        try layer.send(ControlMessage.framebufferUpdateRequest(incremental: false), transmit: tcp.write)
        try layer.send(ControlMessage.autoFramebufferUpdate(width: width, height: height), transmit: tcp.write)

        let answer = try awaitAnswer { try layer.send(offerMessage, transmit: tcp.write) }
        ScreenShareLog.log("host will encode \(answer.canvasWidth)x\(answer.canvasHeight), tile count \(answer.tiles == 0 ? "not stated" : String(answer.tiles))")
        lock.lock()
        stats.canvasWidth = answer.canvasWidth
        stats.canvasHeight = answer.canvasHeight
        pointerSpace = (answer.canvasWidth, answer.canvasHeight)
        lock.unlock()
        if answer.tiles > 1 {
            throw ScreenShareError.unsupported("host insists on \(answer.tiles) video tiles; only single-tile streams are implemented")
        }

        setState(.streaming)
        Thread.detachNewThread { [self] in feedbackLoop() }
    }

    /// Reads the host's plaintext replies until the rectangle that carries the
    /// wrapped session key arrives. Everything after that message is encrypted.
    private func readUntilRekey(_ tcp: TCPStream, wrapKey: Data) throws -> RecordLayer {
        while true {
            let type = try tcp.read(1)[0]
            switch type {
            case 0x14:
                _ = try tcp.read(7)          // status notification
            case 0x00:
                let header = try tcp.read(3)
                let count = Int(header[1]) << 8 | Int(header[2])
                var layer: RecordLayer?
                for _ in 0..<count {
                    var rectangle = ByteReader(try tcp.read(12))
                    let x = Int(try rectangle.u16()), y = Int(try rectangle.u16())
                    let width = Int(try rectangle.u16()), height = Int(try rectangle.u16())
                    let encoding = try rectangle.i32()
                    switch encoding {
                    case Encoding.rekey:
                        layer = try RecordLayer(rekeyBody: try tcp.read(RecordLayer.rekeyBodyLength), wrapKey: wrapKey)
                    case Encoding.cursor:
                        // The host sends the starting pointer shape once, this early.
                        let head = try tcp.read(8)
                        let body = try tcp.read(head.suffix(4).reduce(0) { ($0 << 8) | Int($1) })
                        absorbCursor(x: x, y: y, width: width, height: height, payload: head + body)
                    case 1010, 1011, 1100, 1101, 1105, 1107, 1109, 1110:
                        let length = try tcp.read(2)
                        _ = try tcp.read(Int(length[0]) << 8 | Int(length[1]))
                    default:
                        throw ScreenShareError.protocolViolation("unexpected rectangle encoding \(encoding) before encryption")
                    }
                }
                if let layer { return layer }
            default:
                throw ScreenShareError.protocolViolation("unexpected message type \(type) before encryption (the host may be rate-limiting; wait a few seconds and retry)")
            }
        }
    }

    /// Waits for a usable media answer. If the host's encoder is not ready it
    /// replies with an empty canvas, in which case the offer is simply repeated.
    private func awaitAnswer(resend: () throws -> Void) throws -> MediaAnswer {
        for attempt in 0...16 {
            answerCondition.lock()
            let deadline = Date().addingTimeInterval(5)
            while latestAnswer == nil, !isStopping {
                if !answerCondition.wait(until: deadline) { break }
            }
            let answer = latestAnswer
            latestAnswer = nil
            answerCondition.unlock()

            if isStopping { throw ScreenShareError.network("connection closed during negotiation") }
            guard let answer else { throw ScreenShareError.timeout("host did not answer the media offer") }
            if answer.isUsable { return answer }
            ScreenShareLog.log("host encoder not ready, repeating offer (\(attempt + 1))")
            Thread.sleep(forTimeInterval: 0.2)
            try resend()
        }
        throw ScreenShareError.timeout("host never produced a video canvas")
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func setState(_ new: State) {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        state = new
        lock.unlock()
        onStateChange?(new)
    }

    private func close(reason: String?) {
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        let tcp = stream
        let control = controlSocket
        let video = videoSocket
        state = .closed(reason: reason)
        lock.unlock()

        tcp?.close()
        control?.close()
        video?.close()
        answerCondition.lock()
        answerCondition.broadcast()
        answerCondition.unlock()
        if let reason { ScreenShareLog.log("closed: \(reason)") }
        onStateChange?(.closed(reason: reason))
    }

    // MARK: Control channel

    private func sendControl(_ message: Data) {
        sendQueue.async { [self] in
            lock.lock()
            let layer = records
            let tcp = stream
            let live = state == .streaming
            lock.unlock()
            guard live, let layer, let tcp else { return }
            do {
                try layer.send(message, transmit: tcp.write)
            } catch {
                close(reason: "lost connection to the Mac")
            }
        }
    }

    private func controlLoop(_ tcp: TCPStream, _ layer: RecordLayer) {
        do {
            while !isStopping {
                let prefix = try tcp.read(2)
                let length = Int(prefix[0]) << 8 | Int(prefix[1])
                let message = try layer.open(try tcp.read(length))
                handleControl(message)
            }
        } catch {
            if !isStopping {
                close(reason: (error as? ScreenShareError)?.description ?? error.localizedDescription)
            }
        }
    }

    private func handleControl(_ message: Data) {
        guard let type = message.first, type == 0x00 else { return }

        if let answer = MediaOffer.parseAnswer(in: message) {
            answerCondition.lock()
            latestAnswer = answer
            answerCondition.signal()
            answerCondition.unlock()
        }

        let rectangles = FramebufferUpdate(message: message).rectangles
        for rectangle in rectangles where rectangle.encoding == Encoding.cursor {
            absorbCursor(x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height,
                         payload: rectangle.payload)
        }
        for rectangle in rectangles where rectangle.encoding == Encoding.displayLayout {
            guard let layout = DisplayLayout(payload: rectangle.payload) else { continue }
            ScreenShareLog.log("layout: \(layout.scaledWidth)x\(layout.scaledHeight) points, \(layout.backingWidth)x\(layout.backingHeight) pixels; raw \(Data(rectangle.payload.prefix(120)).hex)")
            lock.lock()
            // Pointer events are addressed in encoded-picture pixels, not points.
            pointerSpace = layout.backingWidth > 0 && layout.backingHeight > 0
                ? (layout.backingWidth, layout.backingHeight)
                : (layout.scaledWidth, layout.scaledHeight)
            lock.unlock()
            onLayoutChange?(layout)
            renegotiateMediaIfPending()
            // A layout change stops the host's unprompted updates; start them again.
            sendControl(ControlMessage.autoFramebufferUpdate(width: layout.backingWidth, height: layout.backingHeight))
            sendControl(ControlMessage.framebufferUpdateRequest(incremental: false))
        }
    }

    /// A cursor rectangle either carries a new shape (stored under an identifier)
    /// or names an earlier one to switch back to. The rectangle's position is the
    /// hotspot and its size the image size.
    private func absorbCursor(x: Int, y: Int, width: Int, height: Int, payload: Data) {
        var reader = ByteReader(payload)
        guard let identifier = try? reader.u32(), let compressedLength = try? reader.u32() else { return }
        let image: CursorImage?
        if compressedLength == 0 {
            image = cursorCache[identifier]   // unknown identifier: keep the current shape
        } else if (1...512).contains(width), (1...512).contains(height),
                  let raw = Zlib.inflateUnfinished(reader.rest(), expectedLength: width * height * 5),
                  let decoded = CursorImage(width: width, height: height, hotspotX: x, hotspotY: y, raw: raw) {
            if cursorCache.count > 256 { cursorCache.removeAll() }
            cursorCache[identifier] = decoded
            ScreenShareLog.log("cursor shape \(identifier): \(width)x\(height), hotspot \(x),\(y)")
            image = decoded
        } else {
            ScreenShareLog.log("unreadable cursor shape \(identifier): \(width)x\(height), \(compressedLength) bytes")
            image = nil
        }
        if let image { onCursorChange?(image) }
    }

    // MARK: Media

    /// Sends tiny datagrams from both media ports so that stateful firewalls and
    /// NATs treat the host's stream as return traffic. Stops once video flows.
    private func openFirewallPath(control: UDPSocket, video: UDPSocket) {
        let probe = Data([0])
        while !isStopping {
            lock.lock()
            let flowing = stats.packetsReceived > 0
            lock.unlock()
            if flowing { return }
            control.send(probe, to: controlRemote)
            video.send(probe, to: videoRemote)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// The control-port socket also receives audio and RTCP; this client ignores
    /// both but keeps the socket drained.
    private func drainLoop(_ socket: UDPSocket) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !isStopping, socket.isOpen {
            guard let count = socket.receive(into: &buffer) else { continue }
            lock.lock()
            stats.controlDatagrams += 1
            let first = stats.controlDatagrams <= 3
            lock.unlock()
            if first {
                ScreenShareLog.log("control-port datagram, \(count) bytes: \(Data(buffer[0..<min(count, 16)]).hex)")
            }
        }
    }

    private func videoLoop(_ socket: UDPSocket) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !isStopping, socket.isOpen {
            guard let count = socket.receive(into: &buffer) else { continue }
            lock.lock()
            stats.videoDatagrams += 1
            let firstDatagrams = stats.videoDatagrams <= 3
            lock.unlock()
            if firstDatagrams {
                ScreenShareLog.log("video-port datagram, \(count) bytes: \(Data(buffer[0..<min(count, 16)]).hex)")
            }
            guard count >= 12 else { continue }
            // RTCP shares the port; its packet types occupy the whole second byte.
            if (192...207).contains(buffer[1]) { continue }
            guard let packet = videoReceiver?.unprotect(Data(buffer[0..<count])) else {
                lock.lock()
                stats.packetsRejected += 1
                let firstRejections = stats.packetsRejected <= 3
                lock.unlock()
                if firstRejections {
                    ScreenShareLog.log("rejected video packet, \(count) bytes: \(Data(buffer[0..<min(count, 16)]).hex)")
                }
                continue
            }
            handleVideo(packet, size: count)
        }
    }

    private func handleVideo(_ packet: RTPPacket, size: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        stats.packetsReceived += 1
        lock.unlock()
        firstPacketTime = firstPacketTime ?? now

        if stats.packetsReceived <= 4 {
            ScreenShareLog.log("video payload \(packet.payload.count) bytes, marker \(packet.marker), ts \(packet.timestamp): \(Data(packet.payload.prefix(96)).hex)")
        }
        if retiredSources.contains(packet.ssrc) { return }
        if sources[packet.ssrc] == nil {
            ScreenShareLog.log(String(format: "video source 0x%08x appeared", packet.ssrc))
            lock.lock()
            let adopt = adoptNextNewSource && activeSource != nil
            if adopt {
                adoptNextNewSource = false
                activeSourceShared = nil
            }
            lock.unlock()
            if adopt {
                // The host restarted its encoder for a new display size.
                retiredSources.formUnion(sources.keys)
                sources.removeAll()
                activeSource = nil
                firstPacketTime = now
            }
            sources[packet.ssrc] = VideoSource()
        }
        let source = sources[packet.ssrc]!
        source.bytes += size
        source.lastPacket = now
        let units = source.depacketizer.add(packet)

        if packet.ssrc == activeSource {
            lock.lock()
            activeSourceHighestSequence = UInt32(truncatingIfNeeded: packet.extendedSequence)
            lock.unlock()
            units.forEach(deliver)
        } else {
            for unit in units {
                if unit.isKeyframe { source.backlog.removeAll() }
                if source.backlog.count < 600 { source.backlog.append(unit) }
            }
            reconsiderActiveSource(now: now)
        }
    }

    /// The host may run more than one video stream. Start with whichever carries
    /// the most data after a short look, and move if the chosen one goes quiet
    /// (which is also what happens when the host restarts its encoder).
    private func reconsiderActiveSource(now: TimeInterval) {
        if let active = activeSource, let current = sources[active] {
            guard now - current.lastPacket > 1.0 else { return }
        } else if let first = firstPacketTime, now - first < 0.25 {
            return
        }
        let candidates = sources.filter { $0.key != activeSource && now - $0.value.lastPacket < 0.5 }
        guard let best = candidates.max(by: { $0.value.bytes < $1.value.bytes }) else { return }

        ScreenShareLog.log(String(format: "using video source 0x%08x", best.key))
        activeSource = best.key
        lock.lock()
        activeSourceShared = best.key
        lock.unlock()
        parameterSets = HEVCParameterSets()
        let backlog = best.value.backlog
        best.value.backlog.removeAll()
        if backlog.first?.isKeyframe != true { requestKeyframe() }
        backlog.forEach(deliver)
    }

    private func deliver(_ unit: VideoAccessUnit) {
        if parameterSets.absorb(unit.nalUnits), parameterSets.isComplete {
            onParameterSets?(parameterSets.all)
        }
        lock.lock()
        stats.accessUnits += 1
        if unit.isKeyframe { stats.keyframes += 1 }
        let early = stats.accessUnits <= 5
        lock.unlock()
        if early {
            let types = unit.nalUnits.map { String(HEVCNAL.type($0)) }.joined(separator: ",")
            ScreenShareLog.log("access unit: NAL types [\(types)], continuous \(unit.continuous), parameter sets complete \(parameterSets.isComplete)")
        }
        // Parameter sets travel with keyframes, so a stream without them needs a new one.
        if !parameterSets.isComplete || (!unit.continuous && !unit.isKeyframe) { requestKeyframe() }
        onAccessUnit?(unit)
    }

    /// Twice a second: a keepalive on the audio stream and a receiver report for
    /// video. Without these the host concludes the viewer has gone away.
    private func feedbackLoop() {
        var tick = 0
        while !isStopping {
            lock.lock()
            let socket = controlSocket
            let feedback = feedbackEncryptor
            let keepalive = keepaliveEncryptor
            let remote = controlRemote
            let source = activeSourceShared
            let highest = activeSourceHighestSequence
            lock.unlock()
            guard let socket, let feedback, let keepalive else { return }

            if let beat = try? keepalive.protect(payload: Data([0x00, 0x68, 0x34, 0x00]), payloadType: 101) {
                socket.send(beat, to: remote)
            }
            var report = RTCP.receiverReport(
                sender: offer.videoSSRC,
                sources: source.map { [(ssrc: $0, highestSequence: highest)] } ?? [])
            if tick % 10 == 0 { report = RTCP.emptySenderReport(sender: offer.videoSSRC) + report }
            if let protected = try? feedback.protect(report) {
                socket.send(protected, to: remote)
            }
            if tick % 4 == 0 {
                let s = statistics
                ScreenShareLog.log("stats: udp video \(s.videoDatagrams) control \(s.controlDatagrams), rtp ok \(s.packetsReceived) rejected \(s.packetsRejected), units \(s.accessUnits) keyframes \(s.keyframes), keyframe requests \(s.keyframeRequests)")
            }
            tick += 1
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

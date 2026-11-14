import Foundation
import Network
import ScreenShareKit

struct GatewayOptions {
    /// nil runs the test pattern instead of connecting to a Mac.
    var mac: (host: String, username: String, password: String)?
    /// Mirror the Mac's physical display rather than creating a virtual one.
    var mirror = false
    var port: UInt16 = 8080
    /// Local address to listen on; nil listens on every interface.
    var listenAddress: String?
    /// Code a browser must present before it is given a session.
    var accessCode = ""
    var verbose = false
}

/// Serves the viewer page over HTTP on `port` and viewers over WebSocket on
/// `port + 1`. One viewer at a time: the session lives exactly as long as its
/// viewer's socket, so the Mac's screen is only taken over while someone watches.
final class Gateway {
    let options: GatewayOptions
    let queue = DispatchQueue(label: "ssgateway")
    private var pageListener: NWListener?
    private var viewerListener: NWListener?
    private var viewer: Viewer?
    private var lastFeedStopped = Date.distantPast

    init(options: GatewayOptions) {
        self.options = options
    }

    func start() throws {
        let page = try listener(port: options.port, webSocket: false)
        page.newConnectionHandler = { [weak self] connection in self?.servePage(connection) }
        page.start(queue: queue)
        pageListener = page

        let viewers = try listener(port: options.port + 1, webSocket: true)
        viewers.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Viewer(connection: connection, gateway: self).start()
        }
        viewers.start(queue: queue)
        viewerListener = viewers
    }

    private func listener(port: UInt16, webSocket: Bool) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = 1 << 16   // viewers only send small JSON messages
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ScreenShareError.unsupported("port \(port) is not usable")
        }
        let listener: NWListener
        if let address = options.listenAddress {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: endpointPort)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("cannot listen on port \(port): \(error)")
                exit(1)
            }
        }
        return listener
    }

    // MARK: Page

    private func servePage(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, received: Data())
    }

    private func readRequest(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, finished, error in
            var received = received
            if let data { received.append(data) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self?.respond(connection, request: received)
            } else if error != nil || finished || received.count > 16384 {
                connection.cancel()
            } else {
                self?.readRequest(connection, received: received)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(1024), as: UTF8.self).components(separatedBy: "\r\n")[0]
        let parts = line.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1].split(separator: "?", omittingEmptySubsequences: false)[0]) : ""
        let found = parts.first == "GET" && (path == "/" || path == "/index.html")
        let body = Data((found ? ViewerPage.html : "Not found").utf8)
        let head = """
            HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r
            Content-Type: \(found ? "text/html" : "text/plain"); charset=utf-8\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Viewers

    /// Makes `newViewer` the one viewer, ending whoever was watching before.
    /// Returns how long to wait before starting its feed, so the previous
    /// session's sockets are free again.
    fileprivate func adopt(_ newViewer: Viewer) -> TimeInterval {
        if let viewer, viewer !== newViewer {
            viewer.close(telling: "Another browser connected to this gateway.")
        }
        viewer = newViewer
        return max(0, 0.5 - Date().timeIntervalSince(lastFeedStopped))
    }

    fileprivate func closed(_ closedViewer: Viewer, hadFeed: Bool) {
        if hadFeed { lastFeedStopped = Date() }
        if viewer === closedViewer { viewer = nil }
    }

    fileprivate func makeFeed(display: VirtualDisplay) -> VideoFeed {
        guard let mac = options.mac else { return TestPatternFeed(display: display) }
        return MacFeed(host: mac.host, username: mac.username, password: mac.password,
                       display: options.mirror ? nil : display)
    }

    /// The virtual display to ask for, given the browser's viewport in points.
    static func display(width: Double, height: Double, pixelRatio: Double) -> VirtualDisplay {
        let width = min(max(width, 100), 4000), height = min(max(height, 100), 4000)
        // The Mac refuses very small displays, so small viewports get a
        // proportionally larger desktop, shown scaled down.
        let factor = max(1, 640 / min(width, height))
        let scaledWidth = width * factor, scaledHeight = height * factor
        // Stay inside the picture sizes the Mac is known to accept.
        let scale = min(min(max(pixelRatio, 1), 3),
                        3840 / max(scaledWidth, scaledHeight), 2160 / min(scaledWidth, scaledHeight))
        return VirtualDisplay(width: Int(scaledWidth) & ~1, height: Int(scaledHeight) & ~1, scale: scale)
    }
}

/// One browser. Everything here runs on the gateway's queue.
private final class Viewer {
    private enum Message {
        static let configuration: UInt8 = 1
        static let frame: UInt8 = 2
        static let cursor: UInt8 = 3
    }

    private let connection: NWConnection
    private let gateway: Gateway
    private var queue: DispatchQueue { gateway.queue }
    private let name: String
    private var feed: VideoFeed?
    private var greeted = false
    private var isClosed = false
    /// Frames handed to the socket that have not been written out yet.
    private var framesInFlight = 0
    /// Pictures are withheld until the next keyframe: at the start, after loss,
    /// and when the browser or the network falls behind.
    private var awaitingKeyframe = true
    /// What has gone to the browser, for explaining a picture that never appears.
    private var sentConfigurations = 0, sentFrames = 0, sentKeyframes = 0
    private var browserShowsVideo = false
    private var browserProblem: String?

    init(connection: NWConnection, gateway: Gateway) {
        self.connection = connection
        self.gateway = gateway
        if case .hostPort(let host, _) = connection.endpoint { name = "\(host)" } else { name = "viewer" }
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        // A socket that never introduces itself is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [self] in if !greeted { close() } }
    }

    private func receive() {
        connection.receiveMessage { [self] data, context, _, error in
            guard error == nil, !isClosed else {
                close()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { handle(object) }
            case .close, nil:
                close()
                return
            default:
                break
            }
            receive()
        }
    }

    // MARK: Messages from the browser

    private func handle(_ message: [String: Any]) {
        func number(_ key: String) -> Double? { (message[key] as? NSNumber)?.doubleValue }
        let type = message["t"] as? String

        guard greeted else {
            guard type == "hello" else { return }
            guard let code = message["code"] as? String, Viewer.matches(code, gateway.options.accessCode) else {
                print("\(name): wrong access code")
                // A short wait slows down guessing.
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    send(["t": "denied"]) { [self] in close() }
                }
                return
            }
            greeted = true
            let display = Gateway.display(width: number("w") ?? 0, height: number("h") ?? 0, pixelRatio: number("dpr") ?? 1)
            print("\(name): connected, viewport \(Int(number("w") ?? 0)) × \(Int(number("h") ?? 0)) points")
            let wait = gateway.adopt(self)
            queue.asyncAfter(deadline: .now() + wait) { [self] in startFeed(display: display) }
            return
        }

        switch type {
        case "p":
            guard let x = number("x"), let y = number("y"), let buttons = number("b"),
                  x.isFinite, y.isFinite else { return }
            feed?.pointer(x: Int(min(max(x, 0), 16384)), y: Int(min(max(y, 0), 16384)), buttons: UInt8(Int(buttons) & 0x1F))
        case "k":
            guard let keysym = number("k"), keysym >= 0, keysym <= Double(UInt32.max),
                  let down = message["d"] as? Bool else { return }
            feed?.key(keysym: UInt32(keysym), down: down)
        case "kf":
            awaitingKeyframe = true
            feed?.requestKeyframe()
        case "resize":
            guard let width = number("w"), let height = number("h") else { return }
            feed?.resize(to: Gateway.display(width: width, height: height, pixelRatio: number("dpr") ?? 1))
        case "first":
            browserShowsVideo = true
        case "log":
            guard let text = message["m"] as? String else { return }
            browserProblem = String(text.prefix(300))
            print("\(name): browser: \(browserProblem!)")
        case "stats":
            browserShowsVideo = true
            if gateway.options.verbose {
                let fields = message.filter { $0.key != "t" }.sorted { $0.key < $1.key }
                print("\(name): " + fields.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
        default:
            break
        }
    }

    private static func matches(_ offered: String, _ expected: String) -> Bool {
        let a = Array(offered.utf8), b = Array(expected.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Feed

    private func startFeed(display: VirtualDisplay) {
        guard !isClosed else { return }
        let feed = gateway.makeFeed(display: display)
        self.feed = feed
        // The feed calls back on its own threads; hop to the gateway's queue,
        // which also keeps configuration and pictures in order.
        feed.onState = { [weak self] state, reason in self?.queue.async { self?.stateChanged(state, reason) } }
        feed.onConfiguration = { [weak self] configuration in self?.queue.async { self?.configure(configuration) } }
        feed.onFrame = { [weak self] frame in self?.queue.async { self?.forward(frame) } }
        feed.onCursor = { [weak self] cursor in self?.queue.async { self?.forward(cursor) } }
        feed.onPointerSpace = { [weak self] width, height in
            self?.queue.async { self?.send(["t": "space", "w": width, "h": height]) }
        }
        feed.start()
    }

    private func stateChanged(_ state: String, _ reason: String?) {
        guard !isClosed else { return }
        if state == "closed" {
            print("\(name): session ended\(reason.map { ": \($0)" } ?? "")")
            close(telling: reason ?? "The Mac ended the session.")
        } else {
            if state == "streaming" {
                print("\(name): streaming")
                checkForVideo(after: 5)
            }
            send(["t": "state", "state": state])
        }
    }

    /// Says, here and on the page, what is missing while no picture is showing.
    private func checkForVideo(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !isClosed, !browserShowsVideo, let feed else { return }
            let text: String
            if sentConfigurations == 0 {
                text = feed.diagnosis() ?? "The gateway has no video format from the Mac yet."
            } else if sentKeyframes == 0 {
                text = feed.diagnosis() ?? "The gateway is still waiting for a keyframe from the Mac."
            } else {
                text = "The gateway sent \(sentFrames) pictures (\(sentKeyframes) keyframes) but the browser has not shown one."
                    + (browserProblem.map { " Browser: \($0)" } ?? "")
            }
            print("\(name): no picture yet. \(text)")
            send(["t": "note", "text": text])
            checkForVideo(after: 10)
        }
    }

    private func configure(_ configuration: DecoderConfiguration) {
        var message = Data([Message.configuration])
        message.append(bigEndian: UInt16(clamping: configuration.width))
        message.append(bigEndian: UInt16(clamping: configuration.height))
        message.append(configuration.record)
        awaitingKeyframe = true
        sentConfigurations += 1
        send(message)
        print("\(name): video is \(configuration.width) × \(configuration.height) pixels")
    }

    private func forward(_ frame: EncodedFrame) {
        guard !isClosed else { return }
        if frame.isKeyframe {
            // A keyframe is large; do not pile it onto a socket that is already far behind.
            guard framesInFlight < 60 else {
                feed?.requestKeyframe()
                return
            }
            awaitingKeyframe = false
        } else if awaitingKeyframe || !frame.continuous || framesInFlight > 30 {
            awaitingKeyframe = true
            feed?.requestKeyframe()
            return
        }

        var message = Data(capacity: 6 + frame.slices.reduce(0) { $0 + $1.count + 4 })
        message.append(Message.frame)
        message.append(frame.isKeyframe ? 1 : 0)
        message.append(bigEndian: frame.timestamp)
        for slice in frame.slices {
            message.append(bigEndian: UInt32(slice.count))
            message.append(slice)
        }
        framesInFlight += 1
        sentFrames += 1
        if frame.isKeyframe { sentKeyframes += 1 }
        send(message) { [self] in framesInFlight -= 1 }
    }

    private func forward(_ cursor: CursorImage) {
        var message = Data([Message.cursor])
        for value in [cursor.width, cursor.height, cursor.hotspotX, cursor.hotspotY] {
            message.append(bigEndian: UInt16(clamping: value))
        }
        message.append(cursor.rgba)
        send(message)
    }

    // MARK: Socket

    private func send(_ object: [String: Any], then: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data, opcode: .text, then: then)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode = .binary, then: (() -> Void)? = nil) {
        guard !isClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in then?() })
    }

    /// Tells the browser why, then closes.
    func close(telling reason: String) {
        guard !isClosed else { return }
        send(["t": "closed", "reason": reason]) { [self] in close() }
        // Do not wait for a browser that has stopped reading.
        queue.asyncAfter(deadline: .now() + 2) { [self] in close() }
        stopFeed()
    }

    private func stopFeed() {
        guard let feed else { return }
        self.feed = nil
        feed.onState = nil
        feed.onFrame = nil
        feed.onConfiguration = nil
        feed.onCursor = nil
        feed.onPointerSpace = nil
        feed.stop()
        gateway.closed(self, hadFeed: true)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if greeted { print("\(name): disconnected") }
        stopFeed()
        gateway.closed(self, hadFeed: false)
        connection.cancel()
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

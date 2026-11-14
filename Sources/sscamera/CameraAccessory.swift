import Foundation

/// A HomeKit IP camera whose picture is the Mac's screen. It has the accessory
/// information services and one or more Camera RTP Stream Management services,
/// each able to carry one stream at a time.
final class CameraAccessory: HAPAccessory {
    private let name: String
    private let serial: String
    private let source: FrameSource
    private weak var server: HAPServer?
    private let streams: [StreamService]

    private enum IID {
        static let information = 1, identify = 2, manufacturer = 3, model = 4, name = 5, serial = 6, firmware = 7
        static let protocolInformation = 8, version = 9
        static let firstStreamService = 10, perStreamService = 10
    }

    init(name: String, serial: String, source: FrameSource, server: HAPServer, streamCount: Int) {
        self.name = name
        self.serial = serial
        self.source = source
        self.server = server
        streams = (0..<streamCount).map {
            StreamService(base: IID.firstStreamService + $0 * IID.perStreamService, source: source, server: server)
        }
    }

    static let model = "Screen Camera"

    var database: [[String: Any]] {
        func characteristic(_ iid: Int, _ type: String, _ format: String, _ perms: [String], _ value: Any? = nil,
                            extra: [String: Any] = [:]) -> [String: Any] {
            var item: [String: Any] = ["iid": iid, "type": type, "format": format, "perms": perms]
            // Every readable characteristic must carry its value.
            if perms.contains("pr") { item["value"] = value ?? "" }
            return item.merging(extra) { $1 }
        }
        var services: [[String: Any]] = [
            ["iid": IID.information, "type": "3E", "characteristics": [
                characteristic(IID.identify, "14", "bool", ["pw"]),
                characteristic(IID.manufacturer, "20", "string", ["pr"], "Remote Desktop"),
                characteristic(IID.model, "21", "string", ["pr"], CameraAccessory.model),
                characteristic(IID.name, "23", "string", ["pr"], name),
                characteristic(IID.serial, "30", "string", ["pr"], serial),
                characteristic(IID.firmware, "52", "string", ["pr"], "1.0.0"),
            ]],
            ["iid": IID.protocolInformation, "type": "A2", "characteristics": [
                characteristic(IID.version, "37", "string", ["pr"], "1.1.0"),
            ]],
        ]
        for stream in streams {
            services.append(["iid": stream.base, "type": "110", "primary": stream === streams.first,
                             "characteristics": stream.characteristics.map {
                                 characteristic($0.iid, $0.type, $0.format, $0.perms, $0.value, extra: $0.extra)
                             }])
        }
        return [["aid": 1, "services": services]]
    }

    private func stream(for iid: Int) -> StreamService? {
        streams.first { iid > $0.base && iid < $0.base + IID.perStreamService }
    }

    func supportsEvents(iid: Int) -> Bool {
        stream(for: iid)?.characteristics.first { $0.iid == iid }?.perms.contains("ev") ?? false
    }

    func read(iid: Int, connection: Int) -> Result<Any, HAPStatus> {
        switch iid {
        case IID.identify: return .failure(.writeOnly)
        case IID.manufacturer: return .success("Remote Desktop")
        case IID.model: return .success(CameraAccessory.model)
        case IID.name: return .success(name)
        case IID.serial: return .success(serial)
        case IID.firmware: return .success("1.0.0")
        case IID.version: return .success("1.1.0")
        default:
            guard let stream = stream(for: iid) else { return .failure(.notFound) }
            return stream.read(iid: iid, connection: connection)
        }
    }

    func write(iid: Int, value: Any, connection: Int) -> HAPStatus? {
        if iid == IID.identify {
            identify()
            return nil
        }
        guard let stream = stream(for: iid) else { return .readOnly }
        return stream.write(iid: iid, value: value, connection: connection)
    }

    func snapshot(width: Int, height: Int, reply: @escaping (Data?) -> Void) {
        source.snapshot(width: width, height: height, reply)
    }

    func identify() {
        print("Identify: \(name) was asked to identify itself")
    }

    func connectionClosed(_ connection: Int) {
        streams.forEach { $0.connectionClosed(connection) }
    }
}

/// One Camera RTP Stream Management service.
final class StreamService {
    struct Characteristic {
        let iid: Int, type: String, format: String, perms: [String]
        var value: Any?
        var extra: [String: Any] = [:]
    }

    let base: Int
    private let source: FrameSource
    private weak var server: HAPServer?

    private var setupIID: Int { base + 6 }
    private var selectedIID: Int { base + 4 }
    private var statusIID: Int { base + 5 }
    private var activeIID: Int { base + 7 }

    private struct Pending {
        var sessionID: Data
        var socket: UDPSocket
        var srtp: SRTPContext
        var ssrc: UInt32
        var response: Data
    }

    private var pending: [Int: Pending] = [:]         // by connection
    private var lastSetupResponse: [Int: Data] = [:]  // by connection
    private var current: (sessionID: Data, stream: CameraStream)?
    private var selected = Data()
    private var active: UInt8 = 1

    init(base: Int, source: FrameSource, server: HAPServer) {
        self.base = base
        self.source = source
        self.server = server
    }

    var characteristics: [Characteristic] {
        [
            Characteristic(iid: base + 1, type: "114", format: "tlv8", perms: ["pr"], value: StreamService.videoConfiguration.base64EncodedString()),
            Characteristic(iid: base + 2, type: "115", format: "tlv8", perms: ["pr"], value: StreamService.audioConfiguration.base64EncodedString()),
            Characteristic(iid: base + 3, type: "116", format: "tlv8", perms: ["pr"], value: StreamService.rtpConfiguration.base64EncodedString()),
            Characteristic(iid: selectedIID, type: "117", format: "tlv8", perms: ["pr", "pw"], value: selected.base64EncodedString()),
            Characteristic(iid: statusIID, type: "120", format: "tlv8", perms: ["pr", "ev"], value: status),
            Characteristic(iid: setupIID, type: "118", format: "tlv8", perms: ["pr", "pw"], value: ""),
            Characteristic(iid: activeIID, type: "B0", format: "uint8", perms: ["pr", "pw", "ev"], value: Int(active),
                           extra: ["minValue": 0, "maxValue": 1, "minStep": 1]),
        ]
    }

    private var status: String {
        TLV8([(1, Data([current == nil ? 0 : 1]))]).encoded.base64EncodedString()
    }

    func read(iid: Int, connection: Int) -> Result<Any, HAPStatus> {
        switch iid {
        case base + 1: return .success(StreamService.videoConfiguration.base64EncodedString())
        case base + 2: return .success(StreamService.audioConfiguration.base64EncodedString())
        case base + 3: return .success(StreamService.rtpConfiguration.base64EncodedString())
        case selectedIID: return .success(selected.base64EncodedString())
        case statusIID: return .success(status)
        case setupIID: return .success((lastSetupResponse[connection] ?? Data()).base64EncodedString())
        case activeIID: return .success(Int(active))
        default: return .failure(.notFound)
        }
    }

    func write(iid: Int, value: Any, connection: Int) -> HAPStatus? {
        switch iid {
        case activeIID:
            guard let number = (value as? NSNumber)?.intValue, number == 0 || number == 1 else { return .invalidValue }
            active = UInt8(number)
            if active == 0 { endStream() }
            server?.notify(iid: activeIID, value: number, except: connection)
            return nil
        case setupIID:
            guard let data = (value as? String).flatMap({ Data(base64Encoded: $0) }), let tlv = TLV8(decoding: data) else {
                return .invalidValue
            }
            return setUpEndpoints(tlv, connection: connection)
        case selectedIID:
            guard let data = (value as? String).flatMap({ Data(base64Encoded: $0) }), let tlv = TLV8(decoding: data) else {
                return .invalidValue
            }
            selected = data
            return select(tlv, connection: connection)
        default:
            return .readOnly
        }
    }

    func connectionClosed(_ connection: Int) {
        pending.removeValue(forKey: connection)?.socket.close()
        lastSetupResponse.removeValue(forKey: connection)
    }

    // MARK: Setup Endpoints

    private func setUpEndpoints(_ request: TLV8, connection: Int) -> HAPStatus? {
        guard let sessionID = request[1], let address = request.nested(3), let videoSRTP = request.nested(4),
              let controllerIP = address[2].map({ String(decoding: $0, as: UTF8.self) }),
              let videoPort = address.integer(3, as: UInt16.self) else { return .invalidValue }
        let isIPv6 = address.byte(1) == 1

        func respond(_ status: UInt8, local: (String, UInt16)? = nil, ssrc: UInt32 = 0) -> Data {
            var reply = TLV8()
            reply.append(1, sessionID)
            reply.append(2, status)
            var accessoryAddress = TLV8()
            accessoryAddress.append(1, isIPv6 ? 1 : 0)
            accessoryAddress.append(2, local?.0 ?? "")
            accessoryAddress.append(3, littleEndian: local?.1 ?? 0)
            accessoryAddress.append(4, littleEndian: local?.1 ?? 0)
            reply.append(3, accessoryAddress)
            reply.append(4, videoSRTP.encoded)
            reply.append(5, request[5] ?? videoSRTP.encoded)
            reply.append(6, littleEndian: ssrc)
            reply.append(7, littleEndian: ssrc &+ 1)
            return reply.encoded
        }

        pending.removeValue(forKey: connection)?.socket.close()
        if current != nil {
            lastSetupResponse[connection] = respond(1)
            return nil
        }
        do {
            guard let server, let local = server.localAddress(of: connection), local.isIPv6 == isIPv6 else {
                throw StoreError("the controller's address family does not match its connection")
            }
            let socket = try UDPSocket(localAddress: local.address, isIPv6: isIPv6)
            var target = controllerIP
            if isIPv6, controllerIP.lowercased().hasPrefix("fe80"), !controllerIP.contains("%"),
               let interface = server.interfaceName(of: connection) {
                target += "%\(interface)"
            }
            guard socket.connect(to: target, port: videoPort) else { throw StoreError("cannot reach \(target):\(videoPort)") }
            let suite = videoSRTP.byte(1) ?? 0
            let srtp = try SRTPContext(masterKey: suite == 2 ? nil : videoSRTP[2], masterSalt: videoSRTP[3] ?? Data(count: 14))
            let ssrc = UInt32.random(in: 1...UInt32.max - 1)
            let response = respond(0, local: (local.address, socket.port), ssrc: ssrc)
            pending[connection] = Pending(sessionID: sessionID, socket: socket, srtp: srtp, ssrc: ssrc, response: response)
            lastSetupResponse[connection] = response
            server.log("stream endpoint \(local.address):\(socket.port) → \(target):\(videoPort)")
        } catch {
            print("cannot set up a stream: \(error)")
            lastSetupResponse[connection] = respond(2)
        }
        return nil
    }

    // MARK: Selected RTP Stream Configuration

    private func select(_ request: TLV8, connection: Int) -> HAPStatus? {
        guard let control = request.nested(1), let sessionID = control[1], let command = control.byte(2) else {
            return .invalidValue
        }
        switch command {
        case 0:  // end
            if current?.sessionID == sessionID { endStream() }
        case 1:  // start
            guard current == nil else { return .busy }
            guard active == 1, let entry = pending.first(where: { $0.value.sessionID == sessionID }) else { return .invalidValue }
            pending.removeValue(forKey: entry.key)
            let stream = CameraStream(source: source, socket: entry.value.socket, srtp: entry.value.srtp,
                                      ssrc: entry.value.ssrc, parameters: StreamService.parameters(request))
            stream.onTimeout = { [weak self, weak stream] in
                self?.server?.queue.async {
                    guard let self, let stream, self.current?.stream === stream else { return }
                    self.endStream()
                }
            }
            current = (sessionID, stream)
            stream.start()
            server?.notify(iid: statusIID, value: status)
        case 2:  // suspend
            if current?.sessionID == sessionID { current?.stream.setSuspended(true) }
        case 3:  // resume
            if current?.sessionID == sessionID { current?.stream.setSuspended(false) }
        case 4:  // reconfigure
            if current?.sessionID == sessionID { current?.stream.reconfigure(StreamService.parameters(request)) }
        default:
            return .invalidValue
        }
        return nil
    }

    private func endStream() {
        guard let current else { return }
        current.stream.stop()
        self.current = nil
        print("Stream ended")
        server?.notify(iid: statusIID, value: status)
    }

    static func parameters(_ request: TLV8) -> StreamParameters {
        var parameters = StreamParameters()
        guard let video = request.nested(2) else { return parameters }
        if let codec = video.nested(2), let profile = codec.byte(1) { parameters.profile = profile }
        if let attributes = video.nested(3) {
            parameters.width = Int(attributes.integer(1, as: UInt16.self) ?? 1280)
            parameters.height = Int(attributes.integer(2, as: UInt16.self) ?? 720)
            parameters.framesPerSecond = Int(attributes.byte(3) ?? 30)
        }
        if let rtp = video.nested(4) {
            parameters.payloadType = rtp.byte(1) ?? 99
            parameters.maxBitrate = Int(rtp.integer(3, as: UInt16.self) ?? 1000)
            if let interval = rtp[4], interval.count == 4 {
                let bits = interval.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                parameters.rtcpInterval = Double(Float(bitPattern: bits))
            }
            if let mtu = rtp.integer(5, as: UInt16.self), mtu > 0 { parameters.mtu = Int(mtu) }
        }
        return parameters
    }

    // MARK: Supported configurations

    /// H.264 in every profile HomeKit knows, at the sizes HomeKit requires of
    /// every camera (320x240 at 15 fps is the Apple Watch's).
    static let videoConfiguration: Data = {
        var codec = TLV8()
        codec.append(1, 0)  // H.264
        var codecParameters = TLV8()
        for profile: UInt8 in [0, 1, 2] { codecParameters.append(1, profile) }
        for level: UInt8 in [0, 1, 2] { codecParameters.append(2, level) }
        codecParameters.append(3, 0)  // non-interleaved packetization
        codec.append(2, codecParameters)
        let sizes: [(UInt16, UInt16, UInt8)] = [
            (1920, 1080, 30), (1280, 720, 30), (640, 360, 30), (480, 270, 30), (320, 180, 30),
            (1280, 960, 30), (1024, 768, 30), (640, 480, 30), (480, 360, 30), (320, 240, 15),
        ]
        for (width, height, rate) in sizes {
            var attributes = TLV8()
            attributes.append(1, littleEndian: width)
            attributes.append(2, littleEndian: height)
            attributes.append(3, rate)
            codec.append(3, attributes)
        }
        return TLV8([(1, codec.encoded)]).encoded
    }()

    /// Audio codecs are offered because controllers expect some, but no audio is sent.
    static let audioConfiguration: Data = {
        var configuration = TLV8()
        for (index, (type, rate)) in [(UInt8(3), UInt8(1)), (3, 2), (2, 1)].enumerated() {  // Opus 16/24 kHz, AAC-ELD 16 kHz
            if index > 0 { configuration.separator() }
            var codecParameters = TLV8()
            codecParameters.append(1, 1)      // mono
            codecParameters.append(2, 0)      // variable bit rate
            codecParameters.append(3, rate)
            var codec = TLV8()
            codec.append(1, type)
            codec.append(2, codecParameters)
            configuration.append(1, codec)
        }
        configuration.append(2, 0)  // no comfort noise
        return configuration.encoded
    }()

    /// AES-128 counter mode with HMAC-SHA1-80, which every controller supports.
    static let rtpConfiguration = TLV8([(2, Data([0]))]).encoded
}

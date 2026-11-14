import CryptoKit
import Foundation
import Network
import ScreenShareKit

/// What the server needs from the accessory it publishes. Every call arrives on
/// the server's queue, and replies may be given later from any thread.
protocol HAPAccessory: AnyObject {
    /// The `accessories` array of the attribute database.
    var database: [[String: Any]] { get }
    /// Whether the characteristic can send events.
    func supportsEvents(iid: Int) -> Bool
    /// The value to report, or a HAP status code if it cannot be read.
    func read(iid: Int, connection: Int) -> Result<Any, HAPStatus>
    func write(iid: Int, value: Any, connection: Int) -> HAPStatus?
    /// A JPEG of at most the given size, or nil.
    func snapshot(width: Int, height: Int, reply: @escaping (Data?) -> Void)
    func identify()
    func connectionClosed(_ connection: Int)
}

struct HAPStatus: Error {
    let code: Int
    static let busy = HAPStatus(code: -70403)
    static let readOnly = HAPStatus(code: -70404)
    static let writeOnly = HAPStatus(code: -70405)
    static let noNotification = HAPStatus(code: -70406)
    static let unavailable = HAPStatus(code: -70402)
    static let notFound = HAPStatus(code: -70409)
    static let invalidValue = HAPStatus(code: -70410)
}

private enum TLVType {
    static let method: UInt8 = 0x00, identifier: UInt8 = 0x01, salt: UInt8 = 0x02, publicKey: UInt8 = 0x03
    static let proof: UInt8 = 0x04, encryptedData: UInt8 = 0x05, state: UInt8 = 0x06, error: UInt8 = 0x07
    static let signature: UInt8 = 0x0A, permissions: UInt8 = 0x0B
}

private enum PairingError {
    static let unknown: UInt8 = 1, authentication: UInt8 = 2, maxTries: UInt8 = 5
    static let unavailable: UInt8 = 6, busy: UInt8 = 7
}

final class HAPServer {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var contentType: String?
        var body: Data

        static func tlv(_ tlv: TLV8) -> Response {
            Response(status: 200, contentType: "application/pairing+tlv8", body: tlv.encoded)
        }
        static func json(_ object: Any, status: Int = 200) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
            return Response(status: status, contentType: "application/hap+json", body: body)
        }
        static func empty(_ status: Int) -> Response { Response(status: status, contentType: nil, body: Data()) }
    }

    let queue = DispatchQueue(label: "sscamera.hap")
    let store: AccessoryStore
    weak var accessory: HAPAccessory?
    private let name: String
    private let model: String
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1
    private var pairSetup: (owner: Int, srp: SRPServer, sessionKey: Data?)?
    private var failedSetupAttempts = 0
    var verbose = false

    init(store: AccessoryStore, name: String, model: String, port: UInt16) {
        self.store = store
        self.name = name
        self.model = model
        self.port = port
    }

    func start(onReady: @escaping (UInt16) -> Void, onFailure: @escaping (Error) -> Void) throws {
        if let accessory {
            let data = try JSONSerialization.data(withJSONObject: accessory.database, options: [.sortedKeys])
            try store.noteDatabase(data)
        }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.service = service()
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady(listener.port?.rawValue ?? 0)
            case .failed(let error): onFailure(error)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func service() -> NWListener.Service {
        let txt = NWTXTRecord([
            "c#": String(store.configurationNumber), "ff": "0", "id": store.deviceID, "md": model,
            "pv": "1.1", "s#": "1", "sf": store.isPaired ? "0" : "1", "ci": "17",
        ])
        return NWListener.Service(name: name, type: "_hap._tcp", domain: nil, txtRecord: txt)
    }

    /// Re-advertises after the pairing state changes, so controllers notice.
    private func updateService() {
        listener?.service = service()
    }

    func log(_ message: @autoclosure () -> String) {
        if verbose { print("[hap] \(message())") }
    }

    // MARK: Connections

    private final class Connection {
        let id: Int
        let link: NWConnection
        /// Bytes received in the clear: before pair-verify finishes, plaintext; after, ciphertext.
        var received = Data()
        var plaintext = Data()
        var readKey: SymmetricKey?    // accessory to controller
        var writeKey: SymmetricKey?   // controller to accessory
        var readCounter: UInt64 = 0
        var writeCounter: UInt64 = 0
        var controllerID: String?
        var verify: (secret: Curve25519.KeyAgreement.PrivateKey, controllerKey: Data, shared: Data)?
        var subscriptions: Set<Int> = []
        var handling = false
        /// Work that must wait until the current response has gone out in the clear.
        var afterResponse: (() -> Void)?

        init(id: Int, link: NWConnection) {
            self.id = id
            self.link = link
        }

        var isSecure: Bool { readKey != nil }
        var remoteHost: String {
            if case .hostPort(let host, _) = link.endpoint { return "\(host)" }
            return "?"
        }
    }

    private func accept(_ link: NWConnection) {
        let connection = Connection(id: nextConnectionID, link: link)
        nextConnectionID += 1
        connections[connection.id] = connection
        log("connection \(connection.id) from \(connection.remoteHost)")
        link.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection)
            default: break
            }
        }
        link.start(queue: queue)
        receive(connection)
    }

    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        log("connection \(connection.id) closed")
        connection.link.cancel()
        if pairSetup?.owner == connection.id { pairSetup = nil }
        accessory?.connectionClosed(connection.id)
    }

    private func receive(_ connection: Connection) {
        connection.link.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if connection.isSecure {
                    connection.received.append(data)
                    guard self.decryptFrames(connection) else { return self.drop(connection) }
                } else {
                    connection.plaintext.append(data)
                }
                self.processRequests(connection)
            }
            if complete || error != nil { return self.drop(connection) }
            self.receive(connection)
        }
    }

    private func decryptFrames(_ connection: Connection) -> Bool {
        guard let key = connection.writeKey else { return false }
        while connection.received.count >= 2 {
            let start = connection.received.startIndex
            let length = Int(connection.received[start]) | Int(connection.received[start + 1]) << 8
            guard length <= 1024 else { return false }
            guard connection.received.count >= 2 + length + 16 else { break }
            let aad = connection.received.prefix(2)
            let sealed = connection.received.subdata(in: start + 2..<start + 2 + length + 16)
            guard let opened = HAPCrypto.open(sealed, key: key, nonce: HAPCrypto.nonce(connection.writeCounter), aad: Data(aad))
            else { return false }
            connection.writeCounter += 1
            connection.plaintext.append(opened)
            connection.received = Data(connection.received.dropFirst(2 + length + 16))
        }
        return true
    }

    /// Handles one complete request at a time, in order; replies may be asynchronous.
    private func processRequests(_ connection: Connection) {
        while !connection.handling, let request = takeRequest(connection) {
            connection.handling = true
            log("\(connection.id) → \(request.method) \(request.path)")
            handle(request, on: connection) { [weak self] response in
                self?.queue.async {
                    guard let self, self.connections[connection.id] != nil else { return }
                    self.send(response, on: connection)
                    connection.handling = false
                    let after = connection.afterResponse
                    connection.afterResponse = nil
                    after?()
                    self.processRequests(connection)
                }
            }
        }
    }

    private func takeRequest(_ connection: Connection) -> Request? {
        let buffer = connection.plaintext
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard buffer.count - (headerEnd.upperBound - buffer.startIndex) >= length else { return nil }
        let body = buffer.subdata(in: headerEnd.upperBound..<headerEnd.upperBound + length)
        connection.plaintext = Data(buffer[(headerEnd.upperBound + length)...])

        guard requestLine.count >= 2 else { return Request(method: "", path: "", query: [:], body: body) }
        let target = String(requestLine[1])
        let pieces = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count == 2 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            }
        }
        return Request(method: String(requestLine[0]), path: String(pieces[0]), query: query, body: body)
    }

    private func send(_ response: Response, on connection: Connection) {
        let reason = [200: "OK", 204: "No Content", 207: "Multi-Status", 400: "Bad Request", 404: "Not Found",
                      405: "Method Not Allowed", 470: "Connection Authorization Required", 500: "Internal Server Error",
                      503: "Service Unavailable"][response.status] ?? "Status"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        if let type = response.contentType { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        log("\(connection.id) ← \(response.status) \(response.body.count) bytes")
        write(Data(head.utf8) + response.body, to: connection)
    }

    private func write(_ data: Data, to connection: Connection) {
        guard let key = connection.readKey else {
            connection.link.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        var out = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + 1024, data.endIndex)
            let length = UInt16(end - offset)
            let aad = Data([UInt8(length & 0xFF), UInt8(length >> 8)])
            out += aad + HAPCrypto.seal(data.subdata(in: offset..<end), key: key,
                                        nonce: HAPCrypto.nonce(connection.readCounter), aad: aad)
            connection.readCounter += 1
            offset = end
        }
        connection.link.send(content: out, completion: .contentProcessed { _ in })
    }

    /// Tells every subscribed connection except `except` that a value changed.
    func notify(iid: Int, value: Any, except: Int? = nil) {
        queue.async { [self] in
            let item: [String: Any] = ["aid": 1, "iid": iid, "value": value]
            guard let body = try? JSONSerialization.data(withJSONObject: ["characteristics": [item]],
                                                         options: [.withoutEscapingSlashes]) else { return }
            let head = "EVENT/1.0 200 OK\r\nContent-Type: application/hap+json\r\nContent-Length: \(body.count)\r\n\r\n"
            for connection in connections.values where connection.isSecure && connection.id != except
                && connection.subscriptions.contains(iid) {
                write(Data(head.utf8) + body, to: connection)
            }
        }
    }

    // MARK: Routing

    private func handle(_ request: Request, on connection: Connection, reply: @escaping (Response) -> Void) {
        switch (request.method, request.path) {
        case ("POST", "/pair-setup"): reply(pairSetup(request.body, connection))
        case ("POST", "/pair-verify"): reply(pairVerify(request.body, connection))
        case ("POST", "/identify"):
            if store.isPaired { return reply(.json(["status": HAPStatus.readOnly.code], status: 400)) }
            accessory?.identify()
            reply(.empty(204))
        case (_, _) where !connection.isSecure:
            reply(.json(["status": -70401], status: 470))
        case ("GET", "/accessories"):
            reply(.json(["accessories": accessory?.database ?? []]))
        case ("GET", "/characteristics"): reply(readCharacteristics(request, connection))
        case ("PUT", "/characteristics"): reply(writeCharacteristics(request, connection))
        case ("POST", "/pairings"): reply(pairings(request.body, connection))
        case ("POST", "/resource"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["resource-type"] as? String == "image", let accessory else { return reply(.empty(400)) }
            let width = (object["image-width"] as? NSNumber)?.intValue ?? 640
            let height = (object["image-height"] as? NSNumber)?.intValue ?? 360
            accessory.snapshot(width: width, height: height) { jpeg in
                reply(jpeg.map { Response(status: 200, contentType: "image/jpeg", body: $0) }
                      ?? .json(["status": HAPStatus.unavailable.code], status: 503))
            }
        default:
            reply(.empty(404))
        }
    }

    // MARK: Characteristics

    private func readCharacteristics(_ request: Request, _ connection: Connection) -> Response {
        guard let ids = request.query["id"], let accessory else { return .empty(400) }
        var items: [[String: Any]] = []
        var failed = false
        for id in ids.split(separator: ",") {
            let parts = id.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            var item: [String: Any] = ["aid": parts[0], "iid": parts[1]]
            switch parts[0] == 1 ? accessory.read(iid: parts[1], connection: connection.id) : .failure(.notFound) {
            case .success(let value):
                item["value"] = value
                if request.query["ev"] == "1" { item["ev"] = connection.subscriptions.contains(parts[1]) }
            case .failure(let status):
                item["status"] = status.code
                failed = true
            }
            items.append(item)
        }
        if failed {
            items = items.map { var item = $0; if item["status"] == nil { item["status"] = 0 }; return item }
            return .json(["characteristics": items], status: 207)
        }
        return .json(["characteristics": items])
    }

    private func writeCharacteristics(_ request: Request, _ connection: Connection) -> Response {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let writes = object["characteristics"] as? [[String: Any]], let accessory else { return .empty(400) }
        var results: [[String: Any]] = []
        var needsBody = false
        for write in writes {
            guard let aid = (write["aid"] as? NSNumber)?.intValue, let iid = (write["iid"] as? NSNumber)?.intValue else { continue }
            var result: [String: Any] = ["aid": aid, "iid": iid, "status": 0]
            if aid != 1 {
                result["status"] = HAPStatus.notFound.code
            } else {
                if let events = write["ev"] as? Bool {
                    if accessory.supportsEvents(iid: iid) {
                        if events { connection.subscriptions.insert(iid) } else { connection.subscriptions.remove(iid) }
                    } else {
                        result["status"] = HAPStatus.noNotification.code
                    }
                }
                if let value = write["value"] {
                    if let status = accessory.write(iid: iid, value: value, connection: connection.id) {
                        result["status"] = status.code
                    } else if write["r"] as? Bool == true, case .success(let value) = accessory.read(iid: iid, connection: connection.id) {
                        result["value"] = value
                        needsBody = true
                    }
                }
            }
            if (result["status"] as? Int) != 0 { needsBody = true }
            results.append(result)
        }
        return needsBody ? .json(["characteristics": results], status: 207) : .empty(204)
    }

    // MARK: Pair Setup

    private func setupFailure(_ state: UInt8, _ error: UInt8) -> Response {
        .tlv(TLV8([(TLVType.state, Data([state])), (TLVType.error, Data([error]))]))
    }

    private func pairSetup(_ body: Data, _ connection: Connection) -> Response {
        guard let tlv = TLV8(decoding: body), let state = tlv.byte(TLVType.state) else { return .empty(400) }
        switch state {
        case 1:
            if store.isPaired { return setupFailure(2, PairingError.unavailable) }
            if failedSetupAttempts >= 100 { return setupFailure(2, PairingError.maxTries) }
            if let current = pairSetup, current.owner != connection.id, connections[current.owner] != nil {
                return setupFailure(2, PairingError.busy)
            }
            let srp = SRPServer(username: "Pair-Setup", password: store.setupCode)
            pairSetup = (connection.id, srp, nil)
            print("Pairing requested by \(connection.remoteHost)")
            return .tlv(TLV8([(TLVType.state, Data([2])), (TLVType.publicKey, srp.serverPublicBytes),
                              (TLVType.salt, srp.salt)]))

        case 3:
            guard let current = pairSetup, current.owner == connection.id,
                  let a = tlv[TLVType.publicKey], let proof = tlv[TLVType.proof] else { return setupFailure(4, PairingError.unknown) }
            guard let (key, serverProof) = current.srp.verify(clientPublic: a, clientProof: proof) else {
                failedSetupAttempts += 1
                pairSetup = nil
                print("Pairing failed: wrong setup code")
                return setupFailure(4, PairingError.authentication)
            }
            pairSetup = (current.owner, current.srp, key)
            return .tlv(TLV8([(TLVType.state, Data([4])), (TLVType.proof, serverProof)]))

        case 5:
            guard let current = pairSetup, current.owner == connection.id, let sessionKey = current.sessionKey,
                  let sealed = tlv[TLVType.encryptedData] else { return setupFailure(6, PairingError.unknown) }
            pairSetup = nil
            let encryptionKey = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            guard let opened = HAPCrypto.open(sealed, key: encryptionKey, nonce: HAPCrypto.nonce("PS-Msg05")),
                  let inner = TLV8(decoding: opened), let identifier = inner[TLVType.identifier],
                  let publicKey = inner[TLVType.publicKey], let signature = inner[TLVType.signature],
                  let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            else { return setupFailure(6, PairingError.authentication) }
            let controllerX = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
            guard controllerKey.isValidSignature(signature, for: controllerX.data + identifier + publicKey) else {
                return setupFailure(6, PairingError.authentication)
            }
            do {
                try store.addPairing(.init(identifier: String(decoding: identifier, as: UTF8.self), publicKey: publicKey, isAdmin: true))
            } catch {
                print("could not save the pairing: \(error)")
                return setupFailure(6, PairingError.unknown)
            }

            let accessoryX = HAPCrypto.hkdf(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            let deviceID = Data(store.deviceID.utf8)
            let longTermKey = store.signingKey.publicKey.rawRepresentation
            guard let accessorySignature = try? store.signingKey.signature(for: accessoryX.data + deviceID + longTermKey) else {
                return setupFailure(6, PairingError.unknown)
            }
            let reply = TLV8([(TLVType.identifier, deviceID), (TLVType.publicKey, longTermKey),
                              (TLVType.signature, accessorySignature)])
            let encrypted = HAPCrypto.seal(reply.encoded, key: encryptionKey, nonce: HAPCrypto.nonce("PS-Msg06"))
            print("Paired with \(connection.remoteHost)")
            updateService()
            return .tlv(TLV8([(TLVType.state, Data([6])), (TLVType.encryptedData, encrypted)]))

        default:
            return .empty(400)
        }
    }

    // MARK: Pair Verify

    private func pairVerify(_ body: Data, _ connection: Connection) -> Response {
        guard let tlv = TLV8(decoding: body), let state = tlv.byte(TLVType.state) else { return .empty(400) }
        switch state {
        case 1:
            guard let controllerKey = tlv[TLVType.publicKey],
                  let controllerPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerKey) else {
                return setupFailure(2, PairingError.unknown)
            }
            let secret = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? secret.sharedSecretFromKeyAgreement(with: controllerPublic) else {
                return setupFailure(2, PairingError.unknown)
            }
            let sharedBytes = shared.withUnsafeBytes { Data($0) }
            let accessoryKey = secret.publicKey.rawRepresentation
            let deviceID = Data(store.deviceID.utf8)
            guard let signature = try? store.signingKey.signature(for: accessoryKey + deviceID + controllerKey) else {
                return setupFailure(2, PairingError.unknown)
            }
            connection.verify = (secret, controllerKey, sharedBytes)
            let sessionKey = HAPCrypto.hkdf(sharedBytes, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let inner = TLV8([(TLVType.identifier, deviceID), (TLVType.signature, signature)])
            return .tlv(TLV8([(TLVType.state, Data([2])), (TLVType.publicKey, accessoryKey),
                              (TLVType.encryptedData, HAPCrypto.seal(inner.encoded, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg02")))]))

        case 3:
            guard let verify = connection.verify, let sealed = tlv[TLVType.encryptedData] else {
                return setupFailure(4, PairingError.authentication)
            }
            connection.verify = nil
            let sessionKey = HAPCrypto.hkdf(verify.shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            guard let opened = HAPCrypto.open(sealed, key: sessionKey, nonce: HAPCrypto.nonce("PV-Msg03")),
                  let inner = TLV8(decoding: opened), let identifier = inner[TLVType.identifier],
                  let signature = inner[TLVType.signature],
                  let pairing = store.pairing(String(decoding: identifier, as: UTF8.self)),
                  let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
                  controllerKey.isValidSignature(signature, for: verify.controllerKey + identifier + verify.secret.publicKey.rawRepresentation)
            else {
                log("pair-verify rejected for connection \(connection.id)")
                return setupFailure(4, PairingError.authentication)
            }
            // The reply goes out in the clear; everything after it is encrypted.
            connection.afterResponse = { [unowned self] in
                connection.readKey = HAPCrypto.hkdf(verify.shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key")
                connection.writeKey = HAPCrypto.hkdf(verify.shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key")
                connection.controllerID = pairing.identifier
                connection.received = connection.plaintext
                connection.plaintext = Data()
                _ = self.decryptFrames(connection)
            }
            log("connection \(connection.id) verified as \(pairing.identifier)")
            return .tlv(TLV8([(TLVType.state, Data([4]))]))

        default:
            return .empty(400)
        }
    }

    // MARK: Pairings

    private func pairings(_ body: Data, _ connection: Connection) -> Response {
        guard let tlv = TLV8(decoding: body), let method = tlv.byte(TLVType.method) else { return .empty(400) }
        guard let controller = connection.controllerID, store.pairing(controller)?.isAdmin == true else {
            return setupFailure(2, PairingError.authentication)
        }
        let ok = Response.tlv(TLV8([(TLVType.state, Data([2]))]))
        do {
            switch method {
            case 3:  // add
                guard let identifier = tlv[TLVType.identifier], let key = tlv[TLVType.publicKey] else { return setupFailure(2, PairingError.unknown) }
                let id = String(decoding: identifier, as: UTF8.self)
                if let existing = store.pairing(id), existing.publicKey != key { return setupFailure(2, PairingError.unknown) }
                try store.addPairing(.init(identifier: id, publicKey: key, isAdmin: (tlv.byte(TLVType.permissions) ?? 0) & 1 == 1))
                print("Added controller \(id)")
                return ok

            case 4:  // remove
                guard let identifier = tlv[TLVType.identifier] else { return setupFailure(2, PairingError.unknown) }
                let id = String(decoding: identifier, as: UTF8.self)
                try store.removePairing(id)
                print(store.isPaired ? "Removed controller \(id)" : "Removed from Home; ready to pair again with \(store.setupCode)")
                connection.afterResponse = { [weak self] in
                    guard let self else { return }
                    for other in self.connections.values where other.controllerID != nil
                        && self.store.pairing(other.controllerID!) == nil {
                        // Close once everything already queued, this reply included, has gone.
                        other.link.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in other.link.cancel() })
                    }
                    self.updateService()
                }
                return ok

            case 5:  // list
                var list = TLV8([(TLVType.state, Data([2]))])
                for (index, pairing) in store.pairings.enumerated() {
                    if index > 0 { list.separator() }
                    list.append(TLVType.identifier, pairing.identifier)
                    list.append(TLVType.publicKey, pairing.publicKey)
                    list.append(TLVType.permissions, pairing.isAdmin ? 1 : 0)
                }
                return .tlv(list)

            default:
                return setupFailure(2, PairingError.unknown)
            }
        } catch {
            print("could not save pairings: \(error)")
            return setupFailure(2, PairingError.unknown)
        }
    }

    /// The local address a connection arrived on, for telling controllers where
    /// to send RTCP.
    func localAddress(of connectionID: Int) -> (address: String, isIPv6: Bool)? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection = connections[connectionID],
              case .hostPort(let host, _)? = connection.link.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return ("\(address)".components(separatedBy: "%")[0], false)
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return ("\(mapped)", false) }
            return ("\(address)".components(separatedBy: "%")[0], true)
        default: return nil
        }
    }

    /// The interface the controller's connection uses, for scoping link-local IPv6.
    func interfaceName(of connectionID: Int) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection = connections[connectionID],
              case .hostPort(.ipv6(let address), _) = connection.link.endpoint else { return nil }
        return address.interface?.name ?? connection.link.currentPath?.availableInterfaces.first?.name
    }
}

extension SymmetricKey {
    var data: Data { withUnsafeBytes { Data($0) } }
}

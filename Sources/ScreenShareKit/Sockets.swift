import Darwin
import Foundation

/// Resolves a host name to an IPv4 address. The media path is IPv4-only, so the
/// control connection is pinned to IPv4 as well to keep both on one family.
func resolveIPv4(_ host: String, port: UInt16) throws -> sockaddr_in {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else {
        throw ScreenShareError.network("cannot resolve \(host) to an IPv4 address")
    }
    defer { freeaddrinfo(result) }
    return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
}

private func makeAddress(_ ip: String?, port: UInt16) throws -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    if let ip {
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw ScreenShareError.network("invalid IPv4 address \(ip)")
        }
    } else {
        address.sin_addr.s_addr = INADDR_ANY
    }
    return address
}

private func withSockaddr<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var copy = address
    return withUnsafePointer(to: &copy) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

private func lastError(_ what: String) -> ScreenShareError {
    .network("\(what): \(String(cString: strerror(errno)))")
}

/// Blocking TCP stream with exact-length reads.
final class TCPStream {
    private var fd: Int32
    private let writeLock = NSLock()

    init(remote: sockaddr_in, localAddress: String?, timeout: TimeInterval) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw lastError("socket") }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(SO_SNDTIMEO, timeout)
        setTimeout(SO_RCVTIMEO, timeout)

        if let localAddress {
            let local = try makeAddress(localAddress, port: 0)
            guard withSockaddr(local, { bind(fd, $0, $1) }) == 0 else {
                let error = lastError("bind \(localAddress)")
                Darwin.close(fd)
                throw error
            }
        }
        guard withSockaddr(remote, { connect(fd, $0, $1) }) == 0 else {
            let error = lastError("connect")
            Darwin.close(fd)
            throw error
        }
    }

    private func setTimeout(_ option: Int32, _ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Changes how long a blocking read waits; 0 means wait forever.
    func setReadTimeout(_ seconds: TimeInterval) { setTimeout(SO_RCVTIMEO, seconds) }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw lastError("send")
                }
                sent += n
            }
        }
    }

    func read(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + received, count - received, 0) }
            if n == 0 { throw ScreenShareError.network("connection closed by host") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw ScreenShareError.timeout("no response from host")
                }
                throw lastError("recv")
            }
            received += n
        }
        return Data(buffer)
    }

    /// Looks at upcoming bytes without consuming them; returns fewer if not yet available.
    func peek(_ count: Int, wait: TimeInterval) -> Data {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(wait * 1000)) > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        let n = recv(fd, &buffer, count, MSG_PEEK)
        return n > 0 ? Data(buffer[0..<n]) : Data()
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

/// UDP socket bound to a fixed local port. The host sends media back to the same
/// port numbers it listens on, so the local ports are not negotiable.
final class UDPSocket {
    private var fd: Int32

    init(localAddress: String?, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw lastError("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Large buffer so the keyframe burst at stream start is not dropped.
        var size: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        // Short receive timeout so the read loop can notice shutdown.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let local = try makeAddress(localAddress, port: port)
        guard withSockaddr(local, { bind(fd, $0, $1) }) == 0 else {
            let error = lastError("bind UDP \(port)")
            Darwin.close(fd)
            throw error
        }
    }

    func send(_ data: Data, to remote: sockaddr_in) {
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            _ = withSockaddr(remote) { sendto(fd, raw.baseAddress, raw.count, 0, $0, $1) }
        }
    }

    /// Returns nil on timeout or once the socket is closed.
    func receive(into buffer: inout [UInt8]) -> Int? {
        guard fd >= 0 else { return nil }
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return n > 0 ? n : nil
    }

    var isOpen: Bool { fd >= 0 }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

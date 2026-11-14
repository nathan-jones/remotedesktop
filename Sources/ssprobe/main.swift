import CoreImage
import CoreVideo
import Foundation
import ScreenShareKit

// Command-line probe: connects to a Mac, reports what arrives and saves the
// first decoded frame, so the protocol stack can be checked without the iOS app.
//
//   ssprobe <host> <user> [--password-file path] [--virtual WxH] [--bind ip]
//           [--seconds n] [--frame out.png]
//
// The password comes from --password-file or the SS_PASSWORD environment variable.

setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

let passwordFile = option("--password-file")
let virtual = option("--virtual")
let bind = option("--bind")
let seconds = Double(option("--seconds") ?? "8") ?? 8
let framePath = option("--frame") ?? "frame.png"

guard arguments.count == 2 else {
    print("usage: ssprobe <host> <user> [--password-file path] [--virtual WxH] [--bind ip] [--seconds n] [--frame out.png]")
    exit(2)
}

var password = ProcessInfo.processInfo.environment["SS_PASSWORD"] ?? ""
if let passwordFile, let contents = try? String(contentsOfFile: passwordFile, encoding: .utf8) {
    password = contents.trimmingCharacters(in: .newlines)
}
guard !password.isEmpty else {
    print("no password: use --password-file or SS_PASSWORD")
    exit(2)
}

var display: VirtualDisplay?
if let virtual {
    let parts = virtual.lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else {
        print("--virtual expects WxH, e.g. 1440x900")
        exit(2)
    }
    display = VirtualDisplay(width: parts[0], height: parts[1])
}

let started = Date()
ScreenShareLog.sink = { print(String(format: "[%6.2fs] %@", Date().timeIntervalSince(started), $0)) }

let session = ScreenShareSession(configuration: .init(
    host: arguments[0], username: arguments[1], password: password,
    virtualDisplay: display, localAddress: bind))
let decoder = HEVCDecoder(outputPixelFormat: kCVPixelFormatType_32BGRA)

let counterLock = NSLock()
var decodedFrames = 0
var savedFrame = false

decoder.onNeedsKeyframe = { session.requestKeyframe() }
decoder.onFrame = { buffer in
    counterLock.lock()
    decodedFrames += 1
    let shouldSave = !savedFrame
    savedFrame = true
    counterLock.unlock()
    guard shouldSave else { return }

    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    ScreenShareLog.sink("first decoded frame: \(width)x\(height)")
    let image = CIImage(cvPixelBuffer: buffer)
    let url = URL(fileURLWithPath: framePath)
    do {
        try CIContext().writePNGRepresentation(
            of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ScreenShareLog.sink("saved \(url.path)")
    } catch {
        ScreenShareLog.sink("could not save frame: \(error)")
    }
}

session.onParameterSets = { sets in
    do {
        try decoder.setParameterSets(sets)
        ScreenShareLog.sink("decoder configured from \(sets.count) parameter sets")
    } catch {
        ScreenShareLog.sink("decoder setup failed: \(error)")
    }
}
session.onAccessUnit = { decoder.decode($0) }
session.onStateChange = { ScreenShareLog.sink("state: \($0)") }

session.start()

let deadline = Date().addingTimeInterval(seconds + 20)
var streamingSince: Date?
while Date() < deadline {
    Thread.sleep(forTimeInterval: 0.25)
    let state = session.currentState
    if case .closed = state { break }
    if state == .streaming {
        streamingSince = streamingSince ?? Date()
        if Date().timeIntervalSince(streamingSince!) >= seconds { break }
    }
}

let stats = session.statistics
session.stop()
Thread.sleep(forTimeInterval: 0.3)
print("""
packets received: \(stats.packetsReceived)  rejected: \(stats.packetsRejected)
access units: \(stats.accessUnits)  keyframes: \(stats.keyframes)  keyframe requests: \(stats.keyframeRequests)
canvas: \(stats.canvasWidth)x\(stats.canvasHeight)  decoded frames: \(decodedFrames)
""")
exit(decodedFrames > 0 ? 0 : 1)

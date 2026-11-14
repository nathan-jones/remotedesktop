// Encodes short HEVC test clips with VideoToolbox and writes them to samples.js
// for the browser probe page. Run: swift make-samples.swift
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

let side = 1088
let frameCount = 60
let fps: Int32 = 60

struct Variant {
    let name: String
    let label: String
    let pixelFormat: OSType
    let profile: CFString?
}

let variants = [
    Variant(name: "main420", label: "HEVC Main 4:2:0 8-bit",
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            profile: kVTProfileLevel_HEVC_Main_AutoLevel),
    Variant(name: "rext444-8", label: "HEVC 4:4:4 8-bit",
            pixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, profile: nil),
    Variant(name: "rext444-10", label: "HEVC 4:4:4 10-bit",
            pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, profile: nil),
]

func makeBuffer(_ format: OSType) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, side, side, format, attributes, &buffer)
    return buffer!
}

/// A desktop-like test card: flat panels, thin coloured lines and coloured text,
/// which is where 4:4:4 differs visibly from 4:2:0.
func draw(frame: Int, label: String, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    let s = CGFloat(side)
    context.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: s, height: s))

    let colours: [CGColor] = [
        CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1), CGColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1), CGColor(red: 1, green: 0.8, blue: 0, alpha: 1),
        CGColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1), CGColor(red: 0.35, green: 0.85, blue: 0.9, alpha: 1),
    ]
    // One-pixel coloured lines.
    for i in 0..<48 {
        context.setFillColor(colours[i % colours.count])
        context.fill(CGRect(x: 64 + CGFloat(i) * 4, y: 96, width: 1, height: 160))
        context.fill(CGRect(x: 320, y: 96 + CGFloat(i) * 4, width: 200, height: 1))
    }
    // Moving window.
    let t = CGFloat(frame) / CGFloat(frameCount)
    let x = 80 + (s - 560) * (0.5 - 0.5 * cos(t * 2 * .pi))
    context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: x, y: 380, width: 400, height: 260))
    context.setFillColor(colours[2])
    context.fill(CGRect(x: x, y: 600, width: 400, height: 40))

    func text(_ string: String, size: CGFloat, colour: CGColor, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    text(label, size: 56, colour: CGColor(red: 1, green: 1, blue: 1, alpha: 1), at: CGPoint(x: 64, y: 940))
    text(String(format: "frame %02d", frame), size: 96, colour: colours[3], at: CGPoint(x: 64, y: 800))
    for (i, colour) in colours.enumerated() {
        text("The quick brown fox jumps over the lazy dog 0123456789", size: 15,
             colour: colour, at: CGPoint(x: 64, y: 330 - CGFloat(i) * 22))
    }
    text("red on blue", size: 30, colour: colours[0], at: CGPoint(x: x + 20, y: 608))
}

func encode(_ variant: Variant) -> [String: Any]? {
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(side), height: Int32(side),
        codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session) == noErr, let session else { return nil }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_500_000 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    if let profile = variant.profile {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
    }

    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    let canvas = makeBuffer(kCVPixelFormatType_32BGRA)

    var samples: [CMSampleBuffer] = []
    let lock = NSLock()
    for frame in 0..<frameCount {
        draw(frame: frame, label: variant.label, into: canvas)
        let source = makeBuffer(variant.pixelFormat)
        guard VTPixelTransferSessionTransferImage(transfer!, from: canvas, to: source) == noErr else { return nil }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: source,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: fps),
            duration: CMTime(value: 1, timescale: fps), frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else { return }
            lock.lock(); samples.append(sample); lock.unlock()
        }
        guard status == noErr else { return nil }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    VTCompressionSessionInvalidate(session)
    samples.sort { $0.presentationTimeStamp < $1.presentationTimeStamp }

    guard let first = samples.first, let format = first.formatDescription,
          let atoms = CMFormatDescriptionGetExtension(
              format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
          let hvcC = atoms["hvcC"] as? Data else { return nil }

    var frames: [[String: Any]] = []
    var total = 0
    for sample in samples {
        guard let block = sample.dataBuffer else { continue }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let count = data.count
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        frames.append(["key": !notSync, "data": data.base64EncodedString()])
        total += count
    }
    let bytes = [UInt8](hvcC)
    print("\(variant.name): \(frames.count) frames, \(total / 1024) KB, profile_idc \(bytes[1] & 0x1f), " +
          "chroma_format_idc \(bytes[16] & 3), bit depth \(Int(bytes[17] & 7) + 8), " +
          "keyframes \(frames.filter { $0["key"] as! Bool }.count)")
    return ["name": variant.name, "label": variant.label, "width": side, "height": side, "fps": Int(fps),
            "description": hvcC.base64EncodedString(), "frames": frames]
}

let clips = variants.compactMap { variant -> [String: Any]? in
    guard let clip = encode(variant) else { print("\(variant.name): encoder refused"); return nil }
    return clip
}
let json = try JSONSerialization.data(withJSONObject: clips)
let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("samples.js")
try (Data("window.HEVC_SAMPLES = ".utf8) + json + Data(";\n".utf8)).write(to: output)
print("wrote \(output.path) (\(json.count / 1024) KB)")

import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures this Mac's own main display, for when the camera runs on the Mac it
/// shows. Screen Sharing cannot be used then: its ports are taken by the Mac's
/// own Screen Sharing service.
final class LocalCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStopped: ((String) -> Void)?
    private let queue = DispatchQueue(label: "sscamera.capture")
    private var stream: SCStream?

    /// HomeKit never asks for more than 1080p, so capture no larger than this.
    private static let maximumSize = CGSize(width: 1920, height: 1200)

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content else {
                self.onStopped?("cannot capture the screen (\(error?.localizedDescription ?? "unknown error")). "
                    + "Allow this terminal under System Settings → Privacy & Security → Screen & System Audio Recording, then restart it.")
                return
            }
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
                self.onStopped?("no display to capture")
                return
            }
            let scale = min(1, LocalCapture.maximumSize.width / CGFloat(display.width),
                            LocalCapture.maximumSize.height / CGFloat(display.height))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale) & ~1
            configuration.height = Int(CGFloat(display.height) * scale) & ~1
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = true
            configuration.queueDepth = 6
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.onStopped?("cannot capture the screen: \(error.localizedDescription)")
                return
            }
            self.stream = stream
            stream.startCapture { error in
                if let error {
                    self.onStopped?("cannot capture the screen: \(error.localizedDescription)")
                } else {
                    print("Capturing this Mac's display at \(configuration.width)x\(configuration.height)")
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sample.imageBuffer else { return }
        // Idle and blank frames carry no new picture.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?("screen capture stopped: \(error.localizedDescription)")
    }
}

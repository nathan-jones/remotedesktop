import CoreVideo
import Foundation
import ScreenShareKit
import SwiftUI
import UIKit

/// Owns one screen-sharing session and its decoder, and publishes what the UI needs.
@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting(String)
        case streaming
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasVideo = false
    /// Most recent diagnostic messages, shown while waiting for video.
    @Published private(set) var recentLog: [String] = []

    /// True while a folding device is half open like a laptop: video above the
    /// hinge, trackpad below.
    @Published private(set) var laptopPosture = false

    /// Receives decoded frames on the main thread; set by the video view.
    var frameSink: ((CVPixelBuffer) -> Void)?
    /// Receives the Mac's pointer shape; the latest one is replayed to a new sink.
    var cursorSink: ((CursorImage) -> Void)? {
        didSet { if let latestCursor { cursorSink?(latestCursor) } }
    }
    private var latestCursor: CursorImage?
    private var latestFrame: CVPixelBuffer?
    /// The account this session signed in with, kept in memory only for as long
    /// as the session lasts so the password can be typed at the Mac's own prompts.
    @Published private(set) var sessionUsername = ""
    @Published private(set) var sessionHost = ""
    private var sessionPassword = ""
    private var thumbnailID: UUID?

    private var session: ScreenShareSession?
    /// The virtual display most recently asked for; nil when mirroring.
    private var requestedDisplay: VirtualDisplay?
    private var wantedDisplay: VirtualDisplay?
    private var decoder: HEVCDecoder?

    var isSessionVisible: Bool { phase != .disconnected }

    /// - Parameter thumbnailID: the saved connection whose card should show
    ///   this session's last frame afterwards.
    func connect(host: String, username: String, password: String, virtualDisplay: VirtualDisplay?,
                 thumbnailID: UUID? = nil) {
        disconnect()
        errorMessage = nil
        hasVideo = false
        phase = .connecting("Connecting…")
        recentLog = []
        ScreenShareLog.sink = { [weak self] message in
            print(message)
            DispatchQueue.main.async {
                guard let self else { return }
                self.recentLog = Array((self.recentLog + [message]).suffix(14))
            }
        }

        var configuration = ScreenShareSession.Configuration(
            host: host.trimmingCharacters(in: .whitespaces),
            username: username, password: password, virtualDisplay: virtualDisplay)
        configuration.drawsCursorLocally = true
        let session = ScreenShareSession(configuration: configuration)
        latestCursor = nil
        self.thumbnailID = thumbnailID
        sessionUsername = username
        sessionHost = host
        sessionPassword = password
        session.onCursorChange = { [weak self] cursor in
            DispatchQueue.main.async {
                guard let self, self.session === session else { return }
                self.latestCursor = cursor
                self.cursorSink?(cursor)
            }
        }
        let decoder = HEVCDecoder()
        self.session = session
        self.decoder = decoder
        requestedDisplay = virtualDisplay
        wantedDisplay = virtualDisplay

        decoder.onNeedsKeyframe = { [weak session] in session?.requestKeyframe() }
        decoder.onFrame = { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self, self.decoder === decoder else { return }
                self.hasVideo = true
                self.latestFrame = buffer
                self.frameSink?(buffer)
            }
        }
        session.onParameterSets = { [weak self] sets in
            do {
                try decoder.setParameterSets(sets)
            } catch {
                let message = (error as? ScreenShareError)?.description ?? error.localizedDescription
                DispatchQueue.main.async { self?.fail(message, from: session) }
            }
        }
        session.onAccessUnit = { decoder.decode($0) }
        session.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.apply(state, from: session) }
        }
        session.start()
    }

    func disconnect() {
        if let latestFrame, let thumbnailID { Thumbnails.save(latestFrame, for: thumbnailID) }
        latestFrame = nil
        thumbnailID = nil
        sessionUsername = ""
        sessionPassword = ""
        session?.stop()
        decoder?.invalidate()
        session = nil
        decoder = nil
        laptopPosture = false
        phase = .disconnected
    }

    private func apply(_ state: ScreenShareSession.State, from source: ScreenShareSession) {
        guard source === session else { return }
        switch state {
        case .idle: break
        case .connecting: phase = .connecting("Connecting…")
        case .authenticating: phase = .connecting("Signing in…")
        case .negotiating: phase = .connecting("Starting video…")
        case .streaming:
            phase = .streaming
            applyWantedDisplay()
        case .closed(let reason): fail(reason, from: source)
        }
    }

    private func fail(_ message: String?, from source: ScreenShareSession) {
        guard source === session else { return }
        disconnect()
        errorMessage = message
    }

    // MARK: Display size

    /// A virtual display with the same point size as the view, so the Mac's
    /// interface appears at the size it would on a display this big, rendered at
    /// this device's pixel density for sharpness. `enlargement` asks for a
    /// roomier desktop than the view, at the cost of smaller text.
    static func display(fitting viewSize: CGSize, enlargement: CGFloat = 1) -> VirtualDisplay {
        // The Mac refuses very small displays (a folded phone's 466x678 points
        // came back as 800x600), so small views get a proportionally larger one.
        let minimumShortSide: CGFloat = 640
        let factor = max(enlargement, minimumShortSide / max(min(viewSize.width, viewSize.height), 1))
        let size = CGSize(width: viewSize.width * factor, height: viewSize.height * factor)
        let longSide = max(size.width, size.height), shortSide = min(size.width, size.height)
        // Stay inside the picture sizes the Mac is known to accept.
        let scale = min(UIScreen.main.scale, 3840 / longSide, 2160 / shortSide)
        return VirtualDisplay(width: Int(size.width) & ~1, height: Int(size.height) & ~1, scale: Double(scale))
    }

    /// Called when the area showing video changes (rotation, folding, split view).
    func videoAreaChanged(_ size: CGSize, laptopPosture: Bool) {
        self.laptopPosture = laptopPosture
        guard requestedDisplay != nil, size.width > 100, size.height > 100 else { return }
        // Half a phone screen is too small a desktop to be useful at 1:1.
        wantedDisplay = SessionModel.display(fitting: size, enlargement: laptopPosture ? 1.4 : 1)
        applyWantedDisplay()
    }

    /// Types the sign-in password wherever the Mac's keyboard focus is, for the
    /// lock screen and administrator prompts.
    func typePassword(pressReturn: Bool) {
        typeText(sessionPassword)
        if pressReturn { tapKey(Keysym.returnKey) }
    }

    /// Types text on the Mac as if it had been entered on its keyboard.
    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            tapKey(Keysym.forCharacter(scalar))
        }
    }

    private func applyWantedDisplay() {
        guard phase == .streaming, let wantedDisplay, wantedDisplay != requestedDisplay else { return }
        requestedDisplay = wantedDisplay
        session?.resize(to: wantedDisplay)
    }

    // MARK: Input

    /// Size of the space pointer coordinates are expressed in.
    var pointerSize: CGSize {
        guard let size = session?.pointerSize else { return .zero }
        return CGSize(width: size.width, height: size.height)
    }

    func pointer(at point: CGPoint, buttons: PointerButtons) {
        session?.sendPointer(x: Int(point.x.rounded()), y: Int(point.y.rounded()), buttons: buttons)
    }

    func key(_ keysym: UInt32, down: Bool) {
        session?.sendKey(keysym: keysym, down: down)
    }

    /// Presses a key with modifiers held, such as Command-C.
    func chord(_ modifiers: [UInt32], _ keysym: UInt32) {
        modifiers.forEach { key($0, down: true) }
        tapKey(keysym)
        modifiers.reversed().forEach { key($0, down: false) }
    }

    func tapKey(_ keysym: UInt32) {
        key(keysym, down: true)
        key(keysym, down: false)
    }
}

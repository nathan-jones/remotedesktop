import AVFoundation
import ScreenShareKit
import SwiftUI
import UIKit

/// Shows the remote screen and turns touches and typing into remote input.
///
/// The screen behaves like a trackpad, so the finger never has to land on (and
/// cover) a small target:
/// - Slide one finger anywhere to move the Mac's pointer; tap anywhere to click
///   where the pointer is.
/// - Touch and hold, then slide, to drag.
/// - Two-finger tap: right click. Two-finger slide: scroll.
/// - Three-finger swipe up: Mission Control; down: the app's windows; left or
///   right: the next or previous Space.
/// - Slide in from the left edge: the Mac's app switcher; keep sliding to move
///   through apps and lift to choose.
/// - Two-finger touch and hold: a ring of Copy, Paste, Undo and Screenshot.
///
/// The pointer is drawn here, from the shape the Mac reports, so it follows the
/// finger without waiting for video. When a folding device is half open with
/// the hinge horizontal, the video takes the upper half and the lower half
/// becomes a trackpad, like a small laptop.
struct RemoteScreenView: UIViewRepresentable {
    let model: SessionModel
    @Binding var keyboardVisible: Bool

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let view = RemoteScreenUIView()
        view.model = model
        view.onKeyboardDismissed = { DispatchQueue.main.async { keyboardVisible = false } }
        model.frameSink = { [weak view] in view?.show($0) }
        model.cursorSink = { [weak view] in view?.setCursor($0) }
        return view
    }

    func updateUIView(_ view: RemoteScreenUIView, context: Context) {
        // On a Mac the view always holds keyboard focus; there is no keyboard to show or hide.
        guard !RemoteScreenUIView.usesDirectPointer else { return }
        if keyboardVisible, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        } else if !keyboardVisible, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }
}

final class RemoteScreenUIView: UIView, UIKeyInput, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    /// On a Mac there is a real mouse, so the remote pointer simply goes where
    /// the local one is instead of being steered like a trackpad.
    static let usesDirectPointer = ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac

    weak var model: SessionModel?
    var onKeyboardDismissed: (() -> Void)?

    private var videoSize = CGSize.zero
    private var lastPointer = CGPoint.zero
    private var scrollRemainder: CGFloat = 0
    private var primaryDown = false
    private var pointerPlaced = false
    private var dragTouch = CGPoint.zero

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CALayer()
    private let trackpadLayer = CALayer()
    private var cursorSize = CGSize.zero       // in picture pixels
    private var cursorHotspot = CGPoint.zero
    private var pointerSpace = CGSize.zero     // the space `lastPointer` is expressed in
    private var hingePartiallyOpen = false
    private static let cursorMagnification: CGFloat = usesDirectPointer ? 1 : 1.75

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)

        trackpadLayer.backgroundColor = UIColor(white: 1, alpha: 0.07).cgColor
        trackpadLayer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        trackpadLayer.borderWidth = 1
        trackpadLayer.cornerRadius = 22
        trackpadLayer.cornerCurve = .continuous
        trackpadLayer.isHidden = true
        layer.addSublayer(trackpadLayer)

        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        cursorLayer.magnificationFilter = .trilinear
        cursorLayer.minificationFilter = .trilinear
        layer.addSublayer(cursorLayer)
        showFallbackCursor()
        isMultipleTouchEnabled = true

        #if !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                self.hingePartiallyOpen = update.hinge?.status == .partiallyOpen
                self.setNeedsLayout()
            })
        }
        #endif

        if RemoteScreenUIView.usesDirectPointer {
            installMouseInput()
            return
        }

        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove))
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)

        let click = UITapGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag))
        drag.minimumPressDuration = 0.3
        addGestureRecognizer(drag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(scroll)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondary))
        secondary.numberOfTouchesRequired = 2
        addGestureRecognizer(secondary)

        for direction in [UISwipeGestureRecognizer.Direction.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe))
            swipe.numberOfTouchesRequired = 3
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }

        let switcher = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleAppSwitcher))
        switcher.edges = .left
        addGestureRecognizer(switcher)
        move.require(toFail: switcher)

        let menu = UILongPressGestureRecognizer(target: self, action: #selector(handleMenuPress))
        menu.numberOfTouchesRequired = 2
        menu.minimumPressDuration = 0.4
        addGestureRecognizer(menu)

        gestureRecognizers?.forEach { $0.delegate = self }
    }

    /// Three-finger swipes belong to the Mac here, not to iOS's own undo and copy gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // MARK: Mac actions

    private var actionMenu: RadialMenuView?
    private var switcherSteps = 0

    /// While the action ring is open, touches on it are its own business.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let actionMenu, let touched = touch.view else { return true }
        return !touched.isDescendant(of: actionMenu)
    }

    @objc private func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        releasePrimary()
        switch gesture.direction {
        case .up: model?.chord([Keysym.control], Keysym.upArrow)        // Mission Control
        case .down: model?.chord([Keysym.control], Keysym.downArrow)    // the app's windows
        case .left: model?.chord([Keysym.control], Keysym.rightArrow)   // next Space
        case .right: model?.chord([Keysym.control], Keysym.leftArrow)   // previous Space
        default: break
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Holds Command for the length of the slide, pressing Tab once to open the
    /// switcher and again for each further stretch of travel (Shift-Tab going back).
    @objc private func handleAppSwitcher(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let stride: CGFloat = 64
        switch gesture.state {
        case .began:
            releasePrimary()
            switcherSteps = 0
            model?.key(Keysym.command, down: true)
            model?.tapKey(Keysym.tab)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let wanted = max(0, Int(gesture.translation(in: self).x / stride))
            while switcherSteps < wanted {
                model?.tapKey(Keysym.tab)
                switcherSteps += 1
                UISelectionFeedbackGenerator().selectionChanged()
            }
            while switcherSteps > wanted {
                model?.chord([Keysym.shift], Keysym.tab)
                switcherSteps -= 1
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .ended, .cancelled, .failed:
            model?.key(Keysym.command, down: false)
        default:
            break
        }
    }

    @objc private func handleMenuPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            releasePrimary()
            actionMenu?.dismiss()
            let menu = RadialMenuView(
                items: [
                    .init(title: "Copy", symbol: "doc.on.doc") { [weak self] in
                        self?.model?.chord([Keysym.command], Keysym.forCharacter("c")) },
                    .init(title: "Paste", symbol: "doc.on.clipboard") { [weak self] in
                        self?.model?.chord([Keysym.command], Keysym.forCharacter("v")) },
                    .init(title: "Screenshot", symbol: "camera.viewfinder") { [weak self] in
                        self?.model?.chord([Keysym.command, Keysym.shift], Keysym.forCharacter("3")) },
                    .init(title: "Undo", symbol: "arrow.uturn.backward") { [weak self] in
                        self?.model?.chord([Keysym.command], Keysym.forCharacter("z")) },
                ],
                onDismiss: { [weak self] in self?.actionMenu = nil })
            actionMenu = menu
            menu.present(in: self, at: gesture.location(in: self))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            actionMenu?.track(gesture.location(in: self))
        case .ended:
            actionMenu?.release()
        case .cancelled, .failed:
            actionMenu?.dismiss()
        default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Mouse (Mac)

    private func installMouseInput() {
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))

        // One recogniser for every mouse button; which one is read when it goes down.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleMouseButton))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)

        // The Mac's own pointer is hidden over the video; the remote one is drawn instead.
        addInteraction(UIPointerInteraction(delegate: self))
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if RemoteScreenUIView.usesDirectPointer, window != nil { _ = becomeFirstResponder() }
    }

    /// Puts the remote pointer under a point in this view.
    private func movePointer(to location: CGPoint, buttons: PointerButtons) {
        guard let space = model?.pointerSize, space.width > 0, let rect = pictureRect else { return }
        pointerPlaced = true
        lastPointer = CGPoint(
            x: min(max((location.x - rect.minX) / rect.width, 0), 1) * (space.width - 1),
            y: min(max((location.y - rect.minY) / rect.height, 0), 1) * (space.height - 1))
        pointerSpace = space
        model?.pointer(at: lastPointer, buttons: buttons)
        placeCursor()
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed, heldButtons.isEmpty else { return }
        movePointer(to: gesture.location(in: self), buttons: [])
    }

    private var heldButtons: PointerButtons = []

    @objc private func handleMouseButton(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            _ = becomeFirstResponder()
            heldButtons = gesture.buttonMask.contains(.secondary) ? .right : .left
        case .changed:
            break
        case .ended, .cancelled, .failed:
            heldButtons = []
        default:
            return
        }
        movePointer(to: gesture.location(in: self), buttons: heldButtons)
    }

    // MARK: Layout

    private var reportedSize = CGSize.zero
    private var reportedLaptop = false
    private var pendingSizeReport: DispatchWorkItem?

    /// Half open with the hinge running across the screen: the two halves of the
    /// display are then the "lid" and the "base" of a small laptop.
    private var isLaptopPosture: Bool { hingePartiallyOpen && bounds.height > bounds.width }

    override func layoutSubviews() {
        super.layoutSubviews()
        let laptop = isLaptopPosture
        let videoFrame = laptop
            ? CGRect(x: 0, y: 0, width: bounds.width, height: (bounds.height / 2).rounded(.down))
            : bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = videoFrame
        trackpadLayer.isHidden = !laptop
        trackpadLayer.frame = CGRect(x: 0, y: videoFrame.maxY, width: bounds.width,
                                     height: bounds.height - videoFrame.maxY).insetBy(dx: 14, dy: 14)
        CATransaction.commit()
        placeCursor()

        guard videoFrame.size != reportedSize || laptop != reportedLaptop else { return }
        reportedSize = videoFrame.size
        reportedLaptop = laptop
        // Rotation and folding pass through intermediate sizes; report once it settles.
        pendingSizeReport?.cancel()
        let size = videoFrame.size
        let report = DispatchWorkItem { [weak self] in
            self?.model?.videoAreaChanged(size, laptopPosture: laptop)
        }
        pendingSizeReport = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: report)
    }

    // MARK: Video

    func show(_ pixelBuffer: CVPixelBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if size != videoSize {
            videoSize = size
            placeCursor()
        }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }

        // Show each frame as soon as it arrives rather than on a media timeline.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: Pointer

    /// Uses a pointer shape sent by the Mac.
    func setCursor(_ cursor: CursorImage) {
        guard let provider = CGDataProvider(data: cursor.rgba as CFData),
              let image = CGImage(
                width: cursor.width, height: cursor.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: cursor.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        cursorLayer.contents = image
        cursorSize = CGSize(width: cursor.width, height: cursor.height)
        cursorHotspot = CGPoint(x: cursor.hotspotX, y: cursor.hotspotY)
        placeCursor()
    }

    /// A plain arrow, shown until the Mac reports its own pointer shape.
    private func showFallbackCursor() {
        let size = CGSize(width: 34, height: 50)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let outline: [(CGFloat, CGFloat)] = [(0, 0), (0, 84), (20, 66), (35, 100), (50, 93), (35, 60), (62, 60)]
            let path = UIBezierPath()
            for (index, point) in outline.enumerated() {
                let scaled = CGPoint(x: 3 + point.0 * 0.44, y: 3 + point.1 * 0.44)
                if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
            }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 3
            UIColor.white.setStroke()
            path.stroke()
            UIColor.black.setFill()
            path.fill()
        }
        cursorLayer.contents = image.cgImage
        cursorSize = size
        cursorHotspot = CGPoint(x: 3, y: 3)
    }

    /// Where the video actually appears inside its area (it keeps its shape).
    private var pictureRect: CGRect? {
        guard videoSize.width > 0, displayLayer.frame.width > 0 else { return nil }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: displayLayer.frame)
        return rect.width > 0 ? rect : nil
    }

    /// Positions the drawn pointer over the picture, first placing it mid-screen
    /// (and telling the Mac) or carrying it across a change of display size.
    private func placeCursor() {
        guard let space = model?.pointerSize, space.width > 0, space.height > 0, let rect = pictureRect else {
            cursorLayer.isHidden = true
            return
        }
        if !pointerPlaced {
            pointerPlaced = true
            lastPointer = CGPoint(x: space.width / 2, y: space.height / 2)
            model?.pointer(at: lastPointer, buttons: [])
        } else if space != pointerSpace, pointerSpace.width > 0 {
            lastPointer.x *= space.width / pointerSpace.width
            lastPointer.y *= space.height / pointerSpace.height
        }
        pointerSpace = space

        // Drawn larger than life: a true-size Mac pointer is hard to spot on a phone.
        let scale = rect.width / space.width * RemoteScreenUIView.cursorMagnification
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = false
        cursorLayer.frame = CGRect(
            x: rect.minX + lastPointer.x * rect.width / space.width - cursorHotspot.x * scale,
            y: rect.minY + lastPointer.y * rect.height / space.height - cursorHotspot.y * scale,
            width: cursorSize.width * scale, height: cursorSize.height * scale)
        CATransaction.commit()
    }

    /// Moves the remote pointer by a finger movement, keeping `buttons` held.
    /// Slow movement is scaled down for precision, fast movement up for reach.
    private func movePointer(by delta: CGPoint, speed: CGFloat, buttons: PointerButtons) {
        guard let space = model?.pointerSize, space.width > 0, let rect = pictureRect else { return }
        placeCursor()
        let gain = (space.width / rect.width) * min(max(0.5 + speed / 700, 0.5), 2.5)
        lastPointer.x = min(max(lastPointer.x + delta.x * gain, 0), space.width - 1)
        lastPointer.y = min(max(lastPointer.y + delta.y * gain, 0), space.height - 1)
        model?.pointer(at: lastPointer, buttons: buttons)
        placeCursor()
    }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed, !primaryDown else { return }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        let velocity = gesture.velocity(in: self)
        movePointer(by: delta, speed: hypot(velocity.x, velocity.y), buttons: [])
    }

    @objc private func handleClick(_ gesture: UITapGestureRecognizer) {
        releasePrimary()
        model?.pointer(at: lastPointer, buttons: .left)
        model?.pointer(at: lastPointer, buttons: [])
    }

    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            dragTouch = location
            primaryDown = true
            model?.pointer(at: lastPointer, buttons: .left)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard primaryDown else { return }
            let delta = CGPoint(x: location.x - dragTouch.x, y: location.y - dragTouch.y)
            dragTouch = location
            movePointer(by: delta, speed: 350, buttons: .left)
        case .ended, .cancelled, .failed:
            releasePrimary()
        default:
            break
        }
    }

    private func releasePrimary() {
        guard primaryDown else { return }
        primaryDown = false
        model?.pointer(at: lastPointer, buttons: [])
    }

    @objc private func handleSecondary(_ gesture: UITapGestureRecognizer) {
        releasePrimary()
        model?.pointer(at: lastPointer, buttons: .right)
        model?.pointer(at: lastPointer, buttons: [])
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            releasePrimary()
            scrollRemainder = 0
        }
        guard gesture.state == .changed else { return }
        scrollRemainder += gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)

        // One wheel step for every 12 points of finger travel.
        let step: CGFloat = 12
        while abs(scrollRemainder) >= step {
            let direction: PointerButtons = scrollRemainder > 0 ? .scrollUp : .scrollDown
            model?.pointer(at: lastPointer, buttons: direction)
            model?.pointer(at: lastPointer, buttons: [])
            scrollRemainder += scrollRemainder > 0 ? -step : step
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onKeyboardDismissed?() }
        return resigned
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            model?.tapKey(Keysym.forCharacter(scalar))
        }
    }

    func deleteBackward() {
        model?.tapKey(Keysym.backspace)
    }

    // Hardware keyboards deliver presses, which carry modifiers and key-up events.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    private func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key, let keysym = Keysym.forHardwareKey(key) else { continue }
            model?.key(keysym, down: down)
            handled = true
        }
        return handled
    }
}

/// X11 key symbols, which is what the remote side expects for key events.
enum Keysym {
    static let backspace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B
    static let leftArrow: UInt32 = 0xFF51
    static let upArrow: UInt32 = 0xFF52
    static let rightArrow: UInt32 = 0xFF53
    static let downArrow: UInt32 = 0xFF54
    static let shift: UInt32 = 0xFFE1
    static let control: UInt32 = 0xFFE3
    static let command: UInt32 = 0xFFEB

    static func forCharacter(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0A, 0x0D: return returnKey
        case 0x09: return tab
        case 0x20...0x7E, 0xA0...0xFF: return scalar.value   // Latin-1 maps directly
        default: return 0x0100_0000 | scalar.value            // any other Unicode character
        }
    }

    static func forHardwareKey(_ key: UIKey) -> UInt32? {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return returnKey
        case .keyboardDeleteOrBackspace: return backspace
        case .keyboardDeleteForward: return 0xFFFF
        case .keyboardTab: return tab
        case .keyboardEscape: return escape
        case .keyboardLeftArrow: return 0xFF51
        case .keyboardUpArrow: return 0xFF52
        case .keyboardRightArrow: return 0xFF53
        case .keyboardDownArrow: return 0xFF54
        case .keyboardHome: return 0xFF50
        case .keyboardEnd: return 0xFF57
        case .keyboardPageUp: return 0xFF55
        case .keyboardPageDown: return 0xFF56
        case .keyboardLeftShift: return 0xFFE1
        case .keyboardRightShift: return 0xFFE2
        case .keyboardLeftControl: return 0xFFE3
        case .keyboardRightControl: return 0xFFE4
        case .keyboardLeftAlt: return 0xFFE9      // Option
        case .keyboardRightAlt: return 0xFFEA
        case .keyboardLeftGUI: return 0xFFEB      // Command
        case .keyboardRightGUI: return 0xFFEC
        default:
            guard let scalar = key.charactersIgnoringModifiers.unicodeScalars.first,
                  key.charactersIgnoringModifiers.unicodeScalars.count == 1 else { return nil }
            return forCharacter(scalar)
        }
    }
}

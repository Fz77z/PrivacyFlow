import AppKit
import PrivacyFlowCore

/// A floating panel that never takes keyboard focus, so clicking or dragging
/// the capsule never pulls focus from the document the user is writing in.
final class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The capsule paints its own shadow. A transparent window's system
        // shadow is traced lazily from what was drawn, and it left a ghost of
        // the previous shape behind every change of size.
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Converting between AppKit's screen coordinates, which rise from the bottom
/// of the primary display, and the top-down coordinates positions are stored in.
enum ScreenSpace {
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Every display's usable area, top-down. Empty means unknown.
    static var workAreas: [WorkArea] {
        NSScreen.screens.map { screen in
            let frame = screen.visibleFrame
            return WorkArea(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }

    static func centre(of frame: CGRect) -> Centre {
        Centre(x: frame.midX, y: primaryHeight - frame.midY)
    }

    /// The AppKit frame of a window of `size` whose top-left corner is at the
    /// top-down point `topLeft`.
    static func frame(topLeft: (x: Double, y: Double), size: CGSize) -> CGRect {
        CGRect(x: topLeft.x, y: primaryHeight - topLeft.y - size.height, width: size.width, height: size.height)
    }
}

/// The capsule: its window, where it sits, what shape it is, and the frame
/// loop that animates it and everything else on screen.
@MainActor
final class CapsuleWindowController {
    private let controller: AppController
    private let toast: ToastWindowController
    private let panel: FloatingPanel
    private let view = CapsuleView()
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var width: Spring
    private var height: Spring
    /// Whether the pointer opened the capsule. Opening takes reaching the cog;
    /// staying open only takes staying on the much larger opened capsule.
    private var openForPointer = false
    private var dragAnchor: (window: CGPoint, pointer: CGPoint)?
    private var pointerMonitors: [Any] = []

    init(controller: AppController, toast: ToastWindowController) {
        self.controller = controller
        self.toast = toast
        let minimal = controller.settings.minimalMode
        let resting = CapsuleGeometry.size(minimal: minimal, pointing: false, dictating: false).points
        width = Spring(resting.width)
        height = Spring(resting.height)
        panel = FloatingPanel(size: CapsuleGeometry.windowSize(minimal: minimal))
        panel.contentView = view
        place(at: WindowPosition.load(from: controller.dataDirectory, areas: ScreenSpace.workAreas))

        view.onCog = { [weak controller] in controller?.toggleConsole() }
        view.onOpenConsole = { [weak controller] in controller?.openConsole() }
        view.onQuit = { [weak controller] in controller?.quit() }
        view.onDragStarted = { [weak self] in self?.beginDrag() }
        view.onDragged = { [weak self] pointer in self?.drag(to: pointer) }
        view.onDragEnded = { [weak self] in self?.endDrag() }
        view.onPointerMoved = { [weak self] in self?.wake() }

        // Clicks pass through wherever the window is transparent, because
        // ignoresMouseEvents is never set: macOS then hit-tests the window by
        // its pixels. So the capsule, and the cog's opening zone, receive the
        // mouse directly, including the very event that brings the pointer
        // onto them, which is what lets the capsule's arrow cursor win over
        // the app underneath. Moving off the capsule sends events to other
        // windows instead, so the pointer is also watched outside it, to
        // notice it leaving. Mouse monitors need no permission. A global
        // monitor only sees events delivered to other apps, so while
        // PrivacyFlow itself is active, with its console or setup in front,
        // its own events are watched too.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            pointerMonitors.append(local)
        }

        controller.onNeedsFrames = { [weak self] in self?.wake() }
        controller.onMinimalModeChanged = { [weak self] in self?.followMinimalMode() }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
        render()
        panel.orderFrontRegardless()
    }

    /// Start the frame loop if it is not already running.
    func wake() {
        guard let displayLink, displayLink.isPaused else { return }
        lastFrame = nil
        displayLink.isPaused = false
    }

    private func pointerMoved() {
        // Only the pointer near the capsule matters; anywhere else is ignored
        // without waking anything.
        let reach = panel.frame.insetBy(dx: -8, dy: -8)
        if reach.contains(NSEvent.mouseLocation) || openForPointer {
            wake()
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let seconds = lastFrame.map { min(link.timestamp - $0, 1.0 / 20) } ?? 1.0 / 60
        lastFrame = link.timestamp
        let dictationWantsFrames = controller.tick(frameSeconds: seconds)
        let shapeMoving = render(frameSeconds: seconds)
        let toastShowing = toast.show(controller.state.toast, capsule: ScreenSpace.centre(of: panel.frame))
        if !(dictationWantsFrames || shapeMoving || toastShowing) {
            link.isPaused = true
        }
    }

    /// Decide the capsule's shape and paint it. Returns whether it is still
    /// animating.
    @discardableResult
    private func render(frameSeconds: Double = 0) -> Bool {
        let minimal = controller.settings.minimalMode
        let pointer = NSEvent.mouseLocation
        let frame = panel.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Both zones in AppKit screen space: the full capsule's footprint keeps
        // it open, and the cog, a little generously, opens it.
        let reach = CGRect(x: centre.x - CapsuleGeometry.fullSize.width / 2, y: centre.y - CapsuleGeometry.fullSize.height / 2, width: CapsuleGeometry.fullSize.width, height: CapsuleGeometry.fullSize.height)
        let cogX = centre.x + CapsuleGeometry.fullSize.width / 2 - CapsuleGeometry.cogInset(height: CapsuleGeometry.fullSize.height)
        let buttonSide = CapsuleGeometry.openingZone
        let button = CGRect(x: cogX - buttonSide / 2, y: centre.y - buttonSide / 2, width: buttonSide, height: buttonSide)
        let reaching = reach.contains(pointer)
        openForPointer = button.contains(pointer) || (openForPointer && reaching)
        let requested = controller.shownOnRequestUntil != nil
        let pointing = minimal && (openForPointer || requested || view.isDragging || view.menuOpen)

        let target = CapsuleGeometry.size(minimal: minimal, pointing: pointing, dictating: controller.isDictating).points
        // Sprung, so growing pops open and a change of mind part way turns
        // around smoothly. One feel for both axes, chosen by the width, so the
        // shape cannot shear.
        let feel: SpringFeel = target.width >= width.value ? .grow : .shrink
        let widthMoving = width.step(towards: target.width, seconds: frameSeconds, feel: feel)
        let heightMoving = height.step(towards: target.height, seconds: frameSeconds, feel: feel)

        let state = controller.state
        let failure = state.hud == .error ? state.lastFailure : nil
        view.look = CapsuleAppearance(
            hud: state.hud,
            failure: failure,
            unreadFailure: state.unreadFailure,
            tooltip: tooltip(state),
            label: CapsuleGeometry.label(for: state.hud, processing: state.processingLabel),
            settledFor: state.doneAt.map { Monotonic.now() - $0 },
            voiceBars: controller.voiceBars,
            minimal: minimal,
            painted: CGSize(width: width.value, height: height.value)
        )
        return widthMoving || heightMoving
    }

    /// What the cog says when the pointer rests on it: that dictation is
    /// paused, a press that was missed, the last failure, or how to dictate.
    private func tooltip(_ state: AppState) -> String {
        if controller.recordingShortcut {
            return "Dictation is paused while a new dictation key is recorded in Settings."
        }
        return controller.missedPress ?? state.lastFailure?.detail ?? "Hold \(controller.settings.dictationShortcut.label) to dictate. Click to open the console."
    }

    /// Put the window around a remembered centre, clamped so the visible
    /// capsule lands on screen, not the catchment around it. With nothing
    /// remembered, the capsule starts centred above the Dock.
    private func place(at remembered: Centre?) {
        let size = CapsuleGeometry.windowSize(minimal: controller.settings.minimalMode)
        let centre = remembered ?? defaultCentre()
        let capsule = CapsuleGeometry.fullSize
        let topLeft = WindowPosition.place(centre, size: capsule, areas: ScreenSpace.workAreas)
        let windowTopLeft = (x: topLeft.x - (size.width - capsule.width) / 2, y: topLeft.y - (size.height - capsule.height) / 2)
        panel.setFrame(ScreenSpace.frame(topLeft: windowTopLeft, size: size), display: true)
    }

    private func defaultCentre() -> Centre {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return Centre(x: 400, y: 400) }
        let visible = screen.visibleFrame
        return ScreenSpace.centre(of: CGRect(x: visible.midX - 1, y: visible.minY + 80, width: 2, height: 2))
    }

    /// The window follows the minimal mode setting and nothing else, keeping
    /// the capsule's centre where it was.
    private func followMinimalMode() {
        place(at: ScreenSpace.centre(of: panel.frame))
        render()
    }

    /// Move the window with the pointer, measured on the screen rather than in
    /// the window, so moving the window does not perturb the next reading.
    private func beginDrag() {
        dragAnchor = (panel.frame.origin, NSEvent.mouseLocation)
        wake()
    }

    private func drag(to pointer: CGPoint) {
        guard let anchor = dragAnchor else { return }
        // Whole points: a window on a fraction of a point is resampled, which
        // softens the capsule's edge while it moves.
        let origin = CGPoint(
            x: (anchor.window.x + pointer.x - anchor.pointer.x).rounded(),
            y: (anchor.window.y + pointer.y - anchor.pointer.y).rounded()
        )
        panel.setFrameOrigin(origin)
    }

    private func endDrag() {
        dragAnchor = nil
        if let problem = WindowPosition.save(ScreenSpace.centre(of: panel.frame), to: controller.dataDirectory) {
            FileHandle.standardError.write(Data("\(problem)\n".utf8))
        }
        wake()
    }
}

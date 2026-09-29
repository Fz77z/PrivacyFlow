import AppKit
import PrivacyFlowCore

/// What the capsule view needs to paint one frame.
struct CapsuleAppearance {
    var hud: HudState
    /// The failure to show, only while the capsule is in the error state; after
    /// that the unread dot carries it forward.
    var failure: Failure?
    var unreadFailure: Bool
    /// The full message the cog's tooltip shows: the last failure's detail,
    /// which outlives the capsule's return to Ready along with the dot.
    var tooltip: String
    var label: (text: String, muted: Bool)
    /// Seconds since the dictation settled, which drives the pop and the shake.
    var settledFor: Double?
    var voiceBars: [Float]
    var minimal: Bool
    /// The size to paint at, which is animated and usually between the three.
    var painted: CGSize
}

/// Paints the capsule into its window and turns the user's clicks and drags
/// into requests. It holds no dictation state of its own.
final class CapsuleView: NSView, NSViewToolTipOwner, NSMenuDelegate {
    /// The mark's four bars, as fractions of its box: position and resting
    /// height. Every state paints the same silhouette.
    private static let bars: [(x: CGFloat, resting: CGFloat)] = [(0.00, 0.27), (0.26, 0.67), (0.52, 0.37), (0.78, 0.57)]
    private static let barWidthFraction: CGFloat = 4 / 36

    /// The transcribing wave: fast and wide enough to read as moving at bead size.
    private static let waveSpeed: CGFloat = 7
    private static let waveSpacing: CGFloat = 0.9
    private static let waveFloor: CGFloat = 0.3
    private static let waveSwing: CGFloat = 0.5
    /// The success pop and the failure shake.
    private static let popSeconds = 0.32
    private static let popHeight: CGFloat = 0.45
    private static let shakeSeconds = 0.42
    private static let shakeSpeed = 42.0
    private static let shakeWidth: CGFloat = 0.11

    /// One thin stroke weight throughout the cog: heavy lines turn a small
    /// glyph into a drawing of a cog rather than an icon of one.
    private static let cogStroke: CGFloat = 1.1
    private static let cogRing: CGFloat = 5.4
    private static let cogHub: CGFloat = 1.9
    private static let cogTeeth = 8
    private static let unreadDotOffset: CGFloat = 8
    /// The opacity of the fill that makes the cog's opening zone part of the
    /// window as far as macOS hit-testing is concerned. Transparent pixels pass
    /// the mouse through, and this is the faintest fill that does not.
    private static let openingZoneAlpha: CGFloat = 1.0 / 255
    /// Soft and close, so the capsule reads as resting just above the desktop.
    private static let shadowBlur: CGFloat = 14
    private static let shadowOffset: CGFloat = 3

    var look: CapsuleAppearance? {
        didSet { needsDisplay = true }
    }

    /// Requests from the user, answered by the window controller.
    var onCog: (() -> Void)?
    var onOpenConsole: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onPointerMoved: (() -> Void)?
    private(set) var menuOpen = false

    private var cogPressed = false
    private var dragging = false
    private var tooltipTag: NSView.ToolTipTag?

    override var isFlipped: Bool { true }

    /// A click on a window of an inactive app is still a click on the capsule.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipTag = addToolTip(fullCogRect, owner: self, userData: nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let appearance = look, let context = NSGraphicsContext.current?.cgContext else { return }
        let room = bounds
        let edge = CapsuleGeometry.edgeWidth
        // The outline sits outside the shape, so the shape leaves it room: with
        // minimal mode off the window is exactly the capsule.
        let painted = CGSize(
            width: min(appearance.painted.width, room.width - edge * 2),
            height: min(appearance.painted.height, room.height - edge * 2)
        )
        let rect = capsuleRect(painted)
        let radius = rect.height / 2

        // In minimal mode the zone around the cog opens the capsule, and it has
        // to receive the mouse itself: see CapsuleWindowController.
        if appearance.minimal {
            let centre = CapsuleGeometry.buttonCentre(windowCentre: CGPoint(x: bounds.midX, y: bounds.midY))
            let side = CapsuleGeometry.openingZone
            context.setFillColor(NSColor.black.withAlphaComponent(Self.openingZoneAlpha).cgColor)
            context.fill(CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
        }

        // A shadow only where the window has room for it, or it would be cut
        // off square at the window's edge.
        let shadowRoom = room.insetBy(dx: Self.shadowBlur / 2 + Self.shadowOffset, dy: Self.shadowBlur / 2 + Self.shadowOffset)
        if shadowRoom.contains(rect) {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -Self.shadowOffset), blur: Self.shadowBlur, color: NSColor.black.withAlphaComponent(0.43).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(Theme.fill.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        // The outline is a solid pill with the fill laid on top, not a stroke
        // beside it: where a stroke and a fill meet, each anti-aliases half
        // the edge and the desktop shows through as a light hairline.
        if !appearance.minimal {
            let outline = rect.insetBy(dx: -edge, dy: -edge)
            context.addPath(CGPath(roundedRect: outline, cornerWidth: radius + edge, cornerHeight: radius + edge, transform: nil))
            context.setFillColor(borderColor(appearance).cgColor)
            context.fillPath()
        }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(Theme.fill.cgColor)
        context.fillPath()

        // The contents fade in as the capsule grows out of the cog: the mark
        // across the growth to the dictating size, the label across the rest.
        let markRect = CapsuleGeometry.markRect(in: rect)
        let markShowing = CapsuleGeometry.progress(painted.width, from: CapsuleGeometry.beadSize.width, to: CapsuleGeometry.activeSize.width)
        if markShowing > 0 {
            context.saveGState()
            context.setAlpha(markShowing)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            paintMark(context, in: markRect, appearance: appearance)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        let labelShowing = CapsuleGeometry.progress(painted.width, from: CapsuleGeometry.activeSize.width, to: CapsuleGeometry.fullSize.width)
        if labelShowing > 0 {
            paintLabel(in: rect, after: markRect, appearance: appearance, opacity: labelShowing)
        }
        paintCog(context, in: rect, appearance: appearance)
    }

    private func capsuleRect(_ size: CGSize) -> CGRect {
        let button = CapsuleGeometry.buttonCentre(windowCentre: CGPoint(x: bounds.midX, y: bounds.midY))
        return CapsuleGeometry.capsuleRect(button: button, size: size)
    }

    /// The cog's reach at full size, which is where it can be clicked and
    /// where its tooltip lives. The cog never moves, so neither does this.
    private var fullCogRect: CGRect {
        let centre = CapsuleGeometry.buttonCentre(windowCentre: CGPoint(x: bounds.midX, y: bounds.midY))
        let side = CapsuleGeometry.iconSize
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    private func borderColor(_ appearance: CapsuleAppearance) -> NSColor {
        if appearance.failure != nil { return Theme.errorBorder }
        switch appearance.hud {
        case .listening: return Theme.borderListening
        case .processing: return Theme.borderTranscribing
        case .done, .copied: return Theme.borderInserted
        default: return Theme.border
        }
    }

    private enum Bar {
        case filled(NSColor)
        case hollow(NSColor)
    }

    /// Filled bars read as live, hollow as unlit, like a signal meter that has
    /// lost its signal. Each failure kind has its own shape, so the mark
    /// answers "was anything lost?" before the words are read.
    private func barStyles(_ appearance: CapsuleAppearance) -> [Bar] {
        guard let failure = appearance.failure else {
            let colour: NSColor
            switch appearance.hud {
            case .listening: colour = Theme.listening
            case .processing: colour = Theme.transcribing
            case .done, .copied: colour = Theme.inserted
            default: colour = Theme.idle
            }
            return Array(repeating: .filled(colour), count: 4)
        }
        switch failure.kind {
        // Never lit: the dictation did not start.
        case .blocked: return Array(repeating: .hollow(Theme.error), count: 4)
        // The input itself is shut, so the bars are dead rather than absent.
        case .inputUnavailable: return Array(repeating: .filled(Theme.markDead), count: 4)
        // Lit, then dropped: the shape of a lost connection.
        case .dropped: return [.filled(Theme.error), .filled(Theme.error), .hollow(Theme.markUnlit), .hollow(Theme.markUnlit)]
        }
    }

    private func paintMark(_ context: CGContext, in box: CGRect, appearance: CapsuleAppearance) {
        let rect = box.offsetBy(dx: shake(appearance) * box.width, dy: 0)
        let barWidth = rect.width * Self.barWidthFraction
        // The hollow stroke scales with the box, or the narrower dictating bars
        // would have no hollow left inside them.
        let hollowStroke = 1.4 * rect.width / 36
        let styles = barStyles(appearance)
        for (index, bar) in Self.bars.enumerated() {
            let height = rect.height * barHeight(appearance, index: index, resting: bar.resting)
            let barRect = CGRect(x: rect.minX + rect.width * bar.x, y: rect.midY - height / 2, width: barWidth, height: height)
            let path = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: min(barWidth / 2, height / 2), transform: nil)
            context.addPath(path)
            switch styles[index] {
            case .filled(let colour):
                context.setFillColor(colour.cgColor)
                context.fillPath()
            case .hollow(let colour):
                context.setStrokeColor(colour.cgColor)
                context.setLineWidth(hollowStroke)
                context.strokePath()
            }
        }
        // The one mark that adds a stroke: it crosses the bars, which is how a
        // muted input reads everywhere else on the system.
        if appearance.failure?.kind == .inputUnavailable {
            let inset = 2 * rect.width / 36
            context.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
            context.setStrokeColor(Theme.error.cgColor)
            context.setLineWidth(2.4 * rect.width / 36)
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    /// How tall a bar stands, as a fraction of the box. Each moving state has
    /// its own motion as well as its own colour, because colour alone fails
    /// anyone who cannot tell red from green.
    private func barHeight(_ appearance: CapsuleAppearance, index: Int, resting: CGFloat) -> CGFloat {
        if appearance.failure != nil { return resting }
        switch appearance.hud {
        case .listening:
            // Silence shows the mark's own shape, and the voice lifts each bar
            // from there towards the top.
            return resting + (1 - resting) * CGFloat(appearance.voiceBars[index])
        case .processing:
            let phase = CGFloat(Monotonic.now()) * Self.waveSpeed - CGFloat(index) * Self.waveSpacing
            return Self.waveFloor + Self.waveSwing * (sin(phase) * 0.5 + 0.5)
        case .done, .copied:
            guard let settledFor = appearance.settledFor else { return resting }
            let progress = min(max(settledFor / Self.popSeconds, 0), 1)
            return min(resting * (1 + sin(progress * .pi) * Self.popHeight), 1)
        default:
            return resting
        }
    }

    /// A few quick swings that die away, like a head shaking no.
    private func shake(_ appearance: CapsuleAppearance) -> CGFloat {
        guard appearance.failure != nil, let settledFor = appearance.settledFor, settledFor < Self.shakeSeconds else { return 0 }
        let dying = 1 - settledFor / Self.shakeSeconds
        return CGFloat(sin(settledFor * Self.shakeSpeed)) * Self.shakeWidth * CGFloat(dying * dying)
    }

    /// The label, cut short with an ellipsis rather than painted through the
    /// cog. The whole message is on the cog's tooltip and in the console.
    private func paintLabel(in rect: CGRect, after mark: CGRect, appearance: CapsuleAppearance, opacity: CGFloat) {
        let text: String
        let font: NSFont
        let colour: NSColor
        if let failure = appearance.failure {
            (text, font, colour) = (failure.headline, Theme.errorFont(), Theme.errorText)
        } else {
            (text, font, colour) = (appearance.label.text, Theme.labelFont(), appearance.label.muted ? Theme.muted : Theme.label)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour.withAlphaComponent(opacity),
            .paragraphStyle: paragraph,
        ]
        let height = ceil(font.ascender - font.descender)
        let labelRect = CGRect(x: mark.maxX + CapsuleGeometry.markGap, y: rect.midY - height / 2, width: CapsuleGeometry.labelRoom, height: height)
        NSAttributedString(string: text, attributes: attributes).draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The cog opens the console. It is there at every size, and in minimal
    /// mode it is the whole capsule at rest.
    private func paintCog(_ context: CGContext, in rect: CGRect, appearance: CapsuleAppearance) {
        let scale = rect.height / CapsuleGeometry.fullSize.height
        let centre = CapsuleGeometry.cogCentre(in: rect)
        let side = CapsuleGeometry.iconSize * scale
        let iconRect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        if cogHovered() {
            let radius = CapsuleGeometry.iconRadius * scale
            context.addPath(CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(Theme.iconHover.cgColor)
            context.fillPath()
        }
        let tint = appearance.failure != nil || appearance.unreadFailure ? Theme.iconAlert : Theme.iconTint
        context.setStrokeColor(tint.cgColor)
        context.setLineWidth(Self.cogStroke)
        context.setLineCap(.round)
        context.strokeEllipse(in: CGRect(x: centre.x - Self.cogRing, y: centre.y - Self.cogRing, width: Self.cogRing * 2, height: Self.cogRing * 2))
        context.strokeEllipse(in: CGRect(x: centre.x - Self.cogHub, y: centre.y - Self.cogHub, width: Self.cogHub * 2, height: Self.cogHub * 2))
        for tooth in 0..<Self.cogTeeth {
            // Offset by half a step so no tooth sits on the vertical, which
            // reads as an arrow rather than part of a ring.
            let angle = 2 * CGFloat.pi * (CGFloat(tooth) + 0.5) / CGFloat(Self.cogTeeth)
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let inner = Self.cogRing - Self.cogStroke / 2
            context.move(to: CGPoint(x: centre.x + direction.x * inner, y: centre.y + direction.y * inner))
            context.addLine(to: CGPoint(x: centre.x + direction.x * CapsuleGeometry.cogToothTip, y: centre.y + direction.y * CapsuleGeometry.cogToothTip))
        }
        context.strokePath()
        // The dot survives the capsule returning to Ready, so a failure that
        // happened while the user was typing elsewhere is still there to find.
        if appearance.unreadFailure {
            let dot = CGPoint(x: centre.x + Self.unreadDotOffset, y: centre.y - Self.unreadDotOffset)
            context.setFillColor(Theme.fill.cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9))
            context.setFillColor(Theme.unreadDot.cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7))
        }
    }

    // MARK: Pointer

    /// The capsule never becomes key, so macOS ignores the cursor rects that
    /// would set the arrow; the app underneath set the cursor last, so the
    /// capsule claims it directly.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        needsDisplay = true
        onPointerMoved?()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        needsDisplay = true
        onPointerMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
        onPointerMoved?()
    }

    /// Whether the pointer is on the cog, read from where it is now rather than
    /// kept from entered and exited events: leaving the capsule over its
    /// transparent pixels sends the events to the window underneath, so an
    /// exit is not guaranteed to arrive here.
    private func cogHovered() -> Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return fullCogRect.contains(point) && paintedRect.contains(point)
    }

    /// The capsule as painted right now, which is what can be grabbed.
    private var paintedRect: CGRect {
        capsuleRect(look?.painted ?? CapsuleGeometry.fullSize)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard paintedRect.contains(point) else { return }
        if fullCogRect.contains(point) {
            cogPressed = true
            return
        }
        dragging = true
        onDragStarted?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        NSCursor.closedHand.set()
        onDragged?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        if cogPressed {
            cogPressed = false
            if fullCogRect.contains(convert(event.locationInWindow, from: nil)) {
                onCog?()
            }
            return
        }
        if dragging {
            dragging = false
            NSCursor.arrow.set()
            onDragEnded?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard paintedRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open console", action: #selector(openConsoleChosen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit PrivacyFlow", action: #selector(quitChosen), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openConsoleChosen() { onOpenConsole?() }
    @objc private func quitChosen() { onQuit?() }

    /// A menu can hang outside the capsule, and the capsule must not shrink or
    /// let clicks through while the user is choosing.
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        onPointerMoved?()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        onPointerMoved?()
    }

    var isDragging: Bool { dragging }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        look?.tooltip ?? "Open console"
    }
}

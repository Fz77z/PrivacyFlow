import CoreGraphics
import Foundation

/// The capsule's shapes and layout, in top-left, y-down points.
///
/// Kept apart from the drawing so the geometry can be tested at every size the
/// animation passes through, not only at the three it rests at.
public enum CapsuleGeometry {
    /// The three shapes the capsule is painted as. All are pills, so none
    /// carries a radius: the radius is half the painted height throughout.
    public static let fullSize = CGSize(width: 216, height: 56)
    /// The capsule at rest in minimal mode: just the cog in a small circle.
    public static let beadSize = CGSize(width: 32, height: 32)
    /// The dictating size: the bars and the cog side by side, with no label.
    public static let activeSize = CGSize(width: 88, height: 44)
    /// The window in minimal mode, larger than the full capsule so it can grow
    /// in place with room for its shadow. Clicks outside the capsule pass through.
    public static let catchmentSize = CGSize(width: 320, height: 120)

    public static let padLeft: CGFloat = 17
    public static let padRight: CGFloat = 10
    /// The mark at full size. Smaller capsules scale it by their height.
    public static let markSize = CGSize(width: 36, height: 30)
    public static let markGap: CGFloat = 11
    public static let iconSize: CGFloat = 36
    public static let iconRadius: CGFloat = 11
    /// The outline, drawn outside the shape.
    public static let edgeWidth: CGFloat = 1
    /// The smallest gap between the mark and the capsule's edge.
    static let markInset: CGFloat = 3
    /// How far past the resting cog the pointer counts as on it, so the small
    /// target opens without having to be hit exactly.
    public static let buttonMargin: CGFloat = 6
    /// The side of the square around the cog that opens a minimal capsule:
    /// the bead plus its margin.
    public static var openingZone: CGFloat { beadSize.width + buttonMargin * 2 }
    /// The cog's tooth tips, which is its reach from its centre.
    public static let cogToothTip: CGFloat = 8

    /// Which of the three shapes the capsule is wearing.
    public enum Size: Equatable, Sendable {
        case bead, active, full

        public var points: CGSize {
            switch self {
            case .bead: beadSize
            case .active: activeSize
            case .full: fullSize
            }
        }
    }

    /// What the capsule is entitled to be. Every input is something the user
    /// is doing, so the app never changes the capsule's shape on its own.
    /// `dictating` runs from the key going down until the result has been shown.
    public static func size(minimal: Bool, pointing: Bool, dictating: Bool) -> Size {
        guard minimal else { return .full }
        if pointing { return .full }
        if dictating { return .active }
        return .bead
    }

    /// The window follows the setting and nothing else. With minimal mode off
    /// the window is exactly the capsule, so it swallows no clicks outside it.
    public static func windowSize(minimal: Bool) -> CGSize {
        minimal ? catchmentSize : fullSize
    }

    /// Where the cog sits for a window centred on `centre`: the full capsule's
    /// cog. Every size hangs from this point, so a capsule opened by pointing
    /// at the cog never moves out from under the pointer.
    public static func buttonCentre(windowCentre centre: CGPoint) -> CGPoint {
        CGPoint(x: centre.x + fullSize.width / 2 - cogInset(height: fullSize.height), y: centre.y)
    }

    /// The cog is centred in the rounded right end, whatever the height.
    public static func cogInset(height: CGFloat) -> CGFloat {
        height / 2
    }

    /// The capsule's rectangle when painted at `size`, hung from the cog.
    public static func capsuleRect(button: CGPoint, size: CGSize) -> CGRect {
        let right = button.x + cogInset(height: size.height)
        return CGRect(x: right - size.width, y: button.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the mark goes for a capsule painted at any size: at the left end,
    /// scaled with the height, and clamped inside so it never overhangs.
    public static func markRect(in rect: CGRect) -> CGRect {
        let scale = rect.height / fullSize.height
        let room = rect.insetBy(dx: markInset, dy: markInset)
        let size = CGSize(
            width: min(markSize.width * scale, max(room.width, 0)),
            height: min(markSize.height * scale, max(room.height, 0))
        )
        let left = min(max(rect.minX + padLeft * scale, room.minX), room.maxX - size.width)
        return CGRect(x: left, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The cog's centre for a capsule painted at `rect`.
    public static func cogCentre(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX - cogInset(height: rect.height), y: rect.midY)
    }

    /// How far `value` has travelled from `from` to `to`, clamped to 0...1.
    public static func progress(_ value: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
        min(max((value - from) / (to - from), 0), 1)
    }

    /// The width the label has between the mark and the cog in the full
    /// capsule. Measured at full size, because fitting it to a half-grown gap
    /// cut every word down to a lone ellipsis while it was still fading in.
    public static var labelRoom: CGFloat {
        let capsule = CGRect(origin: .zero, size: fullSize)
        let mark = markRect(in: capsule)
        let iconLeft = capsule.maxX - padRight - iconSize
        return iconLeft - (mark.maxX + markGap)
    }

    /// What the capsule says in each healthy state, and whether it is muted.
    public static func label(for hud: HudState, processing: String) -> (text: String, muted: Bool) {
        switch hud {
        case .idle, .error: ("Ready", true)
        case .listening: ("Listening", false)
        case .processing: (processing, false)
        case .done: ("Inserted", false)
        case .copied: ("Copied", false)
        // Muted like Ready: nothing was said, so nothing happened.
        case .noSpeech: ("No speech", true)
        // Not muted: the user spoke and their words were discarded.
        case .notUnderstood: ("Didn't catch that", false)
        }
    }
}

/// Where the toast goes, as a top-left corner in y-down points.
///
/// Placed from the capsule rather than a corner of the screen, because the
/// capsule is where the user has chosen to have PrivacyFlow speak to them.
/// Above it, unless the capsule is parked at the top of its display.
public enum ToastPlacement {
    public static let width: CGFloat = 320
    public static let gap: CGFloat = 12

    public static func place(capsule: Centre, capsuleSize: CGSize, toast: CGSize, areas: [WorkArea]) -> (x: Double, y: Double) {
        let above = capsule.y - capsuleSize.height / 2 - gap - toast.height / 2
        let below = capsule.y + capsuleSize.height / 2 + gap + toast.height / 2
        let fitsAbove = WindowPosition.area(for: capsule, in: areas).map { above - toast.height / 2 >= $0.y } ?? true
        let centre = Centre(x: capsule.x, y: fitsAbove ? above : below)
        return WindowPosition.place(centre, size: toast, areas: areas)
    }
}

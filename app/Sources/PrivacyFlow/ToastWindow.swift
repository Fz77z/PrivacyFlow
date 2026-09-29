import AppKit
import PrivacyFlowCore

/// The toast: what PrivacyFlow says when a dictation ends on the clipboard
/// instead of at the cursor, or is heading for refusal while it can be saved.
///
/// The window is inert on purpose. It cannot be clicked, so it never takes
/// focus and never swallows a click aimed at the app underneath.
@MainActor
final class ToastWindowController {
    private static let padding: CGFloat = 14
    private static let lineGap: CGFloat = 6
    /// Past three lines the toast stops being a notice; the whole text is in the
    /// console and on the clipboard.
    private static let bodyRows = 3
    /// How far the contents rise as the toast appears. The window itself never
    /// moves, because repositioning a window every frame stutters.
    private static let rise: CGFloat = 8
    private static let fadeIn = 0.14
    private static let fadeOut = 0.22

    private let panel: FloatingPanel
    private let view = ToastView()
    private var shown: Toast?

    init() {
        panel = FloatingPanel(size: CGSize(width: ToastPlacement.width, height: 100))
        panel.ignoresMouseEvents = true
        panel.contentView = view
    }

    /// Show `toast` beside the capsule, or hide the window when there is none.
    /// Returns whether a toast is on screen and still animating its fade.
    func show(_ toast: Toast?, capsule: Centre) -> Bool {
        guard let toast else {
            if shown != nil {
                panel.orderOut(nil)
                shown = nil
            }
            return false
        }
        if shown != toast {
            shown = toast
            view.toast = toast
            let size = CGSize(width: ToastPlacement.width, height: view.fittingHeight)
            let topLeft = ToastPlacement.place(capsule: capsule, capsuleSize: CapsuleGeometry.fullSize, toast: size, areas: ScreenSpace.workAreas)
            panel.setFrame(ScreenSpace.frame(topLeft: topLeft, size: size), display: false)
            panel.orderFrontRegardless()
        }
        let elapsed = Monotonic.now() - toast.raisedAt
        let arriving = Self.easeOut(min(max(elapsed / Self.fadeIn, 0), 1))
        let leaving = Self.easeOut(min(max((Toast.dwell - elapsed) / Self.fadeOut, 0), 1))
        view.opacity = CGFloat(min(arriving, leaving))
        view.rise = Self.rise * CGFloat(1 - arriving)
        view.needsDisplay = true
        return true
    }

    #if DEBUG
    /// The panel, for the preview harness to capture.
    var panelForPreview: NSWindow { panel }
    #endif

    /// Fast at first and slowing into place, the way things come to rest.
    private static func easeOut(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// Paints a toast's headline, body and footer.
    private final class ToastView: NSView {
        var toast: Toast?
        var opacity: CGFloat = 0
        var rise: CGFloat = 0

        override var isFlipped: Bool { true }

        private var headlineFont: NSFont { Theme.labelFont() }
        private var bodyFont: NSFont { Theme.bodyFont(13) }
        private var footerFont: NSFont { Theme.bodyFont(11) }
        private var textWidth: CGFloat { ToastPlacement.width - padding * 2 }

        /// Laid out before the window is sized, so the window fits the words
        /// rather than the words being squeezed into a guessed window.
        var fittingHeight: CGFloat {
            padding * 2 + lineHeight(headlineFont) + lineGap + bodyHeight + lineGap + lineHeight(footerFont)
        }

        private var bodyHeight: CGFloat {
            guard let toast else { return 0 }
            let measured = body(toast.body).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
            return min(ceil(measured), lineHeight(bodyFont) * CGFloat(bodyRows))
        }

        private func body(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: Theme.label.withAlphaComponent(opacity)])
        }

        private func lineHeight(_ font: NSFont) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: font))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let toast, let context = NSGraphicsContext.current?.cgContext else { return }
            let (headlineColour, border): (NSColor, NSColor)
            switch toast.kind {
            case .copied: (headlineColour, border) = (Theme.label, Theme.borderInserted)
            case .failed: (headlineColour, border) = (Theme.errorText, Theme.errorBorder)
            // Amber, not red: nothing has gone wrong yet, and the user can still act.
            case .quiet: (headlineColour, border) = (Theme.warningText, Theme.warningBorder)
            }
            let rect = bounds.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: rise)
            // The outline is a filled shape with the fill on top, like the
            // capsule's, so no hairline of desktop shows between them.
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.setFillColor(border.withAlphaComponent(opacity).cgColor)
            context.fillPath()
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 13, cornerHeight: 13, transform: nil))
            context.setFillColor(Theme.fill.withAlphaComponent(opacity).cgColor)
            context.fillPath()

            var top = rect.minY + padding - 1
            let left = rect.minX + padding - 1
            NSAttributedString(string: toast.headline, attributes: [.font: headlineFont, .foregroundColor: headlineColour.withAlphaComponent(opacity)])
                .draw(with: CGRect(x: left, y: top, width: textWidth, height: lineHeight(headlineFont)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            top += lineHeight(headlineFont) + lineGap
            body(toast.body).draw(with: CGRect(x: left, y: top, width: textWidth, height: bodyHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            top += bodyHeight + lineGap
            NSAttributedString(string: toast.footer, attributes: [.font: footerFont, .foregroundColor: Theme.muted.withAlphaComponent(opacity)])
                .draw(with: CGRect(x: left, y: top, width: textWidth, height: lineHeight(footerFont)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

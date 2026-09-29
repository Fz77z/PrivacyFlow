import AppKit
import SwiftUI

/// An ordinary titled window around a SwiftUI view, in the app's dark look.
/// Used for the console and for setup, both of which take focus and keystrokes
/// like any other window.
@MainActor
final class HostedWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    var onClose: (() -> Void)?

    init<Content: View>(title: String, size: CGSize, minimumSize: CGSize?, content: Content) {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if minimumSize != nil {
            style.insert(.resizable)
            style.insert(.miniaturizable)
        }
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        super.init()
        window.title = title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.fill
        window.isReleasedWhenClosed = false
        // While this window is key, pointer movement anywhere is delivered to
        // PrivacyFlow rather than to other apps, and the capsule's minimal mode
        // needs to hear it.
        window.acceptsMouseMovedEvents = true
        if let minimumSize {
            window.contentMinSize = minimumSize
        }
        let host = NSHostingView(rootView: content)
        // The window keeps the size it was given; the content scrolls or wraps
        // inside it rather than growing the window to its ideal height.
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.center()
    }

    /// Show and raise it. Activation is only a request since macOS 14 and can
    /// be declined, so the window is also put in front regardless, rather than
    /// opening somewhere behind the app the user is in.
    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    #if DEBUG
    /// The window, for the preview harness to capture.
    var windowForPreview: NSWindow { window }
    #endif

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

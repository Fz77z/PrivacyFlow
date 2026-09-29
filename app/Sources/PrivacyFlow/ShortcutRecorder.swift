import AppKit
import PrivacyFlowCore

/// Records a new dictation shortcut from the keys the user presses next.
///
/// It listens to PrivacyFlow's own key events, which needs no permission: the
/// Settings row it serves is in the console, which is the key window while the
/// user presses the keys. A modifier on its own is taken when it comes up
/// without any key having joined it; a key is taken with whatever modifiers
/// are held when it goes down. Escape cancels.
///
/// While it records, the tap is off, so dictation is paused. Recording ends,
/// and the tap comes back, when PrivacyFlow stops being the active app or the
/// window hosting the recorder closes, whether or not SwiftUI tears the row
/// down: a closed window can outlive its views.
@MainActor
final class ShortcutRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        /// The last attempt was refused, and why.
        case refused(String)
    }

    @Published private(set) var state = State.idle

    private let controller: AppController
    private var monitor: Any?
    /// Notification observers that end the recording from outside the row.
    private var endObservers: [NSObjectProtocol] = []
    /// A modifier pressed on its own, which becomes the shortcut if it comes
    /// up before anything joins it.
    private var loneModifier: SideModifier?

    init(controller: AppController) {
        self.controller = controller
        #if DEBUG
        if let preview = Self.previewState {
            state = preview
        }
        #endif
    }

    #if DEBUG
    /// Debug builds only: the state a preview screenshot starts the row in.
    static var previewState: State?
    #endif

    func start() {
        guard state != .recording else { return }
        state = .recording
        loneModifier = nil
        controller.beginRecordingShortcut()
        let center = NotificationCenter.default
        endObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        // The window with the row in it is the key window: the user just
        // clicked Record there.
        if let window = NSApp.keyWindow {
            endObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Swallowed while recording, so the keys do not also type into
            // the console or trigger its shortcuts.
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func cancel() {
        guard state == .recording else { return }
        finish(with: nil)
        state = .idle
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .keyDown:
            loneModifier = nil
            if event.isARepeat { return }
            var modifiers = SideModifier.pressed(in: flags)
            if event.keyCode == 53 && modifiers.subtracting([.function]).isEmpty {
                cancel()
                return
            }
            // Many keyboards set the Fn flag themselves for function, arrow
            // and navigation keys, so it counts only for other keys.
            if Self.setsFunctionFlagItself(event.keyCode) {
                modifiers.remove(.function)
            }
            offer(Shortcut(keyCode: event.keyCode, modifiers: modifiers))
        case .flagsChanged:
            let pressed = SideModifier.pressed(in: flags)
            guard let changed = SideModifier(keyCode: event.keyCode) else { return }
            if pressed.contains(changed) {
                loneModifier = pressed == [changed] ? changed : nil
            } else if loneModifier == changed && pressed.isEmpty {
                offer(Shortcut(modifier: changed))
            } else {
                loneModifier = nil
            }
        default:
            break
        }
    }

    /// Take a candidate, unless it would break ordinary typing. A warned one is
    /// taken; the Settings row shows its warning for as long as it is in use.
    private func offer(_ shortcut: Shortcut) {
        if case .refused(let reason) = shortcut.assessment {
            finish(with: nil)
            state = .refused(reason)
            return
        }
        finish(with: shortcut)
        state = .idle
    }

    private func finish(with shortcut: Shortcut?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        loneModifier = nil
        controller.endRecordingShortcut(with: shortcut)
    }

    private static func setsFunctionFlagItself(_ keyCode: UInt16) -> Bool {
        KeyNames.functionKeys.contains(keyCode) || [114, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(keyCode)
    }
}

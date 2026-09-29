import AppKit
import Combine

/// PrivacyFlow's icon in the menu bar: its permanent home wherever the capsule
/// is. It opens the console, shows the capsule, quits, and turns red while a
/// failure is unread, because that is when the user is back at work and not
/// looking at the capsule.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: AppController
    private var subscription: AnyCancellable?
    private var shownAlert: String??

    init(controller: AppController) {
        self.controller = controller
        super.init()
        if let button = item.button {
            let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "PrivacyFlow")
            // A template, so macOS draws it in the menu bar's own colour.
            icon?.isTemplate = true
            button.image = icon
            button.toolTip = "PrivacyFlow"
        }
        let menu = NSMenu()
        menu.addItem(menuItem("Show Capsule", #selector(showCapsule)))
        menu.addItem(menuItem("Open Console", #selector(openConsole)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit PrivacyFlow", #selector(quit), key: "q"))
        self.item.menu = menu
        subscription = controller.$state.sink { [weak self] state in
            let detail = state.unreadFailure ? (state.lastFailure?.detail ?? "A dictation failed") : nil
            self?.showAlert(detail)
        }
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    /// Red with the failure in its tooltip, or back to normal with nil. Only
    /// touched when it changes.
    private func showAlert(_ detail: String?) {
        guard shownAlert != .some(detail), let button = item.button else { return }
        shownAlert = .some(detail)
        button.contentTintColor = detail == nil ? nil : .systemRed
        button.toolTip = detail.map { "PrivacyFlow: \($0)" } ?? "PrivacyFlow"
    }

    @objc private func showCapsule() { controller.showCapsuleOnRequest() }
    @objc private func openConsole() { controller.openConsole() }
    @objc private func quit() { controller.quit() }
}

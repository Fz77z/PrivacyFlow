import AppKit
import ApplicationServices
import PrivacyFlowCore

/// Placing text at the cursor: the pasteboard, then a synthetic Cmd-V.
///
/// The text is left on the pasteboard afterwards. Restoring the previous
/// clipboard on a timer raced the target's asynchronous paste handling and
/// could insert the older contents instead of the dictation.
enum Inserter {
    /// How long an application is given to say what has focus. The slowest
    /// first answer measured was 413 ms, from a Finder window whose tree had
    /// not been built, so a second is slack rather than a budget.
    static let accessibilityTimeout: Float = 1

    private static let vKeyCode: CGKeyCode = 0x09

    /// Whether the thing with the keyboard in an application can take text.
    /// Three answers, because an application that answers nothing has not
    /// refused: treating silence as "no" would stop PrivacyFlow pasting into
    /// every app without an accessibility tree.
    enum FocusedField {
        case editable
        case notEditable
        case unknown
    }

    /// The frontmost application's process, without activating anything.
    static func frontmostPid() -> Int32? {
        NSWorkspace.shared.frontmostApplication.map(\.processIdentifier).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Put text on the pasteboard and nothing else. Preserving is not inserting.
    static func copy(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertionProblem("Could not put the text on the clipboard")
        }
    }

    /// Put a failed dictation's words where the user can reach them, reporting
    /// what happened rather than throwing, because a failure here must never
    /// replace the failure that lost the dictation.
    static func preserve(_ text: String, as kind: Preserved) -> Preserved {
        guard !text.isEmpty else { return .unavailable("there was no text to keep") }
        do {
            try copy(text)
            return kind
        } catch {
            return .unavailable("\(error)")
        }
    }

    /// Paste `text` into `targetPid`.
    ///
    /// The pasteboard is written first, before anything that can refuse, so
    /// every path from here leaves the user holding their words. The one case
    /// where PrivacyFlow cannot place them is the case where they need them most.
    ///
    /// Nothing is posted while the dictation key is held: the queue already
    /// waited for it, and it is checked again just before the Cmd-V, because
    /// the key can go down again during the accessibility question, which can
    /// take up to a second. If it did, the paste waits and asks again.
    static func insert(_ text: String, into targetPid: Int32, placement: PlacementQueue) throws -> Insertion {
        try copy(text)
        // A configuration fault with a specific fix, so it is a failure rather
        // than a quiet copy that would hide the only message saying how to fix it.
        guard AXIsProcessTrusted() else {
            throw InsertionProblem("PrivacyFlow is not allowed to send keystrokes, so the text could not be pasted. It is on your clipboard: press Cmd-V to place it. To fix this, turn on PrivacyFlow in System Settings, Privacy & Security, Accessibility, then quit and reopen PrivacyFlow.")
        }
        while true {
            placement.waitUntilKeyUp()
            // Pasting somewhere the user is no longer looking would put text
            // into the wrong document, which is worse than not pasting at all.
            guard frontmostPid() == targetPid else {
                return .copiedOnly
            }
            // Only a positive "that is not a text field" stops the paste.
            if focusedField(of: targetPid) == .notEditable {
                return .copiedNoField
            }
            if !placement.isKeyHeld {
                break
            }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw InsertionProblem("Could not create the Cmd-V that pastes the text")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Posted at the session tap, below PrivacyFlow's own HID tap, so its own
        // paste never counts as the user moving the cursor.
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return .pasted
    }

    /// Ask whether the focused element's value can be set, which is what "you
    /// can type here" means to accessibility. Every real input says yes; a
    /// Finder file list, a browser page body and a chat app's channel list say no.
    static func focusedField(of pid: Int32) -> FocusedField {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, accessibilityTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .unknown
        }
        var settable = DarwinBoolean(false)
        // A failed call means the application could not answer, not that it said no.
        guard AXUIElementIsAttributeSettable(focused as! AXUIElement, kAXValueAttribute as CFString, &settable) == .success else {
            return .unknown
        }
        return settable.boolValue ? .editable : .notEditable
    }
}

/// Why text could not be placed.
struct InsertionProblem: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

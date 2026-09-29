import Carbon
import CoreGraphics
import Foundation
import os
import PrivacyFlowCore

/// Whether the user has pressed a key or a mouse button since this was last
/// asked, shared between the event tap and the pipeline, which is where a stale
/// memory of the cursor would do damage.
final class CursorMoved: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    /// Asking clears it, because each dictation only cares about the interval
    /// since the one before.
    func take() -> Bool {
        flag.withLock { moved in
            defer { moved = false }
            return moved
        }
    }

    fileprivate func record() {
        flag.withLock { $0 = true }
    }
}

/// The event tap that watches the dictation shortcut.
///
/// A modifier on its own types nothing, so it is watched with a listen-only
/// tap that leaves every event untouched. Any other key would also reach the
/// app in front, so it is watched with an active tap that swallows exactly
/// that key's down, repeat and up events for a press it claimed, and nothing
/// else. Which events those are is decided by `ShortcutMatcher`.
///
/// The same tap notices any key press or mouse button that is not the
/// shortcut's, which is how the paste spacing knows its memory of the cursor
/// has gone stale. Those events are counted, never read. PrivacyFlow's own
/// Cmd-V is posted at the session tap, below this one, so it never counts.
final class Hotkey {
    enum Event {
        case pressed
        /// Any part of the shortcut came up: the dictation ends.
        case released
        /// The shortcut turned out to be part of a chord.
        case cancelled
        /// Every part of the press is up, so pastes may go ahead.
        case allReleased
    }

    let cursorMoved: CursorMoved
    let shortcut: Shortcut
    private let state: TapState
    private let port: CFMachPort
    private let source: CFRunLoopSource
    private var runLoop: CFRunLoop?

    /// What the tap callback reads, on the tap's thread, and what the main
    /// thread asks when it reads the keyboard directly.
    private final class TapState: @unchecked Sendable {
        let cursorMoved: CursorMoved
        let onEvent: (Event) -> Void
        let matcher: OSAllocatedUnfairLock<ShortcutMatcher>
        var port: CFMachPort?

        init(shortcut: Shortcut, cursorMoved: CursorMoved, onEvent: @escaping (Event) -> Void) {
            self.cursorMoved = cursorMoved
            self.onEvent = onEvent
            matcher = OSAllocatedUnfairLock(initialState: ShortcutMatcher(shortcut: shortcut))
        }

        /// Feed one event to the matcher and act on its answer, in order.
        /// Returns whether the event must be swallowed.
        func handle(_ event: ShortcutMatcher.Event) -> Bool {
            let (outcome, label) = matcher.withLock { ($0.handle(event), $0.shortcut.label) }
            var events: [Event] = outcome.actions.map { action in
                switch action {
                case .start: .pressed
                case .end: .released
                case .cancel: .cancelled
                }
            }
            if outcome.allReleased {
                events.append(.allReleased)
            }
            if !events.isEmpty {
                DispatchQueue.main.async { events.forEach(self.onEvent) }
            }
            if outcome.keyStateUnreadable {
                // Said once per press. Not a fault: the events and the
                // recording cap still end the dictation.
                FileHandle.standardError.write(Data("PrivacyFlow cannot read the physical state of \(label) on this keyboard, so only its events end this dictation.\n".utf8))
            }
            return outcome.swallow
        }
    }

    /// Install a tap for `shortcut`. `onEvent` is called on the main thread.
    /// `cursorMoved` is shared across taps, so replacing the tap for a new
    /// shortcut does not replace the flag the pipeline holds.
    init(shortcut: Shortcut, cursorMoved: CursorMoved, onEvent: @escaping (Event) -> Void) throws {
        self.shortcut = shortcut
        self.cursorMoved = cursorMoved
        state = TapState(shortcut: shortcut, cursorMoved: cursorMoved, onEvent: onEvent)
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: shortcut.needsKeySwallowed ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(state).toOpaque()
        ) else {
            if shortcut.needsKeySwallowed {
                throw LaunchProblem("macOS refused the event tap that keeps \(shortcut.label) from reaching other apps. That needs Accessibility: turn on PrivacyFlow in System Settings, Privacy & Security, Accessibility, then relaunch, or choose a modifier on its own as the dictation key.")
            }
            throw LaunchProblem("macOS refused to create the event tap that watches \(shortcut.label)")
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            throw LaunchProblem("macOS could not create the event tap's run loop source")
        }
        state.port = port
        self.port = port
        self.source = source
        // Its own thread, so a busy main thread can never make macOS disable
        // the tap for answering slowly.
        let started = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop?
        let thread = Thread {
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "PrivacyFlow hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        self.runLoop = runLoop
    }

    /// Remove the tap, for a new shortcut or for recording one.
    func stop() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        runLoop = nil
    }

    /// Read the keyboard directly and end a dictation whose release was lost:
    /// macOS drops events to taps while secure keyboard entry is on, and a
    /// disabled tap or a locked screen can drop them too. The matcher only
    /// trusts a reading once it has itself seen the press down.
    func checkPhysicalState() {
        let reading = physicalReading()
        _ = state.handle(.physicalState(keyDown: reading.keyDown, flags: reading.flags))
    }

    /// Whether the whole shortcut is physically down while no dictation runs,
    /// which means its press never reached the tap.
    var pressWasMissed: Bool {
        let reading = physicalReading()
        return state.matcher.withLock { !$0.isActive && $0.isFullyDown(keyDown: reading.keyDown, flags: reading.flags) }
    }

    /// Each key of the shortcut read on its own. Modifier keys are read by key
    /// code as well, so the sides are told apart without relying on which bits
    /// the flags state carries.
    private func physicalReading() -> (keyDown: Bool, flags: UInt64) {
        let flags = SideModifier.allCases.reduce(UInt64(0)) { flags, modifier in
            CGEventSource.keyState(.hidSystemState, key: CGKeyCode(modifier.keyCode)) ? flags | modifier.flagMask : flags
        }
        return (CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.keyCode)), flags)
    }

    /// Whether another app has secure keyboard entry on, which hides key
    /// events from every event tap, this one included.
    static var secureInputIsOn: Bool {
        IsSecureEventInputEnabled()
    }

    /// Never blocks: a tap that answers slowly is disabled by macOS.
    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let state = Unmanaged<TapState>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS requires a disabled tap to be re-enabled explicitly.
            if let port = state.port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            state.cursorMoved.record()
            // A click while a modifier-only shortcut is held is a chord.
            _ = state.handle(.mouseDown)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if state.handle(.keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)) {
                return nil
            }
            // A key the user typed could have moved the cursor.
            state.cursorMoved.record()
        case .keyUp:
            if state.handle(.keyUp(keyCode: keyCode, flags: flags)) {
                return nil
            }
        case .flagsChanged:
            _ = state.handle(.flagsChanged(keyCode: keyCode, flags: flags))
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

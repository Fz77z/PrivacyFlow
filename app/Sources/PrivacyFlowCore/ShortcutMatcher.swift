import Foundation

/// Turns raw keyboard and mouse events into the start and end of a dictation,
/// for one shortcut. Pure and synchronous, so the event tap can ask it, on its
/// own thread, whether to swallow each event before letting it go.
///
/// Hold semantics: a dictation starts when the whole shortcut is down and ends
/// when any part of it comes up. Key auto-repeat is ignored. A modifier held
/// on its own that turns out to be part of a chord (Option+E, Command-click,
/// Command+Tab) cancels its dictation, because the user was typing or
/// clicking, not dictating.
///
/// Separately from the dictation, it says when every part of a claimed press
/// is up again, because pasting waits for that: a key-plus-modifier shortcut
/// ends its dictation at the first part released, while the rest may still be
/// held, and a synthetic Cmd-V under a held modifier would reach the app with
/// that modifier added.
public struct ShortcutMatcher: Sendable {
    public enum Event: Sendable {
        case flagsChanged(keyCode: UInt16, flags: UInt64)
        case keyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool)
        case keyUp(keyCode: UInt16, flags: UInt64)
        /// Any mouse button went down.
        case mouseDown
        /// A reading of the keyboard itself, taken while a claimed press is
        /// held: whether the shortcut's key is physically down, and the
        /// modifiers that are. Events can be lost (secure keyboard entry, a
        /// disabled tap, a locked screen); this is what ends a press whose
        /// release was.
        case physicalState(keyDown: Bool, flags: UInt64)
    }

    public enum Action: Equatable, Sendable {
        case start
        /// Any part of the shortcut came up: finish the dictation normally.
        case end
        /// The shortcut turned out to be part of a chord: discard it.
        case cancel
    }

    public struct Outcome: Equatable, Sendable {
        /// What happens to the dictation, in order. Usually none or one; a
        /// press arriving while the last one's release was lost ends the old
        /// dictation and starts a new one.
        public var actions: [Action] = []
        /// Whether the event must be kept from other apps, because it is the
        /// shortcut's own key.
        public var swallow = false
        /// Every part of the claimed press is up, so pasting may go ahead.
        public var allReleased = false
        /// The physical reading disagreed with the events before it had ever
        /// seen the key down, so it cannot see this key and is being ignored
        /// for this press. Said once per press, for the log.
        public var keyStateUnreadable = false

        public init(actions: [Action] = [], swallow: Bool = false, allReleased: Bool = false, keyStateUnreadable: Bool = false) {
            self.actions = actions
            self.swallow = swallow
            self.allReleased = allReleased
            self.keyStateUnreadable = keyStateUnreadable
        }
    }

    private enum Phase: Sendable {
        case idle
        case active
        /// A modifier-only dictation was cancelled by a chord; nothing more
        /// happens until the modifier comes up.
        case cancelled
    }

    public let shortcut: Shortcut
    private var phase = Phase.idle
    /// Some part of a press this matcher claimed is still down.
    private var holding = false
    /// Whether the shortcut's key is down in a press this matcher claimed, so
    /// its repeats and its release are swallowed too, and only those.
    private var ownsKeyPress = false
    /// Whether the physical reading has seen this press fully down. Until it
    /// has, it is never trusted to say the press ended: on some keyboards and
    /// setups (Fn, function keys on a laptop's Fn layer, remapped modifiers)
    /// the reading never shows the key down at all, and trusting it would end
    /// every dictation a moment after it started.
    private var readingSawPressDown = false
    private var reportedUnreadable = false

    public init(shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    public var isActive: Bool { phase == .active }

    /// Whether some part of a claimed press is still down.
    public var isHolding: Bool { holding }

    public mutating func handle(_ event: Event) -> Outcome {
        if let modifier = shortcut.soleModifier {
            return handleModifier(modifier, event)
        }
        return handleKey(event)
    }

    /// Whether a physical reading shows the whole shortcut down.
    public func isFullyDown(keyDown: Bool, flags: UInt64) -> Bool {
        if let modifier = shortcut.soleModifier {
            return SideModifier.pressed(in: flags).contains(modifier)
        }
        return keyDown && modifiersMatch(flags)
    }

    private mutating func beginPress() {
        phase = .active
        holding = true
        readingSawPressDown = false
        reportedUnreadable = false
    }

    /// What a reading says when it cannot yet be trusted: nothing, except the
    /// first time in a press, so it can be logged.
    private mutating func untrustedReading() -> Outcome {
        guard !reportedUnreadable else { return Outcome() }
        reportedUnreadable = true
        return Outcome(keyStateUnreadable: true)
    }

    // MARK: A modifier on its own

    private mutating func handleModifier(_ modifier: SideModifier, _ event: Event) -> Outcome {
        switch event {
        case .flagsChanged(let keyCode, let flags):
            let pressed = SideModifier.pressed(in: flags)
            let down = pressed.contains(modifier)
            switch phase {
            case .idle:
                // Only this modifier's own key going down, on its own, starts.
                // Releasing Shift while holding it, or one Option of two, also
                // leaves the flags showing only this modifier, and is no press.
                if keyCode == modifier.keyCode && down && pressed == [modifier] {
                    beginPress()
                    return Outcome(actions: [.start])
                }
            case .active:
                if !down {
                    phase = .idle
                    holding = false
                    return Outcome(actions: [.end], allReleased: true)
                }
                if pressed != [modifier] {
                    phase = .cancelled
                    return Outcome(actions: [.cancel])
                }
            case .cancelled:
                if !down {
                    phase = .idle
                    holding = false
                    return Outcome(allReleased: true)
                }
            }
            return Outcome()
        case .keyDown, .mouseDown:
            // Any key or click while the modifier is held makes it a chord.
            // Neither is ever swallowed: they are the user's.
            if phase == .active {
                phase = .cancelled
                return Outcome(actions: [.cancel])
            }
            return Outcome()
        case .keyUp:
            return Outcome()
        case .physicalState(_, let flags):
            guard holding else { return Outcome() }
            if SideModifier.pressed(in: flags).contains(modifier) {
                readingSawPressDown = true
                return Outcome()
            }
            guard readingSawPressDown else { return untrustedReading() }
            let wasActive = phase == .active
            phase = .idle
            holding = false
            return Outcome(actions: wasActive ? [.end] : [], allReleased: true)
        }
    }

    // MARK: A key, with or without modifiers

    private mutating func handleKey(_ event: Event) -> Outcome {
        switch event {
        case .keyDown(let keyCode, let flags, let isRepeat):
            guard keyCode == shortcut.keyCode else { return Outcome() }
            var actions: [Action] = []
            var releasedLostPress = false
            if ownsKeyPress {
                // A repeat of the press already claimed: swallowed, ignored.
                if isRepeat {
                    return Outcome(swallow: true)
                }
                // A fresh press of a key this matcher thinks is still down:
                // its release was lost. That press is over; this one starts
                // afresh rather than being swallowed as its repeat.
                ownsKeyPress = false
                if phase == .active {
                    phase = .idle
                    actions.append(.end)
                }
                releasedLostPress = holding
                holding = false
            }
            guard !isRepeat, modifiersMatch(flags) else {
                return Outcome(actions: actions, allReleased: releasedLostPress)
            }
            ownsKeyPress = true
            beginPress()
            return Outcome(actions: actions + [.start], swallow: true)
        case .keyUp(let keyCode, let flags):
            guard keyCode == shortcut.keyCode, ownsKeyPress else {
                return Outcome(allReleased: releaseIfAllUp(flags))
            }
            ownsKeyPress = false
            var actions: [Action] = []
            if phase == .active {
                phase = .idle
                actions = [.end]
            }
            return Outcome(actions: actions, swallow: true, allReleased: releaseIfAllUp(flags))
        case .flagsChanged(_, let flags):
            // A required modifier coming up ends the dictation; the key's own
            // release still belongs to this press and is swallowed later.
            var actions: [Action] = []
            if phase == .active && !shortcut.modifiers.isSubset(of: SideModifier.pressed(in: flags)) {
                phase = .idle
                actions = [.end]
            }
            return Outcome(actions: actions, allReleased: releaseIfAllUp(flags))
        case .mouseDown:
            return Outcome()
        case .physicalState(let keyDown, let flags):
            guard holding else { return Outcome() }
            if isFullyDown(keyDown: keyDown, flags: flags) {
                readingSawPressDown = true
                return Outcome()
            }
            guard readingSawPressDown else { return untrustedReading() }
            var actions: [Action] = []
            if phase == .active {
                phase = .idle
                actions = [.end]
            }
            if !keyDown {
                ownsKeyPress = false
            }
            return Outcome(actions: actions, allReleased: releaseIfAllUp(flags))
        }
    }

    /// Once the dictation is over and the key is up, the press is released
    /// when none of its modifiers is still held.
    private mutating func releaseIfAllUp(_ flags: UInt64) -> Bool {
        guard holding, phase != .active, !ownsKeyPress, shortcut.modifiers.isDisjoint(with: SideModifier.pressed(in: flags)) else {
            return false
        }
        holding = false
        return true
    }

    /// Whether the held modifiers are exactly the shortcut's, sides included.
    /// Fn is compared only when the shortcut uses it: macOS sets the Fn flag
    /// on its own for arrow and function keys on many keyboards.
    private func modifiersMatch(_ flags: UInt64) -> Bool {
        var pressed = SideModifier.pressed(in: flags)
        if !shortcut.modifiers.contains(.function) {
            pressed.remove(.function)
        }
        return pressed == shortcut.modifiers
    }
}

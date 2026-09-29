import Foundation
import Testing
@testable import PrivacyFlowCore

/// Flags as an event would carry them for these modifiers held.
private func flags(_ modifiers: SideModifier...) -> UInt64 {
    modifiers.reduce(0) { $0 | $1.flagMask }
}

private let f5: UInt16 = 96
private let letterE: UInt16 = 14

/// The dictation shortcut as a state machine fed synthetic key events.
struct ShortcutMatcherTests {
    typealias Outcome = ShortcutMatcher.Outcome

    // MARK: A modifier on its own

    @Test func theDefaultStartsAndEndsWithRightOption() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.rightOption))) == Outcome(actions: [.start]))
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: 0)) == Outcome(actions: [.end], allReleased: true))
    }

    /// The generic Option flag is set for either side; only the device bit
    /// tells Left Option from Right Option.
    @Test func sidesAreDistinguished() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        #expect(matcher.handle(.flagsChanged(keyCode: 58, flags: flags(.leftOption))).actions.isEmpty)
        var command = ShortcutMatcher(shortcut: Shortcut(modifier: .leftCommand))
        #expect(command.handle(.flagsChanged(keyCode: 54, flags: flags(.rightCommand))).actions.isEmpty)
        #expect(command.handle(.flagsChanged(keyCode: 55, flags: flags(.leftCommand))).actions == [.start])
    }

    /// Letting go of Shift while still holding Right Option leaves the flags
    /// showing only Right Option, but nothing was pressed: no dictation.
    @Test func releasingAnotherModifierFirstDoesNotStart() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        #expect(matcher.handle(.flagsChanged(keyCode: 56, flags: flags(.leftShift))).actions.isEmpty)
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.leftShift, .rightOption))).actions.isEmpty, "held with Shift, it is part of a chord")
        #expect(matcher.handle(.flagsChanged(keyCode: 56, flags: flags(.rightOption))).actions.isEmpty, "Shift coming up is not Right Option going down")
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: 0)).actions.isEmpty)
    }

    /// The same for an AltGr-style typist holding both Options and releasing
    /// the left one first.
    @Test func releasingTheOtherOptionFirstDoesNotStart() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        _ = matcher.handle(.flagsChanged(keyCode: 58, flags: flags(.leftOption)))
        _ = matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.leftOption, .rightOption)))
        #expect(matcher.handle(.flagsChanged(keyCode: 58, flags: flags(.rightOption))).actions.isEmpty)
        #expect(!matcher.isActive)
    }

    /// Typing Option+E or using Command+Tab is not dictating: the dictation is
    /// cancelled, never ended, so nothing is inserted, and the key is the
    /// user's, so it is never swallowed.
    @Test func aChordCancelsAModifierOnlyDictation() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        _ = matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.rightOption)))
        #expect(matcher.handle(.keyDown(keyCode: letterE, flags: flags(.rightOption), isRepeat: false)) == Outcome(actions: [.cancel]))
        #expect(matcher.handle(.keyUp(keyCode: letterE, flags: flags(.rightOption))) == Outcome())
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: 0)) == Outcome(allReleased: true), "never an end, so nothing is inserted")
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.rightOption))).actions == [.start], "the next press starts afresh")
    }

    /// A click while the modifier is held, such as a Command-click, is a chord
    /// too, and the click is never swallowed.
    @Test func aClickCancelsAModifierOnlyDictation() {
        var matcher = ShortcutMatcher(shortcut: Shortcut(modifier: .rightCommand))
        _ = matcher.handle(.flagsChanged(keyCode: 54, flags: flags(.rightCommand)))
        #expect(matcher.handle(.mouseDown) == Outcome(actions: [.cancel]))
    }

    @Test func anotherModifierJoiningCancels() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        _ = matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.rightOption)))
        #expect(matcher.handle(.flagsChanged(keyCode: 58, flags: flags(.rightOption, .leftOption))).actions == [.cancel])
        #expect(matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.leftOption))) == Outcome(allReleased: true))
    }

    // MARK: A key with modifiers

    let commandF5 = Shortcut(keyCode: f5, modifiers: [.leftCommand])

    /// A combination starts only when it is complete: the modifier alone does
    /// nothing, and the key alone is the user's and passes through.
    @Test func aComboStartsOnlyWhenComplete() {
        var matcher = ShortcutMatcher(shortcut: commandF5)
        #expect(matcher.handle(.flagsChanged(keyCode: 55, flags: flags(.leftCommand))) == Outcome())
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: false)) == Outcome(), "F5 without Command is not the shortcut")
        #expect(matcher.handle(.keyUp(keyCode: f5, flags: 0)).swallow == false)
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: flags(.leftCommand, .function), isRepeat: false)) == Outcome(actions: [.start], swallow: true), "Fn set by the keyboard itself is ignored")
    }

    /// Any part coming up ends the dictation, but pasting waits until every
    /// part is up: the key's own release still belongs to the press and is
    /// swallowed, and only then is the press released.
    @Test func releasingAnyPartEndsItButPastesWaitForAll() {
        var matcher = ShortcutMatcher(shortcut: commandF5)
        _ = matcher.handle(.keyDown(keyCode: f5, flags: flags(.leftCommand), isRepeat: false))
        #expect(matcher.handle(.flagsChanged(keyCode: 55, flags: 0)) == Outcome(actions: [.end]), "the key is still down")
        #expect(matcher.handle(.keyUp(keyCode: f5, flags: 0)) == Outcome(swallow: true, allReleased: true))

        _ = matcher.handle(.keyDown(keyCode: f5, flags: flags(.leftCommand), isRepeat: false))
        #expect(matcher.handle(.keyUp(keyCode: f5, flags: flags(.leftCommand))) == Outcome(actions: [.end], swallow: true), "Command is still down")
        #expect(matcher.handle(.flagsChanged(keyCode: 55, flags: 0)) == Outcome(allReleased: true))
    }

    /// Auto-repeat neither starts a second dictation nor reaches other apps.
    @Test func autoRepeatIsSwallowedAndIgnored() {
        var matcher = ShortcutMatcher(shortcut: Shortcut(keyCode: f5, modifiers: []))
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: false)).actions == [.start])
        for _ in 0..<5 {
            #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: true)) == Outcome(swallow: true))
        }
        #expect(matcher.handle(.keyUp(keyCode: f5, flags: 0)) == Outcome(actions: [.end], swallow: true, allReleased: true))
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: true)) == Outcome(), "a stray repeat after the release is not a press")
    }

    /// A fresh press of the key while its last release was never seen means
    /// that release was lost. The old dictation ends and the new press starts;
    /// it is not swallowed as though it were a repeat.
    @Test func aFreshPressAfterALostReleaseStartsAgain() {
        var matcher = ShortcutMatcher(shortcut: Shortcut(keyCode: f5, modifiers: []))
        _ = matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: false))
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: false)) == Outcome(actions: [.end, .start], swallow: true))
        #expect(matcher.handle(.keyUp(keyCode: f5, flags: 0)) == Outcome(actions: [.end], swallow: true, allReleased: true))
    }

    /// After a lost release, a press without the shortcut's modifiers is the
    /// user's, and the lost press is released so pastes are not held for it.
    @Test func aLostReleaseFollowedByAnOrdinaryPressReleasesIt() {
        var matcher = ShortcutMatcher(shortcut: commandF5)
        _ = matcher.handle(.keyDown(keyCode: f5, flags: flags(.leftCommand), isRepeat: false))
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: 0, isRepeat: false)) == Outcome(actions: [.end], allReleased: true))
    }

    @Test func sidesAreDistinguishedInCombos() {
        var matcher = ShortcutMatcher(shortcut: commandF5)
        #expect(matcher.handle(.keyDown(keyCode: f5, flags: flags(.rightCommand), isRepeat: false)) == Outcome())
    }

    /// Only the shortcut's own key is swallowed, never another.
    @Test func otherKeysAreNeverSwallowed() {
        var matcher = ShortcutMatcher(shortcut: commandF5)
        _ = matcher.handle(.keyDown(keyCode: f5, flags: flags(.leftCommand), isRepeat: false))
        #expect(matcher.handle(.keyDown(keyCode: letterE, flags: flags(.leftCommand), isRepeat: false)) == Outcome())
        #expect(matcher.handle(.mouseDown) == Outcome())
        #expect(matcher.isActive, "a combo is not cancelled by other keys or clicks")
    }

    // MARK: The physical reading

    /// Once the reading has itself seen the press down, it ends a dictation
    /// whose release never arrived, and releases the press.
    @Test(arguments: [Shortcut.rightOption, Shortcut(keyCode: f5, modifiers: [.leftControl])])
    func aReadingThatSawThePressEndsAStuckDictation(shortcut: Shortcut) {
        var matcher = ShortcutMatcher(shortcut: shortcut)
        let modifierOnly = shortcut.soleModifier != nil
        _ = matcher.handle(modifierOnly
            ? .flagsChanged(keyCode: 61, flags: flags(.rightOption))
            : .keyDown(keyCode: f5, flags: flags(.leftControl), isRepeat: false))
        let held = modifierOnly ? flags(.rightOption) : flags(.leftControl)
        #expect(matcher.handle(.physicalState(keyDown: true, flags: held)) == Outcome(), "still held is left alone")
        #expect(matcher.handle(.physicalState(keyDown: false, flags: 0)) == Outcome(actions: [.end], allReleased: true))
        #expect(!matcher.isActive && !matcher.isHolding)
    }

    /// A reading that has never seen the key down cannot see this key at all
    /// (Fn, a laptop's Fn layer, a remapped modifier), so it never ends the
    /// dictation: the events and the recording cap do. It is said once.
    @Test(arguments: [Shortcut(modifier: .function), Shortcut(keyCode: f5, modifiers: [])])
    func aReadingThatNeverSawTheKeyNeverActs(shortcut: Shortcut) {
        var matcher = ShortcutMatcher(shortcut: shortcut)
        _ = matcher.handle(shortcut.soleModifier != nil
            ? .flagsChanged(keyCode: 63, flags: flags(.function))
            : .keyDown(keyCode: f5, flags: 0, isRepeat: false))
        #expect(matcher.handle(.physicalState(keyDown: false, flags: 0)) == Outcome(keyStateUnreadable: true))
        for _ in 0..<10 {
            #expect(matcher.handle(.physicalState(keyDown: false, flags: 0)) == Outcome())
        }
        #expect(matcher.isActive, "the dictation is still running")
        let release: ShortcutMatcher.Event = shortcut.soleModifier != nil ? .flagsChanged(keyCode: 63, flags: 0) : .keyUp(keyCode: f5, flags: 0)
        #expect(matcher.handle(release).actions == [.end], "the events end it")
    }

    /// A cancelled press whose release is lost is still released by a reading
    /// that saw it, or pastes would wait for a key nobody is holding.
    @Test func aReadingReleasesACancelledPress() {
        var matcher = ShortcutMatcher(shortcut: .rightOption)
        _ = matcher.handle(.flagsChanged(keyCode: 61, flags: flags(.rightOption)))
        _ = matcher.handle(.physicalState(keyDown: false, flags: flags(.rightOption)))
        _ = matcher.handle(.keyDown(keyCode: letterE, flags: flags(.rightOption), isRepeat: false))
        #expect(matcher.handle(.physicalState(keyDown: false, flags: 0)) == Outcome(allReleased: true))
    }

    @Test func aFullyDownReadingIsRecognised() {
        let matcher = ShortcutMatcher(shortcut: commandF5)
        #expect(matcher.isFullyDown(keyDown: true, flags: flags(.leftCommand)))
        #expect(!matcher.isFullyDown(keyDown: true, flags: 0))
        #expect(!matcher.isFullyDown(keyDown: false, flags: flags(.leftCommand)))
    }
}

/// Which shortcuts may be used.
struct ShortcutAssessmentTests {
    @Test(arguments: [
        Shortcut(keyCode: 0, modifiers: []),              // A
        Shortcut(keyCode: 18, modifiers: []),             // 1
        Shortcut(keyCode: 43, modifiers: []),             // ,
        Shortcut(keyCode: 49, modifiers: []),             // Space
        Shortcut(keyCode: 36, modifiers: []),             // Return
        Shortcut(keyCode: 48, modifiers: []),             // Tab
        Shortcut(keyCode: 53, modifiers: []),             // Escape
        Shortcut(keyCode: 51, modifiers: []),             // Delete
        Shortcut(keyCode: 126, modifiers: []),            // Up Arrow
        Shortcut(keyCode: 83, modifiers: []),             // Keypad 1
        Shortcut(keyCode: 0, modifiers: [.leftShift]),    // Shift+A types "A"
        Shortcut(keyCode: 14, modifiers: [.rightOption]), // Option+E starts an accent
    ])
    func shortcutsThatTypeAreRefused(shortcut: Shortcut) {
        #expect(Self.isRefused(shortcut), "\(shortcut.label)")
    }

    /// Shift and Option select and edit with these keys in every app.
    @Test(arguments: [UInt16(123), 124, 125, 126, 51, 117, 48, 36, 115, 119, 116, 121])
    func shiftOrOptionWithAnEditingKeyIsRefused(keyCode: UInt16) {
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.leftShift])))
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.rightOption])))
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.leftShift, .leftOption])))
    }

    /// Command with one character is copy, paste, undo, save and the rest:
    /// swallowing Command+V would stop pasting everywhere.
    @Test(arguments: ["C", "V", "X", "Z", "A", "Q", "W", "S", "F", "N", "T", "1", ","])
    func commandWithACharacterIsRefused(name: String) throws {
        let keyCode = try #require([UInt16](0...50).first { KeyNames.name(of: $0) == name })
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.leftCommand])))
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.rightCommand])))
    }

    /// Command with an editing key moves and deletes by line and document,
    /// and Command+Tab switches apps.
    @Test(arguments: [UInt16(123), 124, 125, 126, 51, 117, 48, 36, 115, 119, 116, 121])
    func commandWithAnEditingKeyIsRefused(keyCode: UInt16) {
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.leftCommand])))
        #expect(Self.isRefused(Shortcut(keyCode: keyCode, modifiers: [.rightCommand])))
    }

    @Test func controlTabIsRefused() {
        #expect(Self.isRefused(Shortcut(keyCode: 48, modifiers: [.leftControl])))
    }

    /// A refusal's advice must lead somewhere: the shortcut it suggests for a
    /// letter, a digit or an editing key is one PrivacyFlow accepts.
    @Test(arguments: [UInt16(0), 18, 43, 123, 51])
    func theSuggestedControlAndOptionIsAccepted(keyCode: UInt16) {
        let plain = Shortcut(keyCode: keyCode, modifiers: [])
        guard case .refused(let reason) = plain.assessment else {
            Issue.record("\(plain.label) was not refused")
            return
        }
        #expect(reason.contains("Control and Option"))
        #expect(Shortcut(keyCode: keyCode, modifiers: [.leftControl, .leftOption]).assessment == .allowed)
    }

    /// Control with a letter edits in every text field, Emacs-style.
    @Test func controlWithALetterIsRefused() {
        #expect(Self.isRefused(Shortcut(keyCode: 0, modifiers: [.leftControl])))
        #expect(Self.isRefused(Shortcut(keyCode: 40, modifiers: [.rightControl])))
    }

    /// F17 to F20 have key codes among the keypad's, and are not keypad keys.
    @Test(arguments: [UInt16(64), 79, 80, 90])
    func theHighFunctionKeysAreAccepted(keyCode: UInt16) {
        #expect(Shortcut(keyCode: keyCode, modifiers: []).assessment == .allowed)
        #expect(Shortcut(keyCode: keyCode, modifiers: [.leftShift]).assessment == .allowed, "Shift+F18 is accepted")
    }

    @Test(arguments: [
        Shortcut.rightOption,
        Shortcut(modifier: .rightCommand),
        Shortcut(modifier: .rightControl),
        Shortcut(keyCode: 105, modifiers: []),                      // F13
        Shortcut(keyCode: 2, modifiers: [.rightCommand, .rightOption]), // Right Option + Right Command + D
        Shortcut(keyCode: 0, modifiers: [.leftControl, .leftOption]),    // Control + Option + A
        Shortcut(keyCode: 96, modifiers: [.leftControl, .leftOption]),
    ])
    func ordinaryShortcutsAreAllowed(shortcut: Shortcut) {
        #expect(shortcut.assessment == .allowed, "\(shortcut.label)")
    }

    /// Keys macOS commonly reserves, and modifiers held for everyday shortcuts
    /// and clicks, are usable with the reason said.
    @Test(arguments: [
        Shortcut(modifier: .function),
        Shortcut(modifier: .leftCommand),
        Shortcut(modifier: .leftOption),
        Shortcut(modifier: .leftControl),
        Shortcut(modifier: .leftShift),
        Shortcut(modifier: .rightShift),
        Shortcut(keyCode: 49, modifiers: [.leftCommand]),   // Spotlight
        Shortcut(keyCode: 126, modifiers: [.rightControl]), // Mission Control
    ])
    func reservedShortcutsAreWarnedAbout(shortcut: Shortcut) {
        guard case .warned(let reason) = shortcut.assessment else {
            Issue.record("\(shortcut.label) was not warned about")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func labelsNameSidesAndKeys() {
        #expect(Shortcut.rightOption.label == "Right Option")
        #expect(Shortcut(keyCode: 96, modifiers: [.leftCommand, .rightControl]).label == "Right Control + Left Command + F5")
    }

    static func isRefused(_ shortcut: Shortcut) -> Bool {
        if case .refused = shortcut.assessment { return true }
        return false
    }
}

/// The shortcut in settings.json.
struct ShortcutPersistenceTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("privacyflow-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aChosenShortcutRoundTrips() throws {
        let directory = try directory()
        let shortcut = Shortcut(keyCode: 96, modifiers: [.leftControl, .rightOption])
        #expect(SettingsFile.save(Settings(dictationShortcut: shortcut), to: directory) == nil)
        let loaded = SettingsFile.load(from: directory)
        #expect(loaded.settings.dictationShortcut == shortcut)
        #expect(loaded.problem == nil)
        let text = try String(contentsOf: SettingsFile.url(in: directory), encoding: .utf8)
        #expect(text.contains("\"version\" : 1") && text.contains("\"key_code\" : 96") && text.contains("\"right_option\""))
    }

    @Test func aFileWithoutAShortcutUsesRightOption() throws {
        let directory = try directory()
        try Data(#"{"minimal_mode": true}"#.utf8).write(to: SettingsFile.url(in: directory))
        let loaded = SettingsFile.load(from: directory)
        #expect(loaded.settings.dictationShortcut == .rightOption)
        #expect(loaded.problem == nil)
    }

    /// An unreadable shortcut is reported, costs only the shortcut, and the
    /// app runs on the default.
    @Test(arguments: [
        #"{"version": 2, "key_code": 96, "modifiers": [], "label": "F5"}"#,
        #"{"version": 1, "key_code": 96, "modifiers": ["hyper"], "label": "F5"}"#,
        #"{"version": 1, "modifiers": [], "label": "F5"}"#,
        #"{"version": 1, "key_code": 0, "modifiers": [], "label": "A"}"#,
    ])
    func aBadShortcutIsReportedAndTheDefaultUsed(stored: String) throws {
        let directory = try directory()
        try Data(#"{"sound_cues": false, "dictation_shortcut": \#(stored)}"#.utf8).write(to: SettingsFile.url(in: directory))
        let loaded = SettingsFile.load(from: directory)
        #expect(loaded.settings.dictationShortcut == .rightOption)
        #expect(loaded.settings.soundCues == false, "the other settings still load")
        #expect(loaded.problem?.contains("dictation key") == true)
    }
}

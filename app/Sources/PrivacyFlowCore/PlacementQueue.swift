import Foundation

/// Where finished dictations are placed, one at a time, in the order they were
/// spoken, and never while the dictation key is held.
///
/// Dictations queue: the user can start speaking again while an earlier one
/// is still being transcribed. The earlier result may be ready while the key
/// is down, and pasting then is wrong twice over: the text would land under
/// the user's hands while they speak, and a synthetic Cmd-V while a modifier
/// hotkey is physically held can reach the app with that modifier added. So a
/// placement that pastes waits here until the key comes up, and everything
/// behind it waits in line, which keeps outcomes and the cursor memory in
/// spoken order.
public final class PlacementQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PrivacyFlow placement", qos: .userInitiated)
    private let condition = NSCondition()
    private var keyHeld = false

    public init() {}

    /// The dictation key went down: pastes wait from now on.
    public func keyDown() {
        condition.lock()
        keyHeld = true
        condition.unlock()
    }

    /// The dictation key came up: a paste that was waiting goes ahead.
    public func keyUp() {
        condition.lock()
        keyHeld = false
        condition.broadcast()
        condition.unlock()
    }

    /// Queue `work` behind everything already submitted. When `pastes` is
    /// true it also waits until the key is up. `work` runs on the queue.
    public func submit(pastes: Bool, _ work: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if pastes {
                waitUntilKeyUp()
            }
            work()
        }
    }

    /// Whether the key is held right now.
    public var isKeyHeld: Bool {
        condition.lock()
        defer { condition.unlock() }
        return keyHeld
    }

    /// Block until the key is up. For the paste itself to call again just
    /// before posting Cmd-V, because the key can go down again during the
    /// checks that come first.
    public func waitUntilKeyUp() {
        condition.lock()
        while keyHeld {
            condition.wait()
        }
        condition.unlock()
    }
}

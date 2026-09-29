import CoreAudio
import Foundation
import os

/// Watches properties of one audio device, through Core Audio's function
/// pointer listener API.
///
/// The block API cannot be used here. Swift wraps a closure afresh each time
/// it is handed to C, so the block given to the remove call never matches the
/// one that was added: removal reports success, the listener stays, and
/// everything its closure holds is never freed. A function pointer with its
/// client data is matched exactly.
///
/// The client data is a token, not a pointer to anything. Core Audio may
/// deliver a notification on its own thread just as the watch is stopped, so
/// the handler is looked up by token under a lock, and stopping takes it out
/// of that lookup before removing the listener. A notification in flight then
/// finds nothing to call, and no freed state is ever touched.
final class DevicePropertyWatch {
    typealias Handler = @Sendable (AudioObjectPropertySelector) -> Void

    private struct Registry {
        var nextToken: UInt = 1
        var handlers: [UInt: Handler] = [:]
    }

    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    private let device: AudioObjectID
    private let token: UInt
    private var addresses: [AudioObjectPropertyAddress] = []

    /// Watch `selectors` on `device`, calling `handler` with the selector that
    /// changed, on a Core Audio thread. Throws if any of them cannot be
    /// watched, having removed those that could.
    init(device: AudioObjectID, selectors: [AudioObjectPropertySelector], handler: @escaping Handler) throws {
        self.device = device
        token = Self.registry.withLock { registry in
            let token = registry.nextToken
            registry.nextToken += 1
            registry.handlers[token] = handler
            return token
        }
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListener(device, &address, Self.listener, UnsafeMutableRawPointer(bitPattern: token))
            guard status == noErr else {
                stop()
                throw AudioProblem("Could not watch the audio device for changes (Core Audio error \(status))")
            }
            addresses.append(address)
        }
    }

    deinit {
        stop()
    }

    /// Stop watching. The handler is dropped first, so nothing it holds is
    /// used again, then each listener is removed.
    func stop() {
        Self.registry.withLock { _ = $0.handlers.removeValue(forKey: token) }
        for var address in addresses {
            AudioObjectRemovePropertyListener(device, &address, Self.listener, UnsafeMutableRawPointer(bitPattern: token))
        }
        addresses = []
    }

    /// The one listener function. It finds its handler by token, holding it
    /// only for the call.
    private static let listener: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
        let token = UInt(bitPattern: clientData)
        guard let handler = DevicePropertyWatch.registry.withLock({ $0.handlers[token] }) else { return noErr }
        for index in 0..<Int(count) {
            handler(addresses[index].mSelector)
        }
        return noErr
    }
}

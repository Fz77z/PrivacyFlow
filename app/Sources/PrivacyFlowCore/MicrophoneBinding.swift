import Foundation

/// Which device a microphone was opened on and the preference that led there,
/// kept apart from the audio unit so whether it is still the right device can
/// be answered, and tested, without hardware.
public struct MicrophoneBinding: Equatable, Sendable {
    /// How the device was arrived at.
    public enum Route: Equatable, Sendable {
        /// There was no preference, so the system input.
        case systemDefault
        /// The preferred microphone.
        case preferred
        /// The preferred microphone was not connected, so the system input
        /// stands in. Remembers how many devices carried the preferred name
        /// then, so one more appearing is noticed. A count rather than a yes or
        /// no, because a headset's output half shares its name with its
        /// microphone and can be present on its own.
        case preferredMissing(devicesNamedPreferred: Int)
    }

    public var preferred: String?
    public var route: Route
    public var deviceName: String

    public init(preferred: String?, route: Route, deviceName: String) {
        self.preferred = preferred
        self.route = route
        self.deviceName = deviceName
    }

    /// Whether this is still the device the preference leads to.
    ///
    /// The observations are passed in and asked for only when the route needs
    /// them, because each is a Core Audio query on the keypress path. A
    /// preferred microphone that goes away fails its stream, which the caller
    /// checks first; the system input changing is not its concern, which is
    /// the reason the preference exists.
    public func isCurrent(
        preferred: String?,
        systemInputName: () -> String?,
        devicesNamed: (String) -> Int?
    ) -> Bool {
        guard self.preferred == preferred else { return false }
        switch (route, preferred) {
        case (.preferred, _):
            return true
        case (.systemDefault, _):
            return systemInputName() == deviceName
        case (.preferredMissing(let count), .some(let preferred)):
            return devicesNamed(preferred) == count && systemInputName() == deviceName
        case (.preferredMissing, .none):
            return false
        }
    }

    /// The preferred microphone this one stands in for, if it was not connected.
    public var missingPreferred: String? {
        if case .preferredMissing = route {
            return preferred
        }
        return nil
    }
}

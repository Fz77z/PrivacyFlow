import Foundation

/// How a spring moves: its undamped frequency in cycles per second and its
/// damping ratio. Below one it overshoots a little, which reads as popping
/// open; at one it arrives without overshoot, which is how something tidying
/// itself away should move.
public struct SpringFeel: Sendable {
    public var frequency: Double
    public var damping: Double

    /// Opening: quick, with a few percent of overshoot.
    public static let grow = SpringFeel(frequency: 3.4, damping: 0.72)
    /// Closing: slower and without overshoot.
    public static let shrink = SpringFeel(frequency: 2.6, damping: 1.0)
}

/// One value eased towards a target by a damped spring.
///
/// A spring rather than a tween because it carries velocity: told to shrink
/// halfway through growing, it turns around smoothly instead of restarting a
/// curve from standstill.
public struct Spring: Sendable {
    /// Integrated in small fixed steps whatever the frame rate, so a slow frame
    /// changes how far the spring travels, never whether it is stable.
    static let stepSeconds = 1.0 / 240.0
    static let settledDistance = 0.01
    static let settledSpeed = 0.1

    public private(set) var value: Double
    private var velocity = 0.0

    public init(_ value: Double) {
        self.value = value
    }

    /// Advance by `seconds` towards `target`, returning whether it is still
    /// moving, which is whether another frame is needed.
    public mutating func step(towards target: Double, seconds: Double, feel: SpringFeel) -> Bool {
        let angular = 2 * Double.pi * feel.frequency
        var remaining = seconds
        while remaining > 0 {
            let step = min(remaining, Self.stepSeconds)
            let acceleration = -angular * angular * (value - target) - 2 * feel.damping * angular * velocity
            velocity += acceleration * step
            value += velocity * step
            remaining -= step
        }
        let settled = abs(value - target) < Self.settledDistance && abs(velocity) < Self.settledSpeed
        if settled {
            value = target
            velocity = 0
        }
        return !settled
    }
}

/// Turns the microphone's level into how far each of the mark's four bars
/// stands while the user speaks, from 0 (silent) to 1 (loud).
public struct VoiceMeter: Sendable {
    /// The window of the reported level, which is RMS times eight, in decibels:
    /// about -54 to -30 dBFS, set from a quiet microphone whose silence sits
    /// near -56 dBFS. Hearing is logarithmic, so the window is too.
    static let quietDb: Float = -36
    static let loudDb: Float = -12
    /// Rising fast and falling slowly, like every good level meter, so
    /// syllables land at once and the gaps between them do not flicker.
    static let attackSeconds: Float = 0.025
    static let releaseSeconds: Float = 0.16
    /// Each bar lags the voice by a different amount, so a syllable ripples
    /// across the mark instead of lifting all four as one block.
    static let barLagSeconds: [Float] = [0.09, 0.0, 0.045, 0.13]
    static let barWeight: [Float] = [0.78, 1.0, 0.9, 0.7]

    private var envelope: Float = 0
    private var raw: [Float] = [0, 0, 0, 0]

    public init() {}

    /// Take one reading of the level, `seconds` after the last, and return the
    /// bars to paint.
    public mutating func update(level: Float, seconds: Float) -> [Float] {
        let loudness = Self.loudness(level)
        let timeConstant = loudness > envelope ? Self.attackSeconds : Self.releaseSeconds
        envelope = Self.follow(envelope, target: loudness, seconds: seconds, timeConstant: timeConstant)
        for index in raw.indices {
            raw[index] = Self.follow(raw[index], target: envelope, seconds: seconds, timeConstant: Self.barLagSeconds[index])
        }
        return bars
    }

    public var bars: [Float] {
        raw.indices.map { min(max(raw[$0] * Self.barWeight[$0], 0), 1) }
    }

    static func loudness(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(level)
        return min(max((decibels - quietDb) / (loudDb - quietDb), 0), 1)
    }

    /// A one-pole filter towards `target`. A time constant of zero follows exactly.
    static func follow(_ current: Float, target: Float, seconds: Float, timeConstant: Float) -> Float {
        guard timeConstant > 0 else { return target }
        return target + (current - target) * exp(-seconds / timeConstant)
    }
}

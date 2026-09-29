import Foundation

/// The floor below which a capture holds no speech.
///
/// The worker applies its own floor too, because it is a separate program that
/// must not trust what it is handed. This copy is the fast answer: a press
/// with nothing in it is refused at release, before a file is written or the
/// worker is spoken to, so the capsule never flashes "Transcribing" to say
/// that nothing happened. An energy gate, not a speech detector: refusing
/// quiet speech costs the user their words, so anything above it goes on.
public enum EnergyFloor {
    public static let silenceRms: Float = 0.0017
    public static let minimumSeconds: Double = 0.35

    /// How long a press must be held before PrivacyFlow says it is quiet.
    /// Shorter presses are over before a warning could be read or answered.
    public static let quietWarningAfter: TimeInterval = 3

    /// What a finished capture turned out to be.
    public enum Verdict: Equatable, Sendable {
        case speech(rms: Float)
        case tooQuiet(seconds: Double, rms: Float)
    }

    /// Measure a finished capture at its own sample rate.
    public static func verdict(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Verdict {
        let seconds = Double(samples.count) / sampleRate
        let rms = rootMeanSquare(samples)
        if seconds < minimumSeconds || rms < silenceRms {
            return .tooQuiet(seconds: seconds, rms: rms)
        }
        return .speech(rms: rms)
    }

    /// Whether a press held for `held` seconds, whose audio so far measures
    /// `recordedRms`, is heading for refusal. Measured against the same floor
    /// the verdict applies, so it predicts the outcome rather than estimating it.
    public static func headingForRefusal(held: TimeInterval, recordedRms: Float) -> Bool {
        held >= quietWarningAfter && recordedRms < silenceRms
    }

    /// Accumulated in double precision, because a float total over millions of
    /// squared samples loses enough precision to move the decision.
    public static func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
        }
        return Float((sumSquares / Double(samples.count)).squareRoot())
    }
}

import Foundation

/// The route the router chose for a transcript, as the worker names it.
public enum Route: String, Codable, Sendable {
    case passThrough = "PASS_THROUGH"
    case lightCleanup = "LIGHT_CLEANUP"
    case transform = "TRANSFORM"
    case complex = "COMPLEX"
}

/// What became of a finished dictation that reached the user.
public enum Insertion: Equatable, Sendable {
    /// Pasted at the cursor, which is the ordinary outcome.
    case pasted
    /// Left on the pasteboard because the destination was no longer frontmost.
    case copiedOnly
    /// Left on the pasteboard because the destination had nothing focused that
    /// could receive text. Pasting anyway is not harmless: a Cmd-V into a
    /// Finder window pastes files.
    case copiedNoField
}

/// Where each part of one dictation's time went, in milliseconds. A stage the
/// dictation never reached is nil, so it reads as a dash rather than as a zero
/// that claims it was free.
public struct Timings: Equatable, Sendable {
    public var audioMs: Int?
    public var captureFinalizeMs: Int?
    public var queueMs: Int?
    public var asrMs: Int?
    public var routerMs: Int?
    public var processingMs: Int?
    public var insertMs: Int?
    public var totalMs: Int?

    public init() {}
}

/// Why capture stopped, which decides whether the finished text may be typed
/// into the user's document.
///
/// Only a deliberate release may insert. A ceiling, a full buffer or a lost
/// device means the capture ended without the user asking it to, and quietly
/// typing five minutes of whatever a stuck key overheard would be worse than
/// making them paste it themselves.
public enum CaptureEnd: Equatable, Sendable {
    case released
    case ceilingReached
    case bufferFull
    case deviceLost
    /// The microphone changed its sample rate, or stopped delivering audio,
    /// part way through.
    case deviceChanged

    public var mayInsert: Bool {
        self == .released
    }

    /// What the capsule says about an ending that needs explaining.
    public var headline: String {
        switch self {
        case .released: "Couldn't insert"
        case .ceilingReached: "Recording hit 5 min"
        case .bufferFull: "Recording filled the buffer"
        case .deviceLost: "Microphone disconnected"
        case .deviceChanged: "Microphone changed"
        }
    }

    public var explanation: String {
        switch self {
        case .released:
            "No destination app was focused when dictation started."
        case .ceilingReached:
            "The five minute recording limit was reached, so the recording was stopped and what you said was transcribed."
        case .bufferFull:
            "The recording filled its buffer, so the end of what you said was not captured. What was captured has been transcribed."
        case .deviceLost:
            "The microphone disconnected during the recording, so the rest of what you said was not captured. What was captured has been transcribed."
        case .deviceChanged:
            "The microphone changed its settings or stopped during the recording, so the rest of what you said was not captured. What was captured has been transcribed."
        }
    }
}

/// Where a finished dictation is going.
public enum Destination: Equatable, Sendable {
    /// Into this process, if what it has focused will take text.
    case insert(pid: Int32)
    /// Onto the clipboard, because nothing that could receive it was focused.
    /// Not a failure: the words came back and are one Cmd-V away.
    case clipboard
    /// Nowhere, because the capture ended before the user had finished
    /// speaking. The words are preserved, but this is reported as the lost
    /// dictation it is.
    case lost

    /// Decide from where the dictation was aimed and how its capture ended.
    ///
    /// Having nowhere to put the text is ordinary and is answered, while a
    /// capture cut short is a dictation the user did not finish, and calling
    /// that a success would claim something PrivacyFlow did not do.
    public init(targetPid: Int32?, captureEnd: CaptureEnd) {
        guard captureEnd.mayInsert else {
            self = .lost
            return
        }
        if let targetPid {
            self = .insert(pid: targetPid)
        } else {
            self = .clipboard
        }
    }
}

/// What became of the user's words when the pipeline failed after producing
/// them. Preserving is not inserting: text that failed its processing is never
/// typed into the document as though it had succeeded.
public enum Preserved: Equatable, Sendable {
    /// The raw transcription, because processing never completed.
    case raw
    /// The finished text, which processing produced but insertion could not place.
    case processed
    /// The words could not even be put on the pasteboard.
    case unavailable(String)
}

/// End a reason with a full stop if it has no closing punctuation, so further
/// guidance can follow it as a sentence of its own.
public func asSentence(_ text: String) -> String {
    guard let last = text.last, !".!?".contains(last) else { return text }
    return text + "."
}

/// The detail the console shows for a failure that happened after the user's
/// words existed.
///
/// The original failure always leads, because preservation is something that
/// also happened, never a replacement for the reason. Raw text is never
/// described as though it had been processed.
public func failureDetail(_ original: String, preserved: Preserved) -> String {
    switch preserved {
    case .raw:
        "\(original) Your words are on the clipboard: press Cmd-V to place them. This is the raw transcription, not the processed text."
    case .processed:
        "\(original) The finished text is on the clipboard: press Cmd-V to place it."
    case .unavailable(let why):
        "\(original) The words could not be put on the clipboard either: \(why)"
    }
}

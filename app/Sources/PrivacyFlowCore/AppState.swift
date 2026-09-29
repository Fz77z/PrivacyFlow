import Foundation

/// Seconds on a clock that never jumps, for timing things on screen.
public enum Monotonic {
    public static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// What the capsule is showing, which is also the app's single answer to
/// "where is this dictation up to?". Listening and processing are the two
/// states a dictation is in flight.
public enum HudState: Equatable, Sendable {
    case idle
    case listening
    case processing
    case done
    /// On the pasteboard but not pasted: a success with a caveat.
    case copied
    /// The key was held and nothing was said. Neither a dictation nor a failure.
    case noSpeech
    /// Speech was heard and could not be decoded. Not silence, because the
    /// user spoke, and not a failure, because nothing broke.
    case notUnderstood
    case error
}

/// What a failure means for the person dictating, which the mark paints so it
/// answers "was anything lost?" before any words are read.
public enum FailureKind: Equatable, Sendable {
    /// A precondition was not met and nothing was captured.
    case blocked
    /// The microphone cannot be used at all; pressing again will not help.
    case inputUnavailable
    /// Capture began and the pipeline failed before text reached the cursor.
    case dropped
}

/// A failure as the user experiences it: a kind, a headline short enough for
/// the capsule, and the original message kept whole for the console.
public struct Failure: Equatable, Sendable {
    public var kind: FailureKind
    public var headline: String
    public var detail: String

    public init(kind: FailureKind, headline: String, detail: String) {
        self.kind = kind
        self.headline = headline
        self.detail = detail
    }

    public static func blocked(_ headline: String, _ detail: String) -> Failure {
        Failure(kind: .blocked, headline: headline, detail: detail)
    }

    public static func inputUnavailable(_ headline: String, _ detail: String) -> Failure {
        Failure(kind: .inputUnavailable, headline: headline, detail: detail)
    }

    public static func dropped(_ headline: String, _ detail: String) -> Failure {
        Failure(kind: .dropped, headline: headline, detail: detail)
    }
}

/// Whether a toast reports a dictation that survived, one that was lost, or a
/// press that is heading for refusal while it can still be saved.
public enum ToastKind: Equatable, Sendable {
    case copied
    case failed
    case quiet
}

/// What PrivacyFlow says when a dictation ends up on the clipboard instead of
/// at the cursor. The capsule shows these outcomes as one word for a moment,
/// and every one of them happens precisely because the text did not appear
/// where the user was looking, so the toast says what was kept and how to
/// place it.
public struct Toast: Equatable, Sendable {
    /// How long a toast stays up: long enough to read a sentence of speech.
    public static let dwell: TimeInterval = 4

    public var kind: ToastKind
    public var headline: String
    /// The text that is actually on the clipboard, so what the user reads is
    /// what they will paste.
    public var body: String
    public var footer: String
    public var raisedAt: TimeInterval
    /// Whether the toast tells the user to press ⌘V for its text. Only true
    /// while the clipboard still holds that text.
    public var offersPaste: Bool

    public init(kind: ToastKind, headline: String, body: String, footer: String, raisedAt: TimeInterval, offersPaste: Bool = false) {
        self.kind = kind
        self.headline = headline
        self.body = body
        self.footer = footer
        self.raisedAt = raisedAt
        self.offersPaste = offersPaste
    }

    static func copied(_ headline: String, body: String, now: TimeInterval) -> Toast {
        Toast(kind: .copied, headline: headline, body: body, footer: "Copied to clipboard · ⌘V", raisedAt: now, offersPaste: true)
    }

    /// The clipboard now holds a later dictation's text, so ⌘V would paste
    /// that, not this. The toast still says this dictation was not pasted, and
    /// sends the user to the console, where it can be copied again.
    mutating func supersede() {
        guard offersPaste else { return }
        offersPaste = false
        footer = "Not pasted · a later dictation is on the clipboard · copy this one from the console"
    }

    /// Said while the recording is still running, because that is the only
    /// moment it can be acted on.
    static func quiet(now: TimeInterval) -> Toast {
        Toast(
            kind: .quiet,
            headline: "PrivacyFlow can barely hear you",
            body: "This dictation is too quiet to be transcribed. Move closer to the microphone, or speak up.",
            footer: "Still recording · it can still be saved",
            raisedAt: now
        )
    }

    static func failed(_ headline: String, body: String, footer: String, now: TimeInterval) -> Toast {
        Toast(kind: .failed, headline: headline, body: body, footer: footer, raisedAt: now, offersPaste: true)
    }
}

/// One dictation as the console keeps it.
public struct DictationRecord: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var timestamp: Date
    public var transcript: String
    public var route: Route?
    public var output: String
    public var timings: Timings
    public var failure: Failure?
    /// A remark about an outcome that is neither an insertion nor a failure,
    /// such as a dictation that could not be decoded.
    public var note: String?
    /// How the text got where it went, for a dictation that succeeded.
    public var insertion: Insertion?
}

/// What the resident worker is doing. Loading the models takes a bounded but
/// long time, so not being ready yet is an ordinary state.
public enum WorkerStatus: Equatable, Sendable {
    /// The models are not all downloaded and verified, so the worker has not
    /// been started.
    case awaitingModels
    case starting
    case ready(WorkerReady)
    case failed(String)
}

/// Everything the capsule, the toast and the console show, and the rules for
/// how a dictation's outcome changes it.
public struct AppState: Equatable, Sendable {
    /// How long a finished dictation's result stays on the capsule.
    public static let resultDwell: TimeInterval = 1.4
    /// How many dictations the console keeps.
    public static let historyLimit = 50

    public var hud: HudState = .idle
    public var transcript = ""
    public var route: Route?
    public var output = ""
    public var timings = Timings()
    public var lastFailure: Failure?
    public var history: [DictationRecord] = []
    public var consoleOpen = false
    public var unreadFailure = false
    public var worker: WorkerStatus = .awaitingModels
    /// When the capture was handed to the pipeline, while the capsule still
    /// shows the state before it. The mirror of `doneAt`: that one retires a
    /// state after a delay, this one promotes one.
    public var processingSince: TimeInterval?
    /// When the capsule last settled on a finished or failed dictation.
    public var doneAt: TimeInterval?
    /// At most one: the newest thing worth saying about a dictation.
    public var toast: Toast?
    /// Whether the user is speaking a dictation right now.
    public private(set) var recording = false
    /// How many finished recordings are still being transcribed or waiting to
    /// be placed. Dictations queue, so there can be several.
    public private(set) var inFlight = 0

    public init() {}

    /// Starts a new dictation. Everything describing the previous one goes,
    /// including its dwell timer, so a press that arrives while the last
    /// result is on screen cannot be retired by that result's clock. The
    /// unread dot stays until the console is opened. Earlier dictations still
    /// in flight carry on behind it.
    public mutating func resetForRecording() {
        recording = true
        hud = .listening
        clearResult()
        lastFailure = nil
        processingSince = nil
        doneAt = nil
        toast = nil
    }

    public mutating func clearResult() {
        transcript = ""
        route = nil
        output = ""
        timings = Timings()
    }

    /// The key came up, or the capture had to stop.
    public mutating func endRecording() {
        recording = false
    }

    /// A recording turned out to be part of a chord and was discarded. Nothing
    /// is filed: the user was typing, not dictating.
    public mutating func cancelRecording() {
        recording = false
        processingSince = nil
        if toast?.kind == .quiet {
            toast = nil
        }
        hud = inFlight > 0 ? .processing : .idle
    }

    /// The capture is on its way to the worker. On its own, the capsule does
    /// not change yet: a capture with no speech is answered within a frame or
    /// two, and announcing the work first made the capsule flash a state it
    /// was never meaningfully in. Behind earlier dictations still in flight,
    /// it says processing at once, because that work is already under way.
    public mutating func beginProcessing(now: TimeInterval = Monotonic.now()) {
        inFlight += 1
        if inFlight > 1 {
            hud = .processing
            processingSince = nil
        } else {
            processingSince = now
        }
    }

    /// One dictation in flight has been answered. Called before its outcome
    /// is recorded, so the outcome sees whether others are still queued.
    public mutating func completeInFlight() {
        inFlight = max(inFlight - 1, 0)
    }

    /// What the capsule calls the work it is waiting on. A capture pressed
    /// before the models have loaded is queued behind them, and calling that
    /// "Transcribing" turned a slow start into what looked like a hang.
    /// Derived rather than latched, so it corrects itself when the worker
    /// reports in.
    public var processingLabel: String {
        switch worker {
        case .starting, .awaitingModels: "Loading models"
        case .ready, .failed: "Transcribing"
        }
    }

    /// Say "Transcribing" once the wait has lasted long enough to mention. A
    /// wait that has already been answered is not promoted.
    public mutating func announceProcessing(after delay: TimeInterval, now: TimeInterval = Monotonic.now()) {
        guard let since = processingSince, now - since >= delay else { return }
        hud = .processing
        processingSince = nil
    }

    /// Files a dictation that reached the user, in whichever way it landed.
    /// Only the clipboard endings raise a toast: a dictation that landed at the
    /// cursor needs no announcement, because the user is watching it appear.
    public mutating func recordInserted(_ insertion: Insertion, now: TimeInterval = Monotonic.now()) {
        // A paste leaves an earlier dictation's toast up, so its failure is
        // not hidden by this success. But the paste went through the
        // clipboard, so that toast can no longer offer ⌘V for its text.
        switch insertion {
        case .pasted:
            toast?.supersede()
        case .copiedOnly:
            toast = .copied("Destination changed", body: output, now: now)
        case .copiedNoField:
            toast = .copied("No text field focused", body: output, now: now)
        }
        pushHistory(failure: nil, insertion: insertion)
        present(insertion == .pasted ? .done : .copied, now: now)
    }

    /// Files a failure: the capsule shows it, the console keeps it, and the dot
    /// points at the console unless the console is already open.
    public mutating func recordFailure(_ failure: Failure, preserved: Preserved?, now: TimeInterval = Monotonic.now()) {
        // Raised before the fields are cleared, and from whichever of them the
        // clipboard actually holds. Nothing kept means no toast, because that
        // would send the user to paste whatever was on the clipboard already.
        switch preserved {
        case .processed:
            toast = .failed(failure.headline, body: output, footer: "Copied to clipboard · ⌘V · details in the console", now: now)
        case .raw:
            toast = .failed(failure.headline, body: transcript, footer: "Raw transcript copied · ⌘V · details in the console", now: now)
        case .unavailable, nil:
            toast = nil
        }
        if !consoleOpen {
            unreadFailure = true
        }
        // Only a dropped dictation captured anything, so the fields still
        // holding the previous dictation must not be filed against the others.
        if failure.kind != .dropped {
            clearResult()
        }
        lastFailure = failure
        pushHistory(failure: failure, insertion: nil)
        present(.error, now: now)
    }

    /// Files a failure that happened outside any dictation, such as the worker
    /// exiting between dictations. It is filed and raises the dot, but leaves
    /// the capsule alone, because a dictation on screen may have nothing to do
    /// with it and reports its own outcome.
    public mutating func recordBackgroundFailure(_ failure: Failure) {
        if !consoleOpen {
            unreadFailure = true
        }
        lastFailure = failure
        file(DictationRecord(timestamp: Date(), transcript: "", route: nil, output: "", timings: Timings(), failure: failure, note: nil, insertion: nil))
    }

    /// Files a dictation that was heard and not understood. Told to the user,
    /// unlike silence, but not a failure: no red, no dot.
    public mutating func recordNotUnderstood(note: String, now: TimeInterval = Monotonic.now()) {
        clearResult()
        pushHistory(failure: nil, insertion: nil, note: note)
        present(.notUnderstood, now: now)
    }

    /// Files a press that held no speech. Nothing goes into the history and
    /// the dot is left alone, because nothing was dictated and nothing failed.
    public mutating func recordNoSpeech(now: TimeInterval = Monotonic.now()) {
        present(.noSpeech, now: now)
    }

    /// Warn that the press being held is heading for refusal.
    public mutating func warnQuiet(now: TimeInterval = Monotonic.now()) {
        toast = .quiet(now: now)
    }

    /// Take the toast away once it has been up long enough to read.
    public mutating func retireToast(now: TimeInterval = Monotonic.now()) {
        if let toast, now - toast.raisedAt >= Toast.dwell {
            self.toast = nil
        }
    }

    /// Return the capsule to Ready once a result has had its moment, unless a
    /// new dictation has already taken over.
    public mutating func retireResult(now: TimeInterval = Monotonic.now()) {
        guard let doneAt, now - doneAt > Self.resultDwell, hud != .listening else { return }
        hud = .idle
        self.doneAt = nil
    }

    /// Opening the console is the acknowledgement, so it is the one place the
    /// unread dot is cleared.
    public mutating func openConsole() {
        consoleOpen = true
        unreadFailure = false
    }

    /// Show an outcome on the capsule, if the capsule is free to show it.
    ///
    /// While the user speaks, the capsule says listening whatever finishes
    /// behind it; while other dictations are still queued, it says processing.
    /// Only the last outcome of a run is shown, and the dwell timer starts
    /// then. Every outcome is filed, toasted and dotted by its caller either
    /// way, so nothing an earlier dictation says is lost to a later one.
    private mutating func present(_ outcome: HudState, now: TimeInterval) {
        if recording {
            return
        }
        processingSince = nil
        if inFlight > 0 {
            hud = .processing
            return
        }
        hud = outcome
        doneAt = now
    }

    private mutating func pushHistory(failure: Failure?, insertion: Insertion?, note: String? = nil) {
        let record = DictationRecord(
            timestamp: Date(),
            transcript: transcript,
            route: route,
            output: output,
            timings: timings,
            failure: failure,
            note: note,
            insertion: insertion
        )
        file(record)
    }

    /// Keep a record, newest first, dropping the oldest past the limit.
    private mutating func file(_ record: DictationRecord) {
        history.insert(record, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}

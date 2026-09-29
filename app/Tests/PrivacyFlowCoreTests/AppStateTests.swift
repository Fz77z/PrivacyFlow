import Foundation
import Testing
@testable import PrivacyFlowCore

/// How a dictation's outcome changes what the user sees.
struct AppStateTests {
    /// The dot exists so a failure that happened while the user was elsewhere
    /// is still discoverable, so neither a new press nor a silent one erases it.
    @Test func theUnreadDotSurvivesUntilTheConsoleIsOpened() {
        var state = AppState()
        state.recordFailure(.dropped("Transcription failed", "worker died"), preserved: nil)
        state.resetForRecording()
        state.recordNoSpeech()
        #expect(state.unreadFailure)
        state.openConsole()
        #expect(!state.unreadFailure)
    }

    @Test func aFailureRaisedWhileTheConsoleIsOpenDoesNotSetTheDot() {
        var state = AppState()
        state.openConsole()
        state.recordFailure(.dropped("Transcription failed", "worker died"), preserved: nil)
        #expect(!state.unreadFailure)
    }

    /// A press while the last result is on screen must take the capsule with it,
    /// or the old dwell timer expires mid-dictation and strands it.
    @Test func startingARecordingRetiresThePreviousResultsClock() {
        var state = AppState()
        state.recordInserted(.pasted, now: 100)
        state.resetForRecording()
        state.retireResult(now: 200)
        #expect(state.hud == .listening)
        #expect(state.doneAt == nil)
    }

    /// An answer that beats the announcement delay must never flash Transcribing.
    @Test func anAnswerThatBeatsTheDelayNeverAnnouncesTranscribing() {
        var state = AppState()
        state.resetForRecording()
        state.endRecording()
        state.beginProcessing(now: 10)
        state.announceProcessing(after: 0.12, now: 10.05)
        #expect(state.hud == .listening)
        state.completeInFlight()
        state.recordNoSpeech(now: 10.06)
        state.announceProcessing(after: 0.12, now: 11)
        #expect(state.hud == .noSpeech)
    }

    @Test func aWaitLongEnoughToNoticeDoesSayTranscribing() {
        var state = AppState()
        state.resetForRecording()
        state.beginProcessing(now: 10)
        state.announceProcessing(after: 0.12, now: 10.2)
        #expect(state.hud == .processing)
    }

    /// Work queued behind the model load is not transcribing, and saying so
    /// turned a slow start into what looked like a hang.
    @Test func workQueuedBeforeTheModelsLoadSaysLoadingModels() {
        var state = AppState()
        state.worker = .starting
        #expect(state.processingLabel == "Loading models")
        state.worker = .ready(WorkerReady(loadMilliseconds: 5000, lockedBytes: 1))
        #expect(state.processingLabel == "Transcribing")
    }

    /// A clipboard ending lost nothing, so it is never painted as an error, and
    /// its toast shows the words the user is about to paste.
    @Test(arguments: [Insertion.copiedOnly, .copiedNoField])
    func aDictationThatReachedTheClipboardIsNeverAnError(insertion: Insertion) {
        var state = AppState()
        state.output = "The finished text."
        state.recordInserted(insertion)
        #expect(state.hud == .copied)
        #expect(state.lastFailure == nil)
        #expect(!state.unreadFailure)
        #expect(state.toast?.kind == .copied)
        #expect(state.toast?.body == "The finished text.")
    }

    @Test func anOrdinaryPasteSaysNothing() {
        var state = AppState()
        state.output = "words"
        state.recordInserted(.pasted)
        #expect(state.toast == nil)
    }

    /// The clipboard holds the raw transcript, so the toast shows that and not
    /// the half-processed output.
    @Test func aFailureThatKeptTheRawTranscriptShowsTheTranscript() {
        var state = AppState()
        state.transcript = "what I actually said"
        state.output = "half rewritten"
        state.recordFailure(.dropped("Rewriting failed", "the worker stopped"), preserved: .raw)
        #expect(state.toast?.body == "what I actually said")
        #expect(state.toast?.kind == .failed)
    }

    /// A toast that says the words are on the clipboard when they are not sends
    /// the user to paste whatever was there before.
    @Test func aFailureThatCouldNotKeepAnythingRaisesNoToast() {
        var state = AppState()
        state.transcript = "gone"
        state.recordFailure(.dropped("Transcription failed", "stopped"), preserved: .unavailable("no pasteboard"))
        #expect(state.toast == nil)
    }

    /// Blocked means nothing was captured, so the previous dictation's words
    /// must not be filed against it as though they were lost.
    @Test func aBlockedFailureDoesNotFileThePreviousUtterance() {
        var state = AppState()
        state.transcript = "the thing I said last time"
        state.output = "The thing I said last time."
        state.recordFailure(.blocked("Hotkey unavailable", "detail"), preserved: nil)
        #expect(state.history[0].transcript.isEmpty)
        #expect(state.history[0].output.isEmpty)
    }

    @Test func aDroppedFailureKeepsTheTranscriptItDidGet() {
        var state = AppState()
        state.transcript = "half a sentence"
        state.recordFailure(.dropped("Couldn't insert", "Target changed"), preserved: nil)
        #expect(state.history[0].transcript == "half a sentence")
    }

    /// Pressing and saying nothing is a non-event: no history, no dot.
    @Test func aSilentPressLeavesNoTraceInTheConsole() {
        var state = AppState()
        state.recordNoSpeech()
        #expect(state.hud == .noSpeech)
        #expect(state.history.isEmpty)
        #expect(!state.unreadFailure)
        #expect(state.doneAt != nil)
    }

    /// Being misheard is told and filed, but it is not a failure.
    @Test func aDictationThatCouldNotBeDecodedSaysSoAndFilesIt() {
        var state = AppState()
        state.transcript = "garbage"
        state.recordNotUnderstood(note: "Heard 2.8 s and could not decode it")
        #expect(state.hud == .notUnderstood)
        #expect(state.lastFailure == nil)
        #expect(!state.unreadFailure)
        #expect(state.history[0].note == "Heard 2.8 s and could not decode it")
        #expect(state.history[0].transcript.isEmpty)
    }

    /// The warning is raised while the key is down, and the refusal it predicted
    /// arrives the moment the key comes up; clearing it then would hide why.
    @Test func aQuietWarningOutlivesTheRefusalItPredicted() {
        var state = AppState()
        state.resetForRecording()
        state.warnQuiet()
        state.recordNoSpeech()
        #expect(state.toast?.kind == .quiet)
    }

    @Test func aNewRecordingTakesTheToastWithIt() {
        var state = AppState()
        state.recordInserted(.copiedOnly)
        state.resetForRecording()
        #expect(state.toast == nil)
    }

    /// A worker that exits between dictations is filed and raises the dot, but
    /// must not take the capsule away from a dictation the user is speaking.
    @Test func aBackgroundFailureLeavesADictationOnScreenAlone() {
        var state = AppState()
        state.resetForRecording()
        state.recordBackgroundFailure(.blocked("Worker restarted", "The worker stopped unexpectedly (signal 9)."))
        #expect(state.hud == .listening)
        #expect(state.unreadFailure)
        #expect(state.history[0].failure?.headline == "Worker restarted")
    }

    @Test func historyKeepsTheNewestFifty() {
        var state = AppState()
        for index in 0..<60 {
            state.output = "\(index)"
            state.recordInserted(.pasted)
        }
        #expect(state.history.count == 50)
        #expect(state.history[0].output == "59")
    }
}

/// Dictations queue: the user can speak again while earlier ones are still
/// being transcribed, and each one's outcome must still reach them.
struct QueuedDictationTests {
    /// Speak, release, and start speaking again before the first is answered.
    func secondDictationUnderWay() -> AppState {
        var state = AppState()
        state.resetForRecording()
        state.endRecording()
        state.beginProcessing(now: 0)
        state.resetForRecording()
        return state
    }

    /// The capsule says listening while the user speaks, whatever finishes
    /// behind it, and the earlier dictation is still filed.
    @Test func anEarlierResultArrivingMidRecordingLeavesListeningOnScreen() {
        var state = secondDictationUnderWay()
        state.output = "first"
        state.completeInFlight()
        state.recordInserted(.pasted, now: 1)
        #expect(state.hud == .listening)
        #expect(state.history.first?.output == "first")
        #expect(state.doneAt == nil, "no dwell starts under a live recording")
    }

    /// After the release, the capsule says processing while anything is still
    /// queued, and shows an outcome only when the last one is answered.
    @Test func theCapsuleSaysProcessingUntilTheLastOneIsAnswered() {
        var state = secondDictationUnderWay()
        state.endRecording()
        state.beginProcessing(now: 2)
        #expect(state.hud == .processing, "behind earlier work, processing is said at once")
        state.completeInFlight()
        state.recordInserted(.pasted, now: 3)
        #expect(state.hud == .processing, "one is still queued")
        state.completeInFlight()
        state.recordInserted(.pasted, now: 4)
        #expect(state.hud == .done)
    }

    /// A failure early in a run must not be hidden by a success after it: its
    /// toast, its dot and its history entry all survive.
    @Test func anEarlierFailureIsNotHiddenByALaterSuccess() {
        var state = secondDictationUnderWay()
        state.endRecording()
        state.beginProcessing(now: 2)
        state.output = "the finished text"
        state.completeInFlight()
        state.recordFailure(.dropped("Couldn't insert", "not allowed to paste"), preserved: .processed, now: 3)
        state.output = "second"
        state.completeInFlight()
        state.recordInserted(.pasted, now: 4)
        #expect(state.toast?.kind == .failed)
        #expect(state.unreadFailure)
        #expect(state.history.map(\.output) == ["second", "the finished text"])
    }
}

/// A toast that offered ⌘V stops offering it once a later dictation has
/// replaced the clipboard, because ⌘V would paste that one instead.
struct SupersededToastTests {
    @Test func aLaterPasteStopsAnEarlierToastOfferingCommandV() {
        var state = AppState()
        state.output = "the first dictation"
        state.recordInserted(.copiedNoField)
        #expect(state.toast?.offersPaste == true)
        state.output = "the second dictation"
        state.recordInserted(.pasted)
        let toast = state.toast
        #expect(toast?.offersPaste == false)
        #expect(toast?.headline == "No text field focused", "it still says this dictation was not pasted")
        #expect(toast?.body == "the first dictation")
        #expect(toast?.footer.contains("console") == true)
        #expect(toast?.footer.contains("⌘V") == false)
    }

    /// The quiet warning never offered ⌘V, so there is nothing to withdraw.
    @Test func aToastThatNeverOfferedCommandVIsLeftAlone() {
        var state = AppState()
        state.resetForRecording()
        state.warnQuiet()
        state.recordInserted(.pasted)
        #expect(state.toast?.footer == "Still recording · it can still be saved")
    }
}

/// Placing results in spoken order, and never while the key is held.
struct PlacementQueueTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { usleep(1_000) }
    }

    /// A result that is ready while the user is speaking again waits for the
    /// key to come up, and what is queued behind it waits in line.
    @Test func aPasteReadyMidRecordingWaitsForTheRelease() {
        let queue = PlacementQueue()
        let log = Log()
        queue.keyDown()
        queue.submit(pastes: true) { log.add("first") }
        queue.submit(pastes: false) { log.add("second, a failure") }
        usleep(100_000)
        #expect(log.all.isEmpty, "nothing is placed under the user's hands")
        queue.keyUp()
        waitUntil { log.all.count == 2 }
        #expect(log.all == ["first", "second, a failure"])
    }

    /// The key can go down again after a paste's turn began, during the
    /// checks before Cmd-V; the paste waits again for it to come up.
    @Test func aPasteWhoseKeyGoesDownAgainWaitsAgain() {
        let queue = PlacementQueue()
        let log = Log()
        let turnBegan = DispatchSemaphore(value: 0)
        let pressedAgain = DispatchSemaphore(value: 0)
        queue.submit(pastes: true) {
            turnBegan.signal()
            pressedAgain.wait()
            queue.waitUntilKeyUp()
            log.add("pasted")
        }
        turnBegan.wait()
        queue.keyDown()
        #expect(queue.isKeyHeld)
        pressedAgain.signal()
        usleep(100_000)
        #expect(log.all.isEmpty)
        queue.keyUp()
        waitUntil { !log.all.isEmpty }
        #expect(log.all == ["pasted"])
    }

    @Test func resultsArePlacedInTheOrderTheyWereSpoken() {
        let queue = PlacementQueue()
        let log = Log()
        for index in 0..<20 {
            queue.submit(pastes: index.isMultiple(of: 3)) { log.add("\(index)") }
        }
        waitUntil { log.all.count == 20 }
        #expect(log.all == (0..<20).map(String.init))
    }

    /// Only pasting waits: an outcome that pastes nothing, at the head of the
    /// line, is reported while the key is still down.
    @Test func anOutcomeThatPastesNothingIsNotHeldBack() {
        let queue = PlacementQueue()
        let log = Log()
        queue.keyDown()
        queue.submit(pastes: false) { log.add("no speech") }
        waitUntil { !log.all.isEmpty }
        #expect(log.all == ["no speech"])
        queue.keyUp()
    }
}

/// What the user is told when a dictation's words survived something going wrong.
struct PreservationTests {
    @Test func onlyADeliberateReleaseMayInsert() {
        #expect(CaptureEnd.released.mayInsert)
        #expect(!CaptureEnd.ceilingReached.mayInsert)
        #expect(!CaptureEnd.bufferFull.mayInsert)
        #expect(!CaptureEnd.deviceLost.mayInsert)
        #expect(!CaptureEnd.deviceChanged.mayInsert)
    }

    /// Nowhere to put the text is not a lost dictation; a capture cut short is.
    @Test func aDictationWithNowhereToLandIsNotALostOne() {
        #expect(Destination(targetPid: 4321, captureEnd: .released) == .insert(pid: 4321))
        #expect(Destination(targetPid: nil, captureEnd: .released) == .clipboard)
        #expect(Destination(targetPid: 4321, captureEnd: .deviceLost) == .lost)
        #expect(Destination(targetPid: nil, captureEnd: .bufferFull) == .lost)
    }

    /// The failure leads, and raw text is never described as processed.
    @Test func theOriginalFailureLeadsAndRawTextIsNotCalledFinished() {
        let raw = failureDetail("Routing failed.", preserved: .raw)
        #expect(raw.hasPrefix("Routing failed."))
        #expect(raw.contains("raw transcription"))
        #expect(!raw.contains("finished text"))
        let processed = failureDetail("No destination.", preserved: .processed)
        #expect(processed.contains("finished text"))
        #expect(!processed.contains("raw transcription"))
    }

    @Test func aClipboardFailureIsReportedBesideTheOriginalNotInsteadOfIt() {
        let detail = failureDetail("The worker exited.", preserved: .unavailable("Could not access the pasteboard"))
        #expect(detail.contains("The worker exited."))
        #expect(detail.contains("Could not access the pasteboard"))
        #expect(!detail.contains("Cmd-V"))
    }
}

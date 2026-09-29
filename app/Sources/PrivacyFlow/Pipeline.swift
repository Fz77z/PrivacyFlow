import Foundation
import os
import PrivacyFlowCore

/// One captured dictation on its way through the pipeline.
struct WorkItem {
    var captured: CapturedAudio
    var captureEnd: CaptureEnd
    /// When the key came up, for the total latency.
    var speechFinished: TimeInterval
    var queuedAt: TimeInterval
    /// The application that was frontmost at the press, if it can receive text.
    var targetPid: Int32?
}

/// What became of one dictation that got as far as the worker.
struct WorkResult {
    enum Outcome {
        case inserted(Insertion)
        /// Categorised where it happened: only the pipeline knows whether the
        /// words were lost to the worker or to the paste.
        case failed(Failure)
    }

    var transcript = ""
    var route: Route?
    var output = ""
    var timings = Timings()
    var outcome: Outcome
    /// What the clipboard holds for a dictation that failed after its words
    /// existed, carried as its own answer so the toast shows the text that is
    /// really there.
    var preserved: Preserved?
}

/// Everything the pipeline tells the interface, in one ordered stream.
enum PipelineMessage {
    case workerReady(WorkerReady)
    case workerFailed(String)
    /// A worker that had been ready exited, and a fresh one is being started.
    case workerRestarting(String)
    case finished(WorkResult)
    /// The worker heard nothing. Not a result with an empty transcript: there
    /// is nothing to route, insert or file.
    case noSpeech
    case notUnderstood(note: String)
}

/// The thread that owns the worker, writes the audio and inserts the text.
///
/// Two stages, each a serial queue. Warm-ups and transcriptions share the
/// first, so a warm-up can never overtake the dictation it was sent ahead of.
/// Placing text, the clipboard and the cursor memory belong to the second,
/// which keeps spoken order and holds pastes while the dictation key is down.
/// Splitting them lets a later dictation be transcribed while an earlier one
/// waits to be pasted.
final class Pipeline: @unchecked Sendable {
    /// The worker as the pipeline knows it. Only touched on the queue.
    private enum Slot {
        /// Not asked to start yet: the models are not installed.
        case notStarted
        /// Could not be started, and will not be retried in this run.
        case unavailable(String)
        /// A process, and whether it ever reached ready. Only a worker that
        /// reached ready is replaced when it exits, so a worker that cannot
        /// load is never restarted in a loop.
        case running(WorkerProcess, reachedReady: Bool)
    }

    private let queue = DispatchQueue(label: "PrivacyFlow pipeline", qos: .userInitiated)
    private let audioDirectory: URL
    private let cursorMoved: CursorMoved
    private let deliver: (PipelineMessage) -> Void
    private var slot = Slot.notStarted
    private var launch: Result<WorkerLaunch, LaunchProblem>?
    /// Only touched on the placement queue, which places one dictation at a
    /// time in spoken order, so spacing follows insertion order.
    private var cursor = CursorMemory()
    private let placement = PlacementQueue()
    /// The running worker's process id, readable from the main thread so
    /// quitting can stop a worker that is still loading its models, and
    /// whether the app is quitting, so that exit is not mistaken for a crash.
    private let shutdown = OSAllocatedUnfairLock<(pid: Int32?, quitting: Bool)>(initialState: (nil, false))

    /// `deliver` is called on the main thread.
    init(audioDirectory: URL, cursorMoved: CursorMoved, deliver: @escaping (PipelineMessage) -> Void) {
        self.audioDirectory = audioDirectory
        self.cursorMoved = cursorMoved
        self.deliver = deliver
    }

    /// Start the worker and wait for it to load. Dictations queued meanwhile
    /// wait behind it, which the capsule calls "Loading models".
    func startWorker(_ launch: Result<WorkerLaunch, LaunchProblem>) {
        queue.async { [self] in
            self.launch = launch
            startAndAwaitReady()
        }
    }

    /// Stop the worker, from any thread, if one was started. SIGKILL rather
    /// than a request: this runs as the app goes away, possibly mid-load, and
    /// the worker holds nothing worth flushing.
    func stopWorker() {
        let pid = shutdown.withLock { state -> Int32? in
            state.quitting = true
            return state.pid
        }
        if let pid, pid > 0 {
            kill(pid, SIGKILL)
        }
    }

    /// Warm the router ahead of a dictation. A failure costs speed only, so it
    /// is logged rather than shown; a worker it found broken is already
    /// poisoned, and the dictation behind it reports that.
    func prepare() {
        queue.async { [self] in
            replaceIfExited()
            guard case .running(let process, true) = slot else { return }
            do {
                try process.client.prepare()
            } catch {
                FileHandle.standardError.write(Data("PrivacyFlow could not prepare the router: \(error)\n".utf8))
            }
        }
    }

    /// Launch a worker and wait for its ready line. On the queue.
    private func startAndAwaitReady() {
        guard let launch else { return }
        let process: WorkerProcess
        do {
            process = try WorkerProcess(try launch.get()) { [weak self] in
                // Noticed as it happens, not when the next dictation finds it.
                self?.queue.async { self?.replaceIfExited() }
            }
        } catch {
            let problem = error as? LaunchProblem ?? LaunchProblem("\(error)")
            slot = .unavailable(problem.description)
            send(.workerFailed(problem.description))
            return
        }
        // Recorded before loading, so quitting during the load still stops it.
        shutdown.withLock { $0.pid = process.pid }
        slot = .running(process, reachedReady: false)
        do {
            let ready = try process.client.awaitReady()
            slot = .running(process, reachedReady: true)
            send(.workerReady(ready))
        } catch {
            // The client is poisoned, so every later request reports this too.
            // A worker that never became ready is not restarted.
            send(.workerFailed(asSentence("\(error)") + " Quit and reopen PrivacyFlow to try again."))
        }
    }

    /// If a worker that had reached ready has exited, say why and start a
    /// fresh one. Called when the process ends, and again before each request,
    /// so an exit is handled before anything is sent to a dead worker.
    private func replaceIfExited() {
        guard case .running(let process, let reachedReady) = slot, !process.isRunning, reachedReady else { return }
        guard !shutdown.withLock({ $0.quitting }) else { return }
        send(.workerRestarting(process.exitDescription))
        startAndAwaitReady()
    }

    /// Transcribe a finished recording, then place its outcome once every
    /// dictation spoken before it has been placed.
    func dictate(_ item: WorkItem) {
        queue.async { [self] in
            replaceIfExited()
            let answer = transcribe(item)
            placement.submit(pastes: answer.pastes(item)) { [self] in
                send(place(answer, of: item))
            }
        }
    }

    /// The dictation key went down: nothing is pasted until it comes up.
    func keyDown() {
        placement.keyDown()
    }

    func keyUp() {
        placement.keyUp()
    }

    private func send(_ message: PipelineMessage) {
        DispatchQueue.main.async { [deliver] in deliver(message) }
    }

    /// What the worker stage hands the placement stage for one dictation.
    /// Nothing here has touched the clipboard or the cursor yet: all of that
    /// happens in placement, in spoken order, so a later dictation can never
    /// overwrite the clipboard an earlier one is about to paste from.
    private enum Answer {
        /// Nothing to put anywhere.
        case report(PipelineMessage)
        /// A failure before any words existed.
        case failed(headline: String, detail: String, timings: Timings)
        /// Recognition succeeded and something after it failed, so the raw
        /// words are kept on the clipboard.
        case failedAfterRecognition(transcript: String, message: String, timings: Timings)
        /// Transcribed and routed: the text is placed.
        case transcribed(Transcription, timings: Timings)

        /// Whether placing this pastes, which waits for the key to come up.
        func pastes(_ item: WorkItem) -> Bool {
            guard case .transcribed = self else { return false }
            if case .insert = Destination(targetPid: item.targetPid, captureEnd: item.captureEnd) {
                return true
            }
            return false
        }
    }

    /// Write the recording, hand it to the worker, and delete it again.
    private func transcribe(_ item: WorkItem) -> Answer {
        var timings = Timings()
        timings.queueMs = milliseconds(Monotonic.now() - item.queuedAt)
        timings.audioMs = milliseconds(item.captured.seconds)

        // Presses are refused before the models are installed or once the
        // worker has failed, so reaching either here is a press that raced the
        // change, and it is failed explicitly like any other.
        let client: WorkerClient
        switch slot {
        case .running(let process, _):
            client = process.client
        case .unavailable(let reason):
            return .failed(headline: "Transcription failed", detail: reason, timings: timings)
        case .notStarted:
            return .failed(headline: "Models not installed", detail: "The speech models are not installed yet, so nothing could be transcribed.", timings: timings)
        }

        let finalizeStarted = Monotonic.now()
        let path: URL
        do {
            path = try writeRecording(item.captured)
        } catch {
            return .failed(headline: "Transcription failed", detail: "Could not write the recording: \(error)", timings: timings)
        }
        timings.captureFinalizeMs = milliseconds(Monotonic.now() - finalizeStarted)

        // Deleted however the worker answers: recordings never outlive their
        // utterance.
        let reply = Result { try client.transcribe(audioPath: path.path, audioSeconds: item.captured.seconds) }
        do {
            try FileManager.default.removeItem(at: path)
        } catch {
            FileHandle.standardError.write(Data("PrivacyFlow could not delete \(path.path): \(error)\n".utf8))
        }

        switch reply {
        case .success(.transcribed(let result)):
            timings.asrMs = milliseconds(result.asrMs / 1000)
            timings.routerMs = milliseconds(result.routerMs / 1000)
            timings.processingMs = result.processingMs.map { milliseconds($0 / 1000) }
            return .transcribed(result, timings: timings)
        case .success(.noSpeech):
            return .report(.noSpeech)
        case .success(.unintelligible(let seconds, let detail)):
            return .report(.notUnderstood(note: String(format: "Heard %.1f s and could not decode it (%@). Nothing was inserted.", seconds, detail)))
        case .success(.failed(let message, let transcript)):
            return .failedAfterRecognition(transcript: transcript ?? "", message: message, timings: timings)
        case .failure(let error):
            return .failed(headline: "Transcription failed", detail: "\(error)", timings: timings)
        }
    }

    /// Put one dictation's outcome where it belongs. Runs on the placement
    /// queue, in spoken order, and only once the key is up if it pastes.
    private func place(_ answer: Answer, of item: WorkItem) -> PipelineMessage {
        func failed(_ headline: String, _ detail: String, timings: Timings, keeping partial: (transcript: String, route: Route?, output: String) = ("", nil, ""), preserved: Preserved? = nil) -> PipelineMessage {
            var timings = timings
            timings.totalMs = milliseconds(Monotonic.now() - item.speechFinished)
            return .finished(WorkResult(
                transcript: partial.transcript,
                route: partial.route,
                output: partial.output,
                timings: timings,
                // Every pipeline failure happens after the user spoke, so the
                // words did not come back.
                outcome: .failed(.dropped(headline, detail)),
                preserved: preserved
            ))
        }

        let transcription: Transcription
        var timings: Timings
        switch answer {
        case .report(let message):
            return message
        case .failed(let headline, let detail, let failedTimings):
            return failed(headline, detail, timings: failedTimings)
        case .failedAfterRecognition(let words, let message, let failedTimings):
            // The failure stands, and the words recognised before it are kept.
            let preserved = Inserter.preserve(words, as: .raw)
            return failed("Dictation failed", failureDetail(message, preserved: preserved), timings: failedTimings, keeping: (words, nil, ""), preserved: preserved)
        case .transcribed(let result, let transcribedTimings):
            transcription = result
            timings = transcribedTimings
        }
        let produced = (transcription.transcript, Optional(transcription.route), transcription.output)

        let insertStarted = Monotonic.now()
        let placed: Result<Insertion, Error>
        switch Destination(targetPid: item.targetPid, captureEnd: item.captureEnd) {
        case .lost:
            // Processing succeeded, so the finished text is what is kept.
            let preserved = Inserter.preserve(transcription.output, as: .processed)
            return failed(item.captureEnd.headline, failureDetail(item.captureEnd.explanation, preserved: preserved), timings: timings, keeping: produced, preserved: preserved)
        case .insert(let pid):
            // Anything pressed or clicked since the last insertion could have
            // moved the cursor, so the memory goes before it is consulted.
            if cursorMoved.take() {
                cursor.forget()
            }
            let (previous, beforePrevious) = cursor.recall(pid: pid)
            let joined = PasteSpacing.join(previous: previous, beforePrevious: beforePrevious, text: transcription.output)
            placed = Result { try Inserter.insert(joined, into: pid, placement: placement) }
            // Only text that reached the document says where the cursor is now.
            if case .success(.pasted) = placed {
                cursor.remember(pid: pid, inserted: joined)
            } else {
                cursor.forget()
            }
        case .clipboard:
            // Nothing to paste into, so the clipboard is the whole insertion.
            switch Inserter.preserve(transcription.output, as: .processed) {
            case .processed:
                placed = .success(.copiedNoField)
            case let unavailable:
                return failed("Couldn't copy", failureDetail(item.captureEnd.explanation, preserved: unavailable), timings: timings, keeping: produced, preserved: unavailable)
            }
        }

        switch placed {
        case .success(let insertion):
            timings.insertMs = milliseconds(Monotonic.now() - insertStarted)
            timings.totalMs = milliseconds(Monotonic.now() - item.speechFinished)
            return .finished(WorkResult(
                transcript: transcription.transcript,
                route: transcription.route,
                output: transcription.output,
                timings: timings,
                outcome: .inserted(insertion)
            ))
        case .failure(let error):
            // The pasteboard was written before anything could refuse, so the
            // words have usually survived; asked again rather than assumed.
            let preserved = Inserter.preserve(transcription.output, as: .processed)
            return failed("Couldn't insert", "\(error)", timings: timings, keeping: produced, preserved: preserved)
        }
    }

    /// Convert the capture to the worker's format and write it to the cache.
    private func writeRecording(_ captured: CapturedAudio) throws -> URL {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let samples = try WavEncoding.convert(captured.samples, from: captured.sampleRate)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = "utterance-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")).wav"
        let url = audioDirectory.appendingPathComponent(name)
        try WavEncoding.wavData(samples).write(to: url, options: .atomic)
        return url
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}

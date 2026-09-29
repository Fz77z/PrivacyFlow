import AppKit
import PrivacyFlowCore

/// The app's one owner of dictation: it takes the hotkey, drives the
/// microphone, hands captures to the pipeline and files what comes back.
///
/// Everything here runs on the main thread. The capsule, toast, console and
/// menu bar all read from it, and none of them change dictation state except
/// through it.
@MainActor
final class AppController: ObservableObject {
    /// Matches the capture buffer's ceiling. Reaching it stops the recording;
    /// it does not throw away what was captured.
    static let maximumRecording: TimeInterval = Microphone.maximumSeconds
    /// How long a dictation must be in the pipeline before the capsule says so:
    /// long enough that an immediate answer replaces Listening directly.
    static let processingAnnounceDelay: TimeInterval = 0.12
    /// How long a result holds a minimal capsule open after it lands.
    static let resultHold: TimeInterval = 0.6
    /// How long "Show Capsule" in the menu bar opens a minimal capsule.
    static let showOnRequestFor: TimeInterval = 3

    @Published var state = AppState()
    @Published private(set) var settings: Settings
    /// Why the settings file could not be read, while it still has not been
    /// replaced by a successful save.
    @Published private(set) var settingsProblem: String?
    /// Why the last save failed, shown beside the controls.
    @Published private(set) var settingsWriteError: String?
    /// Why the cues cannot play, shown beside their checkbox: it costs a
    /// confirmation sound, not a dictation.
    @Published private(set) var cueProblem: String?
    /// Why the microphone could not be opened the last time it was tried.
    @Published private(set) var microphoneProblem: String?
    /// Why the hotkey watcher did not install, if it did not.
    @Published private(set) var hotkeyProblem: String?
    /// The microphone being recorded from, for Settings and Status.
    @Published private(set) var microphoneBinding: MicrophoneBinding?
    /// The connected inputs, kept current as devices come and go.
    @Published private(set) var microphoneNames: [String] = []
    @Published private(set) var microphoneListingProblem: String?

    let dataDirectory: URL
    let installer: ModelInstaller
    let workerLaunch: Result<WorkerLaunch, LaunchProblem>
    /// Input Monitoring as it was when the event tap was created. The tap does
    /// not pick up a grant made afterwards, so a later grant needs a relaunch.
    let inputMonitoringAtLaunch: Bool

    /// How far each bar stands while listening. Kept out of the published
    /// state because it changes every frame and nothing but the capsule reads it.
    private(set) var voiceBars: [Float] = [0, 0, 0, 0]
    /// While the capsule is listening, how long the key has been held.
    private(set) var recordingStarted: TimeInterval?
    /// Until when a minimal capsule stays open because the menu asked it to.
    private(set) var shownOnRequestUntil: TimeInterval?

    private var microphone: Microphone?
    private var microphoneChoicePending = false
    /// Whether another app has secure keyboard entry on, which hides the
    /// dictation key from PrivacyFlow.
    @Published private(set) var secureInputOn = false
    /// Said on the capsule's tooltip when a press of the shortcut was seen on
    /// the keyboard but never arrived as events.
    @Published private(set) var missedPress: String?
    /// While the Settings row is waiting for a new shortcut, the tap is off so
    /// the keys being recorded do not start a dictation.
    @Published private(set) var recordingShortcut = false

    private var cues: Cues?
    private var hotkey: Hotkey?
    /// Shared by every tap installed and by the pipeline, so replacing the tap
    /// for a new shortcut keeps one record of the cursor moving.
    private let cursorMoved = CursorMoved()
    /// Whether some part of the dictation shortcut counts as held, from its
    /// press until every part of it is up, whether or not a recording ran.
    /// Pastes wait while it is.
    private var keyHeld = false
    /// Which tap install is current. Events already queued by a tap that has
    /// since been replaced carry an older number and are dropped.
    private var hotkeyGeneration = 0
    private var lastPhysicalCheck: TimeInterval = 0
    private var secureInputTimer: Timer?
    private var pipeline: Pipeline!
    private var warnedQuiet = false
    private var targetPid: Int32?
    private var voiceMeter = VoiceMeter()

    /// Told whenever something needs the capsule to animate.
    var onNeedsFrames: (() -> Void)?
    var onOpenConsole: (() -> Void)?
    var onCloseConsole: (() -> Void)?
    var onMinimalModeChanged: (() -> Void)?

    init(dataDirectory: URL, cacheDirectory: URL, manifest: ModelManifest) {
        self.dataDirectory = dataDirectory
        let loaded = SettingsFile.load(from: dataDirectory)
        settings = loaded.settings
        settingsProblem = loaded.problem
        let modelsDirectory = dataDirectory.appendingPathComponent("models", isDirectory: true)
        installer = ModelInstaller(manifest: manifest, store: ModelStore(root: modelsDirectory))
        workerLaunch = Result { try WorkerLaunch.resolve(models: modelsDirectory) }.mapError { $0 as? LaunchProblem ?? LaunchProblem("\($0)") }
        inputMonitoringAtLaunch = Permissions.inputMonitoring

        let audioDirectory = cacheDirectory.appendingPathComponent("audio", isDirectory: true)
        Self.sweep(audioDirectory)
        pipeline = Pipeline(audioDirectory: audioDirectory, cursorMoved: cursorMoved) { [weak self] message in
            self?.receive(message)
        }
        installHotkey()
        // Secure keyboard entry hides key events from every tap, so it is
        // checked regularly, and more often while it is on, to notice a press
        // that never arrived.
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }

        // Opened now, so a keypress only has to start an already-built unit.
        // Not before the user has been asked, because opening it is what asks.
        if Permissions.microphone == .granted {
            _ = try? currentMicrophone()
        }
        do {
            let cues = try Cues()
            cues.onProblem = { [weak self] problem in self?.cueProblem = problem }
            self.cues = cues
        } catch {
            cueProblem = "\(error)"
        }
        reportStartupProblems()
        refreshMicrophoneNames()
        AudioDevices.observeChanges { [weak self] in self?.refreshMicrophoneNames() }

        installer.onInstalled = { [weak self] in self?.startWorker() }
        if installer.isInstalled {
            startWorker()
        } else {
            installer.resumeIfRequested()
        }
    }

    // MARK: Dictation

    /// The dictation key went down. Nothing is pasted while it is held,
    /// whether or not a recording starts.
    func keyWentDown() {
        keyHeld = true
        missedPress = nil
        pipeline.keyDown()
        startRecording()
    }

    /// Every part of the shortcut is up. A result that became ready while it
    /// was held is pasted now, before this recording's own.
    private func releaseKey() {
        keyHeld = false
        pipeline.keyUp()
    }

    /// The shortcut turned out to be a chord, such as Option+E: the user was
    /// typing. The recording is discarded, silently, and nothing is filed.
    func cancelRecording() {
        guard recordingStarted != nil, let microphone else { return }
        recordingStarted = nil
        _ = microphone.stopRecording()
        state.cancelRecording()
        targetPid = nil
        followMicrophoneChoice()
        onNeedsFrames?()
    }

    private func handle(_ event: Hotkey.Event, generation: Int) {
        guard generation == hotkeyGeneration else { return }
        switch event {
        case .pressed: keyWentDown()
        case .released: finishRecording(.released)
        case .cancelled: cancelRecording()
        case .allReleased: releaseKey()
        }
    }

    /// Install the tap for the shortcut in settings, replacing any other. A
    /// key counted as held by the old tap is released, so pastes cannot wait
    /// on a press the new tap never saw.
    private func installHotkey() {
        removeHotkey()
        hotkeyGeneration += 1
        let generation = hotkeyGeneration
        do {
            hotkey = try Hotkey(shortcut: settings.dictationShortcut, cursorMoved: cursorMoved) { [weak self] event in
                self?.handle(event, generation: generation)
            }
            hotkeyProblem = nil
        } catch {
            hotkeyProblem = "\(error)"
        }
    }

    /// Remove the tap. A press it had counted as held is ended normally and
    /// released, so pastes cannot wait on a press no tap is watching, and
    /// anything it had already queued is dropped by the generation check.
    private func removeHotkey() {
        hotkey?.stop()
        hotkey = nil
        hotkeyGeneration += 1
        if keyHeld {
            finishRecording(.released)
            releaseKey()
        }
    }

    /// Note secure keyboard entry, and a press it hid.
    private func checkSecureInput() {
        let on = Hotkey.secureInputIsOn
        if on != secureInputOn {
            secureInputOn = on
        }
        guard on, !keyHeld, missedPress == nil, let hotkey, hotkey.pressWasMissed else { return }
        missedPress = "A press of \(settings.dictationShortcut.label) was missed: another app has secure keyboard entry on, which hides the keyboard from PrivacyFlow. It is usually a password field or a terminal's Secure Keyboard Entry."
    }

    /// Start a recording. Dictations queue, so earlier ones still being
    /// transcribed carry on behind it; only a recording already under way
    /// refuses a second.
    func startRecording() {
        guard recordingStarted == nil else { return }
        // Refused at the press, before the user speaks, whenever nothing could
        // transcribe what they are about to say. A worker that is loading is
        // not refused: that takes seconds, and the dictation waits for it.
        switch state.worker {
        case .awaitingModels:
            failLocally(.blocked("Models not installed", "The speech models are not installed yet, so there is nothing to transcribe with. Finish setup to download them: open the console from the menu bar, then Status, then Open Setup."))
            return
        case .failed(let reason):
            failLocally(.blocked("Worker unavailable", reason))
            return
        case .starting, .ready:
            break
        }
        // PrivacyFlow's own window is not a destination, and neither is no
        // window at all. Neither is refused: the words go to the clipboard.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let target = Inserter.frontmostPid().flatMap { $0 == ownPid ? nil : $0 }

        switch Permissions.microphone {
        case .granted:
            break
        case .undecided:
            Permissions.requestMicrophone { [weak self] granted in
                if granted { _ = try? self?.currentMicrophone() }
            }
            failLocally(.blocked("Microphone access needed", "PrivacyFlow needs permission to use the microphone. Allow it when macOS asks, then dictate again."))
            return
        case .denied:
            failLocally(.inputUnavailable("Microphone access is off", "PrivacyFlow is not allowed to use the microphone. Turn it on in System Settings, Privacy & Security, Microphone."))
            return
        }
        let microphone: Microphone
        do {
            microphone = try currentMicrophone()
            try microphone.startRecording()
        } catch {
            failLocally(.inputUnavailable("Microphone unavailable", "Microphone unavailable: \(error)"))
            return
        }
        play(.press)
        state.resetForRecording()
        voiceMeter = VoiceMeter()
        voiceBars = voiceMeter.bars
        targetPid = target
        recordingStarted = Monotonic.now()
        warnedQuiet = false
        // Only once the worker is up: while it loads, its models are resident
        // anyway, and a warm-up would only queue in front of the dictation.
        if case .ready = state.worker {
            pipeline.prepare()
        }
        onNeedsFrames?()
    }

    /// The key came up, or the capture had to stop.
    func finishRecording(_ ending: CaptureEnd) {
        guard recordingStarted != nil, let microphone else { return }
        recordingStarted = nil
        state.endRecording()
        let speechFinished = Monotonic.now()
        // Played before the capture is inspected: the user released a key,
        // whatever the audio turns out to hold.
        play(.release)
        let captured = microphone.stopRecording()
        // Answered here because a press that held no speech is the one case
        // where the user is waiting to be told nothing happened, and anything
        // further in is a queue behind the previous dictation.
        let verdict = captured.samples.withUnsafeBufferPointer {
            EnergyFloor.verdict(samples: $0, sampleRate: captured.sampleRate)
        }
        if case .tooQuiet = verdict {
            state.recordNoSpeech()
        } else {
            state.beginProcessing()
            pipeline.dictate(WorkItem(
                captured: captured,
                captureEnd: captured.truncated ? .bufferFull : ending,
                speechFinished: speechFinished,
                queuedAt: Monotonic.now(),
                targetPid: targetPid
            ))
        }
        targetPid = nil
        followMicrophoneChoice()
        onNeedsFrames?()
    }

    /// Advance one frame: stop a capture that has to stop, move the meter,
    /// promote and retire states. Returns whether another frame is wanted.
    func tick(frameSeconds: Double) -> Bool {
        let now = Monotonic.now()
        // Read the keyboard itself a few times a second while the key counts
        // as held, so a release that never arrived still ends the dictation.
        if keyHeld, now - lastPhysicalCheck >= 0.2 {
            lastPhysicalCheck = now
            hotkey?.checkPhysicalState()
        }
        if let started = recordingStarted {
            if now - started >= Self.maximumRecording {
                finishRecording(.ceilingReached)
            } else if let interruption = microphone?.interruption {
                // Capture has stopped, so holding on would only record nothing
                // for as long as the key stays down.
                finishRecording(interruption == .disconnected ? .deviceLost : .deviceChanged)
            }
        }
        var next = state
        next.announceProcessing(after: Self.processingAnnounceDelay, now: now)
        next.retireResult(now: now)
        next.retireToast(now: now)
        if let started = recordingStarted, let microphone {
            voiceBars = voiceMeter.update(level: microphone.level, seconds: Float(frameSeconds))
            // Said once per press: a warning that re-raised itself every frame
            // would never finish appearing.
            if !warnedQuiet, EnergyFloor.headingForRefusal(held: now - started, recordedRms: microphone.recordedRms) {
                warnedQuiet = true
                next.warnQuiet(now: now)
            }
        } else if next.hud == .listening {
            // Released but not yet announced: the bars fall away with the voice.
            voiceBars = voiceMeter.update(level: 0, seconds: Float(frameSeconds))
        }
        if next != state {
            state = next
        }
        if let until = shownOnRequestUntil, now >= until {
            shownOnRequestUntil = nil
        }
        return recordingStarted != nil
            || keyHeld
            || state.hud == .listening
            || state.hud == .processing
            || state.processingSince != nil
            || state.doneAt != nil
            || state.toast != nil
            || shownOnRequestUntil != nil
    }

    /// Whether a dictation holds a minimal capsule open: from the press until
    /// its result has been on screen for a moment.
    var isDictating: Bool {
        if recordingStarted != nil || state.hud == .listening || state.hud == .processing {
            return true
        }
        if let doneAt = state.doneAt, Monotonic.now() - doneAt < Self.resultHold {
            return true
        }
        return false
    }

    private func receive(_ message: PipelineMessage) {
        switch message {
        case .workerReady(let ready):
            state.worker = .ready(ready)
        case .workerFailed(let reason):
            state.worker = .failed(reason)
        case .workerRestarting(let reason):
            state.worker = .starting
            state.recordBackgroundFailure(.blocked("Worker restarted", "\(asSentence(reason)) PrivacyFlow is starting a new one."))
        case .finished(let result):
            state.completeInFlight()
            state.transcript = result.transcript
            state.route = result.route
            state.output = result.output
            state.timings = result.timings
            switch result.outcome {
            case .inserted(let insertion):
                state.recordInserted(insertion)
            case .failed(let failure):
                state.recordFailure(failure, preserved: result.preserved)
            }
        case .noSpeech:
            state.completeInFlight()
            state.recordNoSpeech()
        case .notUnderstood(let note):
            state.completeInFlight()
            state.recordNotUnderstood(note: note)
        }
        onNeedsFrames?()
    }

    /// Fail before anything reached the pipeline. Nothing was dictated, so
    /// nothing is on the clipboard to mention.
    private func failLocally(_ failure: Failure) {
        state.recordFailure(failure, preserved: nil)
        onNeedsFrames?()
    }

    private func startWorker() {
        state.worker = .starting
        pipeline.startWorker(workerLaunch)
    }

    func stopWorker() {
        pipeline.stopWorker()
    }

    // MARK: Microphone

    /// The microphone to record from, reopened if the preference or the device
    /// it leads to changed, if its device went away, or if none was open.
    ///
    /// Reopening costs a hundred milliseconds from the start of that one
    /// dictation. Recording from the old device would cost the whole of it.
    private func currentMicrophone() throws -> Microphone {
        if let microphone, microphone.isCurrent(preferred: settings.preferredMicrophone) {
            return microphone
        }
        // The stale one goes first, so two devices are never held at once.
        microphone = nil
        microphoneBinding = nil
        do {
            let opened = try Microphone(preferred: settings.preferredMicrophone)
            microphone = opened
            microphoneBinding = opened.binding
            microphoneProblem = nil
            return opened
        } catch {
            microphoneProblem = "\(error)"
            throw error
        }
    }

    /// Reopen straight away after a new choice, so it takes effect and a
    /// device that will not open says so while the user is looking at the
    /// choice. A dictation in progress keeps its device until it ends.
    private func followMicrophoneChoice() {
        guard microphoneChoicePending, recordingStarted == nil else { return }
        microphoneChoicePending = false
        guard Permissions.microphone == .granted else { return }
        _ = try? currentMicrophone()
    }

    private func refreshMicrophoneNames() {
        do {
            microphoneNames = try AudioDevices.inputNames()
            microphoneListingProblem = nil
        } catch {
            microphoneNames = []
            microphoneListingProblem = "Could not list microphones: \(error)"
        }
    }

    /// Open the microphone after access was granted during setup.
    func microphoneAccessGranted() {
        guard microphone == nil else { return }
        _ = try? currentMicrophone()
    }

    // MARK: Settings

    func setMinimalMode(_ on: Bool) {
        settings.minimalMode = on
        save()
        onMinimalModeChanged?()
        onNeedsFrames?()
    }

    /// Use a new dictation shortcut, at once, with no restart. A refused one
    /// never gets here: the Settings row refuses it with its reason.
    func setShortcut(_ shortcut: Shortcut) {
        settings.dictationShortcut = shortcut
        save()
        installHotkey()
    }

    /// Stop watching the shortcut while the Settings row records a new one, so
    /// the keys being recorded do not start a dictation.
    func beginRecordingShortcut() {
        recordingShortcut = true
        removeHotkey()
    }

    /// Stop recording a shortcut, using `shortcut` if one was taken, and watch
    /// whichever is now in settings.
    func endRecordingShortcut(with shortcut: Shortcut?) {
        recordingShortcut = false
        if let shortcut {
            settings.dictationShortcut = shortcut
            save()
        }
        installHotkey()
    }

    func setSoundCues(_ on: Bool) {
        settings.soundCues = on
        // An open output holds the Mac awake, so turning cues off closes it now
        // rather than after the idle period.
        if !on {
            cues?.stop()
        }
        save()
    }

    func setPreferredMicrophone(_ name: String?) {
        guard name != settings.preferredMicrophone else { return }
        settings.preferredMicrophone = name
        microphoneChoicePending = true
        save()
        followMicrophoneChoice()
    }

    private func save() {
        settingsWriteError = SettingsFile.save(settings, to: dataDirectory)
        // A successful write replaces whatever was unreadable, so the banner
        // saying the bad file was left alone stops being true.
        if settingsWriteError == nil {
            settingsProblem = nil
        }
    }

    // MARK: Windows and menus

    /// Opening the console is the acknowledgement that clears the unread dot.
    func openConsole() {
        state.openConsole()
        onOpenConsole?()
    }

    /// The cog toggles the console; the menus only ever open it.
    func toggleConsole() {
        if state.consoleOpen {
            onCloseConsole?()
        } else {
            openConsole()
        }
    }

    func consoleClosed() {
        state.consoleOpen = false
    }

    func showCapsuleOnRequest() {
        shownOnRequestUntil = Monotonic.now() + Self.showOnRequestFor
        onNeedsFrames?()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Relaunch, for permissions that only take effect in a new process. The
    /// new copy waits for this one to exit, because the instance lock would
    /// otherwise turn it away.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL.path
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundle]
        do {
            try process.run()
        } catch {
            failLocally(.blocked("Couldn't relaunch", "PrivacyFlow could not relaunch itself: \(error.localizedDescription). Quit it and open it again."))
            return
        }
        quit()
    }

    private func play(_ cue: Cues.Cue) {
        guard settings.soundCues else { return }
        cues?.play(cue)
    }

    /// Startup problems are shown on the capsule and filed in the console. The
    /// dwell timer is cleared, because there is no working state for the
    /// capsule to decay back into.
    private func reportStartupProblems() {
        let failure: Failure?
        if let hotkeyProblem {
            failure = .blocked("Hotkey unavailable", "Hotkey unavailable: \(hotkeyProblem)")
        } else if let microphoneProblem {
            failure = .inputUnavailable("Microphone unavailable", "Microphone unavailable: \(microphoneProblem)")
        } else if let settingsProblem {
            // Last, because the others stop dictation outright and this does not.
            failure = .blocked("Settings unreadable", settingsProblem)
        } else {
            failure = nil
        }
        guard let failure else { return }
        state.recordFailure(failure, preserved: nil)
        state.doneAt = nil
    }

    /// Recordings are deleted after every reply, but a crash leaves the last
    /// one behind. The instance lock guarantees nothing else is using this
    /// directory, so whatever is here belongs to a previous run.
    private static func sweep(_ directory: URL) {
        guard let leftovers = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for leftover in leftovers {
            do {
                try FileManager.default.removeItem(at: leftover)
            } catch {
                FileHandle.standardError.write(Data("PrivacyFlow could not delete leftover audio at \(leftover.path): \(error)\n".utf8))
            }
        }
    }
}

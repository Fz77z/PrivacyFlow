import AVFoundation
import Foundation

/// The two short sounds that confirm a push-to-talk press and release.
///
/// A running audio output is not free: while it runs, coreaudiod holds a
/// PreventUserIdleSystemSleep assertion for this process, so the Mac never
/// idle-sleeps, and a Bluetooth output is held open. So the output is only
/// started when a cue is played, and stopped again once cues have been quiet
/// for `idleStop`. With cues turned off it is never started at all.
///
/// Starting a stopped engine costs time before the first sample plays: about
/// 270 ms on AirPods, against about 40 ms for an engine already running. A
/// dictation's release cue and the next press usually fall inside the idle
/// window, so only a press after a pause pays it. The engine is driven from its
/// own queue, so that cost never blocks the main thread or delays the
/// microphone starting on the same press.
final class Cues: @unchecked Sendable {
    enum Cue {
        case press
        case release
    }

    /// How long the output stays open after the last cue.
    static let idleStop: TimeInterval = 8

    private let queue = DispatchQueue(label: "PrivacyFlow cues", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let press: AVAudioPCMBuffer
    private let release: AVAudioPCMBuffer
    /// Only touched on the queue.
    private var idleTimer: DispatchWorkItem?
    private var needsReconnect = false
    private var configurationObserver: NSObjectProtocol?

    /// Told on the main thread why the output could not start, or nil once it
    /// starts again.
    var onProblem: ((String?) -> Void)?

    /// Load both cues from the bundle. Nothing is started here.
    init() throws {
        press = try Self.load("press")
        release = try Self.load("release")
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: press.format)
        // A change of output device stops the engine; the next cue reconnects
        // and starts it on whatever the user is listening to now.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.needsReconnect = true }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Play a cue, starting the output if it is stopped. Returns at once. A
    /// press mid-cue restarts from the top rather than layering over itself.
    func play(_ cue: Cue) {
        queue.async { [self] in
            guard startIfNeeded() else { return }
            player.stop()
            player.scheduleBuffer(cue == .press ? press : release, at: nil, options: [])
            player.play()
            scheduleStop()
        }
    }

    /// Stop the output now, for when cues are turned off.
    func stop() {
        queue.async { [self] in
            idleTimer?.cancel()
            idleTimer = nil
            player.stop()
            engine.stop()
        }
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        if needsReconnect {
            engine.connect(player, to: engine.mainMixerNode, format: press.format)
            needsReconnect = false
        }
        do {
            try engine.start()
            report(nil)
            return true
        } catch {
            report("The sound output could not be started: \(error.localizedDescription)")
            return false
        }
    }

    private func scheduleStop() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [self] in
            player.stop()
            engine.stop()
            idleTimer = nil
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idleStop, execute: timer)
    }

    private func report(_ problem: String?) {
        DispatchQueue.main.async { [weak self] in self?.onProblem?(problem) }
    }

    /// The cues are rendered as mono 16-bit files; anything else means the
    /// bundle and this code have drifted apart.
    private static func load(_ name: String) throws -> AVAudioPCMBuffer {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            throw LaunchProblem("\(name).wav is missing from the app bundle")
        }
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LaunchProblem("\(name).wav is not a mono cue")
        }
        try file.read(into: buffer)
        return buffer
    }
}

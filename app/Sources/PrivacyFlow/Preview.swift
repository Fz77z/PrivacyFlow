#if DEBUG
import AppKit
import PrivacyFlowCore

/// Debug builds only: `--preview <scene>` puts one screen of the interface up
/// in a fixed state, for screenshots. It takes no instance lock and keeps its
/// data in a scratch directory, so it never touches a real install.
@MainActor
struct Preview {
    let scene: String
    /// With `--capture <path>`, the scene's windows are drawn far off screen,
    /// written to `<path>-<n>.png`, and the app quits. Nothing appears on the
    /// display and nothing is asked of the keyboard or mouse.
    let capturePath: String?

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count else { return nil }
        scene = arguments[index + 1]
        if let capture = arguments.firstIndex(of: "--capture"), capture + 1 < arguments.count {
            capturePath = arguments[capture + 1]
        } else {
            capturePath = nil
        }
    }

    private static var retained: [AnyObject] = []

    /// How far left of every display a captured window is drawn, so it is
    /// never seen.
    private static let offscreenX: CGFloat = -30000

    private var offscreen: Bool { capturePath != nil }

    /// Show a hosted window, or when capturing, put it off screen first and
    /// order it in without activating anything.
    private func present(_ window: HostedWindowController) {
        guard offscreen else {
            window.show()
            return
        }
        let nsWindow = window.windowForPreview
        nsWindow.setFrameOrigin(CGPoint(x: Self.offscreenX, y: 200))
        nsWindow.orderFrontRegardless()
    }

    func run() {
        do {
            try Theme.registerFonts()
        } catch {
            fatalError("\(error)")
        }
        switch scene {
        case "capsules": capsules()
        case "toasts": toasts()
        default: windows()
        }
        guard let capturePath else { return }
        let windows = Self.retained.compactMap { object -> NSWindow? in
            switch object {
            case let window as NSWindow: window
            case let hosted as HostedWindowController: hosted.windowForPreview
            case let toast as ToastWindowController: toast.panelForPreview
            default: nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (index, window) in windows.enumerated() {
                Self.capture(window, to: "\(capturePath)-\(index).png")
            }
            NSApp.terminate(nil)
        }
    }

    /// Write one window's own contents to a PNG. Capturing its own windows
    /// needs no screen recording permission.
    private static func capture(_ window: NSWindow, to path: String) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            FileHandle.standardError.write(Data("Could not capture window \(window.windowNumber)\n".utf8))
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Every capsule state, each in its own window, stacked down the screen.
    private func capsules() {
        let failure = { (kind: FailureKind, headline: String) in Failure(kind: kind, headline: headline, detail: "detail") }
        let full = CapsuleGeometry.fullSize
        let scenes: [(String, CapsuleAppearance)] = [
            ("ready", appearance(.idle)),
            ("listening", appearance(.listening, bars: [0.5, 0.9, 0.7, 0.3])),
            ("loading", appearance(.processing, processing: "Loading models")),
            ("transcribing", appearance(.processing)),
            ("inserted", appearance(.done, settledFor: 10)),
            ("copied", appearance(.copied, settledFor: 10)),
            ("no speech", appearance(.noSpeech)),
            ("not understood", appearance(.notUnderstood)),
            ("blocked", appearance(.error, failure: failure(.blocked, "Hotkey unavailable"))),
            ("input unavailable", appearance(.error, failure: failure(.inputUnavailable, "Microphone unavailable"))),
            ("dropped", appearance(.error, failure: failure(.dropped, "Recording filled the buffer"))),
            ("unread", appearance(.idle, unread: true)),
            ("minimal bead", appearance(.idle, minimal: true, painted: CapsuleGeometry.beadSize)),
            ("minimal bead unread", appearance(.idle, minimal: true, unread: true, painted: CapsuleGeometry.beadSize)),
            ("minimal listening", appearance(.listening, bars: [0.5, 0.9, 0.7, 0.3], minimal: true, painted: CapsuleGeometry.activeSize)),
            ("minimal full", appearance(.processing, minimal: true, painted: full)),
        ]
        guard let screen = NSScreen.main else { return }
        var top = screen.visibleFrame.maxY - 20
        var left = screen.visibleFrame.minX + 40
        for (_, scene) in scenes {
            let size = CapsuleGeometry.windowSize(minimal: scene.minimal)
            if top - size.height < screen.visibleFrame.minY + 20 {
                top = screen.visibleFrame.maxY - 20
                left += 360
            }
            let panel = FloatingPanel(size: size)
            let view = CapsuleView()
            view.look = scene
            panel.contentView = view
            panel.setFrameOrigin(CGPoint(x: left + (offscreen ? Self.offscreenX : 0), y: top - size.height))
            panel.orderFrontRegardless()
            Self.retained.append(panel)
            top -= size.height + 12
        }
    }

    private func appearance(
        _ hud: HudState,
        processing: String = "Transcribing",
        failure: Failure? = nil,
        bars: [Float] = [0, 0, 0, 0],
        settledFor: Double? = nil,
        minimal: Bool = false,
        unread: Bool = false,
        painted: CGSize = CapsuleGeometry.fullSize
    ) -> CapsuleAppearance {
        CapsuleAppearance(
            hud: hud,
            failure: failure,
            unreadFailure: unread,
            tooltip: "Open console",
            label: CapsuleGeometry.label(for: hud, processing: processing),
            settledFor: settledFor,
            voiceBars: bars,
            minimal: minimal,
            painted: painted
        )
    }

    /// The three kinds of toast, each placed from a capsule down the screen.
    private func toasts() {
        guard let screen = NSScreen.main else { return }
        let now = Monotonic.now() - 1
        let kinds: [Toast] = [
            Toast(kind: .copied, headline: "No text field focused", body: "Let's move the Thursday review to Friday morning, and ask Priya to bring the revised numbers.", footer: "Copied to clipboard · ⌘V", raisedAt: now),
            Toast(kind: .failed, headline: "Microphone disconnected", body: "So the first thing I want to cover today is the migration plan, because the timeline has shifted twice now and I think we need to agree on a date that we can actually hold to, and then work backwards from there.", footer: "Copied to clipboard · ⌘V · details in the console", raisedAt: now),
            Toast(kind: .quiet, headline: "PrivacyFlow can barely hear you", body: "This dictation is too quiet to be transcribed. Move closer to the microphone, or speak up.", footer: "Still recording · it can still be saved", raisedAt: now),
        ]
        for (index, toast) in kinds.enumerated() {
            let controller = ToastWindowController()
            let centre = Centre(x: screen.frame.minX + 260 + Double(index) * 380 + (offscreen ? Self.offscreenX : 0), y: 400)
            _ = controller.show(toast, capsule: centre)
            Self.retained.append(controller)
        }
    }

    /// The console tabs or setup, with a real controller over scratch data.
    private func windows() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("privacyflow-preview-\(ProcessInfo.processInfo.processIdentifier)")
        guard let manifestURL = Bundle.main.url(forResource: "models", withExtension: "json"),
              let manifest = try? ModelManifest.load(from: manifestURL) else {
            fatalError("models.json is missing or invalid")
        }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Input Monitoring as the setup scenes need it: setup-refused has it
        // refused throughout, and the setup-granted scenes have it refused
        // when the controller was made, as at launch, and allowed since.
        let refused = scene == "setup-refused"
        let grantedSinceLaunch = scene.hasPrefix("setup-granted")
        if refused || grantedSinceLaunch {
            Permissions.previewInputMonitoring = false
        }
        let controller = AppController(dataDirectory: scratch, cacheDirectory: scratch.appendingPathComponent("cache"), manifest: manifest)
        if grantedSinceLaunch {
            Permissions.previewInputMonitoring = true
        }
        Self.retained.append(controller)
        fillHistory(controller)

        if scene.hasPrefix("setup") {
            if scene == "setup-downloading" || scene == "setup-granted-downloading" {
                controller.installer.previewDownloading(completed: 1_130_000_000, total: 2_400_000_000, model: "Whisper large-v3-turbo")
            } else if scene == "setup-failed" {
                controller.installer.previewFailure("This build of PrivacyFlow does not say where to download weights.safetensors of Whisper large-v3-turbo from, so it cannot be installed. The model list has no address for it yet.")
            }
            let window = HostedWindowController(title: "PrivacyFlow Setup", size: CGSize(width: 580, height: 610), minimumSize: nil, content: OnboardingView(controller: controller, installer: controller.installer, close: {}))
            present(window)
            Self.retained.append(window)
            return
        }
        switch scene {
        case "settings-key-recording":
            ShortcutRecorder.previewState = .recording
        case "settings-key-refused":
            ShortcutRecorder.previewState = .refused(Shortcut(keyCode: 0, modifiers: []).assessmentReason)
        case "settings-key-warned":
            controller.setShortcut(Shortcut(modifier: .function))
        case "settings-key-combo":
            controller.setShortcut(Shortcut(keyCode: 96, modifiers: [.leftControl, .leftOption]))
        default:
            break
        }
        let tab: ConsoleTab = scene.hasPrefix("settings") || scene == "console-settings" ? .settings : scene == "console-status" ? .status : .activity
        let window = HostedWindowController(
            title: "PrivacyFlow",
            size: CGSize(width: 640, height: 520),
            minimumSize: CGSize(width: 520, height: 400),
            content: ConsoleView(controller: controller, installer: controller.installer, initialTab: tab, openSetup: {})
        )
        present(window)
        Self.retained.append(window)
    }

    private func fillHistory(_ controller: AppController) {
        var state = controller.state
        state.transcript = "the quarterly numbers look fine but I want to double check the churn figure before we send it"
        state.output = "The quarterly numbers look fine, but I want to double-check the churn figure before we send it."
        state.route = .lightCleanup
        state.timings.audioMs = 4210
        state.timings.asrMs = 512
        state.timings.routerMs = 41
        state.timings.processingMs = 388
        state.recordInserted(.pasted)
        state.transcript = "so the first thing I want to cover today is the migration plan"
        state.output = ""
        state.route = nil
        state.recordFailure(.dropped("Microphone disconnected", failureDetail(CaptureEnd.deviceLost.explanation, preserved: .processed)), preserved: .processed)
        state.recordNotUnderstood(note: "Heard 2.1 s and could not decode it (average log probability -1.42, floor -1.0). Nothing was inserted.")
        state.transcript = "remind me to call the dentist"
        state.output = "remind me to call the dentist"
        state.route = .passThrough
        state.recordInserted(.copiedNoField)
        state.worker = .ready(WorkerReady(loadMilliseconds: 5321, lockedBytes: 2_400_000_000))
        controller.state = state
    }
}

extension Shortcut {
    /// The reason a refused shortcut gives, for the refused-row preview.
    var assessmentReason: String {
        if case .refused(let reason) = assessment { return reason }
        return ""
    }
}

extension ModelInstaller {
    func previewDownloading(completed: Int64, total: Int64, model: String) {
        showPreview(phase: .downloading, completed: completed, total: total, model: model)
    }

    func previewFailure(_ reason: String) {
        showPreview(phase: .failed(reason), completed: 0, total: 0, model: nil)
    }
}
#endif

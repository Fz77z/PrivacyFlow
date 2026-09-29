import AppKit
import PrivacyFlowCore

/// Starts PrivacyFlow: one instance, its fonts and model list, then the
/// controller and every window around it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lock: InstanceLock?
    private var controller: AppController?
    private var capsule: CapsuleWindowController?
    private var statusItem: StatusItemController?
    private var console: HostedWindowController?
    private var setup: HostedWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let preview = Preview(arguments: CommandLine.arguments) {
            preview.run()
            return
        }
        #endif
        do {
            try launch()
        } catch {
            refuseToStart("\(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stopWorker()
    }

    private func launch() throws {
        let fileManager = FileManager.default
        let dataDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PrivacyFlow", isDirectory: true)
        let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("io.github.fz77z.privacyflow", isDirectory: true)
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        lock = try InstanceLock(at: dataDirectory.appendingPathComponent("privacyflow.lock"))
        try Theme.registerFonts()
        guard let manifestURL = Bundle.main.url(forResource: "models", withExtension: "json") else {
            throw LaunchProblem("models.json is missing from the app bundle")
        }
        let manifest = try ModelManifest.load(from: manifestURL)

        let controller = AppController(dataDirectory: dataDirectory, cacheDirectory: cacheDirectory, manifest: manifest)
        self.controller = controller
        capsule = CapsuleWindowController(controller: controller, toast: ToastWindowController())
        statusItem = StatusItemController(controller: controller)

        let console = HostedWindowController(
            title: "PrivacyFlow",
            size: CGSize(width: 640, height: 520),
            minimumSize: CGSize(width: 520, height: 400),
            content: ConsoleView(controller: controller, installer: controller.installer, openSetup: { [weak self] in self?.setup?.show() })
        )
        console.onClose = { [weak controller] in controller?.consoleClosed() }
        controller.onOpenConsole = { [weak console] in console?.show() }
        controller.onCloseConsole = { [weak console] in console?.close() }
        self.console = console

        let setup = HostedWindowController(
            title: "PrivacyFlow Setup",
            size: CGSize(width: 580, height: 610),
            minimumSize: nil,
            content: OnboardingView(controller: controller, installer: controller.installer, close: { [weak self] in self?.setup?.close() })
        )
        self.setup = setup
        if !controller.installer.isInstalled || Permissions.microphone != .granted || !Permissions.accessibility || !Permissions.inputMonitoring {
            setup.show()
        }
    }

    /// Say why PrivacyFlow cannot run, then quit. A floating app that exits
    /// without a word looks like it never launched.
    private func refuseToStart(_ reason: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "PrivacyFlow could not start"
        alert.informativeText = reason
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// An advisory lock held for the life of the process. A second instance would
/// install a second event tap and race the first to paste into the focused
/// app. The system releases it when the process exits, however it exits.
final class InstanceLock {
    private let descriptor: Int32

    init(at url: URL) throws {
        descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw LaunchProblem("Could not open the lock file at \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno == EWOULDBLOCK
                ? "PrivacyFlow is already running. Look for it in the menu bar."
                : "Could not lock \(url.path): \(String(cString: strerror(errno)))"
            close(descriptor)
            throw LaunchProblem(reason)
        }
    }
}

// A worker that exits while a request is being written must surface as a
// failed write, not kill the app with SIGPIPE.
signal(SIGPIPE, SIG_IGN)
MainActor.assumeIsolated {
    let application = NSApplication.shared
    // Stated here as well as in Info.plist, so a binary run outside its bundle
    // does not take a Dock icon either.
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}

import Foundation
import PrivacyFlowCore

/// Downloads and verifies the models on first launch, and says how it is going.
///
/// Every download resumes from a `.partial` file with an HTTP range request, so
/// a retry, or a relaunch, continues rather than starting over. A model counts
/// as installed only once every file has passed its SHA-256 check, and the
/// worker is not started until every model has.
@MainActor
final class ModelInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Progress through the current phase, in bytes.
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    /// The model being worked on, by its title.
    @Published private(set) var currentModel: String?

    let manifest: ModelManifest
    let store: ModelStore
    /// Called on the main thread when every model is installed.
    var onInstalled: (() -> Void)?

    private let queue = DispatchQueue(label: "PrivacyFlow model installer", qos: .userInitiated)
    private var running = false

    init(manifest: ModelManifest, store: ModelStore) {
        self.manifest = manifest
        self.store = store
        if manifest.models.allSatisfy(store.isInstalled) {
            phase = .installed
            store.clearInstallRequest()
        }
    }

    var isInstalled: Bool { phase == .installed }

    /// Whether models are being downloaded or verified, from the moment that
    /// is asked for rather than from its first progress report.
    var isInstalling: Bool { running }

    /// Continue an install that was downloading when the app quit: the user
    /// already asked for it. One that ended in failure is not retried here; it
    /// waits for the user. Called once at launch, after `onInstalled` is set.
    func resumeIfRequested() {
        guard !isInstalled, store.installRequested else { return }
        install()
    }

    /// Download whatever is missing, then verify everything not yet verified.
    func install() {
        guard !running, phase != .installed else { return }
        let pending = manifest.models.filter { !store.isInstalled($0) }
        let job = ModelDownloader(store: store, models: pending)
        do {
            try job.checkCanDownload()
        } catch {
            phase = .failed("\(error)")
            return
        }
        running = true
        job.report = { [weak self] event in
            DispatchQueue.main.async { self?.apply(event) }
        }
        queue.async {
            job.run()
        }
    }

    private func apply(_ event: ModelDownloader.Event) {
        switch event {
        case .phase(let stage, let total, let completed):
            phase = stage == .downloading ? .downloading : .verifying
            totalBytes = total
            completedBytes = completed
        case .model(let title):
            currentModel = title
        case .bytes(let count):
            completedBytes += count
        case .finished(let problem):
            running = false
            currentModel = nil
            if let problem {
                phase = .failed(problem)
            } else {
                phase = .installed
                onInstalled?()
            }
        }
    }

    #if DEBUG
    /// Put the installer in a fixed state for a preview screenshot.
    func showPreview(phase: Phase, completed: Int64, total: Int64, model: String?) {
        self.phase = phase
        running = phase == .downloading || phase == .verifying
        completedBytes = completed
        totalBytes = total
        currentModel = model
    }
    #endif
}

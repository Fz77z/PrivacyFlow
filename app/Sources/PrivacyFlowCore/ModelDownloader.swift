import Foundation

/// One run of downloading and verifying models, on a thread of the caller's choosing.
///
/// Three passes. Files already here at their pinned size are hashed first, and
/// any that do not match, left by a different pin or damaged, are deleted and
/// downloaded again rather than reported as a failed check. Then the missing
/// files are downloaded, resuming only partials pinned to the same hash. Last,
/// what was just downloaded is hashed, and a mismatch there is a real failure.
public final class ModelDownloader: @unchecked Sendable {
    /// Which pass the downloader is in.
    public enum Stage: Sendable {
        case downloading
        case verifying
    }

    public enum Event: Sendable {
        case phase(Stage, total: Int64, completed: Int64)
        case model(String)
        case bytes(Int64)
        /// Nil when everything installed, otherwise why it stopped.
        case finished(String?)
    }

    let store: ModelStore
    let models: [ModelManifest.Model]
    private let configuration: URLSessionConfiguration
    /// Told, on the downloader's thread, how it is going.
    public var report: (Event) -> Void = { _ in }

    /// `configuration` is for tests, which stub the network; the app uses the
    /// default, an ephemeral session that keeps nothing on disk.
    public init(store: ModelStore, models: [ModelManifest.Model], configuration: URLSessionConfiguration = .ephemeral) {
        self.store = store
        self.models = models
        self.configuration = configuration
    }

    /// Refuse up front, naming the file, rather than half-downloading: a file
    /// with no address, or a disk too full to hold what is left.
    public func checkCanDownload() throws {
        var needed: Int64 = 0
        for model in models {
            for file in model.files where !isFinishedSize(file, in: model) {
                guard file.url != nil else {
                    throw ManifestProblem("This build of PrivacyFlow does not say where to download \(file.path) of \(model.title) from, so it cannot be installed. The model list has no address for it yet.")
                }
                needed += file.bytes - store.resumableBytes(of: file, in: model)
            }
        }
        let values = try? store.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw ManifestProblem("The models need \(formatBytes(needed)) more space, and this Mac has \(formatBytes(available)) free.")
        }
    }

    /// Run to completion on the calling thread, which it blocks.
    ///
    /// The store's install-requested marker is present exactly while this
    /// runs, so finding it at launch means an install was interrupted by
    /// quitting and may resume by itself. A run that ends, in success or in
    /// failure, removes it: a failure waits for the user to try again rather
    /// than downloading again at every launch.
    public func run() {
        defer { store.clearInstallRequest() }
        do {
            try store.requestInstall()
            let alreadyHere = try checkFilesAlreadyHere()
            let downloaded = try downloadMissing(except: alreadyHere)
            try verify(downloaded)
            for model in models {
                try store.recordVerified(model)
            }
            report(.finished(nil))
        } catch {
            report(.finished("\(error)"))
        }
    }

    /// Hash the files already present at their pinned size, keeping those that
    /// match and deleting those that do not. Returns the ones kept.
    private func checkFilesAlreadyHere() throws -> Set<String> {
        let present = models.flatMap { model in model.files.filter { isFinishedSize($0, in: model) }.map { (model, $0) } }
        report(.phase(.verifying, total: present.reduce(Int64(0)) { $0 + $1.1.bytes }, completed: 0))
        var kept = Set<String>()
        for (model, file) in present {
            report(.model(model.title))
            if try store.matches(file, in: model, progress: throttled()) {
                kept.insert(key(file, in: model))
            } else {
                try? FileManager.default.removeItem(at: store.location(of: file, in: model))
            }
        }
        return kept
    }

    /// Download every file not already confirmed. Returns what was downloaded.
    private func downloadMissing(except kept: Set<String>) throws -> [(ModelManifest.Model, ModelManifest.File)] {
        let missing = models.flatMap { model in model.files.filter { !kept.contains(key($0, in: model)) }.map { (model, $0) } }
        var total: Int64 = 0
        var resumable: Int64 = 0
        for (model, file) in missing {
            // A finished file that is not confirmed has the wrong size or the
            // wrong bytes; it cannot be resumed onto.
            try? FileManager.default.removeItem(at: store.location(of: file, in: model))
            total += file.bytes
            resumable += store.resumableBytes(of: file, in: model)
        }
        report(.phase(.downloading, total: total, completed: resumable))
        for (model, file) in missing {
            report(.model(model.title))
            guard let url = file.url else {
                throw ManifestProblem("No download address for \(file.path) of \(model.title)")
            }
            try FileManager.default.createDirectory(at: store.directory(of: model), withIntermediateDirectories: true)
            let offset = store.resumableBytes(of: file, in: model)
            try store.pinPartial(file, in: model)
            try FileDownload(
                configuration: configuration,
                url: url,
                destination: store.partialLocation(of: file, in: model),
                resumeFrom: offset,
                expectedBytes: file.bytes,
                progress: { [report] in report(.bytes($0)) }
            ).run()
            try store.finishPartial(file, in: model)
        }
        return missing
    }

    /// Hash what was just downloaded. A mismatch here is a real failure: the
    /// bytes arrived whole and are not the pinned ones.
    private func verify(_ downloaded: [(ModelManifest.Model, ModelManifest.File)]) throws {
        report(.phase(.verifying, total: downloaded.reduce(Int64(0)) { $0 + $1.1.bytes }, completed: 0))
        for (model, file) in downloaded {
            report(.model(model.title))
            guard try store.matches(file, in: model, progress: throttled()) else {
                try? FileManager.default.removeItem(at: store.location(of: file, in: model))
                throw ManifestProblem("\(file.path) of \(model.title) failed its SHA-256 check after downloading, so it was deleted. Try again; if it fails again, the download source does not match this version of PrivacyFlow.")
            }
        }
    }

    /// A progress callback that reports about ten times a second.
    private func throttled() -> (Int64) -> Void {
        var unreported: Int64 = 0
        var reportedAt = Date.distantPast
        return { [report] bytes in
            unreported += bytes
            guard Date().timeIntervalSince(reportedAt) > 0.1 else { return }
            report(.bytes(unreported))
            unreported = 0
            reportedAt = Date()
        }
    }

    private func isFinishedSize(_ file: ModelManifest.File, in model: ModelManifest.Model) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.location(of: file, in: model).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == file.bytes
    }

    private func key(_ file: ModelManifest.File, in model: ModelManifest.Model) -> String {
        model.directory + "/" + file.path
    }
}

/// One file downloaded into its partial file, resuming from `resumeFrom`
/// bytes. Blocks its thread until the download ends.
///
/// A server that answers a range request with a different range than was
/// asked for would splice the wrong bytes onto the partial, so the partial is
/// then discarded and the file downloaded from the start, at once rather than
/// after the whole file has arrived and failed its check.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let url: URL
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: (Int64) -> Void
    private let done = DispatchSemaphore(value: 0)
    private var resumeFrom: Int64
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    /// Set when the server's range did not match, to start over from zero.
    private var restartFromZero = false
    private var unreported: Int64 = 0
    private var reportedAt = Date.distantPast

    init(configuration: URLSessionConfiguration, url: URL, destination: URL, resumeFrom: Int64, expectedBytes: Int64, progress: @escaping (Int64) -> Void) {
        self.configuration = configuration
        self.url = url
        self.destination = destination
        self.resumeFrom = resumeFrom
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func run() throws {
        try request()
        if restartFromZero {
            // Once only: a request without a range cannot be answered with the
            // wrong range, so there is nothing to loop on.
            restartFromZero = false
            resumeFrom = 0
            try request()
        }
        guard written == expectedBytes else {
            throw ManifestProblem("\(url.lastPathComponent) arrived as \(written) bytes, and should be \(expectedBytes)")
        }
    }

    private func request() throws {
        if resumeFrom == 0 || !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            resumeFrom = 0
        }
        written = resumeFrom
        if written == expectedBytes { return }
        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session.dataTask(with: request).resume()
        done.wait()
        session.finishTasksAndInvalidate()
        if let failure {
            throw failure
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = ManifestProblem("\(url.host ?? "The server") did not answer over HTTP")
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206 where ModelStore.rangeStart(ofContentRange: http.value(forHTTPHeaderField: "Content-Range")) == resumeFrom:
                // Resuming: the server continues exactly where the partial ends.
                handle = try FileHandle(forWritingTo: destination)
                try handle?.truncate(atOffset: UInt64(resumeFrom))
                try handle?.seekToEnd()
            case 206:
                // The wrong range, or no range at all. Start over rather than
                // splice bytes from somewhere else onto the partial.
                progress(-written)
                restartFromZero = true
                completionHandler(.cancel)
                return
            case 200:
                // The server sent the whole file, so what was here is replaced
                // and its bytes come off the progress.
                handle = try FileHandle(forWritingTo: destination)
                try handle?.truncate(atOffset: 0)
                progress(-written)
                written = 0
            default:
                failure = ManifestProblem("\(url.host ?? "The server") answered HTTP \(http.statusCode) for \(url.lastPathComponent)")
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            // A server sending more than the file holds is not sending this file.
            guard written + Int64(data.count) <= expectedBytes else {
                throw ManifestProblem("\(url.host ?? "The server") sent more of \(url.lastPathComponent) than its \(expectedBytes) bytes")
            }
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            unreported += Int64(data.count)
            // Batched to about ten updates a second: the network delivers far
            // smaller pieces than anyone can see move.
            if Date().timeIntervalSince(reportedAt) > 0.1 {
                progress(unreported)
                unreported = 0
                reportedAt = Date()
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        progress(unreported)
        unreported = 0
        if failure == nil, !restartFromZero, let error {
            failure = ManifestProblem("The download of \(url.lastPathComponent) stopped: \(error.localizedDescription)")
        }
        done.signal()
    }
}

import CryptoKit
import Foundation

/// The models PrivacyFlow downloads, as listed in `models.json`.
///
/// Each model is a directory of files under the models directory, and every
/// file is pinned by size and SHA-256. A URL may be absent while the hosting is
/// undecided; the app then refuses to download that file by name rather than
/// guessing where it lives.
public struct ModelManifest: Codable, Equatable, Sendable {
    public var schema: Int
    public var models: [Model]

    public struct Model: Codable, Equatable, Sendable, Identifiable {
        /// The directory the model lives in, and the name the worker knows it by.
        public var directory: String
        /// What the model does, for the interface.
        public var role: String
        /// How the model is named to the user, with any attribution its licence
        /// requires, exactly as it must be shown.
        public var title: String
        public var files: [File]

        public var id: String { directory }

        public var totalBytes: Int64 {
            files.reduce(0) { $0 + $1.bytes }
        }
    }

    public struct File: Codable, Equatable, Sendable {
        /// Relative to the model's directory.
        public var path: String
        public var url: URL?
        public var bytes: Int64
        public var sha256: String
    }

    public static let supportedSchema = 1

    /// Read and check a manifest. A manifest this app cannot trust is refused
    /// as a whole, because a partly understood one could install the wrong thing.
    public static func load(from url: URL) throws -> ModelManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestProblem("PrivacyFlow could not read its model list at \(url.path): \(error.localizedDescription)")
        }
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ManifestProblem("PrivacyFlow's model list at \(url.path) is malformed: \(error)")
        }
        try manifest.validate()
        return manifest
    }

    /// The structural rules a manifest must meet before any file is touched.
    public func validate() throws {
        guard schema == Self.supportedSchema else {
            throw ManifestProblem("The model list uses schema \(schema), and this version of PrivacyFlow reads schema \(Self.supportedSchema)")
        }
        guard !models.isEmpty else {
            throw ManifestProblem("The model list names no models")
        }
        var directories = Set<String>()
        for model in models {
            guard Self.isSafeComponent(model.directory) else {
                throw ManifestProblem("The model directory \"\(model.directory)\" is not a plain folder name")
            }
            guard directories.insert(model.directory).inserted else {
                throw ManifestProblem("The model directory \"\(model.directory)\" is listed twice")
            }
            guard !model.files.isEmpty else {
                throw ManifestProblem("The model \"\(model.directory)\" lists no files")
            }
            var paths = Set<String>()
            for file in model.files {
                let components = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !components.isEmpty, components.allSatisfy(Self.isSafeComponent) else {
                    throw ManifestProblem("The file \"\(file.path)\" in \"\(model.directory)\" does not stay inside its model directory")
                }
                guard paths.insert(file.path).inserted else {
                    throw ManifestProblem("The file \"\(file.path)\" is listed twice in \"\(model.directory)\"")
                }
                guard file.bytes > 0 else {
                    throw ManifestProblem("The file \"\(file.path)\" in \"\(model.directory)\" has no size")
                }
                guard file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                    throw ManifestProblem("The file \"\(file.path)\" in \"\(model.directory)\" has no valid SHA-256")
                }
                if let url = file.url, url.scheme != "https" {
                    throw ManifestProblem("The file \"\(file.path)\" in \"\(model.directory)\" is not downloaded over HTTPS")
                }
            }
        }
    }

    public var totalBytes: Int64 {
        models.reduce(0) { $0 + $1.totalBytes }
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.hasPrefix(".")
    }
}

/// A byte count in decimal units, as Finder shows sizes, so the numbers here
/// match what the user sees in Finder and in About This Mac.
public func formatBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// A model list that cannot be used.
public struct ManifestProblem: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Where the models live on disk, and whether each one is installed.
///
/// A model counts as installed once every file has been checked against its
/// SHA-256 and a marker recording exactly what was checked has been written.
/// Launch then compares the marker and the file sizes, which is cheap, instead
/// of re-hashing gigabytes on every start.
public struct ModelStore: Sendable {
    public static let markerName = ".verified"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(of model: ModelManifest.Model) -> URL {
        root.appendingPathComponent(model.directory, isDirectory: true)
    }

    public func location(of file: ModelManifest.File, in model: ModelManifest.Model) -> URL {
        directory(of: model).appendingPathComponent(file.path)
    }

    /// Whether this model was verified against exactly this manifest entry,
    /// and its files are all still there at their pinned sizes.
    public func isInstalled(_ model: ModelManifest.Model) -> Bool {
        let marker = directory(of: model).appendingPathComponent(Self.markerName)
        guard let recorded = try? String(contentsOf: marker, encoding: .utf8),
              recorded == Self.fingerprint(of: model) else {
            return false
        }
        return model.files.allSatisfy { size(of: location(of: $0, in: model)) == $0.bytes }
    }

    /// Hash every file of a model and, if all match, record the marker.
    ///
    /// Throws naming the first file that is missing or does not match. A file
    /// that does not match is deleted, because keeping it would only make the
    /// next attempt resume onto bytes that are already wrong.
    public func verify(_ model: ModelManifest.Model, progress: (Int64) -> Void = { _ in }) throws {
        for file in model.files {
            let location = location(of: file, in: model)
            guard let actualSize = size(of: location) else {
                throw ManifestProblem("\(file.path) of \(model.title) is missing")
            }
            guard actualSize == file.bytes else {
                throw ManifestProblem("\(file.path) of \(model.title) is \(actualSize) bytes, and should be \(file.bytes)")
            }
            guard try matches(file, in: model, progress: progress) else {
                try? FileManager.default.removeItem(at: location)
                throw ManifestProblem("\(file.path) of \(model.title) failed its SHA-256 check, so it was deleted")
            }
        }
        try recordVerified(model)
    }

    /// Whether a finished file is present at its pinned size and hash.
    public func matches(_ file: ModelManifest.File, in model: ModelManifest.Model, progress: (Int64) -> Void = { _ in }) throws -> Bool {
        let location = location(of: file, in: model)
        guard size(of: location) == file.bytes else { return false }
        return try Self.sha256(of: location, progress: progress) == file.sha256
    }

    /// Record that every file of a model has been checked against this entry.
    public func recordVerified(_ model: ModelManifest.Model) throws {
        let marker = directory(of: model).appendingPathComponent(Self.markerName)
        try Self.fingerprint(of: model).write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: Partial downloads

    /// Where a file is downloaded to before it is complete.
    public func partialLocation(of file: ModelManifest.File, in model: ModelManifest.Model) -> URL {
        let final = location(of: file, in: model)
        return final.deletingLastPathComponent().appendingPathComponent(final.lastPathComponent + ".partial")
    }

    /// Beside each partial download, the SHA-256 it is a download of, so a
    /// partial left by a different pin is never resumed onto.
    public func pinLocation(of file: ModelManifest.File, in model: ModelManifest.Model) -> URL {
        let partial = partialLocation(of: file, in: model)
        return partial.deletingLastPathComponent().appendingPathComponent(partial.lastPathComponent + ".pin")
    }

    /// Record which pin a partial download belongs to, before its first byte.
    public func pinPartial(_ file: ModelManifest.File, in model: ModelManifest.Model) throws {
        try file.sha256.write(to: pinLocation(of: file, in: model), atomically: true, encoding: .utf8)
    }

    /// How many bytes of a partial download can be resumed from, discarding a
    /// partial that cannot: one pinned to a different hash, one with no pin,
    /// or one larger than the file it is meant to become.
    public func resumableBytes(of file: ModelManifest.File, in model: ModelManifest.Model) -> Int64 {
        let partial = partialLocation(of: file, in: model)
        let pin = pinLocation(of: file, in: model)
        guard let bytes = size(of: partial) else {
            try? FileManager.default.removeItem(at: pin)
            return 0
        }
        let pinned = try? String(contentsOf: pin, encoding: .utf8)
        guard pinned == file.sha256, bytes <= file.bytes else {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: pin)
            return 0
        }
        return bytes
    }

    /// Put a completed partial download in its final place.
    public func finishPartial(_ file: ModelManifest.File, in model: ModelManifest.Model) throws {
        let final = location(of: file, in: model)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partialLocation(of: file, in: model), to: final)
        try? FileManager.default.removeItem(at: pinLocation(of: file, in: model))
    }

    // MARK: Consent to download

    /// Present while the user has asked for the models and they are not all
    /// installed yet, so an install interrupted by quitting resumes at launch.
    private var installRequestMarker: URL {
        root.appendingPathComponent(".install-requested")
    }

    public var installRequested: Bool {
        FileManager.default.fileExists(atPath: installRequestMarker.path)
    }

    public func requestInstall() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: installRequestMarker)
    }

    public func clearInstallRequest() {
        try? FileManager.default.removeItem(at: installRequestMarker)
    }

    /// The first byte a 206 response covers, from its Content-Range header,
    /// such as "bytes 1000-1999/2000". Nil when the header is missing or not
    /// a byte range.
    public static func rangeStart(ofContentRange header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let range = header.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[range.startIndex..<dash])
    }

    /// A digest of everything the marker vouches for. A manifest that pins a
    /// different file, size or hash produces a different fingerprint, so a
    /// model updated by a new app version is verified again.
    public static func fingerprint(of model: ModelManifest.Model) -> String {
        let lines = model.files
            .sorted { $0.path < $1.path }
            .map { "\($0.path)\t\($0.bytes)\t\($0.sha256)\n" }
            .joined()
        return SHA256.hash(data: Data((model.directory + "\n" + lines).utf8)).hexString
    }

    /// Stream a file through SHA-256 without holding it in memory.
    public static func sha256(of url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            progress(Int64(chunk.count))
        }
        return hasher.finalize().hexString
    }

    private func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

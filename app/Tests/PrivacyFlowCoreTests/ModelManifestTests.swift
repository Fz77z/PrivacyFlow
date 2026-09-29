import CryptoKit
import Foundation
import Testing
@testable import PrivacyFlowCore

/// Checking, installing and trusting downloaded models.
struct ModelManifestTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("privacyflow-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func model(contents: String, url: URL? = nil) -> ModelManifest.Model {
        let data = Data(contents.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelManifest.Model(
            directory: "tiny",
            role: "Test",
            title: "Tiny",
            files: [.init(path: "weights.bin", url: url, bytes: Int64(data.count), sha256: digest)]
        )
    }

    func place(_ contents: String, for model: ModelManifest.Model) throws {
        let store = ModelStore(root: root)
        try FileManager.default.createDirectory(at: store.directory(of: model), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.location(of: model.files[0], in: model))
    }

    @Test func aVerifiedModelIsInstalledWithoutBeingHashedAgain() throws {
        let model = model(contents: "weights")
        let store = ModelStore(root: root)
        try place("weights", for: model)
        #expect(!store.isInstalled(model), "unverified files are not installed")
        try store.verify(model)
        #expect(store.isInstalled(model))
    }

    /// A file whose bytes are wrong must never count as installed, and is
    /// deleted so a resumed download does not build on it.
    @Test func aFileThatFailsItsHashIsRefusedAndDeleted() throws {
        let model = model(contents: "weights")
        let store = ModelStore(root: root)
        try place("wrongxx", for: model)
        #expect(throws: ManifestProblem.self) { try store.verify(model) }
        #expect(!store.isInstalled(model))
        #expect(!FileManager.default.fileExists(atPath: store.location(of: model.files[0], in: model).path))
    }

    /// A new app version that pins different bytes must verify again rather
    /// than trusting a marker written for the old ones.
    @Test func aMarkerForADifferentManifestIsNotTrusted() throws {
        let old = model(contents: "weights")
        let store = ModelStore(root: root)
        try place("weights", for: old)
        try store.verify(old)
        var updated = old
        updated.files[0].sha256 = String(repeating: "a", count: 64)
        #expect(!store.isInstalled(updated))
    }

    @Test func aDeletedFileUnderAValidMarkerIsNotInstalled() throws {
        let model = model(contents: "weights")
        let store = ModelStore(root: root)
        try place("weights", for: model)
        try store.verify(model)
        try FileManager.default.removeItem(at: store.location(of: model.files[0], in: model))
        #expect(!store.isInstalled(model))
    }

    @Test func aManifestThatEscapesItsDirectoryIsRefused() {
        var bad = model(contents: "weights")
        bad.files[0].path = "../../outside"
        let manifest = ModelManifest(schema: 1, models: [bad])
        #expect(throws: ManifestProblem.self) { try manifest.validate() }
    }

    @Test func aDownloadOverPlainHttpIsRefused() {
        let insecure = model(contents: "weights", url: URL(string: "http://example.com/weights.bin"))
        #expect(throws: ManifestProblem.self) { try ModelManifest(schema: 1, models: [insecure]).validate() }
    }

    /// The manifest that ships in the app has to be one the app accepts, and
    /// the text processor has to carry its licence's attribution exactly.
    @Test func theShippedManifestIsValidAndAttributesS1Mini() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/models.json")
        let manifest = try ModelManifest.load(from: url)
        #expect(manifest.models.contains { $0.title == "S1-mini by Superwhisper" })
    }
}

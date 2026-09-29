import CryptoKit
import Foundation
import Testing
@testable import PrivacyFlowCore

/// A server for the downloader to talk to, in place of the network. Each test
/// sets how it answers and reads back what was asked of it.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    nonisolated(unsafe) static var answer: (URLRequest) -> Answer = { _ in Answer(status: 500, body: Data()) }
    nonisolated(unsafe) static var ranges: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        let answer = Self.answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Downloading and checking the models. Serialized, because the stub server
/// is shared.
@Suite(.serialized)
struct ModelDownloaderTests {
    let contents = Data("abcdefghij".utf8)
    let root: URL
    let model: ModelManifest.Model
    let store: ModelStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("privacyflow-download-\(UUID().uuidString)")
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        model = ModelManifest.Model(
            directory: "tiny",
            role: "Test",
            title: "Tiny",
            files: [.init(path: "weights.bin", url: URL(string: "https://models.test/weights.bin"), bytes: 10, sha256: digest)]
        )
        store = ModelStore(root: root)
        try FileManager.default.createDirectory(at: store.directory(of: model), withIntermediateDirectories: true)
        StubServer.ranges = []
    }

    var file: ModelManifest.File { model.files[0] }

    /// Run a download against the stub and return how it finished.
    func install() -> String?? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let downloader = ModelDownloader(store: store, models: [model], configuration: configuration)
        var outcome: String??
        downloader.report = { event in
            if case .finished(let problem) = event { outcome = .some(problem) }
        }
        downloader.run()
        return outcome
    }

    /// The server answers a range request from the offset asked for, and the
    /// whole file otherwise.
    func honestServer() {
        let contents = contents
        StubServer.answer = { request in
            guard let range = request.value(forHTTPHeaderField: "Range"),
                  let start = Int(range.dropFirst("bytes=".count).dropLast()) else {
                return .init(status: 200, body: contents)
            }
            return .init(status: 206, headers: ["Content-Range": "bytes \(start)-9/10"], body: contents.subdata(in: start..<10))
        }
    }

    func leavePartial(_ text: String, pinnedTo pin: String) throws {
        try Data(text.utf8).write(to: store.partialLocation(of: file, in: model))
        try pin.write(to: store.pinLocation(of: file, in: model), atomically: true, encoding: .utf8)
    }

    func installedContents() throws -> Data {
        try Data(contentsOf: store.location(of: file, in: model))
    }

    @Test func aPartialPinnedToTheSameFileIsResumed() throws {
        honestServer()
        try leavePartial("abcd", pinnedTo: file.sha256)
        #expect(install() == .some(nil))
        #expect(StubServer.ranges == ["bytes=4-"])
        #expect(try installedContents() == contents)
        #expect(store.isInstalled(model))
    }

    /// A server answering a different range than asked would splice the wrong
    /// bytes on, so the partial is dropped and the file fetched from zero at
    /// once, rather than after it has all arrived and failed its check.
    @Test func aServerThatAnswersTheWrongRangeIsRestartedFromZeroAtOnce() throws {
        let contents = contents
        StubServer.answer = { request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                return .init(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: contents)
            }
            return .init(status: 200, body: contents)
        }
        try leavePartial("abcd", pinnedTo: file.sha256)
        #expect(install() == .some(nil))
        #expect(StubServer.ranges == ["bytes=4-", nil])
        #expect(try installedContents() == contents)
    }

    /// A partial left by a different pin, or with no pin, or larger than the
    /// file, holds bytes of some other file and is never resumed onto.
    @Test(arguments: [
        ("abcd", String(repeating: "0", count: 64)),
        ("abcdefghijklmnop", ""),
    ])
    func aPartialThatCannotBeTheFileIsDiscarded(partial: String, pin: String) throws {
        honestServer()
        try leavePartial(partial, pinnedTo: pin.isEmpty ? file.sha256 : pin)
        #expect(install() == .some(nil))
        #expect(StubServer.ranges == [nil])
        #expect(try installedContents() == contents)
    }

    /// A finished file of the right size that an older pin left behind is
    /// replaced quietly, not reported as a failed check the user has to retry.
    @Test func aFinishedFileFromAnotherPinIsReplacedNotReported() throws {
        honestServer()
        try Data("XXXXXXXXXX".utf8).write(to: store.location(of: file, in: model))
        #expect(install() == .some(nil))
        #expect(try installedContents() == contents)
    }

    /// Bytes that arrive whole and do not match the pin are a real failure,
    /// and are not kept.
    @Test func aDownloadThatDoesNotMatchItsPinFails() throws {
        StubServer.answer = { _ in .init(status: 200, body: Data("0123456789".utf8)) }
        let outcome = install()
        #expect(outcome??.contains("failed its SHA-256 check") == true)
        #expect(!FileManager.default.fileExists(atPath: store.location(of: file, in: model).path))
        #expect(!store.isInstalled(model))
    }

    /// The marker that makes an install resume at launch is present while a
    /// download runs, and gone once it ends, in failure as in success: a
    /// failed install must not download again at every launch.
    @Test func onlyAnInterruptedInstallIsLeftToResume() throws {
        let store = store
        var sawMarkerWhileRunning = false
        StubServer.answer = { _ in
            sawMarkerWhileRunning = store.installRequested
            return .init(status: 500, body: Data())
        }
        let outcome = install()
        #expect(outcome != .some(nil), "the server failed")
        #expect(sawMarkerWhileRunning, "quitting now would resume")
        #expect(!store.installRequested, "a failure waits for the user")

        honestServer()
        #expect(install() == .some(nil))
        #expect(!store.installRequested)
    }

    @Test func contentRangeStartsAreRead() {
        #expect(ModelStore.rangeStart(ofContentRange: "bytes 1000-1999/2000") == 1000)
        #expect(ModelStore.rangeStart(ofContentRange: "bytes */2000") == nil)
        #expect(ModelStore.rangeStart(ofContentRange: nil) == nil)
    }
}

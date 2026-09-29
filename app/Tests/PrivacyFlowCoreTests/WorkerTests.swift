import Foundation
import Testing
@testable import PrivacyFlowCore

/// A worker transport that records what was sent and answers from a queue the
/// test fills, so step-keeping and poisoning can be tested without Python.
private final class FakeTransport {
    let replies = ReplyQueue()
    var sent: [String] = []
    var stopped = false
    var writeFails = false

    lazy var client = WorkerClient(
        write: { [unowned self] data in
            if writeFails { throw CocoaError(.fileWriteUnknown) }
            sent.append(String(decoding: data, as: UTF8.self))
        },
        replies: replies,
        stop: { [unowned self] in stopped = true },
        diagnostics: { "Traceback: MemoryError" }
    )
}

struct WorkerProtocolTests {
    static let passThrough = #"{"transcript": "This was written using the dictation.", "route": "PASS_THROUGH", "output": "This was written using the dictation.", "asr_ms": 512.0, "router_ms": 40.1, "processing_ms": null}"#

    @Test func aPassThroughReplyInsertsTheRawTranscriptAndReportsNoProcessing() throws {
        guard case .transcribed(let result) = try WorkerProtocol.parseDictation(Self.passThrough) else {
            Issue.record("a reply carrying a transcript is not silence")
            return
        }
        #expect(result.route == .passThrough)
        #expect(result.output == result.transcript)
        #expect(result.processingMs == nil)
    }

    /// COMPLEX used to be refused; it is now an ordinary route with a rewrite.
    @Test func aComplexReplyIsAnOrdinaryRewrite() throws {
        let line = #"{"transcript": "um so like", "route": "COMPLEX", "output": "So.", "asr_ms": 1.0, "router_ms": 2.0, "processing_ms": 300.5}"#
        guard case .transcribed(let result) = try WorkerProtocol.parseDictation(line) else {
            Issue.record("COMPLEX must not be a failure")
            return
        }
        #expect(result.route == .complex)
        #expect(result.output == "So.")
        #expect(result.processingMs == 300.5)
    }

    /// Silence, an undecodable dictation and a failure must never collapse into
    /// one another: each tells the user something different about their words.
    @Test func theThreeNonTranscriptAnswersStayDistinct() throws {
        #expect(try WorkerProtocol.parseDictation(#"{"no_speech": true}"#) == .noSpeech)
        #expect(try WorkerProtocol.parseDictation(#"{"unintelligible": true, "audio_seconds": 2.1, "detail": "average log probability -1.42, floor -1.0"}"#)
            == .unintelligible(seconds: 2.1, detail: "average log probability -1.42, floor -1.0"))
        #expect(try WorkerProtocol.parseDictation(#"{"no_speech": true, "error": "worker died"}"#)
            == .failed(message: "worker died", transcript: nil), "an error outranks everything else")
    }

    @Test func aFailureAfterRecognitionCarriesTheWordsForPreservation() throws {
        #expect(try WorkerProtocol.parseDictation(#"{"error": "S1-mini returned nothing", "transcript": "what I said"}"#)
            == .failed(message: "S1-mini returned nothing", transcript: "what I said"))
    }

    @Test func aReplyMissingAFieldSaysWhichOne() {
        #expect(throws: ProtocolViolation(description: "The worker's reply omitted the routing latency")) {
            try WorkerProtocol.parseDictation(#"{"transcript": "a", "route": "PASS_THROUGH", "output": "a", "asr_ms": 1.0}"#)
        }
    }

    @Test func aWorkerThatCouldNotLoadSaysWhy() {
        #expect(throws: ProtocolViolation(description: "The worker could not load its models: mlock failed")) {
            try WorkerProtocol.parseReady(#"{"ready": false, "error": "mlock failed"}"#)
        }
    }

    /// The bug this guards: a flat timeout mistook a long dictation on a slow
    /// machine for a wedged worker and poisoned it.
    @Test(arguments: [0.0, 1, 30, 300])
    func theDictationTimeoutAlwaysOutgrowsTheAudioItCovers(seconds: Double) {
        #expect(WorkerTimeouts.dictation(audioSeconds: seconds) > seconds * 2)
    }
}

struct WorkerClientTests {
    @Test func aWarmUpConsumesExactlyItsOwnAcknowledgement() throws {
        let transport = FakeTransport()
        transport.replies.push(#"{"prepared": true, "prepare_ms": 12.3}"#)
        transport.replies.push(WorkerProtocolTests.passThrough)

        try transport.client.prepare()
        let reply = try transport.client.transcribe(audioPath: "/tmp/a.wav", audioSeconds: 1)

        guard case .transcribed = reply else {
            Issue.record("the dictation received the warm-up's reply")
            return
        }
        #expect(transport.sent == ["{\"prepare\":true}\n", "{\"audio_path\":\"/tmp/a.wav\"}\n"])
        #expect(transport.client.fatal == nil)
    }

    /// Out of step, every later dictation would receive the wrong answer, so
    /// the worker is stopped, and the stray line is not repeated because it can
    /// carry what the user said.
    @Test func aWarmUpAnsweredOutOfStepPoisonsTheWorker() {
        let transport = FakeTransport()
        transport.replies.push(WorkerProtocolTests.passThrough)

        do {
            try transport.client.prepare()
            Issue.record("an out-of-step reply was accepted")
        } catch {
            #expect(!"\(error)".contains("written using the dictation"))
        }
        #expect(transport.stopped)
        #expect(transport.client.fatal != nil)
    }

    @Test func aFailedWarmUpLeavesTheWorkerHealthy() {
        let transport = FakeTransport()
        transport.replies.push(#"{"prepared": false, "error": "out of memory"}"#)
        #expect(throws: WorkerFailure("The worker could not prepare the router: out of memory")) {
            try transport.client.prepare()
        }
        #expect(!transport.stopped)
        #expect(transport.client.fatal == nil)
    }

    /// A wedged worker fails the dictation, and every later one fails at once
    /// rather than hanging again.
    @Test func aSilentWorkerIsPoisonedAndLaterRequestsFailImmediately() {
        let transport = FakeTransport()
        #expect(throws: WorkerFailure.self) {
            _ = try transport.client.awaitReady(timeout: 0.05)
        }
        #expect(transport.stopped)
        let started = Date()
        do {
            _ = try transport.client.transcribe(audioPath: "/tmp/a.wav", audioSeconds: 3)
            Issue.record("a poisoned worker accepted a dictation")
        } catch {
            #expect("\(error)" == transport.client.fatal, "later requests carry the reason it was poisoned")
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(transport.sent.isEmpty, "nothing is written to a poisoned worker")
    }

    /// A bundled app has no terminal, so the worker's last words travel with the failure.
    @Test func aWorkerThatExitsSaysWhatItLastPrinted() {
        let transport = FakeTransport()
        transport.replies.close()
        do {
            _ = try transport.client.awaitReady()
            Issue.record("a closed pipe was treated as ready")
        } catch {
            #expect("\(error)".contains("The worker exited. It last said: Traceback: MemoryError"))
        }
    }

    /// A per-utterance failure is not a broken worker.
    @Test func anErrorReplyDoesNotPoisonTheWorker() throws {
        let transport = FakeTransport()
        transport.replies.push(#"{"error": "the file is not 16 kHz"}"#)
        transport.replies.push(WorkerProtocolTests.passThrough)
        #expect(try transport.client.transcribe(audioPath: "/tmp/a.wav", audioSeconds: 1) == .failed(message: "the file is not 16 kHz", transcript: nil))
        guard case .transcribed = try transport.client.transcribe(audioPath: "/tmp/b.wav", audioSeconds: 1) else {
            Issue.record("the worker was poisoned by an ordinary failure")
            return
        }
    }

    /// A stray line read as a dictation's reply leaves the real reply still to
    /// come, where it would answer the next dictation with this one's words.
    @Test func aDictationAnsweredWithAStrayLinePoisonsTheWorker() {
        let transport = FakeTransport()
        transport.replies.push("Loaded 3 models: my secret dictation")
        do {
            _ = try transport.client.transcribe(audioPath: "/tmp/a.wav", audioSeconds: 1)
            Issue.record("a stray line was accepted as a reply")
        } catch {
            #expect(!"\(error)".contains("my secret dictation"))
        }
        #expect(transport.stopped)
        #expect(transport.client.fatal != nil)
    }

    @Test func aFailedWritePoisonsTheWorker() {
        let transport = FakeTransport()
        transport.writeFails = true
        #expect(throws: WorkerFailure.self) {
            _ = try transport.client.transcribe(audioPath: "/tmp/a.wav", audioSeconds: 1)
        }
        #expect(transport.client.fatal != nil)
    }
}

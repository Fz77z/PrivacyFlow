import Foundation

/// A dictation the worker recognised and routed.
public struct Transcription: Equatable, Sendable {
    public var transcript: String
    public var route: Route
    /// The text to insert: the raw transcript for PASS_THROUGH, S1-mini's
    /// rewrite for every other route.
    public var output: String
    public var asrMs: Double
    public var routerMs: Double
    /// Present only when S1-mini ran.
    public var processingMs: Double?
}

/// What one dictation reply means.
public enum DictationReply: Equatable, Sendable {
    case transcribed(Transcription)
    /// Nothing was said. Neither a transcript nor a failure.
    case noSpeech
    /// Speech was heard and could not be decoded. `detail` is the worker's own
    /// measurement of why, never any part of what was decoded.
    case unintelligible(seconds: Double, detail: String)
    /// The utterance failed. `transcript` is present when recognition had
    /// already succeeded, so the words can be kept rather than lost.
    case failed(message: String, transcript: String?)
}

/// The worker's first line, when it loaded.
public struct WorkerReady: Equatable, Sendable {
    /// Both only decorate the Status tab, so a worker that leaves them out is
    /// shown without them rather than refused.
    public var loadMilliseconds: Double?
    public var lockedBytes: Int64?

    public init(loadMilliseconds: Double?, lockedBytes: Int64?) {
        self.loadMilliseconds = loadMilliseconds
        self.lockedBytes = lockedBytes
    }
}

/// What the worker said about a warm-up.
public enum PrepareReply: Equatable, Sendable {
    case prepared
    /// The worker is healthy but the warm-up itself failed.
    case failed(String)
}

/// A reply that does not have the shape its request calls for.
public struct ProtocolViolation: Error, Equatable, CustomStringConvertible {
    public var description: String
}

/// The JSON-lines contract with the worker, described in docs/architecture.md.
///
/// Every field is optional on the wire, so a malformed reply is reported as the
/// field that is missing rather than as an opaque decoding failure.
public enum WorkerProtocol {
    private struct Wire: Decodable {
        var ready: Bool?
        var memory_locked_bytes: Int64?
        var load_ms: Double?
        var prepared: Bool?
        var transcript: String?
        var route: String?
        var output: String?
        var asr_ms: Double?
        var router_ms: Double?
        var processing_ms: Double?
        var no_speech: Bool?
        var unintelligible: Bool?
        var audio_seconds: Double?
        var detail: String?
        var error: String?
    }

    private static func decode(_ line: String) throws -> Wire {
        do {
            return try JSONDecoder().decode(Wire.self, from: Data(line.utf8))
        } catch {
            throw ProtocolViolation(description: "The worker sent a line that is not valid JSON")
        }
    }

    public static func prepareRequest() -> Data {
        Data(#"{"prepare":true}"#.utf8) + Data([0x0A])
    }

    public static func dictationRequest(audioPath: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["audio_path": audioPath], options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Read the startup line. A worker that says it could not load is an error
    /// carrying its reason.
    public static func parseReady(_ line: String) throws -> WorkerReady {
        let wire = try decode(line)
        guard let ready = wire.ready else {
            throw ProtocolViolation(description: "The worker's first line did not say whether it is ready")
        }
        guard ready else {
            throw ProtocolViolation(description: "The worker could not load its models: \(wire.error ?? "it gave no reason")")
        }
        return WorkerReady(loadMilliseconds: wire.load_ms, lockedBytes: wire.memory_locked_bytes)
    }

    /// Read the reply to a warm-up, refusing anything else. The line itself is
    /// never quoted in the error: out of step, it may be a dictation's reply,
    /// and that carries what the user said.
    public static func parsePrepared(_ line: String) throws -> PrepareReply {
        let wire = try decode(line)
        if let error = wire.error {
            return .failed(error)
        }
        if wire.prepared == true {
            return .prepared
        }
        throw ProtocolViolation(description: "expected a warm-up acknowledgement")
    }

    /// Read the reply to a dictation.
    public static func parseDictation(_ line: String) throws -> DictationReply {
        let wire = try decode(line)
        // An error outranks everything else in the same reply: it is a failure
        // whatever else it says.
        if let error = wire.error {
            return .failed(message: error, transcript: wire.transcript)
        }
        if wire.no_speech == true {
            return .noSpeech
        }
        if wire.unintelligible == true {
            // The figures only decorate the console, so their absence does not
            // refuse the answer.
            return .unintelligible(seconds: wire.audio_seconds ?? 0, detail: wire.detail ?? "no reason given")
        }
        func required<Value>(_ value: Value?, _ name: String) throws -> Value {
            guard let value else {
                throw ProtocolViolation(description: "The worker's reply omitted \(name)")
            }
            return value
        }
        let routeName = try required(wire.route, "the route")
        guard let route = Route(rawValue: routeName) else {
            throw ProtocolViolation(description: "The worker named a route this app does not know: \(routeName)")
        }
        return .transcribed(Transcription(
            transcript: try required(wire.transcript, "the transcript"),
            route: route,
            output: try required(wire.output, "the output text"),
            asrMs: try required(wire.asr_ms, "the recognition latency"),
            routerMs: try required(wire.router_ms, "the routing latency"),
            processingMs: wire.processing_ms
        ))
    }
}

/// How long the worker may take before it counts as wedged rather than slow.
public enum WorkerTimeouts {
    /// Loading and locking three models is slow but bounded.
    public static let startup: TimeInterval = 180
    /// The fixed part of a request: framing, dispatch, routing and an S1-mini
    /// rewrite, none of which grow with the audio. Also the warm-up's budget.
    public static let base: TimeInterval = 60
    /// Transcription runs many times faster than real time, so this is loose on
    /// purpose: a flat bound would make a merely slow machine look wedged.
    public static let perAudioSecond: TimeInterval = 4

    public static func dictation(audioSeconds: TimeInterval) -> TimeInterval {
        base + audioSeconds * perAudioSecond
    }
}

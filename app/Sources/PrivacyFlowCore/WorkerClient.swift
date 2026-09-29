import Foundation

/// Lines read from the worker's stdout, handed from the reader thread to the
/// pipeline thread.
///
/// Replies are read through this rather than straight from the pipe so that a
/// wedged worker fails explicitly after a timeout instead of blocking the
/// pipeline, and every dictation after it, forever.
public final class ReplyQueue: @unchecked Sendable {
    public enum Next: Equatable {
        case line(String)
        case timedOut
        /// The worker closed its stdout, which means it exited.
        case closed
    }

    private let condition = NSCondition()
    private var lines: [String] = []
    private var isClosed = false

    public init() {}

    public func push(_ line: String) {
        condition.lock()
        lines.append(line)
        condition.signal()
        condition.unlock()
    }

    public func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Wait up to `timeout` seconds for the next line. Lines that arrived
    /// before the close are still delivered.
    public func next(timeout: TimeInterval) -> Next {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty && !isClosed {
            if !condition.wait(until: deadline) {
                return lines.isEmpty ? (isClosed ? .closed : .timedOut) : .line(lines.removeFirst())
            }
        }
        if !lines.isEmpty {
            return .line(lines.removeFirst())
        }
        return .closed
    }
}

/// Why a request to the worker could not be answered.
public struct WorkerFailure: Error, Equatable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// The resident worker, seen as a sequence of requests each answered by
/// exactly one reply.
///
/// Used from one thread at a time. A timeout, a closed pipe, a failed write or
/// a reply that is out of step with its request poisons it: the process is
/// stopped, and every later request fails at once with the same reason rather
/// than hanging again or receiving someone else's answer. What to do next, a
/// fresh worker or a relaunch, is the app's decision rather than this one's.
public final class WorkerClient: @unchecked Sendable {
    private let write: (Data) throws -> Void
    private let replies: ReplyQueue
    private let stop: () -> Void
    /// The last lines the worker wrote to stderr, if the transport keeps them.
    /// A bundled app has no terminal, so these are the only place a crash's
    /// reason can be read.
    private let diagnostics: () -> String?

    /// The reason the worker was poisoned, once it has been.
    public private(set) var fatal: String?

    public init(
        write: @escaping (Data) throws -> Void,
        replies: ReplyQueue,
        stop: @escaping () -> Void,
        diagnostics: @escaping () -> String? = { nil }
    ) {
        self.write = write
        self.replies = replies
        self.stop = stop
        self.diagnostics = diagnostics
    }

    /// Wait for the worker to load its models. A worker that reports it could
    /// not load is stopped, because it will never answer anything else.
    public func awaitReady(timeout: TimeInterval = WorkerTimeouts.startup) throws -> WorkerReady {
        let line = try readLine(timeout: timeout, activity: "while loading its models")
        do {
            return try WorkerProtocol.parseReady(line)
        } catch let violation as ProtocolViolation {
            throw poison(violation.description)
        }
    }

    /// Ask the worker to make the router resident while the user speaks.
    ///
    /// A warm-up the worker reports as failed leaves it healthy and is thrown
    /// as an ordinary error. A reply that is not an acknowledgement means the
    /// streams are out of step, and that poisons the worker.
    public func prepare() throws {
        try refuseIfPoisoned()
        try send(WorkerProtocol.prepareRequest(), activity: "requests")
        let line = try readLine(timeout: WorkerTimeouts.base, activity: "while preparing the router")
        let reply: PrepareReply
        do {
            reply = try WorkerProtocol.parsePrepared(line)
        } catch let violation as ProtocolViolation {
            throw poison("The worker answered a warm-up with something else (\(violation.description))")
        }
        if case .failed(let message) = reply {
            throw WorkerFailure("The worker could not prepare the router: \(message)")
        }
    }

    /// Transcribe and route one recording. `audioSeconds` sizes the wedge
    /// timeout and nothing else. A per-utterance failure comes back as a
    /// `.failed` reply and leaves the worker healthy.
    public func transcribe(audioPath: String, audioSeconds: TimeInterval) throws -> DictationReply {
        try refuseIfPoisoned()
        try send(WorkerProtocol.dictationRequest(audioPath: audioPath), activity: "audio")
        let line = try readLine(timeout: WorkerTimeouts.dictation(audioSeconds: audioSeconds), activity: "while transcribing")
        do {
            return try WorkerProtocol.parseDictation(line)
        } catch let violation as ProtocolViolation {
            // A line that is not a dictation reply is most likely something
            // other than the reply, and then the real one is still coming and
            // would answer the next request. Nothing after it can be trusted.
            throw poison("The worker answered a dictation with something else (\(violation.description))")
        }
    }

    private func refuseIfPoisoned() throws {
        if let fatal {
            throw WorkerFailure(fatal)
        }
    }

    private func send(_ request: Data, activity: String) throws {
        do {
            try write(request)
        } catch {
            throw poison("The worker stopped accepting \(activity): \(error.localizedDescription)")
        }
    }

    private func readLine(timeout: TimeInterval, activity: String) throws -> String {
        switch replies.next(timeout: timeout) {
        case .line(let line):
            return line
        case .timedOut:
            throw poison("The worker stopped responding \(activity) after \(Int(timeout)) seconds")
        case .closed:
            throw poison("The worker exited")
        }
    }

    /// Record a permanent failure and stop the process, so later requests fail
    /// immediately with the same explanation.
    private func poison(_ reason: String) -> WorkerFailure {
        stop()
        var reason = reason
        if let diagnostics = diagnostics(), !diagnostics.isEmpty {
            reason += ". It last said: \(diagnostics)"
        }
        fatal = reason
        return WorkerFailure(reason)
    }
}

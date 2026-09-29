import Foundation
import os
import PrivacyFlowCore

/// How the worker is started: which interpreter, and with what.
struct WorkerLaunch: Equatable {
    /// Development only: an interpreter to run instead of the bundled runtime.
    /// It must already have `privacyflow_worker` installed, because `-I`
    /// ignores PYTHONPATH.
    static let developmentPythonVariable = "PRIVACYFLOW_DEV_PYTHON"

    var python: URL
    /// Set when the interpreter came from the development variable, so the
    /// Status tab can say so.
    var isDevelopmentOverride: Bool
    var models: URL
    var vad: URL

    /// `-B` because the runtime sits inside the signed bundle: its bytecode is
    /// compiled at build time, and writing any at run time would change the
    /// bundle and break its signature.
    var arguments: [String] {
        ["-I", "-B", "-m", "privacyflow_worker", "--models", models.path, "--vad", vad.path]
    }

    /// The bundled runtime, or the development interpreter when the variable
    /// names one. Nothing else is looked for: a missing runtime is a broken
    /// build, and saying where it was expected is the useful answer.
    static func resolve(models: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WorkerLaunch {
        guard let resources = Bundle.main.resourceURL else {
            throw LaunchProblem("PrivacyFlow could not find its own resources")
        }
        let vad = resources.appendingPathComponent("silero_vad.onnx")
        guard FileManager.default.fileExists(atPath: vad.path) else {
            throw LaunchProblem("The speech gate model is missing from the app bundle at \(vad.path)")
        }
        if let override = environment[developmentPythonVariable], !override.isEmpty {
            let python = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw LaunchProblem("\(developmentPythonVariable) names \(override), which is not an executable file")
            }
            return WorkerLaunch(python: python, isDevelopmentOverride: true, models: models, vad: vad)
        }
        let python = resources.appendingPathComponent("runtime/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw LaunchProblem("This copy of PrivacyFlow has no Python runtime at \(python.path). It was built without the packaging step that bundles it.")
        }
        return WorkerLaunch(python: python, isDevelopmentOverride: false, models: models, vad: vad)
    }
}

/// The running worker process and the threads that read its output.
final class WorkerProcess: @unchecked Sendable {
    /// How many of the worker's last stderr lines are kept for failure messages.
    private static let keptLines = 4

    let client: WorkerClient
    private let process: Process
    private let recentErrors = OSAllocatedUnfairLock(initialState: [String]())
    /// Whether PrivacyFlow killed a still-running worker, rather than finding
    /// it already gone.
    private let stoppedByApp = OSAllocatedUnfairLock(initialState: false)

    var pid: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    /// Why an exited worker stopped, with the last lines it wrote to stderr.
    /// A worker PrivacyFlow stopped itself, because it stopped answering or
    /// answered out of step, says that instead of a bare signal number.
    var exitDescription: String {
        var reason: String
        if stoppedByApp.withLock({ $0 }), let fatal = client.fatal {
            reason = "PrivacyFlow stopped the worker: \(fatal)"
        } else {
            reason = process.terminationReason == .uncaughtSignal
                ? "The worker stopped unexpectedly (signal \(process.terminationStatus))"
                : "The worker stopped unexpectedly (exit status \(process.terminationStatus))"
            let said = recentErrors.withLock { $0.joined(separator: " ") }
            if !said.isEmpty {
                reason += ". It last said: \(said)"
            }
        }
        return reason
    }

    /// Start the worker. Loading happens afterwards, in `client.awaitReady()`.
    /// `onExit` is called on an arbitrary thread when the process ends.
    init(_ launch: WorkerLaunch, onExit: @escaping @Sendable () -> Void) throws {
        let process = Process()
        process.executableURL = launch.python
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment
        // The worker never touches the network; this says so to the library too.
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.process = process

        let replies = ReplyQueue()
        let recentErrors = recentErrors
        let stoppedByApp = stoppedByApp
        client = WorkerClient(
            write: { data in try input.fileHandleForWriting.write(contentsOf: data) },
            replies: replies,
            stop: {
                let pid = process.processIdentifier
                guard pid > 0, process.isRunning else { return }
                stoppedByApp.withLock { $0 = true }
                Darwin.kill(pid, SIGKILL)
            },
            diagnostics: {
                recentErrors.withLock { $0.joined(separator: " ") }
            }
        )

        process.terminationHandler = { _ in onExit() }
        do {
            try process.run()
        } catch {
            throw LaunchProblem("Could not start the worker at \(launch.python.path): \(error.localizedDescription)")
        }

        Self.readLines(from: output.fileHandleForReading, name: "PrivacyFlow worker output") { line in
            replies.push(line)
        } atEnd: {
            replies.close()
        }
        Self.readLines(from: errors.fileHandleForReading, name: "PrivacyFlow worker errors") { line in
            FileHandle.standardError.write(Data("worker: \(line)\n".utf8))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            recentErrors.withLock { lines in
                lines.append(line)
                if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
            }
        } atEnd: {}
    }

    /// Read a pipe line by line on its own thread until it closes.
    private static func readLines(from handle: FileHandle, name: String, line: @escaping (String) -> Void, atEnd: @escaping () -> Void) {
        let thread = Thread {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let text = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    line(text)
                }
            }
            if !pending.isEmpty {
                line(String(decoding: pending, as: UTF8.self))
            }
            atEnd()
        }
        thread.name = name
        thread.start()
    }
}

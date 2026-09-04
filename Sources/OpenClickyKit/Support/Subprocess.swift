import Foundation

/// Runs a child process and captures its output.
///
/// Every external command in OpenClicky goes through here: argument arrays only,
/// never a shell string interpolated from model output, so there is no path from
/// a tool argument to shell metacharacter injection.
public enum Subprocess {

    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public var succeeded: Bool { exitCode == 0 }

        /// stdout when the command succeeded, otherwise a combined diagnostic.
        public var combined: String {
            if succeeded { return stdout }
            var parts: [String] = []
            if !stdout.isEmpty { parts.append(stdout) }
            if !stderr.isEmpty { parts.append(stderr) }
            parts.append("(exit code \(exitCode))")
            return parts.joined(separator: "\n")
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case timedOut(seconds: Int)
        case launchFailed(String)

        public var description: String {
            switch self {
            case let .timedOut(seconds): return "Command exceeded its \(seconds)s timeout and was terminated."
            case let .launchFailed(detail): return "Could not launch process: \(detail)"
            }
        }
    }

    /// Runs `executable` with `arguments`, killing it if it outruns `timeout`.
    ///
    /// - Parameter maxOutputBytes: output beyond this is truncated, so a runaway
    ///   command cannot blow up the transcript (and the context window with it).
    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        stdin: String? = nil,
        timeout: Int = 60,
        maxOutputBytes: Int = 100_000
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = scrubbedEnvironment()
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently with the wait. Reading after termination
        // deadlocks once a child fills the 64KB pipe buffer.
        async let outData = readAll(outPipe, limit: maxOutputBytes)
        async let errData = readAll(errPipe, limit: maxOutputBytes)

        let timedOut = await waitForExit(process, timeout: timeout)

        // Drain regardless: on a timeout the pipes close when the child dies, and
        // whatever it managed to write before then is often the useful diagnostic.
        let stdout = await outData
        let stderr = await errData

        if timedOut { throw Error.timedOut(seconds: timeout) }
        return Result(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Waits for the process to exit, terminating it if it outruns `timeout`.
    ///
    /// - Returns: whether the timeout fired.
    ///
    /// Deliberately not a task group racing a `Task.sleep`: `withCheckedContinuation`
    /// is not cancellation-aware, so a group would block on its implicit await-all
    /// until the child exited anyway — making the timeout silently ineffective.
    private static func waitForExit(_ process: Process, timeout: Int) async -> Bool {
        /// Guarantees the continuation is resumed exactly once, whichever of the
        /// two callbacks gets there first.
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Bool, Never>?
            init(_ continuation: CheckedContinuation<Bool, Never>) {
                self.continuation = continuation
            }
            func resume(timedOut: Bool) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(returning: timedOut)
            }
        }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { _ in once.resume(timedOut: false) }

            // The child can exit before the handler is installed; without this the
            // continuation would never resume.
            if !process.isRunning { once.resume(timedOut: false) }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                once.resume(timedOut: true)
            }
        }
    }

    /// Environment variables removed from every child process.
    ///
    /// A `Process` with no explicit environment inherits the parent's entire one. If
    /// the user authenticates with `ANTHROPIC_API_KEY`, that would put the key in
    /// reach of every command the agent runs — so a prompt-injected `curl` could
    /// exfiltrate it without ever touching a file. The key is stripped at the boundary
    /// instead, independently of whether the command was correctly classified.
    private static let secretEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_ADMIN_KEY",
        "OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "GITHUB_TOKEN", "GH_TOKEN", "NPM_TOKEN", "SLACK_TOKEN",
    ]

    static func scrubbedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in secretEnvironmentKeys { environment.removeValue(forKey: key) }
        // Catch project-specific spellings we cannot enumerate ahead of time.
        for key in environment.keys where isLikelySecret(key) {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static func isLikelySecret(_ key: String) -> Bool {
        let upper = key.uppercased()
        let markers = ["_API_KEY", "_SECRET", "_TOKEN", "_PASSWORD", "_CREDENTIALS", "_PRIVATE_KEY"]
        return markers.contains { upper.hasSuffix($0) || upper.contains($0) }
    }

    private static func readAll(_ pipe: Pipe, limit: Int) async -> String {
        await Task.detached {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if data.count > limit {
                let head = data.prefix(limit)
                let text = String(decoding: head, as: UTF8.self)
                return text + "\n… [truncated, \(data.count - limit) more bytes]"
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

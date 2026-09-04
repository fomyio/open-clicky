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
    /// - Parameter maxOutputBytes: output beyond this is abbreviated, so a runaway
    ///   command cannot blow up the transcript and the context window with it.
    ///   16KB is roughly 4,000 tokens — generous for something the model has to
    ///   read, and small enough that several such results still fit. The previous
    ///   100KB was ~25,000 tokens from a single `ps aux`, and a handful of those
    ///   would have exhausted the context mid-task.
    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        stdin: String? = nil,
        timeout: Int = 60,
        maxOutputBytes: Int = 16_000
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = scrubbedEnvironment()
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // stdin is always set, never inherited.
        //
        // A child that inherits the terminal blocks forever on a command as ordinary
        // as `cat` or `sort` with no file — and worse, it competes with the approval
        // prompt for the user's keystrokes, swallowing the y/n meant for the gate.
        // `shortcuts run` hangs the same way. An agent's subprocess has no business
        // reading the user's terminal, so it gets its input from us or from nothing.
        let inPipe = Pipe()
        process.standardInput = inPipe
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

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

    /// Whether a variable's name suggests it holds a credential.
    ///
    /// Matched on underscore-separated components rather than substrings. The earlier
    /// markers all began with an underscore (`_SECRET`, `_TOKEN`), which meant they
    /// only matched a credential word used as a *suffix* — so the single most common
    /// convention of all, the word first, went straight through: `SECRET_KEY`,
    /// `PASSWORD`, `TOKEN`, `DATABASE_URL`, `SECRET_KEY_BASE` were every one of them
    /// unscrubbed and inherited by every command the agent ran.
    static func isLikelySecret(_ key: String) -> Bool {
        let components = Set(key.uppercased().split(separator: "_").map(String.init))
        let credentialWords: Set<String> = [
            // "PWD" is deliberately absent: it is the standard present-working-
            // directory variable far more often than it is a password.
            "SECRET", "SECRETS", "TOKEN", "PASSWORD", "PASSWD",
            "APIKEY", "CREDENTIAL", "CREDENTIALS", "PRIVATEKEY", "PASSPHRASE",
            "AUTH", "SESSION", "COOKIE", "SIGNING", "CERT", "PEM",
        ]
        if !components.isDisjoint(with: credentialWords) { return true }

        // "KEY" is too common alone (KEYBOARD_LAYOUT, KEYMAP) to flag on its own,
        // so require it to sit beside something that makes it a credential.
        if components.contains("KEY") {
            let qualifiers: Set<String> = [
                "API", "SECRET", "PRIVATE", "ACCESS", "MASTER", "SIGNING", "ENCRYPTION",
                "STRIPE", "AWS", "GCP", "AZURE", "OPENAI", "ANTHROPIC", "SSH", "GPG",
            ]
            if !components.isDisjoint(with: qualifiers) { return true }
        }

        // Connection strings routinely carry `user:password@host` inline.
        if components.contains("URL") || components.contains("URI") || components.contains("DSN") {
            let services: Set<String> = [
                "DATABASE", "DB", "POSTGRES", "POSTGRESQL", "MYSQL", "MONGO", "MONGODB",
                "REDIS", "AMQP", "RABBITMQ", "ELASTIC", "CLICKHOUSE", "SMTP",
            ]
            if !components.isDisjoint(with: services) { return true }
        }
        return false
    }

    private static func readAll(_ pipe: Pipe, limit: Int) async -> String {
        await Task.detached {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return abbreviate(data, to: limit)
        }.value
    }

    /// Keeps the beginning and the end of oversized output.
    ///
    /// Head-only truncation loses the part that usually matters: a build's errors, a
    /// script's summary, the last line of a log. The note in the middle says how much
    /// is missing and what to do about it, because the model can narrow the command
    /// far more cheaply than it can page through 4,000 tokens of listing.
    static func abbreviate(_ data: Data, to limit: Int) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }

        let half = limit / 2
        let head = String(decoding: data.prefix(half), as: UTF8.self)
        let tail = String(decoding: data.suffix(half), as: UTF8.self)
        let omitted = data.count - (half * 2)

        return """
            \(head)

            … [\(omitted) bytes omitted from the middle. Narrow the command — add a             filter, a more specific path, or pipe through `head`/`tail`/`grep` —             rather than reading around this.]

            \(tail)
            """
    }
}

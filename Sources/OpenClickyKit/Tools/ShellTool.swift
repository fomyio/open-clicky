import Foundation

/// Tier 0 — arbitrary shell commands.
///
/// The single highest-leverage tool: most "look at something on my Mac" tasks are
/// answerable here with zero vision tokens. Commands run under `sandbox-exec` when
/// a profile is active, and always through the deny-list.
public struct ShellTool: Tool {
    public let name = "shell"
    public let tier = Tier.shell
    /// Varies with the sandbox, because a fixed claim about confinement is false
    /// under `--no-sandbox` — and it is not a harmless falsehood. It steers the model
    /// away from `ps` for a reason that no longer holds, and worse, gives it an
    /// incorrect picture of its own containment while it decides what is safe to run.
    public var description: String {
        let confinement = switch sandbox {
        case .enabled:
            """
            Commands run confined by `sandbox-exec`, which drops the privileges `ps` \
            needs — use `pgrep -l <name>` or `launchctl list` to see what is running. \
            Writes outside the user's own files are refused by the sandbox.
            """
        case .disabled:
            """
            This run was started with `--no-sandbox`, so commands are **not** confined: \
            they carry the user's full privileges and any write they attempt will \
            succeed. Weigh that before running anything irreversible.
            """
        }

        return """
        Run a shell command on the user's Mac and get its output. This is the cheapest \
        and most precise capability available — prefer it over looking at the screen \
        whenever the answer can be obtained from the filesystem, a CLI, or a database.

        Good uses: inspecting files and directories, `git` status and history, `defaults read`, \
        `mdfind` for Spotlight search, `sqlite3` against app databases, `system_profiler`, \
        reading logs.

        \(confinement)

        Runs via `/bin/zsh -c`, so pipes, redirection and globs work. The working \
        directory defaults to the user's home. Output is truncated at 100KB.
        """
    }

    public var inputSchema: JSONValue {
        .schema([
            "command": .string(describing: "The command line to execute, e.g. `git -C ~/src/app status --short`."),
            "working_directory": .string(describing: "Absolute path to run in. Defaults to the user's home directory."),
            "timeout_seconds": .integer(describing: "Kill the command after this many seconds. Default 60, maximum 600."),
        ], required: ["command"])
    }

    /// Readable so the system prompt can describe the confinement this run actually
    /// has, rather than asserting one it may not.
    let sandbox: ShellSandbox

    public init(sandbox: ShellSandbox = .enabled) {
        self.sandbox = sandbox
    }

    public func risk(for input: JSONValue) -> Risk {
        // A missing argument is a malformed call, not a read: classifying it read
        // would wave it past the gate before `run` ever rejects it.
        guard let command = input["command"]?.stringValue else {
            return .write(summary: "shell command with missing arguments")
        }
        return Policy.classifyShell(command).risk
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let command = try input.string("command")
        try Policy.validateShell(command)

        let cwd = input["working_directory"]?.stringValue
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let timeout = min(max(input.int("timeout_seconds", default: 60), 1), 600)

        let (executable, arguments) = sandbox.wrap(command: command)
        do {
            let result = try await Subprocess.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: cwd,
                timeout: timeout
            )
            // Checked before either path. A tool result reaches the model and is
            // written to the session record, and approving the *action* was never
            // consent to transmit the credential it prints — and the failure path
            // returns combined output, which includes stdout, so it leaks the same
            // thing whenever the command prints before exiting non-zero.
            if Policy.printsSecret(command) {
                let outcome = result.succeeded
                    ? "The command ran."
                    : "The command failed (exit \(result.exitCode))."
                return ToolOutput(
                    content: [.text("\(outcome) \(Policy.withheldSecretNote)")],
                    isError: !result.succeeded
                )
            }
            guard result.succeeded else {
                return ToolOutput(
                    content: [.text(sandbox.explain(failure: result.combined))],
                    isError: true
                )
            }
            return .text(result.stdout)
        } catch let error as Subprocess.Error {
            return .failure(error.description)
        }
    }
}

/// Whether shell commands are confined by `sandbox-exec`.
///
/// `sandbox-exec` is deprecated by Apple but still functional and still the only
/// built-in way to confine a child process on macOS without a full VM.
///
/// The profile denies writes to system locations *and* to the user-level persistence
/// paths that matter — `~/Library/LaunchAgents` in particular, which the user's own
/// process can write without elevation and which macOS loads at next login. It also
/// denies reads of the credential directories, so the deny-list is enforced twice.
///
/// Network access, process spawning and IPC remain open: this is a barrier against
/// accidental damage, not against a determined attacker.
public enum ShellSandbox: Sendable {
    case disabled
    case enabled

    /// A profile that permits reads broadly but confines writes to the user's own
    /// data, keeping the agent out of system locations and other users' files.
    static var profile: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        (version 1)
        (allow default)
        (deny file-write*
          (subpath "/System")
          (subpath "/usr")
          (subpath "/bin")
          (subpath "/sbin")
          (subpath "/Library/LaunchDaemons")
          (subpath "/Library/LaunchAgents")
          (subpath "\(home)/Library/LaunchAgents")
          (subpath "\(home)/.ssh")
          (subpath "/private/var/at"))
        (deny file-read*
          (literal "/etc/master.passwd")
          (subpath "/private/var/db/shadow")
          (subpath "\(home)/.ssh")
          (subpath "\(home)/.aws")
          (subpath "\(home)/.gnupg")
          (subpath "\(home)/Library/Keychains"))
        """
    }

    /// Adds context when a failure is the sandbox rather than the command.
    ///
    /// `sandbox-exec` drops setgid privileges, so `/bin/ps` — which is setgid `kmem` —
    /// fails with a bare "operation not permitted". Left unexplained the model reads
    /// that as a transient error and retries the same command; it needs to know the
    /// cause is structural and what to use instead. Measured across the whole
    /// read-only allowlist, `ps` is the only casualty.
    /// Adds the sandbox as an explanation when the failure looks like one of its
    /// refusals.
    ///
    /// Matched case-insensitively, and on both shapes macOS actually produces. This
    /// tested `contains("operation not permitted")` against output that says
    /// "Operation not permitted" — one capital, exactly the mistake this project
    /// already recorded about path comparison — and against writes, which are refused
    /// as "Permission denied" and were never matched at all. The explanation had
    /// therefore never once appeared, and the model saw a bare denial with no reason
    /// to suspect the sandbox: the obvious next move from there is `sudo`.
    func explain(failure: String) -> String {
        guard case .enabled = self else { return failure }
        let lowered = failure.lowercased()
        guard lowered.contains("operation not permitted")
            || lowered.contains("permission denied")
            || lowered.contains("sandbox") else { return failure }

        // Both remedies, rather than a guess at which applies. The first attempt
        // inferred the cause from the wording and got `ps aux` wrong immediately —
        // it fails as "zsh:1: operation not permitted: ps", which names neither a
        // process nor a path. Two short lines that are always right beat one that is
        // sometimes confidently wrong.
        return """
            \(failure)

            This is the sandbox refusing the command, not a fault in the command itself.

            - Reading process state: `ps` needs privileges the sandbox drops. Use \
            `pgrep -l <name>` or `launchctl list` instead.
            - Writing files: writes are confined to the user's own files, and a path \
            outside them is refused.

            If the task genuinely requires more, say so. The user can restart with \
            `--no-sandbox`; that is their decision, not something to work around with \
            `sudo`.
            """
    }

    func wrap(command: String) -> (executable: String, arguments: [String]) {
        switch self {
        case .disabled:
            return ("/bin/zsh", ["-c", command])
        case .enabled:
            return ("/usr/bin/sandbox-exec", ["-p", Self.profile, "/bin/zsh", "-c", command])
        }
    }
}

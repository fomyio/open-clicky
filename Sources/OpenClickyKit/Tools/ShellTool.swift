import Foundation

/// Tier 0 — arbitrary shell commands.
///
/// The single highest-leverage tool: most "look at something on my Mac" tasks are
/// answerable here with zero vision tokens. Commands run under `sandbox-exec` when
/// a profile is active, and always through the deny-list.
public struct ShellTool: Tool {
    public let name = "shell"
    public let tier = Tier.shell
    public let description = """
    Run a shell command on the user's Mac and get its output. This is the cheapest \
    and most precise capability available — prefer it over looking at the screen \
    whenever the answer can be obtained from the filesystem, a CLI, or a database.

    Good uses: inspecting files and directories, `git` status and history, `defaults read`, \
    `mdfind` for Spotlight search, `sqlite3` against app databases, `system_profiler`, \
    checking what processes are running, reading logs.

    Runs via `/bin/zsh -c`, so pipes, redirection and globs work. The working \
    directory defaults to the user's home. Output is truncated at 100KB.
    """

    public var inputSchema: JSONValue {
        .schema([
            "command": .string(describing: "The command line to execute, e.g. `git -C ~/src/app status --short`."),
            "working_directory": .string(describing: "Absolute path to run in. Defaults to the user's home directory."),
            "timeout_seconds": .integer(describing: "Kill the command after this many seconds. Default 60, maximum 600."),
        ], required: ["command"])
    }

    private let sandbox: ShellSandbox

    public init(sandbox: ShellSandbox = .enabled) {
        self.sandbox = sandbox
    }

    public func risk(for input: JSONValue) -> Risk {
        guard let command = input["command"]?.stringValue else { return .read }
        if Policy.isReadOnlyCommand(command) { return .read }
        return .write(summary: command)
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
            return result.succeeded
                ? .text(result.stdout)
                : ToolOutput(content: [.text(result.combined)], isError: true)
        } catch let error as Subprocess.Error {
            return .failure(error.description)
        }
    }
}

/// Whether shell commands are confined by `sandbox-exec`.
///
/// `sandbox-exec` is deprecated by Apple but still functional and still the only
/// built-in way to confine a child process on macOS without a full VM. It is a
/// meaningful barrier against accidental damage, not against a determined attacker.
public enum ShellSandbox: Sendable {
    case disabled
    case enabled

    /// A profile that permits reads broadly but confines writes to the user's own
    /// data, keeping the agent out of system locations and other users' files.
    static let profile = """
    (version 1)
    (allow default)
    (deny file-write*
      (subpath "/System")
      (subpath "/usr")
      (subpath "/bin")
      (subpath "/sbin")
      (subpath "/Library/LaunchDaemons")
      (subpath "/Library/LaunchAgents"))
    (deny file-read*
      (literal "/etc/master.passwd")
      (subpath "/private/var/db/shadow"))
    """

    func wrap(command: String) -> (executable: String, arguments: [String]) {
        switch self {
        case .disabled:
            return ("/bin/zsh", ["-c", command])
        case .enabled:
            return ("/usr/bin/sandbox-exec", ["-p", Self.profile, "/bin/zsh", "-c", command])
        }
    }
}

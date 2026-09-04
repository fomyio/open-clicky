import Foundation

/// How much the agent may do without stopping to ask.
public enum PermissionMode: String, Sendable, CaseIterable {
    /// Observation only. Every mutating call is refused.
    case readOnly = "read-only"
    /// Prompt before anything that changes state. The default.
    case ask
    /// Mutations proceed silently; destructive calls still prompt.
    case auto
    /// No prompts at all. For scripted runs where the caller accepts the risk.
    case bypass

    public var explanation: String {
        switch self {
        case .readOnly: return "read-only — mutating actions are refused"
        case .ask: return "ask — you approve each action that changes state"
        case .auto: return "auto — writes run automatically, destructive actions still ask"
        case .bypass: return "bypass — nothing prompts"
        }
    }
}

/// Static rules applied before a tool call reaches the permission gate.
///
/// This is a backstop, not the primary defence: it catches the small set of
/// commands whose blast radius is bad enough that no approval prompt should be
/// able to authorise them by accident.
public struct Policy: Sendable {
    /// Shell fragments that are refused outright in every mode.
    ///
    /// Deliberately short. A long list invites false confidence — the real
    /// containment is the permission gate plus running the shell under
    /// `sandbox-exec`, not pattern matching.
    public static let deniedShellPatterns: [String] = [
        "rm -rf /",
        "rm -rf /*",
        "rm -rf ~",
        "rm -rf $HOME",
        ":(){:|:&};:",
        "mkfs",
        "diskutil eraseDisk",
        "diskutil eraseVolume",
        "dd if=/dev/zero of=/dev/",
        "dd of=/dev/disk",
        "csrutil disable",
        "spctl --master-disable",
        "> /dev/sda",
        "chmod -R 777 /",
        "killall -9 kernel_task",
    ]

    /// Paths the agent may never read, regardless of mode. Credentials that would
    /// be exfiltratable via a prompt-injection payload.
    public static let deniedReadPaths: [String] = [
        "/etc/master.passwd",
        "/etc/shadow",
        "/private/etc/master.passwd",
        "~/.ssh/id_rsa",
        "~/.ssh/id_ed25519",
        "~/.aws/credentials",
        "~/.config/gh/hosts.yml",
    ]

    /// Commands that read state and are safe to run without prompting even in `.ask`.
    /// Anything not listed is treated as mutating.
    public static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "fd", "file", "stat",
        "pwd", "whoami", "hostname", "uname", "date", "df", "du", "ps", "top",
        "which", "type", "env", "printenv", "echo", "sw_vers", "system_profiler",
        "defaults", "mdfind", "mdls", "sqlite3", "plutil", "jq", "sort", "uniq",
        "diff", "tree", "man", "networksetup", "ioreg", "pmset", "lsof",
    ]

    public struct Violation: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    /// Rejects a shell command that matches the deny-list.
    public static func validateShell(_ command: String) throws {
        let normalized = command
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in deniedShellPatterns where normalized.contains(pattern) {
            throw Violation(reason: """
            Refused: the command matches the deny-list entry '\(pattern)'. \
            This is blocked in every permission mode. If you genuinely need it, \
            run it yourself in a terminal.
            """)
        }
    }

    /// Rejects a read of a path holding credentials.
    public static func validateRead(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        for denied in deniedReadPaths {
            let deniedExpanded = (denied as NSString).expandingTildeInPath
            if expanded == deniedExpanded {
                throw Violation(reason: "Refused: '\(path)' holds credentials and is never readable by the agent.")
            }
        }
    }

    /// Whether a command line's leading executable is a known read-only utility.
    ///
    /// Shell metacharacters that could chain a second command defeat the check, so
    /// their presence forces the mutating classification.
    public static func isReadOnlyCommand(_ command: String) -> Bool {
        let chaining: Set<Character> = [";", "|", "&", ">", "<", "`", "$"]
        if command.contains(where: { chaining.contains($0) }) { return false }
        guard let first = command.split(separator: " ").first else { return false }
        let executable = (String(first) as NSString).lastPathComponent
        return readOnlyCommands.contains(executable)
    }
}

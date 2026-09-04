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
/// The governing principle is **conservative classification**: a call is treated as
/// mutating unless it can be *proved* read-only. The inverse — assuming read-only
/// and looking for evidence of mutation — is unsound, because a read classification
/// bypasses the permission gate in every mode, so any gap in the evidence-gathering
/// becomes a total bypass rather than a missed prompt.
public enum Policy: Sendable {

    // MARK: - Classification

    public enum Classification: Sendable, Equatable {
        /// Provably observation-only. Skips the permission prompt.
        case readOnly
        case mutating(reason: String)
        case destructive(reason: String)

        public var risk: Risk {
            switch self {
            case .readOnly: return .read
            case let .mutating(reason): return .write(summary: reason)
            case let .destructive(reason): return .dangerous(summary: reason)
            }
        }
    }

    /// Characters that separate one command from another under `zsh -c`.
    ///
    /// Newlines are handled via `isNewline` rather than by listing `\n` and `\r`:
    /// Swift treats CRLF as a *single* grapheme cluster, so `"\r\n"` matches neither
    /// character individually and a CRLF-chained command would not have been split.
    private static let separators: Set<Character> = [";", "|", "&"]

    private static func isSeparator(_ character: Character) -> Bool {
        separators.contains(character) || character.isNewline
    }

    /// Constructs that make static analysis of a command impossible.
    private static let opaqueConstructs = ["$(", "`", "${", "<(", ">("]

    /// Commands that only observe. Anything absent is assumed to mutate.
    public static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "find", "fd",
        "file", "stat", "pwd", "whoami", "hostname", "uname", "date", "df", "du", "ps",
        "which", "type", "printenv", "echo", "sw_vers", "system_profiler",
        "mdfind", "mdls", "plutil", "jq", "sort", "uniq", "cut", "awk", "sed",
        "diff", "tree", "basename", "dirname", "realpath", "readlink",
        "networksetup", "ioreg", "pmset", "lsof", "sysctl", "vm_stat", "uptime",
        "git", "brew", "swift", "xcrun", "defaults", "sqlite3",
    ]

    /// Read-only commands that become mutating with the wrong subcommand or flag.
    ///
    /// `git log` reads; `git push` does not. The classifier requires the second
    /// token to be on this allowlist before granting read-only status.
    private static let subcommandAllowlist: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "branch", "remote", "config",
                "ls-files", "rev-parse", "describe", "blame", "shortlog", "tag"],
        "brew": ["list", "info", "search", "outdated", "config", "--version"],
        "swift": ["--version", "build", "test"],
        "defaults": ["read", "read-type", "domains", "find"],
        "xcrun": ["--find", "--show-sdk-version", "--show-sdk-path", "simctl"],
        // sqlite3 takes SQL as an argument; there is no safe prefix to allowlist.
        "sqlite3": [],
    ]

    /// Fragments refused outright, in every permission mode.
    ///
    /// A narrow, best-effort backstop for the handful of commands whose blast radius
    /// is bad enough that no approval prompt should be able to authorise them by
    /// mistake. It is not, and cannot be, exhaustive — containment comes from the
    /// conservative classifier above and the permission gate, not from this list.
    public static let deniedShellPatterns: [String] = [
        "rm -rf /", "rm -rf /*", "rm -rf ~", "rm -rf $home", "rm -fr /",
        ":(){:|:&};:",
        "mkfs", "diskutil erasedisk", "diskutil erasevolume", "diskutil zerodisk",
        "dd if=/dev/zero of=/dev/", "dd of=/dev/disk", "dd of=/dev/rdisk",
        "csrutil disable", "spctl --master-disable", "nvram boot-args",
        "chmod -r 777 /", "chown -r", "killall -9 kernel_task",
        "> /dev/disk", "> /dev/rdisk",
    ]

    /// Markers that make a command destructive rather than merely mutating.
    private static let destructiveMarkers: [(pattern: String, reason: String)] = [
        ("sudo ", "runs with elevated privileges"),
        ("doas ", "runs with elevated privileges"),
        ("diskutil ", "operates on disks"),
        ("launchctl ", "changes launch services"),
        ("csrutil", "changes system integrity protection"),
        ("spctl ", "changes gatekeeper policy"),
        ("shutdown", "shuts the machine down"),
        ("reboot", "restarts the machine"),
        ("security delete", "deletes from the keychain"),
        ("security dump-keychain", "dumps keychain contents"),
        ("-delete", "deletes matched files"),
        ("-exec rm", "deletes matched files"),
        ("dd ", "writes raw blocks"),
        ("shred ", "irrecoverably erases data"),
        ("git push", "publishes to a remote"),
        ("git reset --hard", "discards local work"),
        ("git clean -f", "deletes untracked files"),
    ]

    /// Paths whose contents are secrets. Never readable through any tool.
    ///
    /// Matched as path prefixes so a whole credential directory is covered.
    public static let deniedReadPaths: [String] = [
        "/etc/master.passwd", "/etc/shadow", "/private/etc/master.passwd",
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.docker/config.json",
        "~/.netrc", "~/.npmrc", "~/.pypirc", "~/.config/gh",
        "~/.kube/config", "~/.config/gcloud", "~/.azure",
        "~/Library/Keychains",
    ]

    /// Paths a write to which establishes persistence or changes security posture.
    public static let sensitiveWritePaths: [String] = [
        "~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "~/.ssh", "~/.zshrc", "~/.zshenv", "~/.zprofile", "~/.bashrc",
        "~/.bash_profile", "~/.profile", "~/.config/fish/config.fish",
        "/etc/hosts", "/etc/sudoers", "~/Library/Preferences/com.apple.loginitems.plist",
        "/usr/local/bin", "/opt/homebrew/bin",
    ]

    public struct Violation: Error, CustomStringConvertible, Equatable {
        public let reason: String
        public var description: String { reason }
    }

    // MARK: - Normalisation

    /// Canonical form for pattern matching.
    ///
    /// Collapses every whitespace run (tabs included), lowercases, and strips quote
    /// characters — so `rm   -rf   /`, `rm\t-rf\t/` and `r''m -rf /` all reduce to the
    /// same string as `rm -rf /` and cannot slip past the deny-list on spacing alone.
    static func normalize(_ command: String) -> String {
        let unquoted = command.filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
        let collapsed = unquoted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Splits a command line into individual commands on every shell separator.
    static func segments(_ command: String) -> [String] {
        command
            .split(whereSeparator: isSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Validation

    /// Refuses a command that matches the deny-list or touches a credential path.
    public static func validateShell(_ command: String) throws {
        let normalized = normalize(command)

        for pattern in deniedShellPatterns where normalized.contains(pattern) {
            throw Violation(reason: """
            Refused: this command matches the deny-list entry '\(pattern)'. \
            It is blocked in every permission mode. If you genuinely need it, run it \
            yourself in a terminal.
            """)
        }

        // The same credential paths `read_file` refuses. Enforced here too, or the
        // deny-list would be one `cat` away from irrelevant.
        if let path = referencedCredentialPath(in: normalized) {
            throw Violation(reason: """
            Refused: this command references '\(path)', which holds credentials. \
            Credential paths are unreadable through every tool, in every permission mode.
            """)
        }
    }

    /// Refuses a read of a path holding credentials.
    public static func validateRead(path: String) throws {
        if let matched = credentialPrefix(matching: path) {
            throw Violation(reason: "Refused: '\(path)' is under '\(matched)', which holds credentials and is never readable by the agent.")
        }
    }

    /// Whether a write to this path establishes persistence or alters security posture.
    public static func isSensitiveWrite(path: String) -> String? {
        let resolved = expand(path)
        for sensitive in sensitiveWritePaths {
            let prefix = expand(sensitive)
            if resolved == prefix || resolved.hasPrefix(prefix + "/") { return sensitive }
        }
        return nil
    }

    private static func expand(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func credentialPrefix(matching path: String) -> String? {
        let resolved = expand(path)
        for denied in deniedReadPaths {
            let prefix = expand(denied)
            if resolved == prefix || resolved.hasPrefix(prefix + "/") { return denied }
        }
        return nil
    }

    /// Finds a credential path mentioned anywhere in a normalised command line.
    private static func referencedCredentialPath(in normalized: String) -> String? {
        let home = expand("~").lowercased()
        for denied in deniedReadPaths {
            let expanded = expand(denied).lowercased()
            // Match both the literal path and its tilde form, since either reaches
            // the same file once the shell expands it.
            let tildeForm = expanded.hasPrefix(home)
                ? "~" + expanded.dropFirst(home.count)
                : expanded
            if normalized.contains(expanded) || normalized.contains(tildeForm) { return denied }
        }
        return nil
    }

    // MARK: - Classification

    /// Classifies a shell command.
    ///
    /// Read-only status requires that *every* segment provably reads: a known
    /// read-only leading command, an allowlisted subcommand where one is required,
    /// no redirection, and no construct that defeats static analysis. Anything else
    /// is mutating or destructive.
    public static func classifyShell(_ command: String) -> Classification {
        let normalized = normalize(command)

        for marker in destructiveMarkers where normalized.contains(marker.pattern) {
            return .destructive(reason: "\(summarize(command)) — \(marker.reason)")
        }
        if let destructive = destructiveRemoval(in: normalized) {
            return .destructive(reason: "\(summarize(command)) — \(destructive)")
        }
        if let sensitive = redirectionTarget(in: command).flatMap({ isSensitiveWrite(path: $0) }) {
            return .destructive(reason: "\(summarize(command)) — writes to \(sensitive)")
        }

        for construct in opaqueConstructs where command.contains(construct) {
            return .mutating(reason: "\(summarize(command)) — contains \(construct), whose effect cannot be determined in advance")
        }
        if command.contains(">") || command.contains("<") {
            return .mutating(reason: "\(summarize(command)) — redirects output")
        }

        let parts = segments(command)
        guard !parts.isEmpty else { return .mutating(reason: summarize(command)) }

        for segment in parts where !isReadOnlySegment(segment) {
            return .mutating(reason: summarize(command))
        }
        return .readOnly
    }

    /// Whether one segment — a single command with its arguments — only observes.
    private static func isReadOnlySegment(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }

        let executable = (first as NSString).lastPathComponent.lowercased()
        guard readOnlyCommands.contains(executable) else { return false }

        // Commands with both reading and writing modes must name an allowlisted one.
        if let allowed = subcommandAllowlist[executable] {
            guard let subcommand = tokens.dropFirst().first(where: { !$0.hasPrefix("-") })
                    ?? tokens.dropFirst().first else { return false }
            guard allowed.contains(subcommand.lowercased()) else { return false }
        }
        return true
    }

    /// Detects a recursive or forced removal, which is destructive rather than mutating.
    private static func destructiveRemoval(in normalized: String) -> String? {
        for segment in segments(normalized) {
            let tokens = segment.split(separator: " ").map(String.init)
            guard let first = tokens.first,
                  (first as NSString).lastPathComponent == "rm" else { continue }
            let flags = tokens.dropFirst().filter { $0.hasPrefix("-") }.joined()
            if flags.contains("r") || flags.contains("f") {
                return "recursive or forced deletion"
            }
        }
        return nil
    }

    /// The destination of a `>` or `>>` redirection, if there is one.
    private static func redirectionTarget(in command: String) -> String? {
        guard let range = command.range(of: ">>") ?? command.range(of: ">") else { return nil }
        let tail = command[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace)
            .first
        return tail.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    private static func summarize(_ command: String) -> String {
        let flat = command.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 140 ? String(flat.prefix(137)) + "…" : flat
    }
}

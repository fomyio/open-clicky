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

    /// How an invocation of a given command earns read-only status.
    ///
    /// Allowlisting an *executable* is not enough: `find`, `git` and `sed` all read
    /// or write depending entirely on their arguments, and `find . -exec sh -c ...`
    /// is arbitrary code execution wearing a file search's clothes. Every read-only
    /// command must therefore declare how its arguments are constrained, and a
    /// command with no entry here is never read-only.
    public struct ArgumentRule: Sendable {
        /// The first argument must be one of these. `nil` imposes no requirement.
        var subcommands: Set<String>?
        /// An argument equal to any of these forfeits read-only status.
        var deniedTokens: Set<String> = []
        /// Maximum non-flag arguments. A second operand is often an output file
        /// (`uniq in out`), which is a write with no flag to give it away.
        var maxOperands: Int?
    }

    /// Arguments that turn any command into an executor, whatever it is.
    ///
    /// `find`'s action primaries are the canonical case and are dangerous wherever
    /// they appear.
    private static let universallyDeniedPrefixes = ["-exec", "-ok", "-fprint", "-fls"]

    /// Commands that can be read-only, and what it takes for them to be.
    ///
    /// Deliberately smaller than a plain executable allowlist. Anything whose
    /// argument space cannot be constrained confidently is simply absent, so it
    /// prompts: `awk` (`system()`), `sed` (`-i`, and `w` inside a script),
    /// `sqlite3` (arbitrary SQL), `networksetup` (`-set*`), `sysctl` (`-w`),
    /// `printenv`/`env` (dumps the environment, secrets included). Losing a
    /// prompt-free `awk` is a small price; letting `awk 'BEGIN{system(...)}'` skip
    /// the permission gate in every mode is not.
    public static let readOnlyCommands: [String: ArgumentRule] = {
        var table: [String: ArgumentRule] = [:]

        // No argument can make these write or execute.
        for command in [
            "ls", "pwd", "whoami", "hostname", "uname", "date", "uptime", "sw_vers",
            "df", "du", "ps", "vm_stat", "system_profiler", "ioreg", "lsof",
            "basename", "dirname", "realpath", "readlink", "which", "type",
            "cat", "head", "tail", "wc", "file", "stat", "tree", "echo",
            "grep", "egrep", "fgrep", "diff", "cut", "jq", "mdfind", "mdls", "man",
        ] {
            table[command] = ArgumentRule()
        }

        // Read unless a specific writing flag appears.
        table["sort"] = ArgumentRule(deniedTokens: ["-o", "--output"])
        table["rg"] = ArgumentRule(deniedTokens: ["--pre", "--hostname-bin"])
        table["fd"] = ArgumentRule(deniedTokens: ["-x", "--exec", "-X", "--exec-batch"])
        // `uniq in out` writes `out`, with nothing in the flags to say so.
        table["uniq"] = ArgumentRule(maxOperands: 1)
        table["find"] = ArgumentRule(deniedTokens: ["-delete"])

        // Read only in an explicitly named reading mode.
        //
        // `git config`, `remote`, `branch` and `tag` are absent on purpose: each has
        // a read form and a write form distinguished only by later arguments, and
        // `git config credential.helper '!curl …'` installs a durable credential
        // exfiltrator. Allowing the read form is not worth owning that distinction.
        table["git"] = ArgumentRule(subcommands: [
            "status", "log", "diff", "show", "ls-files", "rev-parse",
            "describe", "blame", "shortlog",
        ])
        table["brew"] = ArgumentRule(subcommands: ["list", "info", "search", "outdated", "config", "--version"])
        table["defaults"] = ArgumentRule(subcommands: ["read", "read-type", "domains", "find"])
        table["plutil"] = ArgumentRule(subcommands: ["-p", "-lint"])
        table["pmset"] = ArgumentRule(subcommands: ["-g"])
        // `simctl` is absent: `xcrun simctl erase all` wipes every simulator.
        table["xcrun"] = ArgumentRule(subcommands: ["--find", "--show-sdk-version", "--show-sdk-path"])
        // `swift build` and `swift test` write to .build, so only --version reads.
        table["swift"] = ArgumentRule(subcommands: ["--version"])

        return table
    }()

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

    /// Executables whose mere invocation is destructive.
    ///
    /// Matched as whole tokens, not substrings: `"dd "` as a substring also matches
    /// the `add ` in `git remote add`, which classified an unrelated command as a
    /// raw disk write and hid the fact that `git remote` was unguarded.
    private static let destructiveExecutables: [String: String] = [
        "sudo": "runs with elevated privileges",
        "doas": "runs with elevated privileges",
        "diskutil": "operates on disks",
        "launchctl": "changes launch services",
        "csrutil": "changes system integrity protection",
        "spctl": "changes gatekeeper policy",
        "shutdown": "shuts the machine down",
        "reboot": "restarts the machine",
        "halt": "halts the machine",
        "dd": "writes raw blocks",
        "shred": "irrecoverably erases data",
        "srm": "irrecoverably erases data",
        "chflags": "changes file protection flags",
    ]

    /// Multi-word forms that are destructive in context.
    private static let destructivePhrases: [(pattern: String, reason: String)] = [
        ("security delete", "deletes from the keychain"),
        ("security dump-keychain", "dumps keychain contents"),
        ("git push", "publishes to a remote"),
        ("git reset --hard", "discards local work"),
        ("git clean -f", "deletes untracked files"),
        ("git config credential.helper", "installs a git credential handler"),
        ("-delete", "deletes matched files"),
        ("-exec rm", "deletes matched files"),
        ("networksetup -set", "changes network configuration"),
        ("scutil --set", "changes system configuration"),
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
    public static func isSensitiveWrite(path candidate: String) -> String? {
        sensitiveWritePaths.first { path(candidate, isAtOrBeneath: $0) }
    }

    private static func expand(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Whether `path` is at or beneath `prefix`, compared case-insensitively.
    ///
    /// macOS volumes are case-insensitive by default, so `~/.SSH/id_rsa` and
    /// `~/.ssh/id_rsa` are the same file. A case-sensitive comparison here meant a
    /// single capital letter defeated the credential deny-list entirely.
    /// Every path check goes through this one function so the fix cannot be applied
    /// to some call sites and forgotten at others.
    static func path(_ path: String, isAtOrBeneath prefix: String) -> Bool {
        let resolved = expand(path).lowercased()
        let base = expand(prefix).lowercased()
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    private static func credentialPrefix(matching candidate: String) -> String? {
        deniedReadPaths.first { path(candidate, isAtOrBeneath: $0) }
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

        for phrase in destructivePhrases where normalized.contains(phrase.pattern) {
            return .destructive(reason: "\(summarize(command)) — \(phrase.reason)")
        }
        for segment in segments(normalized) {
            guard let first = segment.split(separator: " ").first else { continue }
            let executable = (String(first) as NSString).lastPathComponent
            if let reason = destructiveExecutables[executable] {
                return .destructive(reason: "\(summarize(command)) — \(reason)")
            }
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
    ///
    /// Fails closed at every step: an unknown executable, an unlisted subcommand, a
    /// denied flag or an unexpected operand all forfeit read-only status, because
    /// read-only status is what skips the permission gate.
    static func isReadOnlySegment(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }

        let executable = (first as NSString).lastPathComponent.lowercased()
        guard let rule = readOnlyCommands[executable] else { return false }

        let arguments = Array(tokens.dropFirst())

        // Action primaries turn a search into an executor regardless of the command.
        for argument in arguments {
            let lowered = argument.lowercased()
            if universallyDeniedPrefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
            if rule.deniedTokens.contains(lowered) { return false }
        }

        // A command with both a reading and a writing mode must name the reading one.
        // Compared against the *first* argument rather than the first non-flag token:
        // the reading mode is itself a flag for several of these (`plutil -p`), and
        // an unrecognised leading flag should fail closed rather than be skipped over.
        if let subcommands = rule.subcommands {
            guard let subcommand = arguments.first?.lowercased(),
                  subcommands.contains(subcommand) else { return false }
        }

        if let maxOperands = rule.maxOperands {
            let operands = arguments.filter { !$0.hasPrefix("-") }
            guard operands.count <= maxOperands else { return false }
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

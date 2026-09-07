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

    /// What this mode does, without repeating its own name.
    ///
    /// It used to begin with the mode name, and every caller prefixed that name too —
    /// so the system prompt read "Permission mode: ask — ask — you approve each
    /// action". Visible only by rendering the request and reading it.
    public var explanation: String {
        switch self {
        case .readOnly: return "mutating actions are refused"
        case .ask: return "you approve each action that changes state"
        case .auto: return "writes run automatically, destructive actions still ask"
        case .bypass: return "nothing prompts"
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
        /// Options this command may carry and still only read.
        ///
        /// An allowlist, not a denylist. Denying known-bad options means every option
        /// nobody has thought about yet is permitted — which is how `man -P`,
        /// `git --output`, `sort -o` and `rg --pre` each arrived. `nil` means the
        /// command takes no options that could matter.
        var allowedOptions: Set<String> = []
        /// Maximum non-flag arguments. A second operand is often an output file
        /// (`uniq in out`), which is a write with no flag to give it away.
        var maxOperands: Int?
        /// Non-flag arguments must begin with this. `date +%s` formats the clock;
        /// `date 0830` sets it, and neither carries a flag to tell them apart.
        var requiredOperandPrefix: String?
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
    /// `printenv`/`env` and `jq` (both dump the environment — `jq -n 'env'` reads it
    /// from inside the filter expression, where no flag rule can reach). Losing a
    /// prompt-free `awk` is a small price; letting `awk 'BEGIN{system(...)}'` skip
    /// the permission gate in every mode is not.
    /// Expands `"abc"` into `["-a", "-b", "-c"]`.
    private static func short(_ letters: String) -> Set<String> {
        Set(letters.map { "-\($0)" })
    }

    /// Digits, which several commands accept as a count (`head -20`, `git log -5`).
    private static let digitOptions = short("0123456789")

    /// Commands that can be read-only, and what it takes for them to be.
    ///
    /// Each entry allowlists the options that keep the command a read. An option not
    /// listed — including one that does not exist yet — forfeits read-only status and
    /// the call goes to the permission gate. That is the whole point: three audits
    /// found writing and executing modes hiding behind options nobody had enumerated
    /// (`man -P`, `git log --output`, `sort -o`, `hostname <name>`), and a denylist
    /// can only ever exclude the ones already known.
    ///
    /// Commands whose argument space cannot be constrained at all are simply absent,
    /// so they prompt: `awk` (`system()`), `sed` (`-i`, and `w` inside a script),
    /// `sqlite3` (arbitrary SQL), `networksetup` (`-set*`), `sysctl` (`-w`),
    /// `printenv`/`env` and `jq` (all dump the environment — `jq -n 'env'` reads it
    /// from inside the filter expression, where no option rule can reach).
    ///
    /// The cost of being wrong in the strict direction is a prompt; in the permissive
    /// direction it is a silent bypass of every permission mode. They are not
    /// comparable, so this table errs strict.
    public static let readOnlyCommands: [String: ArgumentRule] = {
        var table: [String: ArgumentRule] = [:]

        // Commands with no options worth constraining.
        for command in ["pwd", "whoami", "uname", "uptime", "sw_vers", "vm_stat"] {
            table[command] = ArgumentRule(allowedOptions: short("amnprsvo"))
        }

        table["ls"] = ArgumentRule(allowedOptions: short("aAbcCdefFgGhHiklmnopqrRsStTuUvwx1@") .union(["--color"]))
        table["cat"] = ArgumentRule(allowedOptions: short("benstuv"))
        table["head"] = ArgumentRule(allowedOptions: short("cnqv").union(digitOptions).union(["--lines", "--bytes"]))
        table["tail"] = ArgumentRule(allowedOptions: short("cnqvfFr").union(digitOptions).union(["--lines", "--bytes", "--follow"]))
        table["wc"] = ArgumentRule(allowedOptions: short("clmw"))
        table["file"] = ArgumentRule(allowedOptions: short("bhikLNnprsvz"))
        table["stat"] = ArgumentRule(allowedOptions: short("fFlLnqrstx"))
        table["basename"] = ArgumentRule(allowedOptions: short("as"))
        table["dirname"] = ArgumentRule()
        table["realpath"] = ArgumentRule(allowedOptions: short("qem"))
        table["readlink"] = ArgumentRule(allowedOptions: short("fn"))
        table["which"] = ArgumentRule(allowedOptions: short("as"))
        table["type"] = ArgumentRule(allowedOptions: short("aftpP"))
        table["df"] = ArgumentRule(allowedOptions: short("ahHiklmnPtT"))
        table["du"] = ArgumentRule(allowedOptions: short("acdghHklmnrsxI").union(["--max-depth"]))
        table["ps"] = ArgumentRule(allowedOptions: short("aAcefgGjlmnopruvwxU"))
        // `pgrep` and `pkill` are one binary — the same inode, hard-linked, choosing
        // its behaviour from `argv[0]`. That is exactly the shape this table is most
        // afraid of, so it was checked rather than assumed: invoked as `pgrep` the
        // binary rejects every signal flag as an illegal option (`-9`, `-HUP`,
        // `-TERM` all exit 2 with a usage line naming a strictly smaller option set
        // than `pkill`'s), and signalling is unreachable through this name. `pkill`
        // is deliberately absent, so it resolves no rule and prompts.
        //
        // Nothing here writes. `-F pidfile` is the only option that opens a file, it
        // reads a PID from it, and on failure it names the path without echoing a
        // byte of the contents — checked against a file of key-shaped text.
        //
        // Earning its place: `pgrep -l Code` cost 3.43s of a 14.6s recorded run,
        // every millisecond of it a person reading a permission prompt for a command
        // that only prints PIDs. `ps` has been read-only here all along, and this is
        // the same read of the same table.
        table["pgrep"] = ArgumentRule(allowedOptions: short("LafilnoqvxdFGPUgtu"))
        table["lsof"] = ArgumentRule(allowedOptions: short("acdFghilnPpRstUuwn"))
        table["ioreg"] = ArgumentRule(allowedOptions: short("abcdfilnprstwx"))
        table["system_profiler"] = ArgumentRule(allowedOptions: ["-xml", "-json", "-detaillevel", "-listdatatypes", "-timeout"])
        table["mdfind"] = ArgumentRule(allowedOptions: short("0lsn").union(["-onlyin", "-name", "-live", "-count", "-literal", "-interpret"]))
        table["mdls"] = ArgumentRule(allowedOptions: short("np").union(["-name", "-raw", "-nullmarker"]))
        table["echo"] = ArgumentRule(allowedOptions: short("neE"))
        table["cut"] = ArgumentRule(allowedOptions: short("bcdfns"))
        table["diff"] = ArgumentRule(allowedOptions: short("abBcdeghiInNpqrstuwyC0123456789").union([
            "--brief", "--unified", "--recursive", "--ignore-case", "--color", "--side-by-side",
        ]))

        let grepOptions = short("abcdDEFGhHiIJLlmnoOqRrsUvwxyzZ").union(digitOptions).union([
            "--include", "--exclude", "--exclude-dir", "--color", "--line-number",
            "--recursive", "--ignore-case", "--word-regexp", "--fixed-strings",
            "--extended-regexp", "--count", "--files-with-matches", "--invert-match",
            "--after-context", "--before-context", "--context", "--binary-files",
            "--null", "--no-messages", "--only-matching", "--regexp", "--file",
        ])
        for command in ["grep", "egrep", "fgrep"] {
            table[command] = ArgumentRule(allowedOptions: grepOptions)
        }

        // `rg --pre <cmd>` runs a program per file; absent, so it prompts.
        table["rg"] = ArgumentRule(allowedOptions: short("ceFgiLlmnNoqsStuvwxz").union(digitOptions).union([
            "--type", "--glob", "--hidden", "--no-ignore", "--files", "--count",
            "--line-number", "--ignore-case", "--fixed-strings", "--word-regexp",
            "--max-count", "--context", "--after-context", "--before-context",
            "--color", "--json", "--only-matching", "--files-with-matches",
        ]))
        // `fd -x`/`-X`/`--exec*` run a program per result; absent.
        table["fd"] = ArgumentRule(allowedOptions: short("HIispLatdelc0u").union(digitOptions).union([
            "--type", "--extension", "--hidden", "--no-ignore", "--glob",
            "--absolute-path", "--max-depth", "--full-path", "--color",
        ]))

        // find's grammar is primaries, not flags. Action primaries (-exec, -delete,
        // -ok, -fprint, -fls) are simply not listed, so they gate — as does any
        // action primary added to find in future.
        table["find"] = ArgumentRule(allowedOptions: short("HLPEdfsxX").union([
            "-name", "-iname", "-type", "-path", "-ipath", "-regex", "-iregex",
            "-maxdepth", "-mindepth", "-size", "-empty", "-perm", "-depth",
            "-mtime", "-atime", "-ctime", "-mmin", "-amin", "-cmin", "-newer",
            "-user", "-group", "-nouser", "-nogroup", "-lname", "-ilname",
            "-print", "-print0", "-printf", "-ls", "-prune", "-follow",
            "-not", "-and", "-or", "-a", "-o", "-true", "-false",
        ]))

        // `-P`/`--pager` makes man eval a command. Absent.
        table["man"] = ArgumentRule(allowedOptions: short("adfhkKtwW").union(["--all", "--where", "--path"]))
        // `-o`/`--output` writes a file. Absent.
        table["sort"] = ArgumentRule(allowedOptions: short("bcCdfghiMmnrRsStuVz").union(digitOptions).union([
            "--reverse", "--numeric-sort", "--unique", "--key", "--field-separator",
            "--human-numeric-sort", "--version-sort", "--ignore-case", "--check",
        ]))
        table["uniq"] = ArgumentRule(allowedOptions: short("cdDfisu").union(digitOptions), maxOperands: 1)
        // `-o`/`--output` writes a file. Absent.
        table["tree"] = ArgumentRule(allowedOptions: short("adfghilnpqrstuvxACDFJLNPRSUX").union(digitOptions).union([
            "--dirsfirst", "--noreport", "--charset", "--filelimit", "--du", "--prune",
        ]))

        // Query-looking commands with a setting mode reached without any flag.
        table["hostname"] = ArgumentRule(maxOperands: 0)          // `hostname newname` sets it
        table["date"] = ArgumentRule(allowedOptions: short("ur").union(["-j", "-f", "-v", "-R"]),
                                     requiredOperandPrefix: "+")  // `date 0830` sets the clock

        // Read only in an explicitly named reading mode.
        //
        // `git config`, `remote`, `branch` and `tag` are absent: each has a read and
        // a write form distinguished only by later arguments, and
        // `git config credential.helper '!curl …'` installs a credential exfiltrator.
        // `--output` writes the commit message verbatim to a file; `--ext-diff` and
        // `--textconv` run programs named by the repository's own config. None are
        // listed, so all three gate.
        table["git"] = ArgumentRule(
            subcommands: [
                "status", "log", "diff", "show", "ls-files", "rev-parse",
                "describe", "blame", "shortlog",
            ],
            allowedOptions: short("nspvqwSMCULl").union(digitOptions).union([
                "--oneline", "--graph", "--stat", "--shortstat", "--numstat",
                "--format", "--pretty", "--decorate", "--abbrev-commit", "--date",
                "--all", "--since", "--until", "--author", "--grep", "--reverse",
                "--name-only", "--name-status", "--follow", "--cached", "--staged",
                "--short", "--porcelain", "--color", "--no-color", "--unified",
                "--word-diff", "--patch", "--no-patch", "--summary", "--branch",
                "--untracked-files", "--merges", "--no-merges", "--first-parent",
            ])
        )
        table["brew"] = ArgumentRule(
            subcommands: ["list", "info", "search", "outdated", "config", "--version"],
            allowedOptions: short("v1").union(["--versions", "--json", "--formula", "--cask", "--quiet"])
        )
        table["defaults"] = ArgumentRule(subcommands: ["read", "read-type", "domains", "find"],
                                         allowedOptions: ["-app", "-currenthost", "-host", "-g", "-globaldomain"])
        table["plutil"] = ArgumentRule(subcommands: ["-p", "-lint"], allowedOptions: ["-s", "-p", "-lint"])
        table["pmset"] = ArgumentRule(subcommands: ["-g"], allowedOptions: ["-g"])
        // `simctl` is absent: `xcrun simctl erase all` wipes every simulator.
        table["xcrun"] = ArgumentRule(subcommands: ["--find", "--show-sdk-version", "--show-sdk-path"],
                                       allowedOptions: ["--find", "--show-sdk-version", "--show-sdk-path", "--sdk"])
        // `swift build`/`test` write to .build, so only --version reads.
        table["swift"] = ArgumentRule(subcommands: ["--version"], allowedOptions: ["--version"])

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
        // Privilege and privacy configuration. `tccutil reset All` wipes every
        // permission the user has granted anything on the machine, and both of these
        // ran silently in auto mode because "resets a database" looks like a write.
        "tccutil": "resets the privacy permissions the user has granted",
        "systemsetup": "changes system configuration",
        // `security find-generic-password -w` prints a stored password on stdout,
        // which is a tool result: it would reach the model and the transcript. The
        // deny-list caught `dump-keychain` as a phrase and missed the executable.
        "security": "reads and modifies the keychain",
        // AppleScript cannot be sandboxed, which is why `app_script` classifies its
        // shell escapes as destructive — and why reaching osascript through `shell`
        // must not be the cheaper way to get the same thing.
        "osascript": "runs AppleScript, which no sandbox confines",
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
        return substitutingHome(in: collapsed.lowercased())
    }

    /// Rewrites the shell's own spellings of the home directory to `~`.
    ///
    /// Done here rather than at a call site, so both the deny-list and the classifier
    /// see the same command: `cat $HOME/.ssh/id_rsa` walked past the credential
    /// deny-list and classified as `.read`, which skips the gate in every mode. Under
    /// the sandbox it was refused, so this was defence in depth working while the
    /// layer above silently did not — but `--no-sandbox` is a documented flag, and
    /// with it that command printed the private key.
    ///
    /// Only the literal spellings. A path a script assembles at runtime is beyond
    /// static matching, which is what the sandbox is for. `$HOME` is not assembled; it
    /// is spelled, and spelling it should never have been enough.
    static func substitutingHome(in command: String) -> String {
        // A boundary is required after the name, or `$HOMEBREW_PREFIX` becomes
        // `~BREW_PREFIX` — the same substring mistake this file documents for verbs,
        // where "get " matched inside "budget".
        let pattern = #"\$(?:\{home\}|home(?![A-Za-z0-9_]))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return command }
        return regex.stringByReplacingMatches(
            in: command, range: NSRange(command.startIndex..., in: command), withTemplate: "~"
        )
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

    /// The agent's own executable, and its `.app` bundle when it has one.
    ///
    /// Resolved once at startup. Writing to the image you are currently running is
    /// never a task worth doing without asking: it replaces the thing the user
    /// approved with something they did not, and every rule in this file lives inside
    /// it. The same reasoning as refusing to answer one's own consent dialogs — a
    /// constraint its subject can rewrite is not a constraint.
    static let runningImagePaths: [String] =
        imagePaths(forExecutable: CommandLine.arguments.first ?? "")

    /// The executable itself, plus any `.app` bundle enclosing it.
    ///
    /// Separated from the runtime lookup so both halves can be tested: the walk needs
    /// a bundle layout to exercise, and the test binary lives in Xcode's toolchain.
    static func imagePaths(forExecutable executable: String) -> [String] {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        guard !executable.isEmpty else { return [] }
        var paths = [resolved.path]

        // Walk up to an enclosing .app, so replacing any part of the bundle counts,
        // not only the one file currently executing. `Contents/Helpers/openclicky` is
        // three levels down, so four steps covers it with one to spare.
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<4 {
            if directory.pathExtension == "app" {
                paths.append(directory.path)
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return paths
    }

    /// Whether a write to this path establishes persistence or alters security posture.
    public static func isSensitiveWrite(path candidate: String) -> String? {
        for image in runningImagePaths where path(candidate, isAtOrBeneath: image) {
            return "the agent's own program"
        }
        return sensitiveWritePathMatch(candidate)
    }

    private static func sensitiveWritePathMatch(_ candidate: String) -> String? {
        sensitiveWritePaths.first { path(candidate, isAtOrBeneath: $0) }
    }

    /// Resolves a path the way the kernel will when the file is opened.
    ///
    /// `standardizingPath` collapses `..` and expands `~` but does **not** follow
    /// symlinks, while `open()` does. Comparing the unresolved string meant a symlink
    /// named `notes.txt` pointing at `~/.ssh/id_rsa` passed the credential deny-list
    /// and was then read straight through — a malicious repo or archive can create
    /// such a link on checkout.
    ///
    /// Resolution is applied to the deepest existing ancestor, so a path that does
    /// not exist yet (a file about to be created) still has its directory chain
    /// resolved — otherwise a symlinked *directory* would reopen the same hole.
    private static func expand(_ path: String) -> String {
        let expanded = (substitutingHome(in: path) as NSString).expandingTildeInPath as NSString
        let standardized = expanded.standardizingPath
        let url = URL(fileURLWithPath: standardized)

        if FileManager.default.fileExists(atPath: standardized) {
            return url.resolvingSymlinksInPath().path
        }

        // Resolve the parent chain, then re-attach the leaf.
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return standardized }
        return parent.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }
    // MARK: - Secrets in output

    /// Whether a command's *output* is itself a credential.
    ///
    /// Classifying the action was only half of it. Approving `security
    /// find-generic-password -w` because the prompt said "reads the keychain" also
    /// sent the password to the model and wrote it into the session record, which is
    /// kept in full and never pruned — a consequence the approval never named. The
    /// action is the user's to allow; transmitting the secret is a separate decision
    /// they were never asked about.
    ///
    /// Deliberately narrow. A general secret-detector applied to every tool result
    /// would misfire on ordinary output, and a redactor nobody trusts gets removed.
    public static func printsSecret(_ command: String) -> Bool {
        let lowered = command.lowercased()
        // An AppleScript reaches the same credential as `do shell script "security …"`,
        // where the segment's first token is `do`. The embedded command is extracted
        // and analysed as a command rather than loosening the match to a substring
        // search, which would flag `grep -w security notes.txt`.
        for embedded in embeddedShellScripts(in: lowered) where printsSecret(embedded) {
            return true
        }
        for segment in segments(lowered) {
            guard realExecutable(of: segment) == "security" else { continue }
            let tokens = segment.split(separator: " ").map(String.init)
            let (options, _) = normalizedArguments(Array(tokens.dropFirst()))
            // `-w` prints the password alone; dump-keychain -d prints every item's data.
            if options.contains(where: { $0.whole == "-w" }) { return true }
            if tokens.contains("dump-keychain") { return true }
        }
        return false
    }

    /// The shell commands an AppleScript would run through `do shell script`.
    private static func embeddedShellScripts(in script: String) -> [String] {
        let pattern = #"do shell script\s+"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(script.startIndex..., in: script)
        return regex.matches(in: script, range: range).compactMap { match in
            Range(match.range(at: 1), in: script).map { String(script[$0]) }
        }
    }

    /// What a tool should return in place of output that is a credential.
    public static let withheldSecretNote = """
        [Output withheld: this command prints a stored credential, and a tool result is \
        sent to the model and written to the session record. The command ran; its output \
        was not captured. If the user needs the value, they should run the command \
        themselves in a terminal.]
        """

    // MARK: - Security surfaces

    /// Processes that own the windows through which macOS grants privileges.
    ///
    /// `UserNotificationCenter` draws the Automation and TCC consent alerts,
    /// `SecurityAgent` the authorisation and admin-password prompts, and System
    /// Settings hosts the Privacy & Security panes.
    static let securitySurfaces: Set<String> = [
        "com.apple.UserNotificationCenter",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences",
        "com.apple.loginwindow",
        // Keychain Access reveals a stored password in cleartext, and edits an item's
        // access-control list so an app never has to ask again — the GUI equivalents
        // of `security find-generic-password -w` and `set-generic-password-partition-list`.
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// Whether the frontmost app is one where a click grants a privilege.
    ///
    /// The containment model assumes the user decides what this agent may do. But the
    /// dialog that asks them is an ordinary window with an ordinary button, so
    /// `ax_press` on "Allow" classified as a routine write and ran unprompted in auto
    /// mode — the agent granting itself Automation access, or toggling Accessibility
    /// in System Settings. A permission gate its subject can operate is not a gate.
    public static func isSecuritySurface(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return securitySurfaces.contains(bundleIdentifier)
    }

    /// Process and app names for the same surfaces, as a script would write them.
    ///
    /// The frontmost check cannot see this route: `tell application "System Events" to
    /// tell process "System Settings"` drives another process without activating it,
    /// and a risk is classified before the script runs, when the frontmost app is
    /// still whatever it was. Matched on the text instead, the way the deny-list is.
    /// Display names *and* bundle identifiers. AppleScript addresses an app either
    /// way — `tell application id "com.apple.systempreferences"`, or `first process
    /// whose bundle identifier is "…"` — and matching only the human-readable name
    /// missed both forms, while the frontmost check missed them too because neither
    /// activates anything.
    private static let securitySurfaceNames =
        securitySurfaces.map { $0.lowercased() } + [
            "usernotificationcenter", "securityagent", "loginwindow",
            "system settings", "system preferences", "keychain access", "passwords",
        ]

    /// Whether a script names one of the windows that grant privileges.
    public static func namesSecuritySurface(_ script: String) -> Bool {
        let lowered = script.lowercased()
        return securitySurfaceNames.contains { lowered.contains($0) }
    }

    /// Raises a risk when the action would land on a security surface.
    ///
    /// Applied centrally rather than per tool: `ax_press`, `click`, `key` and
    /// `app_script` (through System Events UI scripting) all reach that Allow button,
    /// and a check each of them has to remember is a check three of them will
    /// eventually forget. Reads are untouched — looking at a consent dialog is how the
    /// agent tells the user what it is waiting for.
    /// Present only so the mutation sweep can neutralise `escalate` with something
    /// that compiles. Never call it.
    static func identity(_ risk: Risk, frontmostBundleIdentifier: String?,
                         targetBundleIdentifier: String? = nil) -> Risk { risk }

    public static func escalate(
        _ risk: Risk,
        frontmostBundleIdentifier: String?,
        targetBundleIdentifier: String? = nil
    ) -> Risk {
        let reaches = isSecuritySurface(frontmostBundleIdentifier)
            || isSecuritySurface(targetBundleIdentifier)
        guard reaches else { return risk }
        switch risk {
        case .read:
            return risk
        case let .write(summary), let .dangerous(summary):
            return .dangerous(summary: """
                \(summary) — acts on a macOS security dialog, where permissions are \
                granted. Only the user can answer that.
                """)
        }
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
        // Every token that could name a file, canonicalised, then compared with the
        // one comparison this file trusts. Substring-matching the command text missed
        // `~user/.ssh/id_rsa`, `~/Documents/../.ssh/id_rsa`, `~/./.ssh/id_rsa` and
        // `~//.ssh//id_rsa` — four spellings of a single file. The lesson is one this
        // file already states for case sensitivity: compare paths through
        // `path(_:isAtOrBeneath:)`, never as text.
        let walk = pathLikeTokens(in: normalized)
        // The denied paths are expanded once, not once per token. Nested inside the
        // loop this was a filesystem resolution for every (token, denied path) pair —
        // the same dozen constants re-resolved hundreds of times.
        let denied: [(raw: String, expanded: String)] = deniedReadPaths.map {
            ($0, expand($0))
        }
        for token in walk.tokens {
            let candidate = expand(token)
            for entry in denied where path(candidate, isAtOrBeneath: entry.expanded) {
                return entry.raw
            }
        }
        // A command with more paths than the walk will examine cannot be cleared,
        // because the one that matters may be the one past the cap. Capping the walk
        // without this made `cat <80 paths> ~/.ssh/id_rsa` pass — padding as a bypass,
        // introduced by the very change that was meant to bound the cost.
        return walk.truncated ? "more paths than can be checked" : nil
    }

    /// The tokens in a command that could name a file.
    ///
    /// Tokens made relative by an earlier `cd` are included: `cd ~ && cat .ssh/id_rsa`
    /// reaches the same file as `cat ~/.ssh/id_rsa`, and refusing one while allowing
    /// the other is not a deny-list, it is a spelling test.
    /// How many distinct path tokens are examined before a command is simply refused
    /// read-only status.
    ///
    /// Each token costs a filesystem resolution, and the token count comes from input
    /// the model writes: sixty operands measured at 50ms, and nothing bounded it above
    /// that. Past the cap the command is not analysed further and therefore cannot be
    /// proved read-only, which is the safe direction — a prompt, not a bypass.
    private static let pathTokenBudget = 512

    static func pathLikeTokens(in command: String) -> (tokens: [String], truncated: Bool) {
        var tokens: [String] = []
        var seen: Set<String> = []
        var workingDirectory: String?

        for segment in segments(command) {
            let words: [String] = segment.split(separator: " ").map(String.init)
            guard let head = words.first else { continue }

            if head == "cd" {
                let operands: [String] = words.dropFirst().filter { !$0.hasPrefix("-") }
                if let target = operands.first {
                    let resolved = expand(target)
                    workingDirectory = resolved
                    // The destination is evidence in itself. `cd ~/.ssh && cat id_rsa`
                    // names the file with a bare word that looks like nothing, so the
                    // directory is the only part of the command that gives it away.
                    if seen.insert(resolved).inserted { tokens.append(resolved) }
                }
                continue
            }

            for word in words.dropFirst() {
                if word.hasPrefix("-") { continue }
                if word.hasPrefix("~") || word.hasPrefix("/") {
                    if seen.insert(word).inserted { tokens.append(word) }
                    if tokens.count >= pathTokenBudget { return (tokens, true) }
                    continue
                }
                guard let base = workingDirectory else { continue }
                if word.contains("/") || word.hasPrefix(".") {
                    let joined = "\(base)/\(word)"
                    if seen.insert(joined).inserted { tokens.append(joined) }
                    if tokens.count >= pathTokenBudget { return (tokens, true) }
                }
            }
        }
        return (tokens, false)
    }

    // MARK: - Classification

    /// Classifies a shell command.
    ///
    /// Read-only status requires that *every* segment provably reads: a known
    /// read-only leading command, an allowlisted subcommand where one is required,
    /// no redirection, and no construct that defeats static analysis. Anything else
    /// is mutating or destructive.
    public static func classifyShell(
        _ command: String, executableTrust: ExecutableTrust = filesystemExecutableTrust
    ) -> Classification {
        let normalized = normalize(command)

        for phrase in destructivePhrases where normalized.contains(phrase.pattern) {
            return .destructive(reason: "\(summarize(command)) — \(phrase.reason)")
        }
        for segment in segments(normalized) {
            guard let executable = realExecutable(of: segment) else { continue }
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
        // Any path a non-reading command names, not only a redirection target.
        // `cp /tmp/x.plist ~/Library/LaunchAgents/` installs a launch agent — the same
        // persistence as `echo … > ~/Library/LaunchAgents/x.plist`, which was already
        // destructive — with no `>` anywhere in it, so it classified as an ordinary
        // write and ran unprompted in auto mode. Reaching a sensitive path is what
        // matters; the syntax used to reach it is not.
        //
        // Reached only after the read-only test has failed, so `ls ~/Library/
        // LaunchAgents` and `cat ~/.zshrc` are unaffected: reading these paths is
        // ordinary, and it is writing them that establishes persistence.
        for construct in opaqueConstructs where command.contains(construct) {
            return .mutating(reason: "\(summarize(command)) — contains \(construct), whose effect cannot be determined in advance")
        }
        if command.contains(">") || command.contains("<") {
            return .mutating(reason: "\(summarize(command)) — redirects output")
        }

        let parts = segments(command)
        guard !parts.isEmpty else { return .mutating(reason: summarize(command)) }

        for segment in parts where !isReadOnlySegment(segment, executableTrust: executableTrust) {
            // The command is not a read, so any sensitive path it names is a path it
            // may be writing. `cp /tmp/x.plist ~/Library/LaunchAgents/` installs a
            // launch agent — the same persistence as the redirection form, which was
            // already destructive — with no `>` anywhere in it, so it classified as an
            // ordinary write and ran unprompted in auto mode. What matters is reaching
            // the path, not the syntax used to reach it.
            //
            // Deliberately after the read-only test rather than before it: placed
            // earlier, this made `cat ~/.zshrc` and `ls ~/Library/LaunchAgents`
            // destructive. Reading shell config is ordinary; writing it is persistence.
            let walk = pathLikeTokens(in: normalized)
            for token in walk.tokens {
                if let sensitive = isSensitiveWrite(path: expand(token)) {
                    return .destructive(reason: "\(summarize(command)) — writes to \(sensitive)")
                }
            }
            if walk.truncated {
                return .destructive(reason: """
                    \(summarize(command)) — names more paths than can be checked, so \
                    whether it writes a sensitive one is not knowable in advance
                    """)
            }
            return .mutating(reason: summarize(command))
        }
        return .readOnly
    }

    /// Commands whose whole job is to run another command.
    ///
    /// Reading only a segment's first token let any of these hide the real target:
    /// `env security find-generic-password -w -s login` classified as an ordinary
    /// write, so in auto mode it ran unprompted and printed a stored password into a
    /// tool result. Not solved by scanning every token — `grep -rn security ~/notes`
    /// would then be destructive — so the wrappers are named and stepped through.
    private static let commandWrappers: Set<String> = [
        "env", "nice", "nohup", "time", "command", "builtin", "stdbuf",
        "timeout", "gtimeout", "setsid", "script", "caffeinate",
    ]

    /// The executable a segment will actually run, stepping past any wrappers.
    static func realExecutable(of segment: String) -> String? {
        var tokens = segment.split(separator: " ").map(String.init)

        // Bounded: a chain long enough to exhaust this is not a real command line, and
        // an unbounded walk over attacker-shaped input is its own problem.
        for _ in 0..<8 {
            guard let first = tokens.first else { return nil }
            let name = (first as NSString).lastPathComponent.lowercased()
            guard commandWrappers.contains(name) else { return name }

            // Step past the wrapper and its own options. `env FOO=bar cmd` also
            // assigns variables first, which are not the command either.
            tokens = Array(tokens.dropFirst()).drop {
                $0.hasPrefix("-") || ($0.contains("=") && !$0.hasPrefix("/"))
            }.map { $0 }
        }
        return nil
    }

    /// The options and operands an argument list actually expresses.    /// The options and operands an argument list actually expresses.
    ///
    /// Matching denied options against raw tokens is unsound, because a token is not
    /// an option: `--output=/tmp/x` expresses `--output`, and `-ro` expresses both
    /// `-r` and `-o`. Exact-token matching saw neither, so `sort -ro out in` and
    /// `sort --output=out in` both wrote files while classified read-only.
    ///
    /// This is the same mistake as substring-matching verbs, in a different guise:
    /// comparing surface form instead of meaning. Normalise first, then match.
    /// One option token and the ways it can legitimately be read.
    ///
    /// A single-dash token is ambiguous: `-la` is the bundle `-l -a`, while `-name`
    /// is one option that `find` and `mdfind` spell with a single dash. Both
    /// readings are kept and the caller accepts the token if *either* is permitted —
    /// which lets `-name` through without letting `-ro` smuggle in `-o`.
    struct OptionToken: Equatable {
        /// The token as written, minus any `=value`.
        let whole: String
        /// Its letters, when it could be a short bundle. Empty for `--long` forms.
        let letters: Set<String>

        func isPermitted(by allowed: Set<String>) -> Bool {
            if allowed.contains(whole) { return true }
            return !letters.isEmpty && letters.isSubset(of: allowed)
        }
    }

    static func normalizedArguments(_ arguments: [String]) -> (options: [OptionToken], operands: [String]) {
        var options: [OptionToken] = []
        var operands: [String] = []
        var optionsEnded = false

        for argument in arguments {
            let token = argument.lowercased()

            if optionsEnded || token == "-" || !token.hasPrefix("-") {
                operands.append(argument)
                continue
            }
            // A bare `--` ends option parsing; everything after it is an operand.
            if token == "--" {
                optionsEnded = true
                continue
            }

            // `--flag=value` expresses `--flag`; a long option is never a bundle.
            let whole = String(token.split(separator: "=", maxSplits: 1).first ?? "")
            if token.hasPrefix("--") {
                options.append(OptionToken(whole: whole, letters: []))
            } else {
                options.append(OptionToken(
                    whole: whole,
                    letters: Set(whole.dropFirst().map { "-\($0)" })
                ))
            }
        }
        return (options, operands)
    }

    /// Whether one segment — a single command with its arguments — only observes.
    ///
    /// Fails closed at every step: an unknown executable, an unlisted subcommand, a
    /// denied flag or an unexpected operand all forfeit read-only status, because
    /// read-only status is what skips the permission gate.
    /// Directories whose contents the read-only classification is willing to trust.
    ///
    /// Anything outside them is something the agent, or the task, could have put
    /// there.
    private static let trustedExecutableDirectories = [
        "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/libexec",
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
    ]

    /// Whether a command token resolves to a binary in a trusted system location.
    ///
    /// Fails closed: an executable that cannot be found is not read-only either. That
    /// costs nothing — the command was going to fail — and avoids a rule that depends
    /// on which of two lookups happens first.
    /// How the classifier decides whether an executable is trustworthy.
    ///
    /// A parameter rather than a hard filesystem call, because otherwise the suite's
    /// result depends on which binaries a machine happens to have installed: `tree` is
    /// in the read-only table, and on a machine without it every test asserting `tree`
    /// reads would fail. Production always passes the filesystem check.
    public typealias ExecutableTrust = @Sendable (String) -> Bool

    /// Trusts anything. For tests that are about argument rules, not binaries.
    public static let trustAllExecutables: ExecutableTrust = { _ in true }

    public static let filesystemExecutableTrust: ExecutableTrust = { isTrustedExecutable($0) }

    static func isTrustedExecutable(_ token: String) -> Bool {
        let candidates: [String]
        if token.contains("/") {
            candidates = [(token as NSString).expandingTildeInPath]
        } else {
            candidates = trustedExecutableDirectories.map { "\($0)/\(token)" }
        }

        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard FileManager.default.isExecutableFile(atPath: resolved) else { continue }
            let directory = (resolved as NSString).deletingLastPathComponent
            if trustedExecutableDirectories.contains(where: {
                path(directory, isAtOrBeneath: $0)
            }) { return true }
        }
        return false
    }

    static func isReadOnlySegment(
        _ segment: String, executableTrust: ExecutableTrust = filesystemExecutableTrust
    ) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }

        let executable = (first as NSString).lastPathComponent.lowercased()
        guard let rule = readOnlyCommands[executable] else { return false }
        // The name is not the binary. `cp /usr/bin/osascript /tmp/rg` then
        // `/tmp/rg -e '<script>'` matched `rg`'s read-only rule — whose options happen
        // to include `-e` with an operand — and a `.read` skips the gate in every
        // mode, `read-only` included. So this was unprompted arbitrary execution by
        // renaming a file. The project already knew allowlisting an executable is not
        // enough for *arguments*; it was still trusting the executable's own identity.
        guard executableTrust(first) else { return false }

        let arguments = Array(tokens.dropFirst())
        let (options, operands) = normalizedArguments(arguments)

        // Action primaries turn a search into an executor regardless of the command.
        for argument in arguments {
            let lowered = argument.lowercased()
            if universallyDeniedPrefixes.contains(where: { lowered.hasPrefix($0) }) { return false }
        }
        // Every option must be recognised. An unrecognised one is not assumed
        // harmless — that assumption is what three audits kept falsifying.
        guard options.allSatisfy({ $0.isPermitted(by: rule.allowedOptions) }) else { return false }

        // A command with both a reading and a writing mode must name the reading one.
        // Compared against the *first* argument rather than the first non-flag token:
        // the reading mode is itself a flag for several of these (`plutil -p`), and
        // an unrecognised leading flag should fail closed rather than be skipped over.
        if let subcommands = rule.subcommands {
            guard let subcommand = arguments.first?.lowercased(),
                  subcommands.contains(subcommand) else { return false }
        }

        if let maxOperands = rule.maxOperands {
            guard operands.count <= maxOperands else { return false }
        }
        if let prefix = rule.requiredOperandPrefix {
            guard operands.allSatisfy({ $0.hasPrefix(prefix) }) else { return false }
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

    /// Renders a command for the approval prompt.
    ///
    /// Strips control characters rather than just newlines. The prompt is the whole
    /// basis of consent — the user approves what they were shown — and a raw ESC or
    /// CR in the summary can reposition the cursor and overwrite the badge and text
    /// already printed above it, so the line the user reads is not the command that
    /// runs. Escapes are made visible instead of removed silently, because a command
    /// containing them is itself worth seeing.
    static func summarize(_ command: String) -> String {
        var rendered = ""
        for character in command {
            if character == "\n" || character == "\r" {
                rendered += " ⏎ "
            } else if character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) {
                for scalar in character.unicodeScalars {
                    rendered += String(format: "\\x%02X", scalar.value)
                }
            } else {
                rendered.append(character)
            }
        }
        return abbreviateMiddle(rendered, to: 300)
    }

    /// Shortens a command for display without hiding its end.
    ///
    /// Head-only truncation is unsafe in a consent prompt: a long chain can put its
    /// operative part past the cut, so the user reads `mkdir a && mkdir b && …` and
    /// approves something that ends in `mv ~/Documents /tmp`. Both ends are kept, and
    /// the elision says how much is missing so a suspiciously long command is visible
    /// as such.
    static func abbreviateMiddle(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        let half = (budget - 20) / 2
        let removed = text.count - (half * 2)
        return "\(text.prefix(half)) … [\(removed) more] … \(text.suffix(half))"
    }
}

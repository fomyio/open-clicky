import Testing
import Foundation
@testable import OpenClickyKit

/// The CLI reads approvals from the terminal while the tools it gates spawn
/// subprocesses. Those two share a file descriptor, and until recently a child
/// inheriting stdin would consume the keystrokes meant for the prompt — so a
/// command like `cat` did not merely hang, it ate the user's answer.
@Suite("Approval flow", .serialized)
struct ApprovalFlowTests {

    /// Stands in for the terminal: a pipe the prompt reads a line at a time.
    private final class FakeTerminal: @unchecked Sendable {
        private let pipe = Pipe()
        private var buffer = Data()

        init(typing answers: [String]) {
            pipe.fileHandleForWriting.write(Data(answers.map { $0 + "\n" }.joined().utf8))
            try? pipe.fileHandleForWriting.close()
        }

        /// Reads one line, as `readLine()` does for the real CLI.
        func readLine() -> String? {
            while !buffer.contains(0x0A) {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                defer { buffer.removeAll() }
                return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
            }
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            return String(decoding: line, as: UTF8.self)
        }
    }

    /// The regression: a subprocess between two prompts must not consume the second
    /// answer. Before stdin was explicitly set, the child inherited the descriptor
    /// and swallowed it.
    @Test("A subprocess between two prompts does not eat the second answer")
    func subprocessDoesNotConsumeApprovals() async throws {
        let terminal = FakeTerminal(typing: ["y", "n"])
        let answers = Answers()

        let gate = PermissionGate(mode: .ask) { _, _, _ in
            let line = terminal.readLine()
            await answers.record(line)
            return line == "y"
        }

        let first = await gate.decide(tool: "shell", risk: .write(summary: "first"))
        #expect(first == .allow)

        // Exactly what would have stolen the next answer.
        _ = try await Subprocess.run(
            executable: "/bin/cat", arguments: [], timeout: 5
        )
        _ = try await Subprocess.run(
            executable: "/bin/zsh", arguments: ["-c", "sort"], timeout: 5
        )

        let second = await gate.decide(tool: "shell", risk: .write(summary: "second"))
        guard case .deny = second else {
            Issue.record("the second answer was lost; got \(second)")
            return
        }
        #expect(await answers.all == ["y", "n"])
    }

    @Test("Destructive actions prompt every time, even after always-allow")
    func destructiveAlwaysPrompts() async throws {
        let terminal = FakeTerminal(typing: ["a", "y", "n"])
        let answers = Answers()

        let gate = PermissionGate(mode: .ask) { _, _, _ in
            let line = terminal.readLine()
            await answers.record(line)
            return line == "y" || line == "a"
        }

        // "always allow" for this tool.
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir")) == .allow)
        await gate.alwaysAllow("shell")

        // A plain write now passes silently, consuming no answer.
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "touch")) == .allow)
        #expect(await answers.all.count == 1, "an allowlisted write must not ask")

        // A destructive one still asks, and the next answer is the one it gets.
        #expect(await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -rf")) == .allow)
        #expect(await answers.all == ["a", "y"])

        let denied = await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -rf again"))
        guard case .deny = denied else {
            Issue.record("expected the third answer to deny")
            return
        }
    }

    /// Everything the CLI treats as consent, and nothing it does not.
    @Test("Only an explicit yes is consent", arguments: [
        ("y", true), ("yes", true), ("a", true), ("always", true),
        ("n", false), ("no", false), ("", false), ("maybe", false), ("Y ", true),
    ])
    func consentParsing(pair: (String, Bool)) {
        // Mirrors main.swift's parsing so a divergence shows up here.
        let answer = pair.0.lowercased().trimmingCharacters(in: .whitespaces)
        let approved = answer == "y" || answer == "yes" || answer == "a" || answer == "always"
        #expect(approved == pair.1, "'\(pair.0)' should \(pair.1 ? "" : "not ")be consent")
    }

    private actor Answers {
        private(set) var all: [String?] = []
        func record(_ answer: String?) { all.append(answer) }
    }
}

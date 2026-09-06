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
            return line == "y" ? .allow : .deny
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
            switch line {
            case "a": return .allowAlways
            case "y": return .allow
            default: return .deny
            }
        }

        // "always allow" for this tool, granted the only way it can be: by asking.
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir")) == .allow)

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

    /// "Always allow" was offered in the prompt, implemented in the gate, tested in
    /// the gate, described in the README — and connected to nothing. Answering it
    /// approved one action and asked again next time, because no caller ever told the
    /// gate. Found by reading the prompt code rather than testing around it.
    @Test("Always-allow actually stops the asking")
    func alwaysAllowIsHonoured() async {
        let terminal = FakeTerminal(typing: ["a", "y"])
        let answers = Answers()

        let gate = PermissionGate(mode: .ask) { _, _, _ in
            let line = terminal.readLine()
            await answers.record(line)
            switch line {
            case "a": return .allowAlways
            case "y": return .allow
            default: return .deny
            }
        }

        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir a")) == .allow)
        #expect(await answers.all == ["a"])

        // The next two writes must not ask at all — the "y" is never consumed.
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir b")) == .allow)
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir c")) == .allow)
        #expect(await answers.all == ["a"], "the grant did not stick; it asked again")

        // A different tool is not covered by it.
        _ = await gate.decide(tool: "write_file", risk: .write(summary: "create x"))
        #expect(await answers.all == ["a", "y"], "the grant leaked to another tool")
    }

    /// Offering a choice that cannot be honoured is worse than not offering it.
    @Test("Always-allow on a destructive action approves once and no more")
    func alwaysAllowNeverCoversDestructive() async {
        let terminal = FakeTerminal(typing: ["a", "a"])
        let answers = Answers()

        let gate = PermissionGate(mode: .ask) { _, _, _ in
            let line = terminal.readLine()
            await answers.record(line)
            return line == "a" ? .allowAlways : .deny
        }

        #expect(await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -rf x")) == .allow)
        #expect(await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -rf y")) == .allow)
        #expect(await answers.all == ["a", "a"], "a destructive call stopped asking")
    }

    /// Everything the CLI treats as consent, and nothing it does not.
    ///
    /// This used to re-implement `main.swift`'s `switch` and compare the two by eye,
    /// which is how the bug below survived: the copy and the original could disagree
    /// and both stay green. It now calls the parser the CLI calls.
    @Test("Only an explicit yes is consent", arguments: [
        ("y", PermissionGate.Approval.allow), ("yes", .allow), ("Y ", .allow),
        ("a", .allowAlways), ("always", .allowAlways),
        ("n", .deny), ("no", .deny), ("", .deny), ("maybe", .deny),
    ])
    func consentParsing(pair: (String, PermissionGate.Approval)) {
        #expect(PermissionGate.parse(pair.0, isDestructive: false) == pair.1)
    }

    /// A destructive prompt offers only `[y]es / [n]o`, yet "a" approved it. A user
    /// who has been typing "a" for routine writes meets a destructive action and
    /// authorises it out of habit, with an answer the prompt never listed. An
    /// unadvertised key must not be consent — the same rule as the overlay's Return.
    @Test("An unoffered key never approves a destructive action",
          arguments: ["a", "always", "A", " always "])
    func unofferedKeyDoesNotApproveDestructive(answer: String) {
        #expect(PermissionGate.parse(answer, isDestructive: true) == .deny)
    }

    /// An explicit yes still works, or the prompt would be unanswerable.
    @Test("Yes still approves a destructive action", arguments: ["y", "yes", "YES "])
    func yesApprovesDestructive(answer: String) {
        #expect(PermissionGate.parse(answer, isDestructive: true) == .allow)
    }

    /// The offer and its reading must not disagree — that disagreement was the bug.
    @Test("A destructive prompt does not offer what it will not accept")
    func offerMatchesTheParser() {
        let destructive = PermissionGate.choices(isDestructive: true, tool: "shell")
        #expect(!destructive.contains("[a]lways"))
        #expect(PermissionGate.parse("a", isDestructive: true) == .deny)

        let ordinary = PermissionGate.choices(isDestructive: false, tool: "shell")
        #expect(ordinary.contains("[a]lways"))
        #expect(PermissionGate.parse("a", isDestructive: false) == .allowAlways)
    }

    /// EOF — a closed pipe, or Ctrl-D — is not consent.
    @Test("No answer at all is denial")
    func noAnswerIsDenial() {
        #expect(PermissionGate.parse(nil, isDestructive: false) == .deny)
        #expect(PermissionGate.parse(nil, isDestructive: true) == .deny)
    }

    private actor Answers {
        private(set) var all: [String?] = []
        func record(_ answer: String?) { all.append(answer) }
    }
}

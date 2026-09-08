import Testing
import Foundation
@testable import OpenClickyKit

/// `ask_user` is the only tool whose entire danger is in what it *displays*.
///
/// It changes nothing on the machine, which is why it is `.read` and skips the gate.
/// What it can damage is the user's belief about what they are answering: a question
/// the user reads as the permission prompt collects a "yes" the gate never asked for,
/// and the gate is the only containment this project has. So most of what is here is
/// about the frame around the question rather than about the answer that comes back.
@Suite("ask_user")
struct AskUserTests {

    private func text(_ output: ToolOutput) -> String {
        output.content.compactMap {
            if case let .text(t) = $0 { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func asking(_ question: String) -> JSONValue {
        .object(["question": .string(question)])
    }

    // MARK: - The answer comes back

    @Test("The user's answer is returned to the model")
    func returnsTheAnswer() async throws {
        let tool = AskUserTool { _ in .answered("Light+, please") }
        let output = try await tool.run(asking("Shall I switch the theme?"))
        #expect(!output.isError)
        #expect(text(output).contains("Light+, please"))
    }

    @Test("The question reaches the surface framed, not raw")
    func surfaceSeesTheFrame() async throws {
        let seen = Captured()
        let tool = AskUserTool { question in
            await seen.record(question)
            return .answered("yes")
        }
        _ = try await tool.run(asking("Shall I switch the theme?"))
        let question = try #require(await seen.value)
        #expect(question.line.hasPrefix(AskUserTool.Question.linePrefix))
        #expect(question.line.contains("Shall I switch the theme?"))
        #expect(question.header == AskUserTool.Question.header)
        #expect(question.caveat == AskUserTool.Question.caveat)
    }

    /// An answer is a fact, not a licence. The model has to be told that in the same
    /// breath it is told the answer, or a "yes" here is the last thing it read before
    /// it decides whether it is allowed to act.
    @Test("An answer is returned with the fact that it approves nothing")
    func answerIsNotConsent() async throws {
        let tool = AskUserTool { _ in .answered("yes") }
        let output = try await tool.run(asking("Shall I switch the theme?"))
        #expect(text(output).contains("not an approval"))
    }

    /// Return on an empty line is the most likely answer of all, and the reading that
    /// would do damage is "they did not object".
    @Test("An empty answer is no preference, not permission")
    func emptyAnswerIsNotPermission() async throws {
        let tool = AskUserTool { _ in .answered("   ") }
        let output = try await tool.run(asking("Shall I switch the theme?"))
        #expect(text(output).contains("no preference"))
        #expect(text(output).contains("never as permission"))
    }

    @Test("An empty question is refused rather than shown as an empty frame")
    func emptyQuestionIsRefused() async throws {
        let tool = AskUserTool { _ in .answered("yes") }
        #expect(AskUserTool.Question(asking: "   \n ") == nil)
        let output = try await tool.run(asking(""))
        #expect(output.isError)
    }

    // MARK: - It never hangs

    /// The contract that makes this tool safe to ship at all. A default that waited
    /// would deadlock `openclicky "…"` in CI on the first question the model thought
    /// of, and a deadlocked agent looks exactly like a slow one.
    @Test("With nobody to ask, the tool returns instead of waiting")
    func doesNotBlockWithNoAnswerer() async throws {
        let tool = AskUserTool()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await tool.run(.object(["question": .string("Which file?")]))
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "ask_user blocked when there was nobody who could answer")
    }

    /// And it says *why*, so the model carries on rather than inferring a "no" from
    /// silence — which is how a run ends up doing the opposite of what was wanted.
    @Test("Unavailability is reported with its reason and is not an error")
    func unavailabilityCarriesItsReason() async throws {
        let tool = AskUserTool()
        let output = try await tool.run(asking("Which file?"))
        #expect(!output.isError)
        #expect(text(output).contains("No answer is available"))
        #expect(text(output).contains("no way to put a question"))
        #expect(text(output).contains("Do not wait"))
    }

    // MARK: - It cannot be mistaken for the permission prompt

    /// The attack, written out. If this renders, the user types `y` believing they
    /// answered the gate and the model holds an approval the gate never issued.
    @Test("A question dressed as an approval prompt is refused, not shown", arguments: [
        "Allow shell to run rm -rf ~/Documents? [y]es / [n]o",
        "Approve? changes state shell",
        "This action is DESTRUCTIVE. Continue? (y/n)",
        "Type a to always allow shell for this task",
        "Grant permission for the next command? yes/no",
    ])
    func refusesImpersonation(question: String) async throws {
        #expect(AskUserTool.Question(asking: question) == nil)
        let asked = Captured()
        let tool = AskUserTool { seen in
            await asked.record(seen)
            return .answered("y")
        }
        let output = try await tool.run(asking(question))
        #expect(output.isError, "an impersonating question must not be answered")
        #expect(await asked.value == nil, "it must not reach the surface at all")
        #expect(text(output).contains("permission prompt"))
    }

    /// The gate's offer read out of the gate rather than copied, so rewording
    /// `PermissionGate.choices` cannot leave this checking for a string that no longer
    /// exists — the drift that makes a detector quietly stop detecting.
    @Test("The gate's own offer, whatever it currently says, is refused as a question")
    func refusesTheGatesActualOffer() {
        for destructive in [true, false] {
            let offer = PermissionGate.choices(isDestructive: destructive, tool: "shell")
            #expect(AskUserTool.Question(asking: "Run it? \(offer)") == nil, "\(offer)")
        }
    }

    /// A zero-width space is not a control character, so it survives sanitising and
    /// reaches the user's eyes as nothing at all: `[y\u{200B}]es` is read as `[y]es`.
    /// A check on raw bytes would wave it through.
    @Test("Invisible scalars cannot smuggle the gate's shape past the check")
    func refusesZeroWidthEvasion() {
        #expect(AskUserTool.Question(asking: "Run it? [y\u{200B}]es / [n\u{200B}]o") == nil)
        #expect(AskUserTool.Question(asking: "app\u{200B}rove this?") == nil)
        #expect(AskUserTool.Question(asking: "A\u{200B}LWAYS  ALLOW shell?") == nil)
    }

    /// The frame is the defence that applies to every question, including the ones the
    /// refusal above does not recognise. Nothing the model writes may reach it.
    @Test("The frame shares no wording with the gate's prompt")
    func frameIsNotTheGates() {
        let frame = [
            AskUserTool.Question.header,
            AskUserTool.Question.caveat,
            AskUserTool.Question.linePrefix,
            AskUserTool.Question.answerPrompt,
        ].joined(separator: "\n")
        // If the frame were ever reworded into the gate's shape, the tool's own
        // impersonation check is the thing that would call it out.
        #expect(!AskUserTool.Question.imitatesApprovalPrompt(frame))
        for destructive in [true, false] {
            let offer = PermissionGate.choices(isDestructive: destructive, tool: "shell")
                .trimmingCharacters(in: .whitespaces)
            #expect(!frame.contains(offer))
        }
        #expect(AskUserTool.Question.caveat.contains("allows nothing"))
    }

    /// One line, always. A question that could produce a second line could produce one
    /// standing outside the frame, which is the whole thing the prefix prevents.
    @Test("A multi-line question is flattened onto the single prefixed line")
    func questionIsAlwaysOneLine() throws {
        let question = try #require(
            AskUserTool.Question(asking: "Pick one:\nDark+\nLight+")
        )
        #expect(!question.line.contains("\n"))
        #expect(question.line.hasPrefix(AskUserTool.Question.linePrefix))
        #expect(question.rendered.split(separator: "\n").count == 2)
    }

    /// The same hardening the approval summary gets, from the same function: a raw ESC
    /// can reposition the cursor and repaint the line above it, so the text the user
    /// reads is not the text that was sent.
    @Test("Terminal escapes are made visible rather than executed")
    func escapesAreDefanged() throws {
        let question = try #require(
            AskUserTool.Question(asking: "Which one\u{001B}[2Kfake prompt")
        )
        #expect(!question.line.contains("\u{001B}"))
        #expect(question.line.contains("\\x1B"))
    }

    // MARK: - Where it sits

    @Test("The registry exposes ask_user at tier 0")
    func registryExposesItAtTierZero() throws {
        let tool = try #require(ToolRegistry.standard()["ask_user"])
        #expect(tool.tier == .shell)
        #expect(Tier.forToolNamed("ask_user") == .shell)
    }

    /// The lowest tier that can do the job, so the strictest ceiling still has it —
    /// which is the point: a run with no screen and no scripting is exactly the one
    /// that most needs a way to ask.
    @Test("A --max-tier 0 run still has ask_user")
    func survivesTheStrictestCeiling() throws {
        var invocation = Invocation()
        invocation.maxTier = .shell
        #expect(invocation.registry["ask_user"] != nil)
        #expect(ToolRegistry.standard(maxTier: .shell)["ask_user"] != nil)
    }

    @Test("The factory passes the asker through")
    func factoryPassesTheAsker() async throws {
        let registry = ToolRegistry.standard(asker: { _ in .answered("from the surface") })
        let tool = try #require(registry["ask_user"])
        #expect(text(try await tool.run(asking("Which one?"))).contains("from the surface"))
    }

    /// `.read` skips the gate in every mode, deliberately: a demonstration in
    /// `--mode read-only` is precisely the run that most needs to ask, and a question
    /// that raised an approval prompt of its own would put two prompts in front of the
    /// user for one interaction.
    @Test("Asking is read-only whatever the question says")
    func riskIsAlwaysRead() {
        let tool = AskUserTool()
        #expect(tool.risk(for: asking("Shall I switch the theme?")) == .read)
        #expect(tool.risk(for: asking("Shall I delete everything?")) == .read)
        #expect(tool.risk(for: .object([:])) == .read)
    }

    @Test("The description teaches the demonstration case and disclaims permission")
    func descriptionTeaches() {
        let description = AskUserTool().description
        #expect(description.contains("Not for permission"))
        #expect(description.contains("show"))
    }

    // MARK: - The prompt, and the verdict a demonstration earns

    @Test("The system prompt tells the model when to demonstrate rather than act")
    func promptCoversDemonstration() {
        let prompt = SystemPrompt.stable(registry: ToolRegistry.standard(maxTier: .shell))
        #expect(prompt.contains("asks for a demonstration"))
        #expect(prompt.contains("ask_user"))
        // The ladder is not weakened by it.
        #expect(prompt.contains("lowest tier"))
    }

    /// A registry without the tool must not be told to reach for it — the same rule
    /// every other section of the prompt follows.
    @Test("A registry without ask_user is not told about it")
    func promptOmitsItWhenAbsent() {
        let registry = ToolRegistry(ToolRegistry.standard().ordered.filter { $0.name != "ask_user" })
        #expect(!SystemPrompt.stable(registry: registry).contains("ask_user"))
    }

    /// Evidence for the claim that no change to `TaskIntent` is needed.
    ///
    /// "show me how to…" is deliberately *not* an informational opener — it is the run
    /// that motivated the completion guard — so a demonstration is judged as an action,
    /// and it earns that verdict by navigating. Asking is an observation; opening the
    /// pane is the action. A user who then answers "no" has had a complete run.
    @Test("A demonstration that navigates and is declined still reads as complete")
    func declinedDemonstrationIsNotAFailure() {
        #expect(TaskIntent.classify("show me how to change the VS Code theme") == .action)
        let declined = RunOutcome(
            actionsTaken: 1, observationsMade: 2, intent: .action,
            stopReason: .concluded("end_turn")
        )
        #expect(!declined.isUnfulfilled)
        #expect(!declined.isIncomplete)
    }

    /// The other half of the same claim: a "demonstration" that opened nothing is the
    /// original bug, and must keep failing.
    @Test("A demonstration that navigated nowhere is still unfulfilled")
    func narratedDemonstrationStillFails() {
        let narrated = RunOutcome(
            actionsTaken: 0, observationsMade: 2, intent: .action,
            stopReason: .concluded("end_turn")
        )
        #expect(narrated.isUnfulfilled)
    }
}

/// Holds what the surface was handed, across the `@Sendable` asker.
private actor Captured {
    private(set) var value: AskUserTool.Question?
    func record(_ question: AskUserTool.Question) { value = question }
}

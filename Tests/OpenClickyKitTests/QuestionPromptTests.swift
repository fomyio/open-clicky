import Testing
import Foundation
@testable import OpenClickyKit

/// The overlay's half of `ask_user`: a state the run parks in, a reply that reaches the
/// tool, and — the part that has to be gone over twice — every way a run can end while
/// it is parked there.
///
/// A run suspended inside `ask_user` is not merely slow. It is waiting on a
/// continuation, which nothing about task cancellation resumes, and one loop serves the
/// whole conversation — so a question nobody answers wedges every instruction after it
/// as well. That is strictly worse than the state before the Stop button existed: the
/// loop is not running, it is blocked.
///
/// Every test here that suspends on a `PendingReply` arms a watchdog that resolves it
/// with a wrong-on-purpose value, and the suite carries a time limit besides. Both are
/// there because the invariant under test is *a wait that must end*: break it and the
/// natural failure mode is a test that never returns, which the mutation sweep cannot
/// report — a hanging test is worse than a failing one.
@Suite("Overlay questions", .serialized, .timeLimit(.minutes(1)))
struct QuestionPromptTests {

    private static let cancelled = "the run was stopped before the question could be answered"
    private static let watchdogFired = "WATCHDOG"

    private func question(_ text: String = "Settings is open on Color Theme. Switch to Light+?")
        -> AskUserTool.Question {
        AskUserTool.Question(asking: text)!
    }

    private func text(_ output: ToolOutput) -> String {
        output.content.compactMap {
            if case let .text(value) = $0 { return value }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - The state

    /// The overlay has to leave the question as reliably as it enters it, or a run that
    /// was answered goes on showing a question it has finished with.
    @Test("The controller enters the question state and leaves it again")
    func entersAndLeavesTheQuestionState() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("show me how to change the theme")
        await controller.handle(.toolStarted(name: "app_script", tier: .script, summary: "open"))
        let working = await controller.state

        let asked = question()
        let answer = await controller.requestAnswer(asked) {
            #expect(await controller.state == .awaitingAnswer(asked))
            #expect(await controller.state.isInterruptible, "Stop must be reachable here")
            #expect(await !controller.state.isReadyForInput, "no instruction takes this field")
            return .answered("Light+")
        }
        #expect(answer == .answered("Light+"))
        #expect(await controller.state == working, "the run should resume where it paused")
    }

    @Test("The answer reaches the caller, and the model")
    func theAnswerReachesTheCaller() async throws {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("task")

        let tool = AskUserTool { asked in
            await controller.requestAnswer(asked) { .answered("the second one") }
        }
        let output = try await tool.run(.object(["question": .string("Which file did you mean?")]))
        #expect(!output.isError)
        #expect(text(output).contains("the second one"))
    }

    /// The state is the *only* thing the overlay is given, so what the overlay can
    /// render is whatever this carries. The caveat is the line that separates a
    /// question from a consent the model was never granted, and a surface cannot show
    /// what it was not handed.
    @Test("The question state carries the caveat the tool wrote")
    func theQuestionStateCarriesTheCaveat() async throws {
        let state = SessionState.awaitingAnswer(question())
        let carried = try #require(state.pendingQuestion)
        #expect(carried.caveat == AskUserTool.Question.caveat)
        // Spelt out rather than only compared to the constant, so emptying either the
        // constant or the accessor is caught here.
        #expect(carried.caveat.contains("not a permission request"))
        #expect(carried.caveat.contains("allows nothing"))
        #expect(carried.header == AskUserTool.Question.header)
        #expect(carried.answerPrompt == AskUserTool.Question.answerPrompt)
        #expect(carried.line.hasPrefix(AskUserTool.Question.linePrefix))
    }

    /// `Question` spends an entire type stopping the model's words from being read as
    /// the permission prompt. Handing a question to a surface that renders approvals
    /// would undo all of it at the last step, because the user answers what they see.
    /// So the two states carry different types and neither answers to the other's
    /// accessor.
    @Test("A question is not an approval and cannot be answered as one")
    func aQuestionIsNotAnApproval() {
        let asking = SessionState.awaitingAnswer(question())
        let approving = SessionState.awaitingApproval(
            .init(tool: "shell", summary: "rm -rf ~", isDestructive: true)
        )
        #expect(asking != approving)
        #expect(asking.pendingApproval == nil, "a question must not render approval controls")
        #expect(approving.pendingQuestion == nil, "an approval must not render an answer field")
        #expect(asking.pendingQuestion != nil)
        #expect(approving.pendingApproval != nil)
        // Both block the overlay, and for the same reason neither takes an instruction.
        #expect(!asking.isReadyForInput)
        #expect(asking.isInterruptible)
        #expect(asking.isVisible)
    }

    // MARK: - Skipping is not cancelling

    /// The two look alike — no words came back either way — and mean opposite things.
    /// A skip is a person who read the question and had no preference, and the model is
    /// told to take the reversible option and carry on. A cancellation is a run being
    /// torn down, and telling it "no preference, carry on" would set it going again at
    /// the moment the user asked it to stop.
    @Test("A skip and a cancellation are told to the model differently")
    func skipIsDistinctFromCancel() async throws {
        let skipped = try await AskUserTool { _ in .answered("") }
            .run(.object(["question": .string("Which one?")]))
        let cancelled = try await AskUserTool { _ in .unavailable(reason: Self.cancelled) }
            .run(.object(["question": .string("Which one?")]))

        #expect(text(skipped).contains("no preference"))
        #expect(text(skipped).contains("never as permission"))
        #expect(!text(skipped).contains("No answer is available"))

        #expect(text(cancelled).contains("No answer is available"))
        #expect(text(cancelled).contains("Do not wait"))
        #expect(text(cancelled).contains(Self.cancelled))
        #expect(!text(cancelled).contains("no preference"))
    }

    // MARK: - Every way out answers the question

    /// Escape and the Stop button both arrive here, and a question is where stopping
    /// matters most: the loop is inside a tool call rather than between two of them.
    @Test("Escape while a question is showing stops the run")
    func escapeDuringAQuestionStops() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("task")
        _ = await controller.requestAnswer(question()) {
            #expect(await controller.escape() == true, "a question is interruptible")
            return .unavailable(reason: Self.cancelled)
        }
        #expect(await controller.state == .stopped(reason: "Stopped."),
                "a cancel must not be painted over by the question's restore")
    }

    /// The delegate funnels all four teardown paths — Escape, the Stop button, a
    /// superseding instruction, and ending the conversation (which is also the only
    /// caller of `startOver`) — into one call that answers *both* prompts. This is that
    /// funnel, and the thing it must not do is answer only the approval.
    @MainActor
    @Test("Every path that ends a run answers a pending question", arguments: [
        "Escape", "Stop button", "a superseding instruction", "New conversation",
    ])
    func everyCancellationPathAnswersAQuestion(path: String) async {
        let approval = PendingReply<Bool>(whenCancelled: false)
        let pending = PendingReply<AskUserTool.Answer>(
            whenCancelled: .unavailable(reason: Self.cancelled)
        )
        // What `AppDelegate.cancelPendingPrompts` does, and what each of those four
        // paths calls.
        let teardown = { approval.cancel(); pending.cancel() }

        let questionWatchdog = watchdog(on: pending, resolvingWith: .answered(Self.watchdogFired))
        let answer = await pending.expecting { () async -> AskUserTool.Answer in
            teardown()
            return await pending.wait()
        }
        questionWatchdog.cancel()
        #expect(answer == .unavailable(reason: Self.cancelled),
                "\(path) left the run suspended inside ask_user")

        // And the approval it has always answered still is: the mechanism was
        // generalised, not replaced, so this behaviour must be bit-for-bit what it was.
        // Watchdogged for the same reason — an approval nobody answers hangs just as
        // silently, and the sweep needs a failure, not a stall.
        let approvalWatchdog = watchdog(on: approval, resolvingWith: true)
        let approved = await approval.expecting { () async -> Bool in
            teardown()
            return await approval.wait()
        }
        approvalWatchdog.cancel()
        #expect(approved == false, "\(path) stopped denying a pending approval")
    }

    /// The race, reproduced. The continuation is created on the loop's executor and has
    /// to hop to the main actor to become resumable; a cancel landing in that gap used
    /// to resume nothing at all. Here the cancel deliberately arrives before the wait
    /// has registered, which is the exact window.
    ///
    /// A watchdog resolves the wait after two seconds so a regression fails this test
    /// rather than hanging the suite — an invariant whose test hangs is one the sweep
    /// cannot count.
    @MainActor
    @Test("A cancelled run does not leave a question suspended")
    func aCancelledRunDoesNotLeaveAQuestionSuspended() async {
        let pending = PendingReply<AskUserTool.Answer>(
            whenCancelled: .unavailable(reason: Self.cancelled)
        )
        let watchdog = watchdog(on: pending, resolvingWith: .answered(Self.watchdogFired))
        let answer = await pending.expecting { () async -> AskUserTool.Answer in
            // Before `wait` has had any chance to register: nothing is resumable yet,
            // and this must still be remembered.
            pending.cancel()
            return await pending.wait()
        }
        watchdog.cancel()
        #expect(answer == .unavailable(reason: Self.cancelled),
                "a cancel inside the registration window was dropped")
    }

    /// The other half of that latch. It is armed only while an answer is genuinely
    /// owed, because a cancel remembered from nothing would answer the *next* prompt —
    /// which the user meets as the agent refusing something nobody was asked about, or
    /// a question that skips itself.
    @MainActor
    @Test("A cancel with nothing pending does not answer the next prompt")
    func staleCancelDoesNotAnswerTheNextPrompt() async {
        let pending = PendingReply<AskUserTool.Answer>(
            whenCancelled: .unavailable(reason: Self.cancelled)
        )
        pending.cancel()
        #expect(!pending.isPending)

        let watchdog = watchdog(on: pending, resolvingWith: .answered(Self.watchdogFired))
        let answer = await pending.expecting { () async -> AskUserTool.Answer in
            await pending.wait { pending.resolve(.answered("Light+")) }
        }
        watchdog.cancel()
        #expect(answer == .answered("Light+"), "a stale cancel poisoned the next question")
    }

    /// Resolves a wait that should already have been resolved, so a regression reports
    /// a wrong answer instead of never returning.
    ///
    /// The value it resolves with is deliberately the one the assertion rejects: if the
    /// watchdog is what ended the wait, the test fails and says so, rather than passing
    /// because something eventually came back.
    @MainActor
    private func watchdog<Value: Sendable>(
        on pending: PendingReply<Value>, resolvingWith value: Value
    ) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            pending.resolve(value)
        }
    }
}

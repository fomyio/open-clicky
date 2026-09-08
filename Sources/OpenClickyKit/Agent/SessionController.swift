import Foundation

/// What the overlay should be showing.
///
/// A state machine rather than a pile of booleans, so "running and also awaiting
/// approval" cannot be represented — and separated from AppKit so the transitions
/// are testable without a window server.
public enum SessionState: Sendable, Equatable {
    /// Hidden. The hotkey brings it back.
    case dormant
    /// Accepting a task.
    case accepting(draft: String)
    /// Working. `activity` is the latest line to show.
    case working(activity: String)
    /// Blocked on the user. Nothing proceeds until this resolves.
    case awaitingApproval(Approval)
    /// Blocked on the user for an *answer*, not a decision. Nothing proceeds until
    /// this resolves either — but what resolves it is prose, and it authorises
    /// nothing. See `requestAnswer` for why the two are separate cases.
    case awaitingAnswer(AskUserTool.Question)
    /// Finished; `summary` is the closing message.
    case finished(summary: String, cost: String?)
    /// Stopped or failed.
    case stopped(reason: String)

    public struct Approval: Sendable, Equatable {
        public let tool: String
        public let summary: String
        public let isDestructive: Bool

        /// Whether a bare Return may approve this.
        ///
        /// Never for a destructive action. The CLI requires typing "y" and treats a
        /// bare Return as denial, so the overlay binding Return to Approve made the
        /// graphical surface the more permissive of the two at exactly the moment
        /// that matters most: a stray keypress — habit, or the overlay appearing
        /// mid-keystroke — approving an irreversible command. Destructive actions
        /// take Command-Return instead, which is still keyboard-reachable but cannot
        /// be arrived at by accident.
        public var acceptsBareReturn: Bool { !isDestructive }
    }

    /// The approval this state is blocked on, or nil.
    ///
    /// A surface asks *this* rather than pattern-matching the case, so a state that is
    /// not an approval can never be rendered with an approval's controls. That is not
    /// tidiness: `AskUserTool.Question` spends an entire type refusing to let the
    /// model's words be read as the permission prompt, and drawing Approve and Deny
    /// under one at the last step would undo every bit of it — the user answers what
    /// they see.
    public var pendingApproval: Approval? {
        if case let .awaitingApproval(approval) = self { return approval }
        return nil
    }

    /// The question this state is blocked on, or nil. The other half of the pair above,
    /// and deliberately a different type: nothing can be handed to both.
    public var pendingQuestion: AskUserTool.Question? {
        if case let .awaitingAnswer(question) = self { return question }
        return nil
    }

    /// Whether the overlay should be on screen.
    public var isVisible: Bool {
        if case .dormant = self { return false }
        return true
    }

    /// Whether Escape should stop a run rather than dismiss the overlay.
    ///
    /// True while a question is on screen for the same reason it is true during an
    /// approval, and it matters more here: the run is not merely working, it is
    /// suspended inside a tool call, so the Stop control this drives is the only thing
    /// between the user and a session that cannot be ended.
    public var isInterruptible: Bool {
        switch self {
        case .working, .awaitingApproval, .awaitingAnswer: return true
        case .dormant, .accepting, .finished, .stopped: return false
        }
    }

    /// Whether the overlay should be offering an input field.
    ///
    /// True after a task ends as well as before the first one, which is the whole of
    /// "a finished task does not end the run" as the overlay experiences it: the
    /// natural end of a task is *ready for the next instruction*, not gone. The
    /// outcome stays on screen beside the field — the per-task verdict lines exist
    /// because a run must not report success it did not earn, and an overlay that
    /// swept them away to make room for a prompt would undo that.
    ///
    /// False while working or awaiting an approval, for the reason it always was: a
    /// second instruction accepted mid-run would interleave two tasks on one loop.
    ///
    /// False while awaiting an answer too, and there the field on screen is a *third*
    /// thing: a question has its own text field, which takes the answer to the question
    /// and never an instruction. One field that meant either would let a user who did
    /// not read the frame submit "yes" as a new task, or an instruction as an answer.
    public var isReadyForInput: Bool {
        switch self {
        case .accepting, .finished, .stopped: return true
        case .dormant, .working, .awaitingApproval, .awaitingAnswer: return false
        }
    }
}

/// Drives the overlay's state from agent events.
///
/// Owns no UI. The app layer observes `state` and renders it; the tests drive the
/// same transitions directly.
public actor SessionController {
    public private(set) var state: SessionState = .dormant
    private var meter: CostMeter?
    /// What the run changed, delivered one event before `.finished`.
    private var outcome: RunOutcome?

    /// Every call the run has made, for a surface that shows more than one line.
    ///
    /// **Per conversation, not per task.** The obvious reading of "a panel for
    /// monitoring a run" is that it empties when a run does, and that is the reading
    /// this project has already corrected once at the level above: a finished task
    /// leaves its verdict on screen precisely because the end of a task is the start
    /// of the next instruction, and four separate fixes exist to stop the overlay
    /// sweeping that away. A log that cleared on every `.finished` would reintroduce
    /// the same mistake one row down — "now close it" is judged against what the last
    /// instruction actually did, and by the time it is typed the evidence would be
    /// gone. So it clears where the conversation does, in `startOver`, which is the
    /// one place this file already documents as *meaning* the loss of what came
    /// before. `record(instruction:)` marks each task boundary inside it, so a
    /// conversation-long log still reads as a sequence of tasks.
    public private(set) var activity = ActivityLog()

    /// Called on every transition, for the UI to re-render.
    private let onChange: @Sendable (SessionState) async -> Void

    /// Called whenever the activity log grows or is cleared.
    ///
    /// Separate from `onChange` because the two do not fire together: `transition`
    /// deliberately does nothing when the state is unchanged, and two identical tool
    /// results in a row *are* the same state — so a log delivered through that channel
    /// would drop exactly the repetition worth watching. Optional, so the CLI and the
    /// tests that only care about the state machine are unaffected.
    private let onActivity: @Sendable (ActivityLog) async -> Void

    public init(
        onChange: @escaping @Sendable (SessionState) async -> Void,
        onActivity: @escaping @Sendable (ActivityLog) async -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onActivity = onActivity
    }

    private func transition(to next: SessionState) async {
        guard next != state else { return }
        state = next
        await onChange(next)
    }

    // MARK: - User-driven transitions

    /// Hotkey pressed. Opens the input, or brings a running session back into view.
    public func summon() async {
        switch state {
        case .dormant:
            await transition(to: .accepting(draft: ""))
        case .accepting, .working, .awaitingApproval, .awaitingAnswer:
            // Already on screen; the hotkey should not discard a run in progress.
            break
        case .finished, .stopped:
            // Also already on screen, and already taking input — a finished task ends
            // ready for the next instruction. The hotkey here means "give me the
            // field", which it already has; transitioning to `.accepting` would clear
            // the last task's verdict off the screen in exchange for nothing, and that
            // verdict is what four separate fixes exist to keep honest.
            break
        }
    }

    /// Escape. Dismisses when idle, stops the run when working.
    ///
    /// - Returns: whether a run should be cancelled.
    public func escape() async -> Bool {
        let shouldCancel = state.isInterruptible
        if shouldCancel {
            await transition(to: .stopped(reason: "Stopped."))
        } else {
            await transition(to: .dormant)
        }
        return shouldCancel
    }

    public func dismiss() async {
        await transition(to: .dormant)
    }

    /// The user asked to start over: back to an empty input, whatever was on screen.
    ///
    /// Deliberately not what `summon` does. The hotkey must not discard anything — it
    /// is pressed to reach the field, and the last task's verdict has to survive that.
    /// This is the one place where losing the verdict is the point: the conversation it
    /// belonged to is over, and leaving it above a fresh input would attach it to the
    /// instruction the user is about to type.
    public func startOver() async {
        // The log goes with the conversation, for the same reason the verdict does:
        // what the previous thread did is context for the thread it belonged to, and
        // leaving it above a fresh input would attach it to the instruction the user
        // is about to type. This is the only place it is emptied.
        activity.clear()
        await onActivity(activity)
        await transition(to: .accepting(draft: ""))
    }

    /// The submitted task, or `nil` if it is empty or the overlay is not accepting.
    ///
    /// Takes the text rather than reading it from state. It used to read the draft the
    /// controller held, updated through a separate method the app never called —
    /// because the text field kept its own copy. So the controller's draft was always
    /// empty, `submit` always returned nil, and **the app could not run a task at
    /// all**: type anything, press Return, nothing happens. That method is gone; the
    /// draft has one home.
    ///
    /// Requiring the text as an argument removes the possibility. There is no longer
    /// a way to submit without saying what.
    ///
    /// Accepted from a finished or stopped state as well as from an idle one, because
    /// those are where a persistent session spends most of its life: the overlay shows
    /// the last task's verdict and an input field, and typing into it continues the
    /// same conversation. Still refused while working — see `isReadyForInput`.
    public func submit(_ draft: String) async -> String? {
        guard state.isReadyForInput else { return nil }
        let task = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            // Keep the draft visible rather than silently clearing it — but only where
            // there is nothing else on screen to lose. A bare Return over a finished
            // task would otherwise replace that task's verdict with an empty prompt,
            // and the verdict is the one thing the run is judged by.
            if case .accepting = state { await transition(to: .accepting(draft: draft)) }
            return nil
        }
        activity.record(instruction: task)
        await onActivity(activity)
        await transition(to: .working(activity: "Thinking…"))
        return task
    }

    // MARK: - Agent-driven transitions

    public func handle(_ event: AgentLoop.Event) async {
        // Recorded before the state is derived from it, so the panel and the status
        // line can never disagree about the order things happened in. Only the events
        // the log keeps notify — see `ActivityLog.record`.
        if activity.record(event) { await onActivity(activity) }

        switch event {
        case .thinking:
            await transition(to: .working(activity: "Thinking…"))

        case let .assistantText(text):
            let line = text.split(separator: "\n").last.map(String.init) ?? text
            await transition(to: .working(activity: line))

        case let .toolStarted(name, tier, summary):
            await transition(to: .working(activity: "[T\(tier.rawValue)] \(name): \(summary)"))

        case let .toolFinished(name, ok, _):
            await transition(to: .working(activity: ok ? "\(name) ✓" : "\(name) failed"))

        case let .toolDenied(name, _):
            await transition(to: .working(activity: "\(name) declined"))

        case let .toolSkipped(name):
            await transition(to: .working(activity: "\(name) skipped"))

        case let .cost(meter):
            self.meter = meter

        case let .retrying(attempt, total, delay, _):
            await transition(to: .working(
                activity: "Rate limited — retrying in \(Int(delay.rounded()))s (\(attempt)/\(total))"
            ))

        case .usage, .interrupted:
            break

        case let .planned(model, _):
            await transition(to: .working(activity: "Planned with \(model)"))

        case let .planningFailed(model, _):
            await transition(to: .working(activity: "No plan — \(model) unreachable"))

        case let .outcome(outcome):
            // Kept for `.finished` to phrase itself with. The overlay shows one
            // closing line, and "Done." over a run that changed nothing is the same
            // lie in a smaller space than the terminal's.
            self.outcome = outcome

        case let .finished(reason):
            // An interruption is the user's own doing and reads better as "stopped"
            // than as a completion with a reason attached. Compared against the
            // constant the loop emits, not matched against its wording.
            if reason == AgentLoop.Event.interruptedReason {
                await transition(to: .stopped(reason: "Stopped."))
            } else if let outcome, outcome.isIncomplete {
                await transition(to: .stopped(reason: outcome.report))
            } else {
                await transition(to: .finished(summary: reason, cost: meter?.summary))
            }
        }
    }

    /// Blocks on the user's decision.
    ///
    /// The state carries the approval so the overlay can render it; the caller awaits
    /// the returned value. Nothing else advances meanwhile — the agent loop is
    /// suspended inside the permission gate.
    public func requestApproval(
        tool: String, summary: String, isDestructive: Bool,
        decide: @Sendable () async -> Bool
    ) async -> Bool {
        let previous = state
        await transition(to: .awaitingApproval(
            .init(tool: tool, summary: summary, isDestructive: isDestructive)
        ))
        let approved = await decide()
        // Restore the working state so the run continues where it left off.
        if case .awaitingApproval = state {
            await transition(to: previous)
        }
        return approved
    }

    /// Blocks on the user's *answer*, which is a different thing from their permission.
    ///
    /// Shaped like `requestApproval` above and deliberately not folded into it. The two
    /// look alike from here — park the overlay on the user, suspend the loop, restore
    /// the previous state afterwards — and are opposites in the only way that matters:
    /// one authorises an action and is the sole containment this project has, the other
    /// authorises nothing at all. `AskUserTool.Question` exists to keep the model from
    /// dressing the second as the first, and a shared state carrying "some text and
    /// maybe a decision" would hand the surface the ambiguity that type was written to
    /// remove. So the question travels as itself, already framed by the tool, and the
    /// overlay renders `header`, `caveat` and `line` rather than wording of its own.
    ///
    /// The state is restored on the way out for the same reason an approval's is: the
    /// run continues where it paused. Unless something stopped it meanwhile — a cancel
    /// leaves `.stopped` standing, which is why this checks the case rather than
    /// assuming it still owns the screen.
    public func requestAnswer(
        _ question: AskUserTool.Question,
        answer: @Sendable () async -> AskUserTool.Answer
    ) async -> AskUserTool.Answer {
        let previous = state
        await transition(to: .awaitingAnswer(question))
        let reply = await answer()
        if case .awaitingAnswer = state {
            await transition(to: previous)
        }
        return reply
    }
}

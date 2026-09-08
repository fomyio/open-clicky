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

    /// Whether the overlay should be on screen.
    public var isVisible: Bool {
        if case .dormant = self { return false }
        return true
    }

    /// Whether Escape should stop a run rather than dismiss the overlay.
    public var isInterruptible: Bool {
        switch self {
        case .working, .awaitingApproval: return true
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
    public var isReadyForInput: Bool {
        switch self {
        case .accepting, .finished, .stopped: return true
        case .dormant, .working, .awaitingApproval: return false
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

    /// Called on every transition, for the UI to re-render.
    private let onChange: @Sendable (SessionState) async -> Void

    public init(onChange: @escaping @Sendable (SessionState) async -> Void) {
        self.onChange = onChange
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
        case .accepting, .working, .awaitingApproval:
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
        await transition(to: .working(activity: "Thinking…"))
        return task
    }

    // MARK: - Agent-driven transitions

    public func handle(_ event: AgentLoop.Event) async {
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
}

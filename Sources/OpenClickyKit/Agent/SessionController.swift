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
}

/// Drives the overlay's state from agent events.
///
/// Owns no UI. The app layer observes `state` and renders it; the tests drive the
/// same transitions directly.
public actor SessionController {
    public private(set) var state: SessionState = .dormant
    private var meter: CostMeter?

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
        case .dormant, .finished, .stopped:
            await transition(to: .accepting(draft: ""))
        case .accepting, .working, .awaitingApproval:
            // Already on screen; the hotkey should not discard a run in progress.
            break
        }
    }

    public func updateDraft(_ text: String) async {
        guard case .accepting = state else { return }
        await transition(to: .accepting(draft: text))
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

    /// The submitted task, or `nil` if the draft is empty.
    public func submit() async -> String? {
        guard case let .accepting(draft) = state else { return nil }
        let task = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }
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

        case .usage, .interrupted:
            break

        case let .finished(reason):
            // An interruption is the user's own doing and reads better as "stopped"
            // than as a completion with a reason attached.
            if reason.contains("interrupted") {
                await transition(to: .stopped(reason: "Stopped."))
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

import Foundation

/// Decides whether a classified tool call is allowed to run.
///
/// The gate never executes anything itself — it only answers yes or no, so the
/// approval policy stays testable in isolation from the side effects.
public actor PermissionGate {

    public enum Decision: Sendable, Equatable {
        case allow
        case deny(reason: String)
    }

    /// What the user chose.
    ///
    /// `allowAlways` used to be expressible only by the caller reaching back into the
    /// gate afterwards — which nothing did, so "always allow" was offered in the
    /// prompt, implemented here, tested here, described in the README, and connected
    /// to nothing at all. Returning the intent instead means the gate applies it.
    public enum Approval: Sendable, Equatable {
        case deny
        case allow
        /// Allow, and stop asking about this tool for the rest of *this task*.
        /// Ignored for destructive calls, which always ask.
        case allowAlways
    }

    /// Reads a typed answer as consent, or refuses to.
    ///
    /// In the library rather than in the CLI because the tests were *mirroring* the
    /// CLI's `switch` rather than calling it — so the two could disagree and both
    /// stay green, which is how the bug below survived.
    ///
    /// Nothing but an offered choice approves. A destructive prompt offers only
    /// `[y]es / [n]o`, yet "a" was approving it: a user who has been typing "a" for
    /// routine writes meets a destructive action and authorises it out of habit, with
    /// an answer the prompt never listed. An unadvertised key must not be consent —
    /// the same rule as the overlay's Return.
    public static func parse(_ answer: String?, isDestructive: Bool) -> Approval {
        switch (answer ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "y", "yes":
            return .allow
        case "a", "always":
            // Never offered for a destructive call, because a standing grant cannot
            // be honoured for one. Not offered means not accepted.
            return isDestructive ? .deny : .allowAlways
        default:
            return .deny
        }
    }

    /// The choices a prompt should show, so the offer and the parser cannot disagree.
    public static func choices(isDestructive: Bool, tool: String) -> String {
        isDestructive
            ? "  [y]es / [n]o: "
            : "  [y]es / [n]o / [a]lways allow \(tool) this task: "
    }

    /// Asks the user to approve one action.
    /// The CLI wires this to stdin; the app wires it to an overlay prompt.
    public typealias Prompt = @Sendable (_ toolName: String, _ summary: String, _ risk: Risk) async -> Approval

    private let mode: PermissionMode
    private let prompt: Prompt
    /// Tool names the user chose to always allow for the rest of the current task.
    ///
    /// Cleared at every task boundary by `beginTask()`. It used to last as long as the
    /// process, which was the same thing back when a process ran exactly one task — and
    /// stopped being the same thing when `--interactive` made a process last hours. A
    /// grant given to the first instruction would still have been standing at the
    /// twentieth, in a session whose earlier context the user had long stopped holding
    /// in their head, and nothing on screen would have said so.
    ///
    /// The offer is worded to match: `[a]lways allow <tool> this task`. A standing
    /// grant whose scope the prompt misstates is worse than no standing grant, because
    /// the user prices the answer by what they were told it buys.
    private var taskAllowlist: Set<String> = []

    public init(mode: PermissionMode, prompt: @escaping Prompt) {
        self.mode = mode
        self.prompt = prompt
    }

    /// Forgets every standing grant. Called at the start of each task.
    ///
    /// A no-op for a one-shot run, which has exactly one task — this exists so a
    /// long-lived session cannot accumulate authority the user gave once and cannot
    /// see. The gate is the only containment this project has, so the thing it
    /// remembers has to have a lifetime the user can state without checking.
    public func beginTask() {
        taskAllowlist.removeAll()
    }

    public func decide(tool: String, risk: Risk) async -> Decision {
        switch risk {
        case .read:
            // Observation is always permitted; the tools themselves enforce the
            // credential-path deny-list before they read anything.
            return .allow

        case let .write(summary):
            switch mode {
            case .readOnly:
                return .deny(reason: "read-only mode: '\(tool)' would change state (\(summary)).")
            case .auto, .bypass:
                return .allow
            case .ask:
                if taskAllowlist.contains(tool) { return .allow }
                switch await prompt(tool, summary, risk) {
                case .deny:
                    return .deny(reason: "The user declined this action.")
                case .allow:
                    return .allow
                case .allowAlways:
                    taskAllowlist.insert(tool)
                    return .allow
                }
            }

        case let .dangerous(summary):
            switch mode {
            case .readOnly:
                return .deny(reason: "read-only mode: '\(tool)' is destructive (\(summary)).")
            case .bypass:
                return .allow
            case .ask, .auto:
                // A session allowlist entry never covers a destructive call —
                // "always allow shell" must not silently authorise `rm -rf`. An
                // `allowAlways` answer here approves this one call and nothing more.
                return await prompt(tool, summary, risk) == .deny
                    ? .deny(reason: "The user declined this action.")
                    : .allow
            }
        }
    }
}

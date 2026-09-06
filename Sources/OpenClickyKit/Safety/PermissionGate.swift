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
        /// Allow, and stop asking about this tool for the rest of the session.
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
            : "  [y]es / [n]o / [a]lways allow \(tool): "
    }

    /// Asks the user to approve one action.
    /// The CLI wires this to stdin; the app wires it to an overlay prompt.
    public typealias Prompt = @Sendable (_ toolName: String, _ summary: String, _ risk: Risk) async -> Approval

    private let mode: PermissionMode
    private let prompt: Prompt
    /// Tool names the user chose to always allow for the rest of this session.
    private var sessionAllowlist: Set<String> = []

    public init(mode: PermissionMode, prompt: @escaping Prompt) {
        self.mode = mode
        self.prompt = prompt
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
                if sessionAllowlist.contains(tool) { return .allow }
                switch await prompt(tool, summary, risk) {
                case .deny:
                    return .deny(reason: "The user declined this action.")
                case .allow:
                    return .allow
                case .allowAlways:
                    sessionAllowlist.insert(tool)
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

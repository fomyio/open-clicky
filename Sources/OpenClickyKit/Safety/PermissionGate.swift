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

    /// Asks the user to approve one action. Returning `false` denies it.
    /// The CLI wires this to stdin; the app wires it to an overlay prompt.
    public typealias Prompt = @Sendable (_ toolName: String, _ summary: String, _ risk: Risk) async -> Bool

    private let mode: PermissionMode
    private let prompt: Prompt
    /// Tool names the user chose to always allow for the rest of this session.
    private var sessionAllowlist: Set<String> = []

    public init(mode: PermissionMode, prompt: @escaping Prompt) {
        self.mode = mode
        self.prompt = prompt
    }

    public func alwaysAllow(_ toolName: String) {
        sessionAllowlist.insert(toolName)
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
                return await prompt(tool, summary, risk)
                    ? .allow
                    : .deny(reason: "The user declined this action.")
            }

        case let .dangerous(summary):
            switch mode {
            case .readOnly:
                return .deny(reason: "read-only mode: '\(tool)' is destructive (\(summary)).")
            case .bypass:
                return .allow
            case .ask, .auto:
                // A session allowlist entry never covers a destructive call —
                // "always allow shell" must not silently authorise `rm -rf`.
                return await prompt(tool, summary, risk)
                    ? .allow
                    : .deny(reason: "The user declined this action.")
            }
        }
    }
}

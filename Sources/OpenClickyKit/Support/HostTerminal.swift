import Foundation

/// The terminal application a CLI process is printing into, as a bundle identifier.
///
/// Exists for one reason: a CLI's own host terminal is a surface the agent must never
/// mistake for the app it is driving. `UIFingerprint` samples the *frontmost*
/// application, and the frontmost application while `openclicky "…"` runs is, by
/// default, the terminal the user typed that into — whose focused element's value is
/// the scrollback the agent is itself printing to. Measured on this machine, five
/// samples of Terminal's focused element over two seconds with no action taken at all:
/// title changed 0/4 intervals, value changed 4/4. Every action therefore "verified".
/// In one recorded run a `cmd+shift+p` meant for VS Code came back as
/// `✓ … the focused element's value changed to "Last login: Wed Sep  2 …"`.
///
/// `TERM_PROGRAM` is the only identification available without asking the window
/// server which process owns the terminal — it is exported by every terminal below,
/// survives `zsh`/`bash` and is not inherited by anything the agent launches itself.
/// It is a hint, not a guarantee: an unset or unrecognised value yields nothing, and
/// nothing means no suppression, which is exactly today's behaviour. Guessing an id
/// would be worse than not knowing one — a wrong id suppresses evidence from an app
/// the agent was genuinely asked to drive.
public enum HostTerminal {
    /// `TERM_PROGRAM` values and the bundle identifier each one stands for.
    ///
    /// Keyed by the exact string the terminal exports, so the lookup cannot be fooled
    /// by a substring: `vscode` is VS Code's integrated terminal, and matching it
    /// loosely would also catch anything else that happened to contain it.
    static let bundleIDsByTermProgram: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "Hyper": "co.zeit.hyper",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "Alacritty": "org.alacritty",
        "kitty": "net.kovidgoyal.kitty",
    ]

    /// The bundle identifier for a `TERM_PROGRAM` value, or nil when it names nothing
    /// this knows. `nil` for an empty or absent value too — a terminal that exports
    /// nothing is indistinguishable from not running under one.
    public static func bundleIdentifier(termProgram: String?) -> String? {
        guard let termProgram, !termProgram.isEmpty else { return nil }
        return bundleIDsByTermProgram[termProgram]
    }

    /// The host terminal of this process, as a list so it can be handed straight to
    /// `ToolRegistry.standard(selfBundleIDs:)`. Empty when unknown.
    ///
    /// The environment read is here rather than in `Invocation` because it is I/O, and
    /// this file's one testable rule — the mapping — takes its input as a parameter.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [bundleIdentifier(termProgram: environment["TERM_PROGRAM"])].compactMap { $0 }
    }
}

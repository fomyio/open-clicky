import Foundation

/// Which request fields a model family actually accepts.
///
/// `thinking: {type: "adaptive"}` and `output_config.effort` are Claude 4.6-and-later
/// features. Sending either to an older family is a 400 on every single request, not a
/// degraded answer — so the shape of the request has to follow the model it is going
/// to. Before this existed the encoder sent adaptive thinking unconditionally, which
/// was correct only for as long as the default model happened to be Opus 5: changing
/// the default to Haiku broke every request, and the failure looked like a bad API key
/// rather than an unsupported field.
///
/// Unknown models get the conservative shape. Both fields are optional on the wire, so
/// omitting them is valid everywhere, while sending them where they are not understood
/// fails hard — the safe direction for a guess is *off*. A newer family therefore has
/// to be added here to get adaptive thinking; that is deliberate, and cheaper than the
/// alternative of every unrecognised `--model` returning 400.
public struct ModelCapabilities: Sendable, Equatable {

    /// Accepts `thinking: {type: "adaptive"}`.
    public let adaptiveThinking: Bool
    /// Accepts `output_config.effort`.
    public let effort: Bool

    public init(adaptiveThinking: Bool, effort: Bool) {
        self.adaptiveThinking = adaptiveThinking
        self.effort = effort
    }

    /// Families known to accept the 4.6+ request fields.
    ///
    /// Prefixes, so dated ids (`claude-opus-4-6-20260514`) match their family.
    private static let modernFamilies = [
        "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-sonnet-5", "claude-sonnet-4-6",
        "claude-fable-5", "claude-mythos-5",
    ]

    public static func forModel(_ model: String) -> ModelCapabilities {
        let isModern = modernFamilies.contains { model.hasPrefix($0) }
        return ModelCapabilities(adaptiveThinking: isModern, effort: isModern)
    }
}

/// The model the agent uses when nothing overrides it.
///
/// One definition, because there were four: `Invocation`, `AgentLoop.Configuration`,
/// the `--help` text and `Credentials.verify` each carried their own copy. They agreed
/// only by coincidence, and a default changed in three of the four would leave the
/// fourth quietly running a different model — most visibly in `verify`, which would
/// then prove a key works against a model the agent never calls.
public enum DefaultModel {
    public static let id = "claude-haiku-4-5-20251001"
}

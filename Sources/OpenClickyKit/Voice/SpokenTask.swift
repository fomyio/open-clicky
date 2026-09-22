import Foundation

/// A turn on its way to being run, with whatever was already decided about it.
///
/// `Effect.submit` used to carry a bare `String`, which was right while the only thing a
/// session could say about a turn was its words. It can now say more: that part of the
/// request has already been worked out, that it was carried out before the model was
/// asked, and that nothing further is needed.
///
/// Kept as a value the session produces and the caller performs, like every other
/// effect. The session decides *what* was asked for; whether a run happens, and what
/// becomes of it, stays the caller's.
public struct SpokenTask: Sendable, Equatable {

    /// What the person said, as it will be given to the agent.
    public let text: String

    /// Calls already decided, to be run before anything is sent anywhere.
    ///
    /// Empty for the overwhelming majority of turns, which is the behaviour that shipped
    /// before any of this existed.
    public let opening: [FastPath.Action]

    /// Whether those calls are the whole of the request.
    ///
    /// Only ever a *permission*: `AgentLoop` still refuses to end a run on them unless
    /// each one actually ran, was allowed by the gate, and verified as a change.
    public let concludesTask: Bool

    public init(text: String, opening: [FastPath.Action] = [], concludesTask: Bool = false) {
        self.text = text
        self.opening = opening
        self.concludesTask = concludesTask
    }

    /// An ordinary spoken turn, with nothing decided in advance.
    public static func spoken(_ text: String) -> SpokenTask { SpokenTask(text: text) }
}

public extension FastPath.Action {
    /// The pre-decided call this action becomes, or nil when it is not one.
    ///
    /// The one place an `Action` turns into something `AgentLoop` will execute, so the
    /// name of the tool and the shape of its argument are written once. `.none` and
    /// `.model` return nil rather than a call that does nothing — a pre-decided move
    /// that no tool answers would be counted, recorded, and invisible.
    var openingMove: OpeningMove? {
        switch self {
        case .none, .model:
            return nil
        case let .activate(identifier):
            return OpeningMove(
                tool: "activate_app",
                input: .object(["bundle_identifier": .string(identifier)]),
                // Present tense and a few words, the same register `ActionCommentary`
                // keeps: this is spoken underneath something that is already happening.
                narration: "Bringing that to the front.",
                spokenResult: "Done.",
                concludesTask: true
            )
        }
    }
}

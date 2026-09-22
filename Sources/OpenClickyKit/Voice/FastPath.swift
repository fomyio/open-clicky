import Foundation

/// What a classifier may decide on its own, and the rules that decide whether to let it.
///
/// Pure. No network, no disk, no clock. Everything here is a total function over an
/// answer and the options that answer was chosen from, because this is the one place in
/// the project where a classifier is allowed to cause an action — and a rule that can
/// only be checked by talking to a vendor is a rule that will be checked once.
///
/// The shape is one flat `Choice` whose **option is the action**. The obvious
/// alternative — a route question of automatic/none/llm, plus a separate question per
/// family — is wrong in a way that is easy to miss: "automatic" does not say *which*
/// family, so reading it needs either a fourth question or a rule for guessing which
/// argument field to trust, and those fields can contradict each other. One list of
/// concrete actions has one probability distribution, no cross-field disagreement to
/// represent, and a consumer that is a lookup rather than a routing tree.
public enum FastPath {

    /// What the classifier picked.
    public enum Action: Sendable, Equatable {
        /// Nothing to do: a remark, a thought out loud, something said to somebody else.
        case none
        /// Beyond a closed choice. The model takes it, as it does today.
        case model
        /// Bring an application to the front, launching it if it is not running.
        case activate(bundleIdentifier: String)

        /// The option name on the wire, and the key this action is remembered by once
        /// it has been done.
        ///
        /// One string for both jobs on purpose. A turn is classified several times as it
        /// is spoken — on the first three words, then the first six — and the same
        /// instruction appears in every window; without a stable identity the session
        /// performs it once per window. Deriving that identity from the option name
        /// rather than keeping a second mapping means the two cannot drift.
        public var name: String {
            switch self {
            case .none: return "none"
            case .model: return "llm"
            case let .activate(identifier): return "activate:\(identifier)"
            }
        }

        /// Reads an option name back. Unknown shapes read as `.model`, never as a
        /// guess — a name this build cannot execute is a silent no-op if it is treated
        /// as anything else.
        public static func named(_ raw: String) -> Action {
            if raw == "none" { return .none }
            if raw == "llm" { return .model }
            if raw.hasPrefix("activate:") {
                let identifier = String(raw.dropFirst("activate:".count))
                return identifier.isEmpty ? .model : .activate(bundleIdentifier: identifier)
            }
            return .model
        }

        /// Whether this is something to actually do.
        public var isActionable: Bool {
            if case .activate = self { return true }
            return false
        }
    }

    /// The options offered for one turn, and what was left out of them.
    public struct Options: Sendable, Equatable {
        public let apps: [AppCatalogue.Entry]
        /// Whether the catalogue had more than would fit.
        ///
        /// Carried into the decision rather than logged. A `Choice` always returns one
        /// of the options it was given, so a classifier shown a truncated list names the
        /// closest thing it *was* shown — which is how "open Fantastical" launches
        /// Calendar. When this is true the fast path wants a reason to believe the right
        /// answer was even on the list.
        public let truncated: Bool

        public init(apps: [AppCatalogue.Entry], truncated: Bool) {
            self.apps = apps
            self.truncated = truncated
        }

        public static let empty = Options(apps: [], truncated: false)

        public init(catalogue: AppCatalogue) {
            self.init(apps: catalogue.entries, truncated: catalogue.truncated)
        }

        public var isEmpty: Bool { apps.isEmpty }

        /// Every option, as the classifier is shown them.
        ///
        /// `none` and `llm` are always present and are the two that must never be cut.
        /// Without them a `Choice` has no way to say "this is not one of these" and is
        /// forced to name an app for "what's the weather" — which is not a wrong answer
        /// by the model, it is a question with no right answer in it.
        public var criteria: [String: String] {
            var options: [String: String] = [
                Action.none.name:
                    "Nothing to do. The speaker is talking to somebody else, thinking "
                    + "out loud, or saying something that asks for no action.",
                Action.model.name:
                    "Anything else at all. Any request that is not exactly one of the "
                    + "actions listed here, anything asking for more than one thing, "
                    + "anything needing a judgement, and anything you are unsure about. "
                    + "This is the right answer whenever no other option is plainly it.",
            ]
            for app in apps {
                options[Action.activate(bundleIdentifier: app.bundleIdentifier).name] =
                    "Bring this application to the front, launching it if needed: "
                    + app.criterion
            }
            return options
        }
    }

    /// Whether an answer may be acted on, decided locally.
    ///
    /// **The one carefully-argued exception** to the rule `TurnReading` states in its
    /// own header — that a classifier may make the session more cautious and may never
    /// make it act. This function is where that exception is bounded, which is why it is
    /// pure and why every clause below is separately testable.
    ///
    /// - Parameters:
    ///   - chosen: the option the classifier picked.
    ///   - confidence: its confidence in that pick.
    ///   - runnerUp: the margin over the second-place option, when the distribution is
    ///     available. Nil when it is not, which is not a reason to act on less.
    ///   - options: what was actually offered, so a name from outside them is refused.
    public static func resolve(
        chosen: String,
        confidence: Double,
        margin: Double?,
        options: Options
    ) -> Action {
        let action = Action.named(chosen)
        guard action.isActionable else { return action }
        guard confidence >= confidenceFloor else { return .model }

        // A name that was never offered. A `Choice` should not be able to return one,
        // so reaching this means a version skew between what was sent and what answered
        // — and the safe reading of an answer to a question we did not ask is that there
        // is no answer.
        guard case let .activate(identifier) = action,
              let entry = options.apps.first(where: { $0.bundleIdentifier == identifier })
        else { return .model }

        // Two builds of one app. "Open chrome" does not choose between them and no
        // margin can make it, so the catalogue collapsed them at build time and this
        // refuses what it marked.
        guard !entry.isAmbiguous else { return .model }

        // A distribution, when there is one. A calibrated 0.91 spread thinly over two
        // near-identical options is a coin flip wearing a decimal point.
        if let margin, margin < marginFloor { return .model }

        // The list was cut, so the right answer may simply not have been on it. A
        // running app is still safe to act on — it is on screen, it is what somebody
        // looking at their machine means, and it is never what truncation removes.
        if options.truncated, !entry.isRunning { return .model }

        return action
    }

    /// How sure the classifier must be before a turn is acted on without a model.
    ///
    /// High, and asymmetric for the same reason every threshold in `TurnReading` is:
    /// the two mistakes are not equal. Declining wrongly costs one model round trip —
    /// the behaviour that shipped before any of this existed. Acting wrongly does
    /// something to the user's machine that they did not ask for.
    public static let confidenceFloor = 0.90

    /// How far ahead of the runner-up the winner must be, where that is known.
    public static let marginFloor = 0.25
}

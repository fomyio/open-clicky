import Foundation

/// What one utterance turned out to be, read from the words rather than from the clock.
///
/// Every rule this replaces is a word list. `VoiceTurn` decides whether somebody has
/// finished talking by looking at their last word; `VoiceCommand` decides whether they
/// asked the agent to stop by matching the whole phrase against a set. Both work, both
/// are honest about what they cost — `VoiceTurn`'s own comment records the auxiliaries
/// that had to be *removed* from it, because a list cannot tell "what voices does Siri
/// **have**" (a complete question, and exactly what this feature is for) from "check for
/// me **the**" (half a sentence). That is not a gap in the list. It is a semantic
/// question, and a list is the wrong instrument for it.
///
/// So this is the same judgements asked of something that reads meaning, and the
/// important design decision is that it is **advisory in one direction only**. Every
/// field below can make the session more cautious — wait longer, stop sooner, act less
/// — and none of them can make it act where the existing rules would not have. A
/// classifier that could approve, submit or escalate on its own would be a second
/// authority to keep in step with the first, and this project has already paid for that
/// lesson in three places.
///
/// **Probabilities, not verdicts.** The thresholds live here, next to the numbers they
/// read, so there is one place to argue with rather than a guess at each call site.
public struct TurnReading: Sendable, Equatable {

    /// What the utterance is *for*, as distinct from what it says.
    ///
    /// The distinction that matters most is the last pair. "Open the other one" during a
    /// run is not a new task — it is a correction of the one already going — and today
    /// it becomes barge-in plus a brand new instruction with none of the context that
    /// made it meaningful. Nothing in the session can currently tell those apart,
    /// because telling them apart requires knowing what the agent was doing.
    public enum Intent: String, Sendable, Equatable, CaseIterable {
        /// Do something. The overwhelming majority.
        case instruction
        /// A question about the machine or the screen. Still a task; noted apart from
        /// `instruction` because it never needs an approval gate and rarely needs tier 3.
        case question
        /// A correction or refinement of the task already running.
        case amendment
        /// Not addressed to the agent at all, or addressed to it but asking nothing.
        case chitchat
        /// Asking the agent to stop.
        case halt
        /// Answering a question the agent asked.
        case approval

        /// The descriptions sent to the model as the choice criteria.
        ///
        /// Kept beside the cases rather than in the client, so a case added here cannot
        /// silently ship a schema that has never heard of it — the criteria are the
        /// whole of what the model knows about an option, and an option described
        /// nowhere is one it can never pick for the right reason.
        public static var criteria: [String: String] {
            [
                Intent.instruction.rawValue:
                    "Asking the assistant to do something on the Mac.",
                Intent.question.rawValue:
                    "Asking the assistant a question about the Mac, the screen, or what "
                    + "it just did.",
                Intent.amendment.rawValue:
                    "Correcting, redirecting or adding to the task the assistant is "
                    + "already running, rather than starting a new one.",
                Intent.chitchat.rawValue:
                    "Not a request to the assistant: talking to another person, thinking "
                    + "out loud, reading aloud, or a stray remark.",
                Intent.halt.rawValue:
                    "Asking the assistant to stop what it is doing, and nothing else.",
                Intent.approval.rawValue:
                    "Answering yes or no to a question the assistant asked.",
            ]
        }
    }

    /// The exact text this reading was asked about.
    ///
    /// Load-bearing, not bookkeeping. Classification runs *while the speaker is still
    /// going*, so a reading routinely comes back describing a prefix of what they
    /// eventually said — "delete the" is overwhelmingly incomplete and "delete the old
    /// screenshots" is not. Deciding the second with the first's answer would be the
    /// worst kind of wrong: confident, and about a sentence nobody finished. Every use
    /// goes through `applies(to:)`.
    public let utterance: String

    /// P(this was said to the assistant, rather than to a person or to nobody).
    public let addressed: Double

    /// P(this is a finished instruction rather than somebody mid-sentence).
    public let complete: Double

    /// P(this is asking the agent to stop, and nothing else).
    ///
    /// "And nothing else" is `VoiceCommand`'s standard and is kept verbatim: "stop"
    /// halts, "stop the music" is an instruction about iTunes and has to reach the agent
    /// intact.
    public let halt: Double

    public let intent: Intent

    /// The model's own confidence in `intent`, which it is trained to calibrate.
    public let intentConfidence: Double

    public init(
        utterance: String, addressed: Double, complete: Double,
        halt: Double, intent: Intent, intentConfidence: Double
    ) {
        self.utterance = utterance
        self.addressed = addressed
        self.complete = complete
        self.halt = halt
        self.intent = intent
        self.intentConfidence = intentConfidence
    }

    // MARK: - Thresholds

    /// Below this, an utterance is treated as overheard rather than addressed.
    ///
    /// Deliberately far from a coin toss, and asymmetric on purpose. The two mistakes
    /// are not equal: acting on a sentence said to somebody else runs a task on the
    /// user's Mac, and *declining* to act on one that was meant for the agent is a turn
    /// the user has to say again. Both are bad, but only one of them is bad silently and
    /// only one of them mutates a machine — and the second is the one the existing
    /// invariant already names: nothing may swallow what somebody said.
    ///
    /// So suppression requires the model to be nearly certain, and everything in the
    /// wide middle submits exactly as it does today.
    public static let addressedFloor = 0.15

    /// Below this, the speaker is taken to be mid-sentence and given `grace`.
    ///
    /// Looser than `addressedFloor` because being wrong costs almost nothing here: the
    /// settle timer submits the turn regardless once the grace expires, so the worst
    /// case is a short wait. That asymmetry is `VoiceTurn`'s and is inherited whole.
    public static let completeFloor = 0.35

    /// Above this, an utterance halts a run even though `VoiceCommand` did not match it.
    ///
    /// High, because this can cancel work. It exists for the shapes the exact-match set
    /// cannot reach — "no no stop", "okay that's not what I wanted, stop" — and not to
    /// second-guess the set on anything it already answers.
    public static let haltCeiling = 0.85

    // MARK: - Reading it

    /// Whether this reading is about the text now being decided.
    public func applies(to text: String) -> Bool { utterance == text }

    /// Whether this was confidently not addressed to the agent.
    public var saysOverheard: Bool { addressed < Self.addressedFloor }

    /// Whether the speaker sounds like they had not finished.
    public var saysUnfinished: Bool { complete < Self.completeFloor }

    /// Whether this is a halt that `VoiceCommand`'s set would have missed.
    public var saysHalt: Bool { halt > Self.haltCeiling }
}

/// Everything the classifier is told about the moment an utterance arrived in.
///
/// The context is not decoration: "open the other one" is an amendment during a run and
/// a bare instruction outside one, and "yes" is an answer only if something asked. A
/// classifier given the words alone would have to guess at exactly the distinctions it
/// was added to make.
public struct TurnContext: Sendable, Equatable {
    /// The turn so far, as the session currently has it.
    public let utterance: String
    /// The last thing the agent said out loud, or empty. What makes an answer an answer.
    public let agentLastSaid: String
    /// Whether a run is going, which is what makes an amendment possible.
    public let isRunInFlight: Bool
    /// Whether the permission gate is holding a destructive call on an answer.
    public let isAwaitingApproval: Bool

    public init(
        utterance: String, agentLastSaid: String,
        isRunInFlight: Bool, isAwaitingApproval: Bool
    ) {
        self.utterance = utterance
        self.agentLastSaid = agentLastSaid
        self.isRunInFlight = isRunInFlight
        self.isAwaitingApproval = isAwaitingApproval
    }
}

/// Something that can read an utterance. One call, all questions.
///
/// **Never throws, and returns nil rather than failing.** This sits on the hot path of a
/// voice turn, and the only useful answer to "the network was slow" is the behaviour the
/// session had before this existed. An error type here would be an error handled at a
/// place that must not stop to handle one.
public protocol TurnClassifier: Sendable {
    func read(_ context: TurnContext) async -> TurnReading?
}

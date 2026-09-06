import Foundation

/// What a run actually did, as distinct from what it said it did.
///
/// The loop used to end a turn with `guard !calls.isEmpty else { .finished }` — "the
/// model stopped talking" reported as "the task is done". Session
/// `DE641705-78C8-4A7C-BFF3-7168528CCD29` is the case that motivated this: asked to
/// format the markdown in the active VS Code tab, the agent ran one `shell` probe,
/// discovered Accessibility was not granted, wrote a paragraph of instructions for the
/// user to follow by hand, and the run closed with `── end_turn` — byte-identical to
/// how a successful run closes. Nothing on screen changed, and nothing said so.
///
/// The distinction that matters is not "did the model emit tool calls" — it emitted
/// one — but "did it change anything". `Risk` already answers that for every
/// invocation: `.read` observes, `.write` and `.dangerous` change state. Counting the
/// two separately turns an unverifiable claim in prose into an arithmetic fact.
public struct RunOutcome: Sendable, Equatable {

    /// Invocations that ran and were classified as changing state.
    ///
    /// Counted after `Policy.escalate` and after the gate allowed them, so a denied or
    /// skipped call is not an action — the point is what actually happened to the
    /// machine, not what was proposed.
    public let actionsTaken: Int

    /// Invocations that ran and only observed.
    public let observationsMade: Int

    /// Whether the task was phrased as a request to act rather than a question.
    public let intent: TaskIntent

    /// Why the loop stopped, as reported to the user.
    public let stopReason: String

    public init(
        actionsTaken: Int, observationsMade: Int, intent: TaskIntent, stopReason: String
    ) {
        self.actionsTaken = actionsTaken
        self.observationsMade = observationsMade
        self.intent = intent
        self.stopReason = stopReason
    }

    /// A run that was asked to do something and changed nothing.
    ///
    /// Deliberately *not* "took no tool calls": a run that observes six times and acts
    /// zero times has done exactly as much to the user's machine as one that did
    /// nothing at all, and the VS Code session is precisely that shape.
    public var isUnfulfilled: Bool {
        intent == .action && actionsTaken == 0
    }

    /// The line a user reads when the run changed nothing it was asked to change.
    ///
    /// Phrased as a statement of fact rather than an apology or a diagnosis. The loop
    /// does not know *why* nothing happened — missing permissions, a model that
    /// narrated instead of acting, a task that turned out to need nothing done — and
    /// guessing wrong is worse than reporting the fact and letting the reply above it
    /// speak for itself.
    public var report: String {
        guard isUnfulfilled else { return stopReason }
        let observed = observationsMade == 1 ? "1 observation" : "\(observationsMade) observations"
        return "nothing was done — \(stopReason) after \(observed) and no actions. "
            + "The reply above describes rather than reports; check it before assuming the task is complete."
    }
}

/// Whether a task asked for an action or asked a question.
///
/// A deliberately small, conservative classifier. It exists to keep the "nothing was
/// done" warning off the very common legitimate path — "how much disk space is left?"
/// is answered by one `shell` read and zero actions, and flagging that would train the
/// user to ignore the warning within a day.
///
/// It errs toward `.action`, because the two mistakes are not symmetric: calling a
/// question an action prints one extra line of noise, while calling an action a
/// question restores the original bug in full.
public enum TaskIntent: String, Sendable, Equatable {
    /// The user asked for something to be done.
    case action
    /// The user asked for information.
    case question

    /// Words that open a question. Matched only at the very start of the task, because
    /// they appear mid-sentence in plenty of imperatives — "tell me what is playing"
    /// is an instruction, and "open the file that is newest" contains "is".
    private static let interrogativeOpeners: Set<String> = [
        "what", "whats", "what's", "where", "wheres", "where's", "when", "why",
        "who", "whos", "who's", "which", "whose", "how", "hows", "how's",
        "is", "are", "was", "were", "does", "do", "did", "can", "could",
        "should", "would", "will", "has", "have", "am",
    ]

    /// Classifies a task by its wording.
    ///
    /// The environment probe is prepended to the task before it reaches the
    /// transcript, so this takes the raw task text — classifying the probe's
    /// `<environment>` block would make every task start with a `<`.
    public static func classify(_ task: String) -> TaskIntent {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .action }

        // A trailing question mark is the one signal a user gives deliberately, so it
        // outranks the opener check in both directions.
        if trimmed.hasSuffix("?") { return .question }

        let firstWord = trimmed
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) } ?? ""

        return interrogativeOpeners.contains(firstWord) ? .question : .action
    }
}

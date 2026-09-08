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
///
/// `Risk` answers it *almost* well enough, and the gap took a second session to find.
/// It says what an invocation was **permitted** to change, decided before the call
/// ran and by definition blind to how it went. A `key` press is `.write` whether the
/// app takes the keystroke or drops it on the floor. Session
/// `39BAB4C3-478C-4D37-9933-9E2C5E2DDC45` is that gap: asked to "press cmd+shift+p to
/// open the command palette", the run recorded `act=1 obs=1 unfulfilled=False`,
/// stopped on `end_turn` and exited 0 — while the tool result it counted read
/// "Pressed cmd+shift+p. No observable change: the frontmost app, window and focused
/// element are all as they were." and the model's own closing prose read "The command
/// palette didn't open." Every layer of the run knew. The arithmetic did not, because
/// the only layer that had checked reported its finding in English.
///
/// So the counter takes a second input: `ToolOutput.changeVerdict`, the verdict of
/// the action's own `UIFingerprint` check, carried as a value rather than a sentence.
/// A permitted change that provably did not happen is not an action. Three states,
/// not two — most tools are never verified at all, and reading "not checked" as
/// "checked and found nothing" would strip `write_file` and `shell` of every action
/// they take and break this guarantee from the other side.
public struct RunOutcome: Sendable, Equatable {

    /// Invocations that ran and were classified as changing state.
    ///
    /// Counted after `Policy.escalate` and after the gate allowed them, so a denied or
    /// skipped call is not an action — the point is what actually happened to the
    /// machine, not what was proposed. Nor is a call whose own verification saw
    /// nothing move: it was proposed, permitted and run, and still changed nothing.
    public let actionsTaken: Int

    /// Invocations that ran and only observed — plus the ones that tried to act and
    /// were verified to have moved nothing, which learned something about the machine
    /// and changed none of it. See the counting site in `AgentLoop` for why those are
    /// booked here rather than dropped from both counters.
    public let observationsMade: Int

    /// Whether the task was phrased as a request to act rather than a question.
    public let intent: TaskIntent

    /// Why the loop stopped — the sentence the user reads, *and* whether that stop
    /// was the run finishing or the run being cut off. See `StopReason`.
    public let stopReason: StopReason

    public init(
        actionsTaken: Int, observationsMade: Int, intent: TaskIntent, stopReason: StopReason
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

    /// A run that stopped before it reached the end of its own work.
    ///
    /// `isUnfulfilled` asks whether anything changed. It never asked whether the run
    /// *finished*, and those are different failures: a run can take five actions, be
    /// cut off halfway through the sixth, and satisfy "it changed something" perfectly.
    /// Session listing, verbatim:
    ///
    ///     open vscode and open the command palette | act=5 obs=7 unfulfilled=False
    ///     stop=turn limit (12) reached
    ///
    /// VS Code was opened, the palette was not, the run ran out of turns mid-task and
    /// exited 0 — because one action had been taken, and the only layer that knew the
    /// run had been cut off said so in a sentence nobody could read as a fact.
    ///
    /// Read off `StopReason.disposition`, never off its wording. The sentences here are
    /// user-visible copy and will be reworded; a check that greps them is a check that
    /// silently stops firing, which is the defect the change verdict was extracted to
    /// avoid one commit ago.
    public var wasCutShort: Bool {
        stopReason.disposition == .cutShort
    }

    /// Either way of not completing the task: nothing changed, or the run was cut off.
    ///
    /// The CLI's exit code and the overlay's closing state both want this question and
    /// not either half of it — to a caller in a shell script, "changed nothing" and
    /// "did not finish" mean the same thing, so they share exit 2 rather than splitting
    /// into two codes nobody would branch on differently.
    public var isIncomplete: Bool {
        isUnfulfilled || wasCutShort
    }

    /// The line a user reads when the run did not complete what it was asked to do.
    ///
    /// Phrased as a statement of fact rather than an apology or a diagnosis. The loop
    /// does not know *why* nothing happened — missing permissions, a model that
    /// narrated instead of acting, a task that turned out to need nothing done — and
    /// guessing wrong is worse than reporting the fact and letting the reply above it
    /// speak for itself. The cut-short line holds the same line: it says the run
    /// stopped early and what it had done by then, and does not speculate about how
    /// much of the task that covered.
    ///
    /// A run can be both — zero actions *and* cut off at the turn limit — and the
    /// "nothing was done" wording wins, because it already interpolates the stop
    /// reason's own sentence. "nothing was done — turn limit (12) reached after 3
    /// observations and no actions" states both facts; the cut-short line would state
    /// only the weaker one, having lost that nothing at all changed.
    public var report: String {
        if isUnfulfilled {
            return "nothing was done — \(stopReason.sentence) after \(Self.counted(observationsMade, "observation")) and no actions. "
                + "The reply above describes rather than reports; check it before assuming the task is complete."
        }
        if wasCutShort {
            return "did not finish — \(stopReason.sentence) after \(Self.counted(actionsTaken, "action")) "
                + "and \(Self.counted(observationsMade, "observation")). "
                + "The run stopped before the model said it was done; check what it did before assuming the task is complete."
        }
        return stopReason.sentence
    }

    /// "1 observation", "4 observations". "1 observations" reads as a bug in the tool
    /// rather than a fact about the run, and this codebase has fixed it twice already.
    private static func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Why the loop stopped, and whether that stop was the run finishing.
///
/// The loop has five exits and each handed `conclude` an English sentence: `"turn
/// limit (12) reached"`, `"response truncated at the 4096-token limit"`, `"the model
/// declined this request (…)"`, `"interrupted by the user"`, and `response.stopReason
/// ?? "end_turn"`. Exactly one of those five means the model decided it was done. The
/// other four mean something stopped it. Nothing downstream could tell them apart,
/// because the difference existed only in the prose, so the exit code and the closing
/// line treated a run that ran out of turns exactly like one that finished.
///
/// The fix is the same shape as `ChangeVerdict`: carry the finding as a value next to
/// the sentence rather than expecting a later layer to parse it back out. The sentence
/// stays exactly as it was — it is user-visible copy in a terminal, an overlay and a
/// session listing — and the `disposition` is what code branches on.
///
/// There is no memberwise initialiser on purpose. A stop reason is constructed through
/// `.concluded(_:)`, `.cutShort(_:)` or `.interrupted`, so adding a sixth exit to the
/// loop forces a decision about which of the three it is; a defaulted parameter would
/// let the next exit be added as "concluded" by omission, which is the failure this
/// type exists to prevent.
public struct StopReason: Sendable, Equatable {

    /// What the stop means for the task, as opposed to what it says to the user.
    public enum Disposition: String, Sendable, Equatable {
        /// The model ended its own turn with nothing further to call. The only exit
        /// that means the agent got to the end of its own work — whether that work
        /// achieved anything is `RunOutcome.isUnfulfilled`'s separate question.
        case concluded
        /// Something ended the run before the model was done: the turn budget, the
        /// token ceiling, a refusal. Whatever the task needed next did not happen.
        case cutShort
        /// The user stopped it. Neither a completion nor a failure to report: a
        /// ctrl-c is the user getting what they asked for, and flagging it as the
        /// agent falling short would put a warning on every deliberate stop and
        /// teach the user to ignore the warning.
        case interrupted
    }

    /// The wording shown to the user. Unchanged from when this was a bare `String`;
    /// no caller may branch on it.
    public let sentence: String

    /// What that wording means, for the layers that have to act on it.
    public let disposition: Disposition

    private init(sentence: String, disposition: Disposition) {
        self.sentence = sentence
        self.disposition = disposition
    }

    /// The model finished its turn with no further tool calls.
    public static func concluded(_ sentence: String) -> StopReason {
        StopReason(sentence: sentence, disposition: .concluded)
    }

    /// The run was stopped before the model was finished.
    public static func cutShort(_ sentence: String) -> StopReason {
        StopReason(sentence: sentence, disposition: .cutShort)
    }

    /// The user stopped the run.
    ///
    /// The wording is reachable as a constant — `AgentLoop.Event.interruptedReason` —
    /// because `SessionController` compares against it to render "Stopped." rather
    /// than a completion. It matches the constant, never the wording.
    public static let interrupted = StopReason(
        sentence: "interrupted by the user", disposition: .interrupted
    )
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

    /// Imperative verbs that ask for information and cannot ask for a change.
    ///
    /// Found by running the thing: `count the files in /tmp and tell me the number` is
    /// phrased as an instruction, so the opener check called it an action — and a
    /// correct run answers it with one read and zero actions, which the guard would
    /// then report as "nothing was done" and exit 2, breaking any `&&` chain after it.
    /// A guard that fires on correct runs is one the user learns to ignore, which
    /// costs more than the case it was built for.
    ///
    /// Deliberately narrow. `show`, `tell`, `find`, `check` and `read` are all
    /// excluded, because each has a perfectly ordinary action reading on a Mac —
    /// `tell application "Spotify" to play` is the idiom this project is built around,
    /// and `show me in my current vscode how can I format the markdown file` is the
    /// exact run that motivated the guard. Only verbs with no state-changing sense at
    /// all belong here.
    private static let informationalOpeners: Set<String> = [
        "count", "list", "summarize", "summarise", "describe", "explain", "compare",
    ]

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

        if interrogativeOpeners.contains(firstWord) { return .question }
        if informationalOpeners.contains(firstWord) { return .question }
        return .action
    }
}

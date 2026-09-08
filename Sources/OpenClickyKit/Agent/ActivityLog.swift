import Foundation

/// What the agent has actually done, in order, kept so a surface can show it.
///
/// The overlay has always had exactly one line: whatever the last event happened to
/// say, overwritten by the next one a fraction of a second later. That is enough to
/// know something is happening and not enough to know *what* — a run that read three
/// files, was refused a fourth, and then pressed a button is indistinguishable from
/// one that did nothing but press the button, because only the last frame survives.
/// A user watching a program drive their Mac is entitled to the whole sequence, and
/// especially to the parts of it the agent asked for and did not get.
///
/// In `OpenClickyKit` rather than in the app for the reason `Conversation` and
/// `ProviderSelection` are: the app target has no tests, and the two properties that
/// matter here — that it stays bounded, and that it never shows what the transcript
/// withholds — are exactly the kind that fail silently and cost nothing to check.
///
/// Nothing is sanitised on the way in, deliberately. Every string this type stores
/// arrived through a check that already exists: `.toolStarted` carries `Risk.summary`,
/// which is `Policy.summarize`d on the way out of the classifier because the tools
/// kept forgetting to; `.toolFinished` carries the flattening of `output.content`,
/// which is the *same array* the loop puts in the `tool_result` sent to the model, so
/// `Policy.printsSecret` withholding a credential from the model withholds it from
/// here by construction. A second sanitiser in this file would be a second thing to
/// keep in step with the first, and the first is the one three audits hardened.
public struct ActivityLog: Sendable, Equatable {

    /// One thing that happened.
    public struct Entry: Sendable, Equatable, Identifiable {

        public enum Kind: Sendable, Equatable {
            /// A task the user submitted. A divider, not a tool call.
            case instruction
            /// A call that passed the gate and is running.
            case started
            case succeeded
            case failed
            /// Refused at the permission gate. The point of the whole panel.
            case denied
            /// Not run, because an earlier call in the same turn failed.
            case skipped
        }

        /// Monotonic and never reused, including across a trim.
        ///
        /// SwiftUI identifies rows by this. An index would do the wrong thing the
        /// first time the log drops its oldest entry: every row's identity would
        /// shift by one and the list would animate as though all of them had changed.
        public let id: Int
        public let kind: Kind
        /// The tool's name, or the empty string for an entry that is not a call.
        public let tool: String
        /// The tier the call was made at, when it was a call. `Tier.forToolNamed`
        /// answers for the events that do not carry one, and honestly returns nil for
        /// a name this build does not know.
        public let tier: Tier?
        /// The risk summary, the result, the denial's reason, or the instruction.
        public let detail: String
    }

    /// How many entries are kept.
    ///
    /// The session is persistent — one overlay, one loop, one conversation, for as
    /// long as the user leaves it running — so an unbounded log is a leak measured in
    /// hours rather than in turns. 200 is chosen against the two things that bound
    /// it from either side: a single task cannot emit many more than that (40 turns
    /// is the loop's own ceiling, and a turn's batch is a handful of calls, each
    /// producing a start and a finish), so a run is almost always visible whole; and
    /// 200 entries of a 160-character detail is ~40 KB, which is nothing beside a
    /// single screenshot. Above that the panel is scrollback nobody scrolls.
    public static let capacity = 200

    /// Oldest first, so a reader arriving late reads downward to the present.
    public private(set) var entries: [Entry] = []

    /// How many entries the bound has discarded.
    ///
    /// Kept and shown rather than dropped silently. The alternative is a panel that
    /// says "shell ✓" fourteen times and does not mention that the eleven calls
    /// before them are gone — which reads as a complete record of the run and is not
    /// one. Trimming from the front and counting it keeps the claim honest: what is
    /// on screen is the *end* of the run, and the panel says how much is missing.
    public private(set) var elided = 0

    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Everything that has happened, including what the bound discarded.
    public var totalRecorded: Int { entries.count + elided }

    /// The most recent entry, which is what a collapsed panel shows.
    public var latest: Entry? { entries.last }

    /// Records an agent event, if it is one worth keeping.
    ///
    /// - Returns: whether anything was appended, so a caller can avoid notifying a UI
    ///   about a token count.
    @discardableResult
    public mutating func record(_ event: AgentLoop.Event) -> Bool {
        switch event {
        case let .toolStarted(name, tier, summary):
            append(.started, tool: name, tier: tier, detail: summary)
        case let .toolFinished(name, ok, detail):
            append(ok ? .succeeded : .failed, tool: name, tier: Tier.forToolNamed(name), detail: detail)
        case let .toolDenied(name, reason):
            append(.denied, tool: name, tier: Tier.forToolNamed(name), detail: reason)
        case let .toolSkipped(name):
            append(
                .skipped, tool: name, tier: Tier.forToolNamed(name),
                detail: "an earlier action in this turn failed"
            )
        default:
            // Thinking, assistant prose, usage, cost, plans and the closing verdict all
            // have a home on screen already. This panel answers one question — what did
            // it *do* — and a log that also carries the narration answers it worse.
            return false
        }
        return true
    }

    /// Records the instruction a task is starting from.
    ///
    /// The log spans the conversation rather than the task, so without this the tenth
    /// instruction's calls sit directly under the ninth's with nothing between them.
    public mutating func record(instruction: String) {
        append(.instruction, tool: "", tier: nil, detail: instruction)
    }

    /// Empties the log.
    ///
    /// Called where the conversation ends and nowhere else — see `SessionController`.
    public mutating func clear() {
        entries.removeAll()
        elided = 0
        // `nextID` deliberately keeps counting. Restarting it would let a row from the
        // new conversation share an identity with one SwiftUI is still animating out.
    }

    private mutating func append(_ kind: Entry.Kind, tool: String, tier: Tier?, detail: String) {
        entries.append(Entry(id: nextID, kind: kind, tool: tool, tier: tier, detail: detail))
        nextID += 1
        // From the front, so what remains is contiguous and ends at the present. A cap
        // that dropped the *newest* would keep the panel frozen on the first minute of
        // a run; one that dropped from the middle would splice two moments together
        // and read as one.
        if entries.count > Self.capacity {
            let excess = entries.count - Self.capacity
            entries.removeFirst(excess)
            elided += excess
        }
    }
}

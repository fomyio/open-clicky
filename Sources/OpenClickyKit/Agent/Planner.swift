import Foundation

/// Asks a stronger model how to approach a task before a cheaper one carries it out.
///
/// The capability ladder applied to model choice instead of tool choice. The tiers
/// already say a task should be answered by the cheapest capability that can do it;
/// the same argument holds one level up, because choosing *which* tier to use is the
/// judgement call, and doing it well is what a strong model is for. Deciding to run
/// `prettier` over a file rather than driving a GUI is a planning decision worth Opus
/// prices once; the twelve turns that follow are not.
///
/// # Why this is a separate conversation
///
/// The obvious implementation — plan on turn 0 with the strong model, switch to the
/// cheap one for the rest — is not available here, and the reason is an invariant
/// rather than a preference. The transcript is append-only and assistant turns replay
/// verbatim, thinking blocks included, because those blocks are bound to the model
/// that produced them. Switching models mid-conversation would replay one model's
/// thinking to another, which is at best wasted tokens and at worst a 400 on every
/// subsequent turn.
///
/// So the planner runs as a self-contained call with its own prompt and its own
/// short-lived message list, and hands back nothing but text. The executor's
/// transcript never contains a foreign assistant turn, and the two models never share
/// a conversation. It costs one extra round-trip; it cannot corrupt the run.
///
/// # What it does not do
///
/// It holds no tools and takes no actions. A plan is a suggestion to the executor,
/// not a script it must follow — the executor observes the real machine and the
/// planner never does, so the executor has to be free to depart from it. Anything
/// else would make a stale plan authoritative over a fresh observation.
public struct Planner: Sendable {

    /// The model asked to plan. Nil disables planning entirely.
    public let model: String
    /// Small on purpose: a plan is a handful of lines, and a planner given room to
    /// write an essay writes one — which is then paid for again in the executor's
    /// first user message, on every turn, forever.
    public let maxTokens: Int

    public init(model: String, maxTokens: Int = 1_000) {
        self.model = model
        self.maxTokens = maxTokens
    }

    /// The planner's system prompt.
    ///
    /// Built from the registry so it can only propose tiers this run actually has.
    /// A plan that opens with "take a screenshot" under `--max-tier 1` is worse than
    /// no plan: the executor spends a turn discovering the tool is absent, and the
    /// plan it was given is now partly wrong in a way it has to reason around.
    public static func prompt(registry: ToolRegistry) -> String {
        """
        You are the planning half of OpenClicky, an agent that operates a user's Mac.
        Another model will carry out your plan. You take no actions yourself.

        \(SystemPrompt.ladderSummary(registry: registry))

        Given the task and the machine's current state, write a short plan: at most \
        five numbered steps, one line each, naming the tier and the tool you would use \
        for each. Prefer the cheapest tier that can do the job — most "control my Mac" \
        tasks are a shell command or an AppleScript, not a sequence of clicks.

        Say plainly if the task looks impossible with the capabilities listed, or if \
        it is a question to answer rather than an action to take.

        Be terse. The executor pays for these tokens on every turn of its run.
        """
    }

    /// What a planning call produced, and what it cost to produce.
    ///
    /// The usage travels with the text because the caller has to bill it. Returning
    /// the plan alone left the planner's tokens unrecorded, and a run with an Opus
    /// planner in front of a Haiku executor then reported the cheaper half as the
    /// whole cost — understating the bill by most of it.
    public struct Planned: Sendable {
        public let text: String
        public let usage: Wire.Usage
    }

    /// Produces a plan, or nil if the planner could not be reached.
    ///
    /// Failure is deliberately not fatal. A planner is an optimisation, and a run that
    /// refuses to start because the *advice* was unavailable is strictly worse than
    /// one that proceeds without it — the executor is a complete agent on its own and
    /// was, until this existed, the only one there was.
    public func plan(
        task: String,
        environment: String,
        registry: ToolRegistry,
        client: any MessagesClient
    ) async -> Attempt {
        let request = Wire.Request(
            model: model,
            maxTokens: maxTokens,
            system: [.init(Self.prompt(registry: registry), cacheControl: true)],
            messages: [.user("\(environment)\n\n\(task)")],
            // No tools. A planner that could act would be an executor, and it would
            // be acting on a machine it has not observed.
            tools: []
        )
        let response: Wire.Response
        do {
            response = try await client.send(request)
        } catch {
            // Kept, not swallowed. The commonest way this fails is a planner model the
            // configured provider has never heard of — `--provider ollama --planner
            // claude-opus-5` sends "claude-opus-5" to Ollama — and the endpoint's own
            // error says exactly that. Collapsing it to nil turned a typo into a run
            // that quietly did not plan.
            return .unavailable(String(describing: error).truncated(300))
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .unavailable("the planning model returned no text")
        }
        return .planned(Planned(text: text, usage: response.usage))
    }

    /// What a planning attempt produced.
    ///
    /// An enum rather than an optional because "there is no plan" has two meanings
    /// that must not be confused: nobody asked for one, and one was asked for and did
    /// not arrive. The second is a failure to report — the user typed `--planner` and
    /// paid for a round-trip.
    public enum Attempt: Sendable {
        case planned(Planned)
        case unavailable(String)
    }

    /// How the plan is handed to the executor.
    ///
    /// Framed as advice from another model, explicitly non-binding, and explicitly
    /// junior to what the executor can see for itself. The executor observes the real
    /// machine; the planner never did. A plan presented as instruction would have the
    /// executor follow a stale step past the evidence in front of it — which is the
    /// failure mode that makes planning worth less than not planning.
    /// Opens the block appended to the first user message.
    ///
    /// A constant because two readers depend on it: the loop writes it, and every
    /// reader of the record has to cut it back off to recover what was asked. Matched
    /// against, never retyped.
    public static let briefMarker = "<plan>"

    public static func brief(_ plan: String) -> String {
        """
        <plan>
        A stronger model was asked how to approach this before you started. Its \
        suggestion:

        \(plan)
        </plan>

        The plan is advice, not instruction. It was written without observing the \
        machine, so where what you see disagrees with it, what you see wins. Depart \
        from it whenever you have a reason to, and say so when you do.
        """
    }
}

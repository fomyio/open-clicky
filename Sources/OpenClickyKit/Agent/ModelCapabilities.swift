import Foundation

/// Which request fields a model family actually accepts, and what it can be trusted
/// to do once the request arrives.
///
/// `thinking: {type: "adaptive"}` and `output_config.effort` are Claude 4.6-and-later
/// features. Sending either to an older family is a 400 on every single request, not a
/// degraded answer — so the shape of the request has to follow the model it is going
/// to. Before this existed the encoder sent adaptive thinking unconditionally, which
/// was correct only for as long as the default model happened to be Opus 5: changing
/// the default to Haiku broke every request, and the failure looked like a bad API key
/// rather than an unsupported field.
///
/// Opening the agent to OpenAI-compatible providers widened the question rather than
/// duplicating it. "Which system role does it take", "which key carries the output
/// cap", "what pixel space do its images live in" and "can it drive pixels at all"
/// are the same question — what does this model accept — and answering them in a
/// second type would recreate the desync this one was built to remove.
///
/// Unknown models get the conservative shape. Every field here is optional on the
/// wire or safe to under-claim, so guessing *off* degrades a run while guessing *on*
/// fails it: adaptive thinking 400s where it is not understood, and a model told it
/// can read screenshots when it cannot returns confident coordinates for an image it
/// never saw. A newer family therefore has to be added here to get the good shape;
/// that is deliberate.
public struct ModelCapabilities: Sendable, Equatable {

    /// Accepts `thinking: {type: "adaptive"}`.
    public let adaptiveThinking: Bool
    /// Accepts `output_config.effort`.
    public let effort: Bool

    /// Whether images can be sent to this model at all.
    ///
    /// Not a cost question. A text-only model handed an `image_url` either 400s or —
    /// worse, and this is the common one on local runtimes — drops the image and
    /// answers from the prompt alone, inventing coordinates for a screen it never saw.
    public let vision: Bool

    /// The pixel space this model's images live in. See `ImageSpace`.
    public let imageSpace: ImageSpace

    /// Which role carries the system prompt on an OpenAI-compatible endpoint.
    ///
    /// The reasoning families renamed it: `developer` on o-series and GPT-5, `system`
    /// everywhere else, including every local runtime.
    public let systemRole: String

    /// The key that carries the output cap on an OpenAI-compatible endpoint.
    ///
    /// `max_tokens` is deprecated on OpenAI and rejected outright by the reasoning
    /// families, while `max_completion_tokens` is unknown to Ollama's older builds.
    /// There is no field that works everywhere, so the model picks.
    public let outputTokenField: String

    /// Whether the endpoint understands OpenAI's `strict` function schemas.
    ///
    /// Independent of whether a given schema *qualifies* — strict mode additionally
    /// requires every property to appear in `required`, which several of our schemas
    /// deliberately do not do. Both gates are applied; see `OpenAIWire.tools`.
    public let strictTools: Bool

    /// The highest tier this model can be trusted to drive.
    ///
    /// Tier 3 is predicting a coordinate from a picture. A model that cannot see the
    /// picture has no business being offered `click`, and a small local one that can
    /// see it is still far better served by `ax_press` on an element id — so the
    /// ceiling is a capability, not a preference, and `ToolRegistry` removes the tools
    /// rather than the prompt discouraging them.
    public var maxTier: Tier { vision ? .pixels : .accessibility }

    /// Whether this model should be steered onto the accessibility tree.
    ///
    /// True for everything that cannot see, which is the same set as `!vision` today
    /// but is asked as a different question and may not stay the same set.
    public var prefersElementIDs: Bool { !vision }

    /// Accepts `reasoning_effort`, the OpenAI families' own control.
    ///
    /// A separate question from `effort`, which is Anthropic's `output_config.effort`.
    /// They are differently-shaped fields on different dialects, and the reason this
    /// codebase declined to map between them for so long was that inventing a mapping
    /// would silently change what the user asked for.
    ///
    /// The argument stopped holding once the GPT-5 family arrived. The status quo was
    /// never "we did not choose an effort" — it was "we silently chose **medium**",
    /// which is the default, and which is what made a 1,000-token planner budget produce
    /// a thousand reasoning tokens and an empty string. Declining to map is itself a
    /// choice, made on the user's behalf, in the direction that costs the most.
    public let reasoningEffort: Bool

    public init(
        adaptiveThinking: Bool,
        effort: Bool,
        reasoningEffort: Bool = false,
        promptCaching: Bool = false,
        vision: Bool = false,
        imageSpace: ImageSpace = .anthropic,
        systemRole: String = "system",
        outputTokenField: String = "max_tokens",
        strictTools: Bool = false
    ) {
        self.adaptiveThinking = adaptiveThinking
        self.effort = effort
        self.reasoningEffort = reasoningEffort
        self.effortFamilyIsAnthropic = promptCaching
        self.vision = vision
        self.imageSpace = imageSpace
        self.systemRole = systemRole
        self.outputTokenField = outputTokenField
        self.strictTools = strictTools
    }

    /// Families known to accept the 4.6+ request fields.
    ///
    /// Prefixes, so dated ids (`claude-opus-4-6-20260514`) match their family.
    private static let modernFamilies = [
        "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-sonnet-5", "claude-sonnet-4-6",
        "claude-fable-5", "claude-mythos-5",
    ]

    /// OpenAI families that see images.
    private static let openAIVisionFamilies = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "chatgpt-4o", "o3", "o4",
    ]

    /// OpenAI families that renamed the system role and the output cap.
    private static let openAIReasoningFamilies = ["o1", "o3", "o4", "gpt-5"]

    /// Locally-served models that see images.
    ///
    /// Short on purpose. A model missing from this list loses tier 3 and keeps working
    /// through the accessibility tree; a text-only model wrongly on it silently
    /// invents coordinates.
    private static let localVisionFamilies = [
        "llava", "llama3.2-vision", "llama3.1-vision", "qwen2-vl", "qwen2.5vl",
        "minicpm-v", "moondream", "mistral-small3.1", "llama-4-scout",
        "llama-4-maverick", "pixtral",
    ]

    /// Set for the ids this build speaks the Messages API to.
    private let effortFamilyIsAnthropic: Bool

    public static func forModel(_ model: String) -> ModelCapabilities {
        let id = normalized(model)
        let isModern = modernFamilies.contains { id.hasPrefix($0) }

        if id.hasPrefix("claude") {
            return ModelCapabilities(
                adaptiveThinking: isModern, effort: isModern, promptCaching: true,
                vision: true, imageSpace: .anthropic,
                // Only reachable through an OpenAI-compatible proxy in front of
                // Anthropic, which speaks the OpenAI dialect either way.
                systemRole: "system", outputTokenField: "max_tokens", strictTools: true
            )
        }

        if openAIVisionFamilies.contains(where: { id.hasPrefix($0) })
            || id.hasPrefix("gpt-") || id.hasPrefix("o1") {
            let isReasoning = openAIReasoningFamilies.contains { id.hasPrefix($0) }
            return ModelCapabilities(
                adaptiveThinking: false, effort: false, reasoningEffort: isReasoning,
                vision: openAIVisionFamilies.contains { id.hasPrefix($0) },
                imageSpace: .openAI,
                systemRole: isReasoning ? "developer" : "system",
                outputTokenField: isReasoning ? "max_completion_tokens" : "max_tokens",
                strictTools: true
            )
        }

        if localVisionFamilies.contains(where: { id.hasPrefix($0) }) {
            return ModelCapabilities(
                adaptiveThinking: false, effort: false,
                vision: true, imageSpace: .localVision,
                systemRole: "system", outputTokenField: "max_tokens",
                // Ollama, llama.cpp and Groq accept the field's absence; several
                // reject the field itself. Absent is the shape that works everywhere.
                strictTools: false
            )
        }

        // Everything else: text-only, tier 2, the plainest request that exists.
        return ModelCapabilities(
            adaptiveThinking: false, effort: false,
            vision: false, imageSpace: .unconstrained,
            systemRole: "system", outputTokenField: "max_tokens", strictTools: false
        )
    }

    /// Whether this project places cache breakpoints in requests for this model.
    ///
    /// Only the Anthropic dialect has `cache_control`, and `OpenAIWire.messages` drops it
    /// entirely — so on every other endpoint this build asks for no caching at all, and
    /// a zero hit rate there describes the absence of a mechanism rather than a prefix
    /// being invalidated. The canary that said otherwise fired on every local run: an
    /// Ollama or Groq prompt is far above the caching floor, so the "your prefix is
    /// churning" branch was the one that ran, every time, unfixably. A warning that
    /// always fires is one nobody reads by the third run.
    ///
    /// Keyed on the model id rather than the client, which is the one seam a report has:
    /// a Claude served *through* an OpenAI-compatible proxy is the case this gets wrong,
    /// and it gets it wrong in the direction of showing a note that names a real
    /// mechanism rather than hiding one.
    public var promptCaching: Bool { effortFamilyIsAnthropic }

    /// This project's effort ladder, in the vocabulary `reasoning_effort` accepts.
    ///
    /// Five levels into four, and the collapse is deliberate in both directions.
    ///
    /// **`xhigh` and `max` fold to `high`**, because `high` is the most this field
    /// offers. Folding is honest where silence was not: the run says so once, the way
    /// `cappedTierWarning` does for a tier it could not reach.
    ///
    /// **Nothing maps to `minimal`.** It is an accepted value and it spends *zero*
    /// reasoning tokens — measured: 0 reasoning tokens and 134 completion tokens where
    /// the default spent 1,000. So it does not mean "think a little", it means "do not
    /// think", and quietly turning a reasoning model into a non-reasoning one behind a
    /// flag whose lowest setting is called `low` would be the same class of silent
    /// substitution this whole field exists to stop. Someone who wants that can pick a
    /// model that does not reason.
    public static func reasoningEffort(for effort: String) -> String {
        switch effort {
        case "low": return "low"
        case "medium": return "medium"
        case "high", "xhigh", "max": return "high"
        // Unreachable through the parser, which validates the value. A word nobody
        // taught this code gets the API's own default rather than a guess.
        default: return "medium"
        }
    }

    /// Whether this ladder rung is being folded into a coarser one.
    public static func foldsReasoningEffort(_ effort: String) -> Bool {
        effort == "xhigh" || effort == "max"
    }

    /// Strips the decoration a model id picks up on its way through a proxy.
    ///
    /// LiteLLM routes by `openai/gpt-4o` and `ollama/llava`, Ollama tags by
    /// `llava:13b`, and Bedrock prefixes with a region. Matching the raw string meant
    /// `openai/gpt-4o` fell through to the unknown branch and lost its eyes — a
    /// working configuration silently demoted to tier 2 by a prefix the user did not
    /// choose and could not remove.
    static func normalized(_ model: String) -> String {
        let lowered = model.lowercased()
        let afterSlash = lowered.split(separator: "/").last.map(String.init) ?? lowered
        return afterSlash.split(separator: ":").first.map(String.init) ?? afterSlash
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

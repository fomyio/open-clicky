import Foundation

/// One model a picker can offer, and what it can be trusted to do.
///
/// `vision` is derived from `ModelCapabilities`, never stated here. A catalogue that
/// carried its own copy would be a second answer to "can this model see", and the two
/// would drift — with the picker promising tier 3 for a model the registry then
/// refuses to give the pixel tools to, which looks like a broken app rather than a
/// disagreement between two lists.
public struct ModelChoice: Sendable, Equatable, Identifiable {
    /// The model id sent on the wire, and the identity in a picker.
    public let id: String
    /// What to show. The id itself where the id is already readable.
    public let label: String
    /// One short phrase on when to pick it. Nil where there is nothing worth saying.
    public let note: String?

    public init(id: String, label: String? = nil, note: String? = nil) {
        self.id = id
        self.label = label ?? id
        self.note = note
    }

    public var capabilities: ModelCapabilities { .forModel(id) }

    /// Whether this model can be sent a screenshot.
    ///
    /// The question a picker exists to answer. A text-only model handed an image
    /// either 400s or — the common case on local runtimes — drops it and answers from
    /// the prompt alone, inventing coordinates for a screen it never saw. So the
    /// registry removes the pixel tools rather than trusting the model to decline
    /// them, and the picker says so before the run rather than after.
    public var vision: Bool { capabilities.vision }

    /// The highest tier a run on this model can reach.
    public var maxTier: Tier { capabilities.maxTier }

    /// A one-line verdict for a settings panel.
    public var capabilitySummary: String {
        vision
            ? "Sees the screen — tiers 0–3, including clicks on a screenshot."
            : "Cannot be sent images — tiers 0–2, driven through the accessibility tree."
    }
}

/// The models each provider is offered in the app, and which of them can plan.
///
/// Deliberately a short, curated list rather than a live `/models` query: the endpoint
/// answers with everything an account can reach, including embedding and audio models
/// that would 400 on the first request, and it answers nothing at all when the
/// credential is the thing being set up. Every list here is also a free-text field in
/// the UI, so an id this build has never heard of is always reachable — the catalogue
/// is a shortcut, never a gate.
public enum ModelCatalog {

    /// Models offered for the executor — the model that actually drives the Mac.
    public static func models(for kind: Provider.Kind) -> [ModelChoice] {
        switch kind {
        case .anthropic:
            return [
                ModelChoice(id: "claude-opus-5", label: "Claude Opus 5",
                            note: "Most capable; the one to reach for on hard UI work"),
                ModelChoice(id: "claude-sonnet-5", label: "Claude Sonnet 5",
                            note: "Balanced"),
                ModelChoice(id: DefaultModel.id, label: "Claude Haiku 4.5",
                            note: "Fastest and cheapest; the default"),
                ModelChoice(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
            ]
        case .openai:
            return [
                ModelChoice(id: "gpt-5", label: "GPT-5"),
                ModelChoice(id: "gpt-4.1", label: "GPT-4.1"),
                ModelChoice(id: "gpt-4o", label: "GPT-4o", note: "The default"),
                ModelChoice(id: "o3", label: "o3", note: "Reasoning; slower per turn"),
            ]
        case .groq:
            return [
                ModelChoice(id: "meta-llama/llama-4-scout-17b-16e-instruct",
                            label: "Llama 4 Scout"),
                ModelChoice(id: "meta-llama/llama-4-maverick-17b-128e-instruct",
                            label: "Llama 4 Maverick"),
                ModelChoice(id: "llama-3.3-70b-versatile", label: "Llama 3.3 70B",
                            note: "The default"),
            ]
        case .ollama:
            return [
                ModelChoice(id: "llama3.2-vision", label: "Llama 3.2 Vision"),
                ModelChoice(id: "qwen2.5vl", label: "Qwen2.5-VL"),
                ModelChoice(id: "llava", label: "LLaVA"),
                ModelChoice(id: "llama3.2", label: "Llama 3.2", note: "The default"),
            ]
        case .litellm:
            // Nothing to offer, and offering something would be worse than an empty
            // list: LiteLLM routes by names its own configuration defines, so every
            // guess is a 404 that reads as "the proxy is broken".
            return []
        }
    }

    /// Models offered as the planner — asked how to approach the task, once, before
    /// the executor starts.
    ///
    /// The same provider's list, because the planner runs on the same client with the
    /// same credential: a planner from another provider is a model id this endpoint
    /// has never heard of, which is exactly how `--provider ollama --planner
    /// claude-opus-5` fails today.
    ///
    /// Text-only models are included. A planner takes no actions and sees no
    /// screenshots — it reads the task and the environment probe — so vision is not
    /// what makes one good at planning, and excluding them would remove the cheapest
    /// sensible pairing on a local runtime.
    public static func planners(for kind: Provider.Kind) -> [ModelChoice] {
        models(for: kind)
    }

    /// Why a planner choice is questionable, or nil when it is fine.
    ///
    /// Advice, not a rule — the settings panel shows it and still saves. Planning
    /// costs a round-trip and the planner's own prices, and the two ways to spend that
    /// for nothing are worth naming where the choice is made rather than discovering
    /// in a bill.
    public static func plannerCaution(planner: String, executor: String) -> String? {
        let planner = planner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !planner.isEmpty else { return nil }
        if planner == executor {
            return """
                This is the same model as the executor, so planning costs an extra \
                round-trip and adds no judgement the run would not already have. \
                Pick a stronger model, or none.
                """
        }
        return nil
    }
}

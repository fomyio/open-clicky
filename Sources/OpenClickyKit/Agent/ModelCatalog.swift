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
/// Deliberately a short, curated list rather than a live `/models` query, for the
/// hosted providers: the endpoint answers with everything an account can reach,
/// including embedding and audio models that would 400 on the first request, and it
/// answers nothing at all when the credential is the thing being set up. Every list
/// here is also a free-text field in the UI, so an id this build has never heard of is
/// always reachable — the catalogue is a shortcut, never a gate.
///
/// Ollama is the one exception, and it is `isLiveQueried`. Both objections above are
/// objections to a *hosted* endpoint's answer, and neither survives a keyless local
/// daemon: there is no credential to set up first, and what it lists is not everything
/// an account may reach but exactly what this machine has pulled. A curated list, by
/// contrast, cannot be right for it even in principle — see `models(for:)`.
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
            // Empty for LiteLLM's reason, arrived at the hard way. This list used to
            // offer `llama3.2-vision`, `qwen2.5vl`, `llava` and `llama3.2` — and on
            // the machine the bug was found on, the daemon served `deepseek-r1:7b`,
            // `llama3:latest`, `glm-5.2:cloud` and five more. Not one of the four was
            // installed. Every Ollama entry in the picker 404'd, including the default
            // the picker opened on, and a 404 from a local daemon reads as a broken
            // install rather than as a model nobody pulled.
            //
            // No static list can be right here, so none is offered. An Ollama id names
            // something a particular machine has pulled, and the two endpoints that
            // serve the same model do not agree about its id: the local daemon relays
            // a cloud model as `glm-5.2:cloud`, while `https://ollama.com/v1` serves
            // that same model as `glm-5.2`. An id is only meaningful next to the
            // endpoint that answers for it, so the list is asked of that endpoint —
            // `installed(for:baseURL:apiKey:)` — and until it answers there is nothing
            // honest to show. The UI degrades to its free-text field on an empty
            // catalogue, which is the right control for a value only the daemon knows.
            return []
        case .litellm:
            // Nothing to offer, and offering something would be worse than an empty
            // list: LiteLLM routes by names its own configuration defines, so every
            // guess is a 404 that reads as "the proxy is broken".
            return []
        }
    }

    /// Whether this provider's list is asked of its endpoint rather than written here.
    ///
    /// True for Ollama alone. The two standing objections to a live `/models` query —
    /// that it lists models which would 400 on the first request, and that it answers
    /// nothing while the credential is still being set up — are both objections to a
    /// hosted, billed, credentialed endpoint. A local daemon needs no credential, and
    /// what it lists is precisely what someone pulled onto this machine, so for it the
    /// query is not a worse answer than a curated list: it is the only correct one.
    public static func isLiveQueried(_ kind: Provider.Kind) -> Bool { kind == .ollama }

    /// The models an endpoint reports it actually serves.
    ///
    /// Ids come back exactly as the endpoint wrote them, and nothing here rewrites one.
    /// That is the whole point: `glm-5.2:cloud` is what the local daemon calls the
    /// model it relays, `glm-5.2` is what `https://ollama.com/v1` calls the same model,
    /// and a suffix stripped on the way to a picker becomes a 404 on the way to the
    /// wire. `ModelCapabilities.normalized` splits an id at the colon to *look up* a
    /// family; it must never be what a model id is sent as.
    ///
    /// Every failure is the same empty list: an unreachable daemon, a timeout, a
    /// non-200, a body that does not parse. A settings window is opened *because*
    /// something is misconfigured, so it must not be the thing that throws — and an
    /// empty catalogue is not a dead end here, it is the free-text field.
    ///
    /// - Parameter apiKey: sent only where it can be sent safely. See below.
    public static func installed(
        for kind: Provider.Kind, baseURL: URL?, apiKey: String? = nil
    ) async -> [ModelChoice] {
        await installed(for: kind, baseURL: baseURL, apiKey: apiKey, session: nil)
    }

    /// Seam for tests: a stubbed `URLSession`, so the wire shape is exercised without
    /// a daemon. Every test in this project that touches HTTP goes through one.
    static func installed(
        for kind: Provider.Kind, baseURL: URL?, apiKey: String?, session: URLSession?
    ) async -> [ModelChoice] {
        guard isLiveQueried(kind), let endpoint = baseURL ?? kind.defaultBaseURL else {
            return []
        }

        // The refusal `Provider.resolve` makes, made quietly. A bearer token over
        // plaintext HTTP to anything but the loopback interface is readable by every
        // hop in between; a run refuses outright rather than leak it. A listing has a
        // quieter option — ask unauthenticated, which a local daemon answers and a
        // remote one rejects into the empty list every other failure produces here.
        // What it must not do is become the one path that sends the key in the clear.
        var key = apiKey
        if endpoint.scheme?.lowercased() == "http", !Provider.isLoopback(endpoint.host) {
            key = nil
        }

        let client = OpenAICompatibleClient(
            provider: kind.label, baseURL: endpoint, apiKey: key,
            session: session ?? shortLivedSession()
        )
        return await client.availableModels().map { ModelChoice(id: $0) }
    }

    /// A session for one listing. Separate from the run's, whose request timeout is ten
    /// minutes because a local model on CPU can take that long for one turn — a
    /// settings window that inherited it would sit spinning for ten minutes on a daemon
    /// that is simply not running.
    private static func shortLivedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = ["User-Agent": "OpenClicky/0.1 (macOS)"]
        return URLSession(configuration: config)
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

import Foundation

/// What a loop was built out of, reduced to the fields that shape it.
///
/// A persistent session reuses one `AgentLoop` across many instructions, and that loop
/// is *made* of the provider it was resolved from: the client and its endpoint, the
/// tool registry, the image space, the model and the planner are all fixed at
/// construction and cannot be changed afterwards. So a cached loop is only valid for as
/// long as the configuration it was built from is still the configuration a new task
/// would resolve to — and the moment the Settings window writes a different one, the
/// loop becomes a thing that talks to the previous endpoint with the previous tools,
/// silently, while the overlay reports the new choice. That is the defect class this
/// project keeps finding, so the check is a value comparison rather than a promise
/// someone remembers to keep.
///
/// In the library rather than in the app for the reason `ProviderSelection` is: the
/// rule is decidable, the app target has no tests, and a rule defended by nothing is
/// how a settings change quietly stops taking effect.
///
/// Object identity is deliberately not the comparison. Two `Provider` values resolved
/// a minute apart from an unchanged `config.json` describe the same run and must be
/// treated as the same configuration, or every task would rebuild and "carries context
/// forward" would be false while looking true.
public struct SessionConfiguration: Equatable, Sendable {

    /// Which dialect the client speaks, which header signs the request, and — through
    /// `ModelCapabilities` — what image space a screenshot is scaled into. A loop built
    /// for one provider cannot serve another under any circumstances.
    public let kind: Provider.Kind

    /// The executor. It decides the request shape, the tier ceiling and whether the
    /// pixel tools exist at all: a model that cannot be sent an image is handed no
    /// screenshot tools, and that registry is baked into the loop. Swapping the model
    /// under a cached loop would leave a seeing model without eyes, or send an image to
    /// one that 400s on it.
    public let model: String

    /// The endpoint. Provider and model can both be unchanged while this moves from a
    /// local daemon to a proxy on another machine; the client holds it, so a cached
    /// loop would keep addressing the old one.
    public let baseURL: URL?

    /// The planner, or nil for an unplanned run. Held in `AgentLoop.Configuration`, so
    /// turning it on, off, or over to a different model changes what happens before the
    /// first tool call of every task — and it is billed separately, so a stale planner
    /// spends money on a model the user has stopped choosing.
    public let planner: String?

    /// A digest of the credential, never the credential.
    ///
    /// The key is signed into every request by a client built once, so a key corrected
    /// in Settings mid-session would not reach the endpoint until something rebuilt the
    /// loop — the user's fix would appear to do nothing and every following task would
    /// 401. Included for that, digested because a configuration value gets compared,
    /// logged near, and printed beside things a secret must not be.
    ///
    /// `Hasher` is seeded per process, so this is meaningless outside the session that
    /// produced it — which is exactly the lifetime it is compared over, and one less
    /// place a key can be recognised.
    public let credentialDigest: Int?

    /// Whether the agent asks before it acts.
    ///
    /// Here for the same reason everything else on this struct is: `AgentLoop` takes
    /// its mode at construction and hands the same value to `SystemPrompt.session`, so
    /// a loop built while the setting said "Manual" keeps prompting for the rest of the
    /// session however many times the switch is flipped — and the *model* keeps being
    /// told it will be asked. Without this field, turning auto-approval on would appear
    /// to do nothing until the app was restarted, which is precisely the class of
    /// silent settings desync `SessionConfiguration` exists to make impossible.
    ///
    /// It is also the direction that matters most: a conversation carried forward under
    /// a stale *permissive* mode would keep acting without asking after the user had
    /// turned that off.
    public let mode: PermissionMode

    public init(provider: Provider, mode: PermissionMode = .ask) {
        self.mode = mode
        self.kind = provider.kind
        self.model = provider.model
        self.baseURL = provider.baseURL
        self.planner = provider.plannerModel
        self.credentialDigest = provider.credentials.map { credentials in
            var hasher = Hasher()
            switch credentials {
            case let .apiKey(value):
                hasher.combine("apiKey")
                hasher.combine(value)
            case let .oauthToken(value):
                hasher.combine("oauthToken")
                hasher.combine(value)
            }
            return hasher.finalize()
        }
    }

    /// Whether a loop built for this configuration is still the right loop for `other`.
    ///
    /// Named rather than left as `==` at the call site because the call site is a
    /// decision about whether to throw away a conversation, and "these two structs are
    /// equal" does not say that.
    public func matches(_ other: SessionConfiguration) -> Bool {
        self == other
    }

    /// One phrase naming what changed, for a session that had to start over.
    ///
    /// The first difference in a fixed order, not all of them: choosing a different
    /// provider usually changes the model, the endpoint and the key at once, and
    /// "the provider, the model, the endpoint and the key changed" is noise around the
    /// one fact the user recognises as their own action. Nil when nothing differs.
    public func difference(from previous: SessionConfiguration) -> String? {
        if mode != previous.mode { return "the execution mode changed to \(mode.rawValue)" }
        if kind != previous.kind { return "the provider changed to \(kind.label)" }
        if model != previous.model { return "the model changed to \(model)" }
        if planner != previous.planner {
            guard let planner else { return "the planner was turned off" }
            return "the planner changed to \(planner)"
        }
        if baseURL != previous.baseURL { return "the endpoint changed" }
        if credentialDigest != previous.credentialDigest { return "the API key changed" }
        return nil
    }
}

/// How many instructions a persistent session has carried, and what it is carrying them
/// against.
///
/// The bookkeeping half of "a finished task does not end the run". The loop and the
/// transcript live in the app, because they need AppKit's lifetime and a window; the
/// rule deciding whether they may be reused lives here, where a test can drive twenty
/// instructions through it in a millisecond and no window server is involved.
public struct Conversation: Equatable, Sendable {

    /// What happens to an instruction submitted now.
    public enum Start: Equatable, Sendable {
        /// The existing loop and transcript serve it. `instruction` is its 1-based
        /// index in the session, matching the `task` field of the transcript's `run`
        /// note.
        case carriedForward(instruction: Int)
        /// Nothing is carried: the caller must build a new loop and a new transcript.
        /// `reason` names the configuration change that forced it, or nil when there
        /// was simply no conversation yet.
        case startedOver(reason: String?)
    }

    /// The configuration the current conversation is being held against, or nil before
    /// the first instruction.
    public private(set) var configuration: SessionConfiguration?
    /// Instructions in the current conversation, including the one in flight.
    public private(set) var instructions: Int
    /// What the most recent `begin` decided, so the overlay can say why a thread ended.
    public private(set) var start: Start?

    public init() {
        self.configuration = nil
        self.instructions = 0
        self.start = nil
    }

    /// Records an instruction about to run against `next`, and says whether the
    /// existing loop may serve it.
    ///
    /// The single decision point deliberately. The caller's only job is to drop its
    /// loop on `.startedOver`, which is one line it cannot get subtly wrong — as
    /// opposed to a caller that compares fields itself, which is the version of this
    /// that forgets a field the day a fifth one is added.
    public mutating func begin(_ next: SessionConfiguration) -> Start {
        if let configuration, configuration.matches(next) {
            instructions += 1
            let decision = Start.carriedForward(instruction: instructions)
            start = decision
            return decision
        }
        let reason = configuration.flatMap { next.difference(from: $0) }
        configuration = next
        // Not `+= 1`. The count is the transcript's, and a restarted conversation has a
        // new transcript holding exactly this instruction — carrying the old number
        // forward would have the overlay claim context that no request contains.
        instructions = 1
        let decision = Start.startedOver(reason: reason)
        start = decision
        return decision
    }

    /// Forgets everything. The next instruction begins a new conversation.
    ///
    /// A session that can never be reset grows its context without bound and traps the
    /// user in an old thread — "now close it" resolving against something from twenty
    /// minutes ago is worse than not resolving at all.
    public mutating func startOver() {
        self = Conversation()
    }

    /// Whether there is a conversation for a "start fresh" control to clear.
    public var carriesContext: Bool { instructions > 0 }

    /// What the overlay says under its input about what the next instruction carries.
    ///
    /// Nil before the first instruction, where there is nothing to say and a line
    /// saying so would be noise. Pluralised rather than assembled from a count nobody
    /// reads back — "1 instructions" is the same defect as the "1 turns" this codebase
    /// has already fixed twice.
    public var summary: String? {
        guard instructions > 0 else { return nil }
        let carried = "carrying \(instructions) earlier instruction"
            + (instructions == 1 ? "" : "s")
        // Named only on the instruction that started the new thread. After that the
        // conversation is simply itself, and the reason would be describing something
        // several tasks in the past.
        guard case let .startedOver(reason?) = start, instructions == 1 else { return carried }
        return "\(carried) — started over because \(reason)"
    }
}

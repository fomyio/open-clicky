import Foundation

/// Where the model comes from: which endpoint, which credential, which model id.
///
/// Resolution follows `Credentials` exactly — an explicit flag, then the environment,
/// then `~/.openclicky/config.json` — rather than inventing a parallel scheme. There
/// is one store for secrets in this project and one order for reading it, and a
/// second of either is a second thing to audit.
public struct Provider: Sendable {

    public enum Kind: String, CaseIterable, Sendable {
        case anthropic, openai, ollama, litellm, groq

        /// What errors and `doctor` call it. Named per provider because the same
        /// failure means opposite things: "could not connect" against a local Ollama
        /// is a daemon that is not running, and against OpenAI is a network that is
        /// down.
        public var label: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            case .ollama: return "Ollama"
            case .litellm: return "LiteLLM"
            case .groq: return "Groq"
            }
        }

        /// `nil` for Anthropic, whose endpoint is not configurable — it speaks the
        /// Messages API, not this dialect, and pointing it elsewhere would send an
        /// Anthropic-shaped body to something that cannot read it.
        public var defaultBaseURL: URL? {
            switch self {
            case .anthropic: return nil
            case .openai: return URL(string: "https://api.openai.com/v1")
            case .ollama: return URL(string: "http://localhost:11434/v1")
            case .litellm: return URL(string: "http://localhost:4000")
            case .groq: return URL(string: "https://api.groq.com/openai/v1")
            }
        }

        /// `nil` where no default is defensible.
        ///
        /// LiteLLM routes by a name its own configuration defines, so there is nothing
        /// to guess — and guessing produces a 404 that reads as "the proxy is broken".
        ///
        /// Ollama is the same shape of problem, learned later. This returned
        /// `"llama3.2"`, and on the machine that was found on the daemon served
        /// `deepseek-r1:7b`, `llama3:latest`, `glm-5.2:cloud` and five others — the
        /// default was a model nobody had pulled, so the out-of-the-box run 404'd. An
        /// Ollama id names something a particular machine holds, and the built-in
        /// answer to "which one" is that this build cannot know: `ModelCatalog` asks
        /// the daemon, and a run with nothing chosen says so rather than guessing.
        public var defaultModel: String? {
            switch self {
            case .anthropic: return DefaultModel.id
            case .openai: return "gpt-4o"
            case .groq: return "llama-3.3-70b-versatile"
            case .ollama, .litellm: return nil
            }
        }

        /// The provider's own conventional variable, checked after the generic one.
        public var apiKeyVariable: String {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai: return "OPENAI_API_KEY"
            case .ollama: return "OLLAMA_API_KEY"
            case .litellm: return "LITELLM_API_KEY"
            case .groq: return "GROQ_API_KEY"
            }
        }

        /// "A" or "An", for the label that follows.
        ///
        /// "A OpenAI key is already stored" reads as a typo in the one message whose
        /// job is to be trusted with a secret. The same defect as "1 turns" and "one
        /// tiers", both fixed here already: a sentence assembled from a value nobody
        /// read back.
        public var article: String {
            "AEIOU".contains(label.uppercased().first ?? "X") ? "An" : "A"
        }

        /// Whether a run can start without a key at all. Only a local daemon can.
        public var requiresKey: Bool { self != .ollama }
    }

    /// Where the key was found. Nil when the provider needs none.
    ///
    /// Reported because "configured" is two different situations with two different
    /// fixes, and a user chasing a stale key needs to know which file or variable to
    /// change rather than which ones to try.
    public enum Source: String, Sendable {
        case environment, configFile = "config file"
    }
    public let source: Source?

    public let kind: Kind
    public let model: String
    /// `nil` for Anthropic. See `Kind.defaultBaseURL`.
    public let baseURL: URL?
    /// How the request is signed, or `nil` for a keyless local endpoint.
    public let credentials: Credentials?

    /// A stronger model asked how to approach the task before `model` carries it out,
    /// or `nil` to run unplanned.
    ///
    /// It travels with the provider because it is the same question asked twice — the
    /// planner is served by *this* endpoint, with *this* credential, and a planner id
    /// the provider has never heard of is the commonest way planning fails. Resolving
    /// it anywhere else would let the two disagree.
    public let plannerModel: String?

    public init(
        kind: Kind, model: String, baseURL: URL?, credentials: Credentials?,
        source: Source? = nil, plannerModel: String? = nil
    ) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.credentials = credentials
        self.source = source
        self.plannerModel = plannerModel
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingCredentials(Kind)
        case modelRequired(Kind)
        case invalidBaseURL(String)
        case insecureBaseURL(String)

        public var description: String {
            switch self {
            case let .missingCredentials(kind):
                return """
                No \(kind.label) credentials found.

                Store a key in \(ConfigFile.defaultURL.path) (recommended):
                  openclicky auth --provider \(kind.rawValue)

                Or set it for this shell only:
                  export \(kind.apiKeyVariable)=...
                """
            case let .modelRequired(kind):
                // Named per provider, because "no default" has two different causes
                // and two different fixes. Telling an Ollama user that it "routes by
                // names its own configuration defines" sends them to a proxy config
                // they do not have, when the answer is one command away on their own
                // machine.
                let why = kind == .ollama
                    ? """
                    \(kind.label) serves only the models this machine has pulled, so \
                    there is no default worth guessing — a guess is a 404 that reads \
                    as a broken install.

                    See what it has:
                      ollama list
                    """
                    : """
                    \(kind.label) has no default model — it routes by names its own \
                    configuration defines, so there is nothing to guess.
                    """
                return """
                \(why)

                Name one:
                  openclicky --provider \(kind.rawValue) --model <id> "<task>"
                """
            case let .invalidBaseURL(text):
                return """
                '\(text)' is not a usable base URL. It needs a scheme and a host, \
                e.g. http://localhost:11434/v1
                """
            case let .insecureBaseURL(host):
                return """
                Refusing to send an API key to http://\(host) in cleartext — anything \
                on the network path can read it.

                Use https, or drop the key if the endpoint does not need one \
                (a local Ollama does not).
                """
            }
        }
    }

    /// Resolves the provider for this run.
    ///
    /// One order, applied to every field: what the caller passed, then the
    /// environment, then the stored settings, then a built-in default. The stored
    /// settings are what the app's picker writes, so a model chosen there is the model
    /// the CLI runs — the alternative was two surfaces disagreeing about which
    /// endpoint this machine calls.
    ///
    /// - Parameters:
    ///   - kind: from `--provider`. Falls back to `OPENCLICKY_PROVIDER`, the stored
    ///     provider, then Anthropic.
    ///   - baseURL: from `--base-url`. Falls back to `OPENCLICKY_BASE_URL`, the stored
    ///     base URL, then the provider's own default.
    ///   - model: from `--model`, when the user actually typed one. Falls back to
    ///     `OPENCLICKY_MODEL`, the stored model, then the provider's default — because
    ///     the built-in default only ever meant "the default for Anthropic", and
    ///     sending it to Ollama is a 404 that reads as a broken install.
    ///   - planner: from `--planner`. Falls back to `OPENCLICKY_PLANNER`, then the
    ///     stored planner. Nil runs unplanned, which is what every run did before the
    ///     planner existed and remains the default.
    public static func resolve(
        /// Deliberately without a default.
        ///
        /// A default of `ConfigFile()` reads the real `~/.openclicky/config.json`, so
        /// every test that forgot to override it loaded the developer's own keys —
        /// and printed them on failure. That is the most dangerous possible default
        /// here, for the same reason `Tool.risk(for:)` has none: the omission looks
        /// like nothing in review, and the failure is silent until it is loud.
        config: ConfigFile,
        kind requestedKind: Kind? = nil,
        baseURL requestedBaseURL: String? = nil,
        model requestedModel: String? = nil,
        planner requestedPlanner: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Provider {
        func value(_ name: String) -> String? {
            // An exported-but-empty variable is a common shell accident, and treating
            // it as a setting is how a run silently uses something nobody chose.
            guard let text = environment[name], !text.isEmpty else { return nil }
            return text
        }

        // Unreadable settings are not a reason to refuse a run: they carry no
        // credential, and a malformed file still has to leave `auth` reachable to fix
        // it. A missing *key* is reported below, where it is actually fatal.
        let stored = (try? config.settings()) ?? ConfigFile.Settings()

        let kind = requestedKind
            ?? value("OPENCLICKY_PROVIDER").flatMap(Kind.init(rawValue:))
            ?? stored.provider.flatMap(Kind.init(rawValue:))
            ?? .anthropic

        // Only the settings belonging to the provider actually in play. A model id is
        // meaningful only next to the endpoint that serves it: settings saying
        // `ollama` + `llava` must not hand "llava" to `--provider anthropic`, which is
        // a 404 that reads as a broken install rather than as a stale setting.
        let applicable = stored.applies(to: kind.rawValue) ? stored : ConfigFile.Settings()

        let model = requestedModel ?? value("OPENCLICKY_MODEL") ?? applicable.model
            ?? kind.defaultModel
        guard let model else { throw Error.modelRequired(kind) }

        let planner = requestedPlanner ?? value("OPENCLICKY_PLANNER") ?? applicable.planner

        if kind == .anthropic {
            // Delegated wholesale rather than reimplemented: Anthropic accepts an
            // OAuth token as well as an API key, on a different header, and a second
            // copy of that rule would be a second place to get it wrong.
            let (credentials, source) = try Credentials.resolveWithSource(
                config: config, environment: environment
            )
            return Provider(
                kind: kind, model: model, baseURL: nil,
                credentials: credentials, source: source, plannerModel: planner
            )
        }

        guard let baseURL = try resolveBaseURL(
            requested: requestedBaseURL ?? value("OPENCLICKY_BASE_URL") ?? applicable.baseURL,
            kind: kind
        ) else {
            throw Error.invalidBaseURL(requestedBaseURL ?? "<none>")
        }

        let found = try storedKey(for: kind, config: config, environment: environment)
        let key = found?.key
        let source = found?.source
        if key == nil, kind.requiresKey { throw Error.missingCredentials(kind) }

        // A bearer token over plaintext HTTP to anything but the loopback interface
        // is readable by every hop in between. Refused rather than warned about: a
        // warning on a leak the user cannot see happening is not a control.
        if let key, !key.isEmpty, baseURL.scheme?.lowercased() == "http",
           !isLoopback(baseURL.host) {
            throw Error.insecureBaseURL(baseURL.host ?? baseURL.absoluteString)
        }

        return Provider(
            kind: kind, model: model, baseURL: baseURL,
            credentials: key.map(Credentials.apiKey), source: source,
            plannerModel: planner
        )
    }

    /// This provider's key and where it came from, or `nil` when none is stored.
    ///
    /// `OPENCLICKY_API_KEY` first so one variable can override every provider, then the
    /// provider's own conventional name, then the config file — which is the only store
    /// on disk, and the one `auth` and the app both write.
    ///
    /// Extracted from `resolve` when the settings window's model listing became a
    /// second caller. There is one store for secrets in this project and one order for
    /// reading it; a listing that read the file directly would be a second copy of that
    /// order, and the two would disagree the day one of them learned about a variable
    /// the other did not.
    ///
    /// Throws rather than reporting "no key" when the file is world-readable. The
    /// distinction is load-bearing and has been lost here before: a caught throw cannot
    /// be told apart from an empty one, and an exposed file that reads as "nothing
    /// configured" is a key that stays compromised and unmentioned.
    public static func storedKey(
        for kind: Kind,
        config: ConfigFile,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (key: String, source: Source)? {
        // An exported-but-empty variable is a common shell accident, and treating it
        // as a setting is how a run silently uses something nobody chose.
        func value(_ name: String) -> String? {
            guard let text = environment[name], !text.isEmpty else { return nil }
            return text
        }
        if let key = value("OPENCLICKY_API_KEY") ?? value(kind.apiKeyVariable) {
            return (key, .environment)
        }
        if let stored = try config.keys()[kind.rawValue], !stored.isEmpty {
            return (stored, .configFile)
        }
        return nil
    }

    static func resolveBaseURL(requested: String?, kind: Kind) throws -> URL? {
        guard let requested else { return kind.defaultBaseURL }
        guard let url = URL(string: requested),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw Error.invalidBaseURL(requested)
        }
        return url
    }

    /// Only these reach no network at all.
    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Whether this provider's client shows text as it arrives.
    ///
    /// Asked rather than assumed, because the consequence of guessing wrong is
    /// invisible in one direction and silent in the other: a renderer that suppresses
    /// its own output expecting a stream that never comes loses the reply entirely,
    /// and one that does not suppress prints it twice. Only the OpenAI-compatible
    /// clients stream today — Anthropic's event shapes are a separate job, and
    /// `makeClient` accepts `onText` for it and ignores it.
    public var streamsText: Bool { kind != .anthropic }

    /// Whether tokens sent here are billed by anyone.
    ///
    /// Decided by the endpoint, not the provider name: LiteLLM on loopback is a proxy
    /// that may well bill through to OpenAI, but a run against `localhost:11434` is
    /// served by this machine. Asking "does this reach a network" is the question that
    /// stays right when someone points `--base-url` somewhere unexpected, which naming
    /// providers would not.
    public var isBilled: Bool {
        kind != .ollama || !Self.isLoopback(baseURL?.host)
    }

    /// The rate to price this run at, or `nil` to price it by model.
    public var pricing: Pricing? { isBilled ? nil : .unbilled }

    /// What this model accepts and can be trusted to drive.
    public var capabilities: ModelCapabilities { .forModel(model) }

    /// One line for `doctor` and the run header.
    ///
    /// The planner is named here because it is the half of a two-model run that is
    /// otherwise invisible: it is billed at its own price, it runs before the first
    /// tool call, and a header that mentioned only the executor understated both.
    public var summary: String {
        var parts = ["\(kind.label) · \(model)"]
        if let plannerModel { parts.append("planned by \(plannerModel)") }
        if let baseURL { parts.append(baseURL.absoluteString) }
        return parts.joined(separator: " · ")
    }

    /// The client for this provider, already carrying its credentials.
    ///
    /// The only place a provider becomes a client, so there is exactly one answer to
    /// "which dialect does this endpoint speak" and no caller has to know.
    /// - Parameter onText: shows assistant text as it arrives. Only the
    ///   OpenAI-compatible clients stream today; Anthropic's event shapes are a
    ///   different job, and passing this for Anthropic is accepted and ignored rather
    ///   than silently changing which path a run takes.
    public func makeClient(
        onRetry: RetryNotice? = nil, onText: StreamNotice? = nil
    ) -> any MessagesClient {
        switch kind {
        case .anthropic:
            return AnthropicClient(
                credentials: credentials ?? .apiKey(""), onRetry: onRetry
            )
        case .openai, .ollama, .litellm, .groq:
            var key: String?
            if case let .apiKey(value)? = credentials { key = value }
            if case let .oauthToken(value)? = credentials { key = value }
            return OpenAICompatibleClient(
                provider: kind.label,
                baseURL: baseURL ?? URL(string: "http://localhost:11434/v1")!,
                apiKey: key,
                onRetry: onRetry,
                onText: onText
            )
        }
    }

    /// Tries the configuration against the endpoint with the smallest possible request.
    ///
    /// "A key is stored" is not the same claim as "this works", and the gap between
    /// them is where a mistyped key, an unreachable daemon, or a model id the provider
    /// has never heard of hides until three commands later. One token in and one out
    /// answers the question people actually have — and against a local Ollama it also
    /// answers "is the model pulled", which is the usual first failure.
    ///
    /// A broader question than `Credentials.verify`, deliberately. That one asks
    /// whether a *key* works and counts any non-auth answer as proof it does, which is
    /// correct for what it is asked. This asks whether the *configuration* works, and
    /// a model the endpoint has never heard of fails that even though the credential
    /// passed — the distinction `Verification.misconfigured` exists to carry.
    public func verify(using client: (any MessagesClient)? = nil) async -> Credentials.Verification {
        let messages = client ?? makeClient()
        let request = Wire.Request(
            model: model, maxTokens: 1,
            system: [], messages: [.user("hi")], tools: []
        )
        do {
            _ = try await messages.send(request)
            return .working
        } catch let error as OpenAICompatibleClient.Error {
            if case let .api(_, status, _, message, _) = error {
                if let verdict = Self.misconfiguration(status: status, message: message) {
                    return verdict
                }
            }
            return Credentials.interpret(error)
        } catch let error as AnthropicClient.Error {
            if case let .api(status, _, message, _) = error {
                if let verdict = Self.misconfiguration(status: status, message: message) {
                    return verdict
                }
            }
            return Credentials.interpret(error)
        } catch {
            return Credentials.interpret(error)
        }
    }

    /// A 4xx on the smallest request the API defines, read as a verdict.
    ///
    /// The probe carries one message, one token of output and no tools, so there is
    /// nothing in it for an endpoint to object to except the configuration itself —
    /// almost always a model id it has never heard of. Counting that as "the
    /// credential was accepted" is true and useless: it is what made
    /// `doctor --provider ollama` report a verified setup that died on a 404 one
    /// command later, because the model had never been pulled.
    ///
    /// Auth failures and rate limits are excluded: the first is `.rejected`, and the
    /// second says nothing about the configuration at all.
    static func misconfiguration(status: Int, message: String) -> Credentials.Verification? {
        guard (400..<500).contains(status), ![401, 403, 429].contains(status) else {
            return nil
        }
        return .misconfigured(message)
    }
}

/// What a client failure means for a credential check.
///
/// Two clients and two error enums, but one question — was the credential refused,
/// or was the endpoint simply not there? Asking it through a protocol keeps `verify`
/// a single implementation; the alternative was a second copy switching over a second
/// enum, which is how the two would have drifted apart on the case that matters:
/// "unreachable" must not be reported as a bad key, or a laptop on a train is told
/// its credentials are wrong.
protocol CredentialFailure: Swift.Error {
    /// The endpoint refused the credential (401/403), with its own reason.
    var credentialRejection: String? { get }
    /// The endpoint could not be reached at all.
    var unreachableReason: String? { get }
}

extension AnthropicClient.Error: CredentialFailure {
    var credentialRejection: String? {
        if case let .api(status, _, message, _) = self, status == 401 || status == 403 {
            return message
        }
        return nil
    }

    var unreachableReason: String? {
        if case let .transport(underlying) = self { return underlying.localizedDescription }
        return nil
    }
}

extension OpenAICompatibleClient.Error: CredentialFailure {
    var credentialRejection: String? {
        if case let .api(_, status, _, message, _) = self, status == 401 || status == 403 {
            return message
        }
        return nil
    }

    var unreachableReason: String? {
        if case let .transport(_, underlying) = self { return underlying.localizedDescription }
        return nil
    }
}

extension Credentials {
    /// Reads a failed probe as a verdict on the credentials, for either client.
    ///
    /// Anything that is not a refusal and not a transport failure counts as working:
    /// the request itself being rejected — a bad model id, a 400 on some field — is
    /// proof the credential was accepted, and it is not the question being asked.
    static func interpret(_ error: Swift.Error) -> Verification {
        guard let failure = error as? CredentialFailure else { return .unreachable("\(error)") }
        if let rejection = failure.credentialRejection { return .rejected(rejection) }
        if let unreachable = failure.unreachableReason { return .unreachable(unreachable) }
        return .working
    }
}

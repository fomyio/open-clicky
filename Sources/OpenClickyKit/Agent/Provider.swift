import Foundation

/// Where the model comes from: which endpoint, which credential, which model id.
///
/// Resolution follows `Credentials` exactly — an explicit flag, then the environment,
/// then the Keychain, and never a file on disk — rather than inventing a parallel
/// scheme. There is one store for secrets in this project and one order for reading
/// it, and a second of either is a second thing to audit.
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
        public var defaultModel: String? {
            switch self {
            case .anthropic: return DefaultModel.id
            case .openai: return "gpt-4o"
            // Both default to a text-only model on purpose: it is the common local
            // choice, it is the cheap one, and it demonstrates the tier-2 path the
            // accessibility tree exists for.
            case .ollama: return "llama3.2"
            case .groq: return "llama-3.3-70b-versatile"
            case .litellm: return nil
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

        /// Where `openclicky auth` stores this provider's key.
        ///
        /// It lives here rather than on `Keychain` so the Support layer keeps knowing
        /// nothing about providers: the Keychain wrapper stores strings under account
        /// names, and which account names exist is an Agent-layer question.
        public var keychainAccount: String {
            self == .anthropic ? Keychain.apiKeyAccount : "\(rawValue)-api-key"
        }

        /// Whether a run can start without a key at all. Only a local daemon can.
        public var requiresKey: Bool { self != .ollama }
    }

    public let kind: Kind
    public let model: String
    /// `nil` for Anthropic. See `Kind.defaultBaseURL`.
    public let baseURL: URL?
    /// How the request is signed, or `nil` for a keyless local endpoint.
    public let credentials: Credentials?

    public init(kind: Kind, model: String, baseURL: URL?, credentials: Credentials?) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.credentials = credentials
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

                Store a key in the macOS Keychain (recommended):
                  openclicky auth --provider \(kind.rawValue)

                Or set it for this shell only:
                  export \(kind.apiKeyVariable)=...
                """
            case let .modelRequired(kind):
                return """
                \(kind.label) has no default model — it routes by names its own \
                configuration defines, so there is nothing to guess.

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
    /// - Parameters:
    ///   - kind: from `--provider`. Falls back to `OPENCLICKY_PROVIDER`, then Anthropic.
    ///   - baseURL: from `--base-url`. Falls back to `OPENCLICKY_BASE_URL`, then the
    ///     provider's own default.
    ///   - model: from `--model`, when the user actually typed one. Falls back to
    ///     `OPENCLICKY_MODEL`, then the provider's default — because the built-in
    ///     default only ever meant "the default for Anthropic", and sending it to
    ///     Ollama is a 404 that reads as a broken install.
    public static func resolve(
        kind requestedKind: Kind? = nil,
        baseURL requestedBaseURL: String? = nil,
        model requestedModel: String? = nil,
        keychain: Keychain = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Provider {
        func value(_ name: String) -> String? {
            // An exported-but-empty variable is a common shell accident, and treating
            // it as a setting is how a run silently uses something nobody chose.
            guard let text = environment[name], !text.isEmpty else { return nil }
            return text
        }

        let kind = requestedKind
            ?? value("OPENCLICKY_PROVIDER").flatMap(Kind.init(rawValue:))
            ?? .anthropic

        let model = requestedModel ?? value("OPENCLICKY_MODEL") ?? kind.defaultModel
        guard let model else { throw Error.modelRequired(kind) }

        if kind == .anthropic {
            // Delegated wholesale rather than reimplemented: Anthropic accepts an
            // OAuth token as well as an API key, on a different header, and a second
            // copy of that rule would be a second place to get it wrong.
            return Provider(
                kind: kind, model: model, baseURL: nil,
                credentials: try Credentials.resolve(
                    keychain: keychain, environment: environment
                )
            )
        }

        guard let baseURL = try resolveBaseURL(
            requested: requestedBaseURL ?? value("OPENCLICKY_BASE_URL"), kind: kind
        ) else {
            throw Error.invalidBaseURL(requestedBaseURL ?? "<none>")
        }

        // `OPENCLICKY_API_KEY` first so one variable can override every provider,
        // then the provider's own conventional name, then the Keychain — the same
        // order `Credentials.resolve` uses, for the same reason.
        var key = value("OPENCLICKY_API_KEY") ?? value(kind.apiKeyVariable)
        if key == nil, let stored = try keychain.read(account: kind.keychainAccount),
           !stored.isEmpty {
            key = stored
        }
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
            credentials: key.map(Credentials.apiKey)
        )
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
    public var summary: String {
        var parts = ["\(kind.label) · \(model)"]
        if let baseURL { parts.append(baseURL.absoluteString) }
        return parts.joined(separator: " · ")
    }

    /// The client for this provider, already carrying its credentials.
    ///
    /// The only place a provider becomes a client, so there is exactly one answer to
    /// "which dialect does this endpoint speak" and no caller has to know.
    public func makeClient(onRetry: RetryNotice? = nil) -> any MessagesClient {
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
                onRetry: onRetry
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

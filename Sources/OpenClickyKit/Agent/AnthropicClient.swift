import Foundation

/// The one call the agent loop makes.
///
/// A protocol so the loop can be driven by a scripted responder in tests. The loop's
/// batching, fail-fast and denial handling are the parts most worth testing and the
/// least worth paying an API round-trip to exercise.
public protocol MessagesClient: Sendable {
    func send(_ request: Wire.Request) async throws -> Wire.Response
}

/// Minimal Anthropic Messages API client.
///
/// Raw HTTP rather than an SDK because Anthropic ships none for Swift. Scope is
/// deliberately narrow: one endpoint, non-streaming, with the retry and error
/// semantics the agent loop depends on.
public actor AnthropicClient: MessagesClient {

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingCredentials
        case api(status: Int, type: String, message: String, retryAfter: Double?)
        case transport(underlying: Swift.Error)
        case malformedResponse(String)

        public var description: String {
            switch self {
            case .missingCredentials:
                // Every command named here must actually parse: this is the first
                // error most people meet, and it previously suggested
                // `openclicky auth --set`, which fails with "Unknown option".
                return """
                No Anthropic credentials found.

                Store a key in the macOS Keychain (recommended):
                  openclicky auth

                Or set it for this shell only:
                  export ANTHROPIC_API_KEY=sk-ant-...

                Keys are at https://console.anthropic.com/settings/keys
                """
            case let .api(status, type, message, _):
                return "Anthropic API error \(status) (\(type)): \(message)"
            case let .transport(underlying):
                return "Network error: \(underlying.localizedDescription)"
            case let .malformedResponse(detail):
                return "Malformed API response: \(detail)"
            }
        }

        /// Whether retrying the identical request could plausibly succeed.
        var isRetryable: Bool {
            switch self {
            case .transport: return true
            case let .api(status, _, _, _): return status == 408 || status == 409 || status == 429 || status >= 500
            case .missingCredentials, .malformedResponse: return false
            }
        }
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    private let credentials: Credentials
    private let session: URLSession
    private let maxRetries: Int
    private let onRetry: RetryNotice?
    private let retryBaseDelay: Double

    /// Called before each backoff, so a wait can be shown rather than merely endured.
    ///
    /// Kept as a name on this type because callers spell it `AnthropicClient.RetryNotice`;
    /// the definition moved to module scope when a second client needed the same shape.
    public typealias RetryNotice = OpenClickyKit.RetryNotice

    public init(
        credentials: Credentials,
        maxRetries: Int = 3,
        onRetry: RetryNotice? = nil
    ) {
        let config = URLSessionConfiguration.ephemeral
        // Agentic turns with adaptive thinking can run long; the SDK default is 10 min.
        config.timeoutIntervalForRequest = 600
        config.httpAdditionalHeaders = ["User-Agent": "OpenClicky/0.1 (macOS)"]
        self.init(
            credentials: credentials,
            session: URLSession(configuration: config),
            maxRetries: maxRetries,
            onRetry: onRetry
        )
    }

    /// Seam for tests: lets a stubbed `URLSession` and a near-zero backoff be
    /// injected, so the retry policy can be exercised without real requests or
    /// several seconds of real sleeping.
    init(
        credentials: Credentials,
        session: URLSession,
        maxRetries: Int = 3,
        retryBaseDelay: Double = 0.5,
        onRetry: RetryNotice? = nil
    ) {
        self.credentials = credentials
        self.session = session
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.onRetry = onRetry
    }

    /// Sends one request, retrying transport failures and retryable statuses with
    /// exponential backoff plus jitter. Honours `Retry-After` when the server sends it.
    public func send(_ request: Wire.Request) async throws -> Wire.Response {
        var attempt = 0
        while true {
            do {
                return try await perform(request)
            } catch let error as Error where error.isRetryable && attempt < maxRetries {
                let delay = retryDelay(attempt: attempt, error: error)
                attempt += 1
                await onRetry?(attempt, maxRetries, delay, error.description)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func perform(_ body: Wire.Request) async throws -> Wire.Response {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        switch credentials {
        case let .apiKey(key):
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case let .oauthToken(token):
            // OAuth tokens go on Authorization, not x-api-key, and need this beta flag.
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }

        req.httpBody = try Wire.encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Error.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse("not an HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(Wire.APIError.self, from: data)
            throw Error.api(
                status: http.statusCode,
                type: decoded?.error.type ?? "unknown",
                message: decoded?.error.message ?? String(data: data, encoding: .utf8) ?? "<no body>",
                retryAfter: (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
            )
        }

        do {
            return try JSONDecoder().decode(Wire.Response.self, from: data)
        } catch {
            throw Error.malformedResponse("\(error)")
        }
    }

    /// Backoff before the next attempt.
    ///
    /// A server-sent `Retry-After` wins: it reflects when capacity will actually be
    /// available, and retrying sooner just burns another request against the limit.
    /// Otherwise exponential with jitter, so a fleet of clients does not resynchronise
    /// onto the same retry instant.
    func retryDelay(attempt: Int, error: Error) -> Double {
        var retryAfter: Double?
        if case let .api(_, _, _, value) = error { retryAfter = value }
        return Backoff.delay(attempt: attempt, retryAfter: retryAfter, base: retryBaseDelay)
    }
}

/// How we authenticate to the API.
public enum Credentials: Sendable {
    case apiKey(String)
    case oauthToken(String)

    /// Resolves credentials in the same precedence the Anthropic SDKs use:
    /// `ANTHROPIC_API_KEY`, then `ANTHROPIC_AUTH_TOKEN`, then the Keychain.
    ///
    /// A key is never written to disk by OpenClicky — the Keychain is the store.
    ///
    /// The environment is a parameter so a test can state one instead of mutating the
    /// process's own — `setenv` in a test suite is shared mutable state, and the
    /// provider tests that needed it would have raced every other suite reading it.
    public static func resolve(
        keychain: Keychain = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Credentials {
        let env = environment
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty { return .apiKey(key) }
        if let token = env["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty { return .oauthToken(token) }
        if let stored = try keychain.read(account: Keychain.apiKeyAccount), !stored.isEmpty {
            return .apiKey(stored)
        }
        throw AnthropicClient.Error.missingCredentials
    }

    /// What happened when a key was tried against the API.
    public enum Verification: Sendable, Equatable {
        case working
        case rejected(String)
        case unreachable(String)

        public var summary: String {
            switch self {
            case .working:
                return "Verified against the API."
            case let .rejected(detail):
                return """
                The API rejected this key: \(detail)
                It is stored, but no run will work until it is replaced.
                """
            case let .unreachable(detail):
                return """
                Stored, but could not be checked: \(detail)
                That is a network problem, not necessarily a bad key.
                """
            }
        }
    }

    /// Tries the credentials against the API with the smallest possible request.
    ///
    /// "Stored in the Keychain" is not the same claim as "this key works", and telling
    /// someone the first while they hear the second is how a mistyped key becomes a
    /// failure three commands later, attributed to something else. One token in and
    /// one out costs a fraction of a cent and answers the question they actually have.
    public func verify(using client: (any MessagesClient)? = nil) async -> Verification {
        let messages = client ?? AnthropicClient(credentials: self)
        let request = Wire.Request(
            model: DefaultModel.id, maxTokens: 1,
            system: [], messages: [.user("hi")], tools: []
        )
        do {
            _ = try await messages.send(request)
            return .working
        } catch {
            // Read through `CredentialFailure`, which both clients conform to, so the
            // one rule that matters — an unreachable endpoint is not a verdict on the
            // key — is stated once rather than once per client.
            return Credentials.interpret(error)
        }
    }
}

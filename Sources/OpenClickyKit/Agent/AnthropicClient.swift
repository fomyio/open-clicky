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
                return """
                No Anthropic credentials found. Set ANTHROPIC_API_KEY, or store a key with:
                  openclicky auth --set
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
    private let retryBaseDelay: Double

    public init(credentials: Credentials, maxRetries: Int = 3) {
        let config = URLSessionConfiguration.ephemeral
        // Agentic turns with adaptive thinking can run long; the SDK default is 10 min.
        config.timeoutIntervalForRequest = 600
        config.httpAdditionalHeaders = ["User-Agent": "OpenClicky/0.1 (macOS)"]
        self.init(
            credentials: credentials,
            session: URLSession(configuration: config),
            maxRetries: maxRetries
        )
    }

    /// Seam for tests: lets a stubbed `URLSession` and a near-zero backoff be
    /// injected, so the retry policy can be exercised without real requests or
    /// several seconds of real sleeping.
    init(
        credentials: Credentials,
        session: URLSession,
        maxRetries: Int = 3,
        retryBaseDelay: Double = 0.5
    ) {
        self.credentials = credentials
        self.session = session
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
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

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)

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
        if case let .api(_, _, _, retryAfter) = error, let retryAfter, retryAfter > 0 {
            return min(retryAfter, 60)
        }
        let base = min(pow(2.0, Double(attempt)) * retryBaseDelay, 8.0)
        let jitter = Double.random(in: 0...(base * 0.25))
        return base + jitter
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
    public static func resolve(keychain: Keychain = .standard) throws -> Credentials {
        let env = ProcessInfo.processInfo.environment
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty { return .apiKey(key) }
        if let token = env["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty { return .oauthToken(token) }
        if let stored = try keychain.read(account: Keychain.apiKeyAccount), !stored.isEmpty {
            return .apiKey(stored)
        }
        throw AnthropicClient.Error.missingCredentials
    }
}

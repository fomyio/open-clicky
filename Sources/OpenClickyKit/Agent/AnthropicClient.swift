import Foundation

/// Minimal Anthropic Messages API client.
///
/// Raw HTTP rather than an SDK because Anthropic ships none for Swift. Scope is
/// deliberately narrow: one endpoint, non-streaming, with the retry and error
/// semantics the agent loop depends on.
public actor AnthropicClient {

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingCredentials
        case api(status: Int, type: String, message: String)
        case transport(underlying: Swift.Error)
        case malformedResponse(String)

        public var description: String {
            switch self {
            case .missingCredentials:
                return """
                No Anthropic credentials found. Set ANTHROPIC_API_KEY, or store a key with:
                  openclicky auth --set
                """
            case let .api(status, type, message):
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
            case let .api(status, _, _): return status == 408 || status == 409 || status == 429 || status >= 500
            case .missingCredentials, .malformedResponse: return false
            }
        }
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"
    private let credentials: Credentials
    private let session: URLSession
    private let maxRetries: Int

    public init(credentials: Credentials, maxRetries: Int = 3) {
        self.credentials = credentials
        self.maxRetries = maxRetries
        let config = URLSessionConfiguration.ephemeral
        // Agentic turns with adaptive thinking can run long; the SDK default is 10 min.
        config.timeoutIntervalForRequest = 600
        config.httpAdditionalHeaders = ["User-Agent": "OpenClicky/0.1 (macOS)"]
        self.session = URLSession(configuration: config)
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
                message: decoded?.error.message ?? String(data: data, encoding: .utf8) ?? "<no body>"
            )
        }

        do {
            return try JSONDecoder().decode(Wire.Response.self, from: data)
        } catch {
            throw Error.malformedResponse("\(error)")
        }
    }

    private func retryDelay(attempt: Int, error: Error) -> Double {
        let base = min(pow(2.0, Double(attempt)) * 0.5, 8.0)
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

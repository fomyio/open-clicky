import Testing
import Foundation
@testable import OpenClickyKit

/// The retry policy decides whether a transient 429 or 529 ends the run. Exercised
/// through a stubbed `URLProtocol` rather than the network, so the tests are
/// hermetic and finish in milliseconds.
@Suite("API client retries", .serialized)
struct ClientRetryTests {

    /// Serves scripted responses and counts the requests it saw.
    ///
    /// Static state because `URLProtocol` is instantiated by `URLSession`, which
    /// gives no hook to inject per-instance context. The suite is `.serialized` so
    /// the sharing is safe.
    final class StubProtocol: URLProtocol {
        struct Step {
            let status: Int
            let body: String
            var headers: [String: String] = [:]
        }

        nonisolated(unsafe) private static var steps: [Step] = []
        nonisolated(unsafe) private static var requestCount = 0
        private static let lock = NSLock()

        static func script(_ steps: [Step]) {
            lock.lock(); defer { lock.unlock() }
            Self.steps = steps
            requestCount = 0
        }

        static var seen: Int {
            lock.lock(); defer { lock.unlock() }
            return requestCount
        }

        private static func next() -> Step {
            lock.lock(); defer { lock.unlock() }
            requestCount += 1
            return steps.isEmpty ? Step(status: 500, body: "{}") : steps.removeFirst()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let step = Self.next()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: step.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(step.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static let successBody = """
    {"id":"msg_1","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn",
     "content":[{"type":"text","text":"ok"}],
     "usage":{"input_tokens":10,"output_tokens":5}}
    """

    private func makeClient(maxRetries: Int = 3) -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return AnthropicClient(
            credentials: .apiKey("sk-ant-test-not-a-real-key"),
            session: URLSession(configuration: config),
            maxRetries: maxRetries,
            // Near-zero backoff: the policy is under test, not the clock.
            retryBaseDelay: 0.001
        )
    }

    private var request: Wire.Request {
        Wire.Request(
            model: "claude-opus-5", maxTokens: 1_000,
            system: [.init("system")], messages: [.user("hi")], tools: []
        )
    }

    // MARK: - Retryable failures

    @Test("A transient failure is retried and then succeeds", arguments: [429, 500, 502, 529])
    func retriesTransientFailures(status: Int) async throws {
        StubProtocol.script([
            .init(status: status, body: #"{"error":{"type":"overloaded","message":"busy"}}"#),
            .init(status: 200, body: Self.successBody),
        ])
        let response = try await makeClient().send(request)
        #expect(response.text == "ok")
        #expect(StubProtocol.seen == 2)
    }

    /// Time-limited deliberately. With the bound removed this retries forever, and a
    /// hanging test is worse than a failing one: CI times out with no indication of
    /// what broke. Found while mutating the bound — the sweep itself hung.
    @Test("Retries stop at the configured limit", .timeLimit(.minutes(1)))
    func stopsAtMaxRetries() async {
        StubProtocol.script(Array(repeating: .init(
            status: 529, body: #"{"error":{"type":"overloaded","message":"busy"}}"#
        ), count: 10))

        await #expect(throws: AnthropicClient.Error.self) {
            _ = try await makeClient(maxRetries: 2).send(request)
        }
        // The initial attempt plus two retries.
        #expect(StubProtocol.seen == 3)
    }

    // MARK: - Non-retryable failures

    /// A 400 will fail identically however many times it is sent; retrying it wastes
    /// the user's money and delays the error they need to see.
    @Test("Client errors are not retried", arguments: [400, 401, 403, 404, 422])
    func doesNotRetryClientErrors(status: Int) async {
        StubProtocol.script([
            .init(status: status, body: #"{"error":{"type":"invalid_request_error","message":"bad"}}"#),
        ])
        await #expect(throws: AnthropicClient.Error.self) {
            _ = try await makeClient().send(request)
        }
        #expect(StubProtocol.seen == 1)
    }

    @Test("The error carries the API's own message through")
    func surfacesAPIMessage() async {
        StubProtocol.script([
            .init(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"thinking.budget_tokens is not supported"}}"#),
        ])
        do {
            _ = try await makeClient().send(request)
            Issue.record("expected a throw")
        } catch let error as AnthropicClient.Error {
            #expect(error.description.contains("budget_tokens"))
            #expect(error.description.contains("400"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A malformed success body is reported, not retried")
    func malformedBodyIsNotRetried() async {
        StubProtocol.script([.init(status: 200, body: "not json at all")])
        await #expect(throws: AnthropicClient.Error.self) {
            _ = try await makeClient().send(request)
        }
        #expect(StubProtocol.seen == 1)
    }

    // MARK: - Backoff

    /// The server knows when capacity returns; retrying sooner just burns another
    /// request against the limit.
    @Test("Retry-After from the server wins over the computed backoff")
    func honoursRetryAfter() async throws {
        let client = makeClient()
        let error = AnthropicClient.Error.api(
            status: 429, type: "rate_limit_error", message: "slow down", retryAfter: 7
        )
        #expect(await client.retryDelay(attempt: 0, error: error) == 7)
    }

    @Test("An absurd Retry-After is capped")
    func capsRetryAfter() async throws {
        let client = makeClient()
        let error = AnthropicClient.Error.api(
            status: 429, type: "rate_limit_error", message: "slow down", retryAfter: 8_000
        )
        #expect(await client.retryDelay(attempt: 0, error: error) == 60)
    }

    @Test("Backoff grows with each attempt and stays bounded")
    func backoffGrowsAndIsBounded() async throws {
        let client = makeClient()
        let error = AnthropicClient.Error.api(
            status: 529, type: "overloaded_error", message: "busy", retryAfter: nil
        )
        let first = await client.retryDelay(attempt: 0, error: error)
        let later = await client.retryDelay(attempt: 4, error: error)
        #expect(later > first)
        #expect(later <= 10, "the ceiling plus jitter should keep this bounded")
    }

    // MARK: - Request shape

    @Test("A rate-limited response honours Retry-After end to end")
    func retryAfterAppliesToRealRequests() async throws {
        StubProtocol.script([
            .init(
                status: 429,
                body: #"{"error":{"type":"rate_limit_error","message":"slow down"}}"#,
                headers: ["retry-after": "0"]
            ),
            .init(status: 200, body: Self.successBody),
        ])
        let response = try await makeClient().send(request)
        #expect(response.text == "ok")
        #expect(StubProtocol.seen == 2)
    }
}

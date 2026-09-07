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

    private func makeClient(
        maxRetries: Int = 3, onRetry: AnthropicClient.RetryNotice? = nil
    ) -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return AnthropicClient(
            credentials: .apiKey("sk-ant-test-not-a-real-key"),
            session: URLSession(configuration: config),
            maxRetries: maxRetries,
            // Near-zero backoff: the policy is under test, not the clock.
            retryBaseDelay: 0.001,
            onRetry: onRetry
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

    // MARK: - A wait nobody can see reads as a hang

    /// A rate limit with `Retry-After: 60` and three retries is three minutes during
    /// which the CLI prints "· thinking…" and the overlay says "Thinking…". That is
    /// indistinguishable from a hang, and the reasonable response to a hang is to kill
    /// the run — so the client was quietly training people to abandon requests that
    /// were about to succeed.
    @Test("Each backoff is announced before it is waited out")
    func retriesAreAnnounced() async throws {
        let notices = Notices()
        StubProtocol.script([
            .init(status: 429, body: #"{"error":{"type":"rate_limit_error","message":"slow down"}}"#),
            .init(status: 500, body: #"{"error":{"type":"api_error","message":"oops"}}"#),
            .init(status: 200, body: Self.successBody),
        ])
        let client = makeClient { attempt, total, delay, reason in
            await notices.record(attempt: attempt, of: total, delay: delay, reason: reason)
        }

        _ = try await client.send(request)

        let recorded = await notices.all
        #expect(recorded.count == 2, "one notice per backoff, not per request")
        #expect(recorded.first?.attempt == 1)
        #expect(recorded.first?.of == 3)
        #expect(recorded.allSatisfy { $0.delay > 0 })
        #expect(recorded.first?.reason.contains("429") == true,
                "the notice should say what happened")
    }

    /// A request that succeeds first time must stay silent — a notice on every call
    /// is noise, and noise is what stops warnings being read.
    @Test("A successful request announces nothing")
    func successAnnouncesNothing() async throws {
        let notices = Notices()
        StubProtocol.script([.init(status: 200, body: Self.successBody)])
        let client = makeClient { attempt, total, delay, reason in
            await notices.record(attempt: attempt, of: total, delay: delay, reason: reason)
        }
        _ = try await client.send(request)
        #expect(await notices.all.isEmpty)
    }

    private actor Notices {
        struct Notice { let attempt: Int; let of: Int; let delay: Double; let reason: String }
        private(set) var all: [Notice] = []
        func record(attempt: Int, of: Int, delay: Double, reason: String) {
            all.append(Notice(attempt: attempt, of: of, delay: delay, reason: reason))
        }
    }

    // MARK: - Retry-After in both its forms

    // RFC 7231 permits seconds or an HTTP-date, and `Double.init` reads only the
    // first. A proxy sending the date form — nginx and Cloudflare both do — parsed as
    // nil and fell through to a 1-8 second backoff, so a limit asking for a minute got
    // three rapid retries into the same wall and then failed the run.

    @Test("A delay in seconds is read as seconds")
    func numericRetryAfterIsRead() {
        #expect(Backoff.retryAfterSeconds("60") == 60)
        #expect(Backoff.retryAfterSeconds("0.5") == 0.5)
        #expect(Backoff.retryAfterSeconds("  30  ") == 30)
    }

    @Test("An HTTP-date is read as the seconds until it")
    func httpDateRetryAfterIsRead() throws {
        let now = Date(timeIntervalSince1970: 784_111_777)   // 06 Nov 1994 08:49:37 GMT
        let seconds = try #require(
            Backoff.retryAfterSeconds("Sun, 06 Nov 1994 08:50:37 GMT", now: now)
        )
        #expect(abs(seconds - 60) < 0.001)
    }

    @Test("A date already past means no wait, not no answer")
    func pastDateIsZeroNotNil() throws {
        // nil would discard the server's answer and back off anyway.
        let now = Date(timeIntervalSince1970: 784_111_777)
        let seconds = try #require(
            Backoff.retryAfterSeconds("Sun, 06 Nov 1994 08:48:37 GMT", now: now)
        )
        #expect(seconds == 0)
    }

    @Test("Absent or unparsable headers fall back to the backoff")
    func unreadableHeaderYieldsNil() {
        #expect(Backoff.retryAfterSeconds(nil) == nil)
        #expect(Backoff.retryAfterSeconds("") == nil)
        #expect(Backoff.retryAfterSeconds("   ") == nil)
        #expect(Backoff.retryAfterSeconds("later") == nil)
    }

    @Test("A date-form header actually changes the delay")
    func dateFormReachesTheDelay() throws {
        // The consequence, not just the parse: without this the delay is the
        // exponential one, which is under 8 seconds.
        let now = Date(timeIntervalSince1970: 784_111_777)
        let seconds = try #require(
            Backoff.retryAfterSeconds("Sun, 06 Nov 1994 08:50:37 GMT", now: now)
        )
        let honoured = Backoff.delay(attempt: 0, retryAfter: seconds, base: 1)
        #expect(honoured == 60)
        let ignored = Backoff.delay(attempt: 0, retryAfter: nil, base: 1)
        #expect(ignored < 8)
    }

    @Test("The parse does not depend on the machine's locale or time zone")
    func parsingIsLocaleIndependent() throws {
        // A device on a non-Gregorian calendar, or a shifted zone, must read the same
        // bytes the same way — the server sent GMT.
        let now = Date(timeIntervalSince1970: 784_111_777)
        let seconds = try #require(
            Backoff.retryAfterSeconds("Sun, 06 Nov 1994 08:50:37 GMT", now: now)
        )
        #expect(abs(seconds - 60) < 0.001)
    }


    // MARK: - One retry predicate, not two

    // `Backoff` exists because "one definition, because there were about to be two,
    // and two would have drifted". Only half the policy moved: the timing was shared
    // and the predicate deciding whether to wait at all stayed copied into both
    // clients. They agreed, which is what made it a drift risk rather than a bug —
    // nothing would have failed if one had been edited.

    @Test("Statuses the server asks us to retry are retryable", arguments: [
        408, 409, 429, 500, 502, 503, 504, 599,
    ])
    func retryableStatuses(_ status: Int) {
        #expect(Backoff.isRetryable(status: status))
    }

    @Test("A request that was wrong is not retried", arguments: [
        400, 401, 403, 404, 413, 422,
    ])
    func nonRetryableStatuses(_ status: Int) {
        // Retrying a bad key or a malformed body burns quota to fail identically.
        #expect(!Backoff.isRetryable(status: status))
    }

    @Test("Both clients answer the same for every status")
    func clientsAgreeOnRetryability() {
        // The property the shared definition exists to guarantee. Asserted across the
        // whole range rather than at a few points, because a divergence would most
        // likely be one edited boundary.
        for status in 100...599 {
            let anthropic = AnthropicClient.Error
                .api(status: status, type: "t", message: "m", retryAfter: nil)
                .isRetryable
            let openAI = OpenAICompatibleClient.Error
                .api(provider: "p", status: status, type: "t", message: "m", retryAfter: nil)
                .isRetryable
            #expect(anthropic == openAI, "disagreed on \(status)")
            #expect(anthropic == Backoff.isRetryable(status: status), "\(status)")
        }
    }

    @Test("Transport failures are retryable and malformed responses are not")
    func nonStatusErrorsAreUnchanged() {
        // A dropped connection may succeed next time; a response we could not parse
        // will parse the same way again.
        struct Dropped: Swift.Error {}
        #expect(AnthropicClient.Error.transport(underlying: Dropped()).isRetryable)
        #expect(OpenAICompatibleClient.Error
            .transport(provider: "p", underlying: Dropped()).isRetryable)
        #expect(!AnthropicClient.Error.malformedResponse("x").isRetryable)
        #expect(!OpenAICompatibleClient.Error
            .malformedResponse(provider: "p", detail: "x").isRetryable)
    }

}

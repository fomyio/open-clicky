import Testing
import Foundation
@testable import OpenClickyKit

/// Credential resolution has an order, and picking the wrong source is silent: the
/// request simply goes out signed by something the user did not intend, and the only
/// symptom is an authentication error they cannot explain.
@Suite("Credential resolution", .serialized)
struct CredentialsTests {

    /// A keychain that never touches the real one.
    private func scratchKeychain() -> Keychain {
        Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
    }

    private func withEnvironment(
        _ values: [String: String?], _ body: () throws -> Void
    ) rethrows {
        let saved = values.keys.reduce(into: [String: String?]()) {
            $0[$1] = ProcessInfo.processInfo.environment[$1]
        }
        for (key, value) in values {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try body()
    }

    @Test("An API key in the environment wins")
    func environmentKeyWins() throws {
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-from-keychain", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        try withEnvironment([
            "ANTHROPIC_API_KEY": "sk-ant-from-environment",
            "ANTHROPIC_AUTH_TOKEN": "oauth-token",
        ]) {
            guard case let .apiKey(key) = try Credentials.resolve(keychain: keychain) else {
                Issue.record("expected an API key")
                return
            }
            #expect(key == "sk-ant-from-environment")
        }
    }

    /// The two are sent on different headers, so choosing the wrong one produces a
    /// request that is malformed rather than merely unauthorised.
    @Test("An OAuth token is used when no API key is set")
    func oauthTokenIsSecond() throws {
        let keychain = scratchKeychain()
        try withEnvironment([
            "ANTHROPIC_API_KEY": nil,
            "ANTHROPIC_AUTH_TOKEN": "oauth-token",
        ]) {
            guard case let .oauthToken(token) = try Credentials.resolve(keychain: keychain) else {
                Issue.record("expected an OAuth token")
                return
            }
            #expect(token == "oauth-token")
        }
    }

    @Test("The Keychain is used when the environment is empty")
    func keychainIsLast() throws {
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-from-keychain", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        try withEnvironment(["ANTHROPIC_API_KEY": nil, "ANTHROPIC_AUTH_TOKEN": nil]) {
            guard case let .apiKey(key) = try Credentials.resolve(keychain: keychain) else {
                Issue.record("expected the stored key")
                return
            }
            #expect(key == "sk-ant-from-keychain")
        }
    }

    /// An exported-but-empty variable is a common shell accident. Treating it as a
    /// credential sends an unauthenticated request instead of falling through.
    @Test("An empty variable is skipped rather than used")
    func emptyVariablesAreSkipped() throws {
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-from-keychain", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        try withEnvironment(["ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": ""]) {
            guard case let .apiKey(key) = try Credentials.resolve(keychain: keychain) else {
                Issue.record("expected to fall through to the Keychain")
                return
            }
            #expect(key == "sk-ant-from-keychain")
        }
    }

    @Test("With nothing available the error explains what to do")
    func nothingAvailable() {
        let keychain = scratchKeychain()
        withEnvironment(["ANTHROPIC_API_KEY": nil, "ANTHROPIC_AUTH_TOKEN": nil]) {
            #expect(throws: AnthropicClient.Error.self) {
                _ = try Credentials.resolve(keychain: keychain)
            }
        }
    }

    // MARK: - Keychain round trip

    @Test("A stored secret round-trips and can be deleted")
    func keychainRoundTrip() throws {
        let keychain = scratchKeychain()
        let account = "round-trip-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }

        #expect(try keychain.read(account: account) == nil, "absent before writing")
        try keychain.write("sk-ant-secret-value", account: account)
        #expect(try keychain.read(account: account) == "sk-ant-secret-value")

        // Writing again replaces rather than duplicating, which would make reads
        // return whichever item the search happened to match first.
        try keychain.write("sk-ant-replaced", account: account)
        #expect(try keychain.read(account: account) == "sk-ant-replaced")

        try keychain.delete(account: account)
        #expect(try keychain.read(account: account) == nil)
    }

    /// Documents a limitation rather than a guarantee, which is the honest thing to
    /// assert here.
    ///
    /// The code requests `ThisDeviceOnly`, to keep the key out of encrypted backups
    /// and Migration Assistant transfers. It does not take effect: that attribute
    /// only applies in the data-protection keychain, which needs an entitlement a
    /// SwiftPM binary cannot have. The login keychain accepts the attribute and
    /// silently drops it — which nothing noticed until a test read it back.
    ///
    /// If the tool ever gains the entitlement this starts returning a value, and the
    /// expectation below should be tightened to require the right one.
    @Test("The requested device scoping is not actually applied")
    func deviceScopingIsNotInEffect() throws {
        let keychain = scratchKeychain()
        let account = "scope-\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }

        try keychain.write("sk-ant-scoped", account: account)

        // The value round-trips regardless; only the protection class is unavailable.
        #expect(try keychain.read(account: account) == "sk-ant-scoped")
        #expect(try keychain.accessibility(account: account) == nil,
                "the login keychain has started reporting a protection class — tighten this")
    }

    @Test("Deleting something absent is not an error")
    func deletingAbsentIsFine() throws {
        try scratchKeychain().delete(account: "never-written-\(UUID().uuidString)")
    }

    @Test("Secrets are scoped to their service")
    func servicesAreIsolated() throws {
        let first = scratchKeychain()
        let second = scratchKeychain()
        let account = "shared-name"
        defer { try? first.delete(account: account); try? second.delete(account: account) }

        try first.write("first-value", account: account)
        #expect(try second.read(account: account) == nil, "a different service must not see it")
    }

    // MARK: - Verifying a key rather than just storing it

    /// "Stored in the Keychain" is not the same claim as "this key works", and someone
    /// told the first while hearing the second discovers the difference three commands
    /// later, attributing it to something else.
    @Test("A rejected key is reported as rejected, not as stored")
    func rejectedKeyIsReported() async {
        let client = FixedClient(error: .api(
            status: 401, type: "authentication_error",
            message: "API key is invalid.", retryAfter: nil
        ))
        let result = await Credentials.apiKey("sk-ant-x").verify(using: client)
        #expect(result == .rejected("API key is invalid."))
        #expect(result.summary.contains("no run will work"))
    }

    /// A network failure is not a bad key, and saying so avoids sending someone to
    /// regenerate a key that was fine.
    @Test("An unreachable API is distinguished from a bad key")
    func unreachableIsNotRejected() async {
        struct Offline: Swift.Error, LocalizedError {
            var errorDescription: String? { "The Internet connection appears to be offline." }
        }
        let client = FixedClient(error: .transport(underlying: Offline()))
        let result = await Credentials.apiKey("sk-ant-x").verify(using: client)
        guard case let .unreachable(detail) = result else {
            Issue.record("a network failure was reported as \(result)")
            return
        }
        #expect(detail.contains("offline"))
        #expect(result.summary.contains("not necessarily a bad key"))
    }

    /// The question is whether the credentials were accepted. A request rejected for
    /// any other reason still answers it — and treating that as a bad key would send
    /// someone to replace a working one.
    @Test("A non-auth API error still means the key was accepted")
    func otherErrorsMeanTheKeyWorks() async {
        let client = FixedClient(error: .api(
            status: 400, type: "invalid_request_error",
            message: "max_tokens: must be greater than 0", retryAfter: nil
        ))
        #expect(await Credentials.apiKey("sk-ant-x").verify(using: client) == .working)
    }

    @Test("A successful response means the key works")
    func successMeansWorking() async {
        #expect(await Credentials.apiKey("sk-ant-x").verify(using: FixedClient(error: nil)) == .working)
    }

    /// Sends whatever it is told to, or nothing at all. Never reaches the network.
    private struct FixedClient: MessagesClient {
        let error: AnthropicClient.Error?

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            if let error { throw error }
            let fields: [String: JSONValue] = [
                "id": .string("msg"), "role": .string("assistant"),
                "model": .string("claude-opus-5"), "stop_reason": .string("end_turn"),
                "content": .array([]),
                "usage": .object(["input_tokens": .number(1), "output_tokens": .number(1)]),
            ]
            return try JSONDecoder().decode(
                Wire.Response.self, from: try JSONEncoder().encode(JSONValue.object(fields))
            )
        }
    }

    /// `auth` printed the Keychain service as a literal in its success message. If
    /// the service ever changed, the message would confidently name the wrong one and
    /// send someone looking in the wrong place in Keychain Access — a small lie, and
    /// exactly the kind that costs an hour.
    @Test("The named service is the one credentials are stored under")
    func serviceNameMatchesTheStandardKeychain() throws {
        #expect(Keychain.serviceName == "com.openclicky.credentials")

        // Written and read back through the named service, so the name cannot drift
        // from the store it claims to describe.
        let keychain = Keychain(service: Keychain.serviceName + ".test-\(UUID().uuidString)")
        try keychain.write("sk-ant-test-value", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }
        #expect(try keychain.read(account: Keychain.apiKeyAccount) == "sk-ant-test-value")
    }
}

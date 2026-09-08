import Testing
import Foundation
@testable import OpenClickyKit

/// Credential resolution has an order, and picking the wrong source is silent: the
/// request simply goes out signed by something the user did not intend, and the only
/// symptom is an authentication error they cannot explain.
@Suite("Credential resolution", .serialized)
struct CredentialsTests {

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
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file", provider: "anthropic")

        try withEnvironment([
            "ANTHROPIC_API_KEY": "sk-ant-from-environment",
            "ANTHROPIC_AUTH_TOKEN": "oauth-token",
        ]) {
            guard case let .apiKey(key) = try Credentials.resolve(config: config) else {
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
        try withEnvironment([
            "ANTHROPIC_API_KEY": nil,
            "ANTHROPIC_AUTH_TOKEN": "oauth-token",
        ]) {
            guard case let .oauthToken(token) = try Credentials.resolve(config: isolatedConfig()) else {
                Issue.record("expected an OAuth token")
                return
            }
            #expect(token == "oauth-token")
        }
    }

    /// The config file is the last step and the only store on disk. There is no
    /// Keychain fallback any more: its read is gated per binary, so `swift build` made
    /// every run ask again, and the dialog taught its user to click through prompts.
    @Test("The config file is used when the environment is empty")
    func configFileIsLast() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file", provider: "anthropic")

        try withEnvironment(["ANTHROPIC_API_KEY": nil, "ANTHROPIC_AUTH_TOKEN": nil]) {
            guard case let .apiKey(key) = try Credentials.resolve(config: config) else {
                Issue.record("expected the stored key")
                return
            }
            #expect(key == "sk-ant-from-file")
        }
    }

    /// An exported-but-empty variable is a common shell accident. Treating it as a
    /// credential sends an unauthenticated request instead of falling through.
    @Test("An empty variable is skipped rather than used")
    func emptyVariablesAreSkipped() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file", provider: "anthropic")

        try withEnvironment(["ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": ""]) {
            guard case let .apiKey(key) = try Credentials.resolve(config: config) else {
                Issue.record("expected to fall through to the config file")
                return
            }
            #expect(key == "sk-ant-from-file")
        }
    }

    @Test("With nothing available the error explains what to do")
    func nothingAvailable() {
        withEnvironment(["ANTHROPIC_API_KEY": nil, "ANTHROPIC_AUTH_TOKEN": nil]) {
            #expect(throws: AnthropicClient.Error.self) {
                _ = try Credentials.resolve(config: isolatedConfig())
            }
        }
    }

    /// The first error most people meet has to send them somewhere that exists.
    @Test("The missing-credentials error names the file and a command that parses")
    func missingCredentialsErrorIsActionable() {
        let message = AnthropicClient.Error.missingCredentials.description
        #expect(message.contains(ConfigFile.defaultURL.path))
        #expect(!message.lowercased().contains("keychain"), "the Keychain is gone")
        guard case let .success(invocation) = Invocation.parse(["auth"]) else {
            Issue.record("the command the error suggests does not parse")
            return
        }
        #expect(invocation.command == .auth)
    }

    // MARK: - Verifying a key rather than just storing it

    /// "Stored" is not the same claim as "this key works", and someone
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

    /// `auth` printed its store as a literal in its success message. If the path ever
    /// changed, the message would confidently name the wrong one and send someone
    /// looking in the wrong place — a small lie, and exactly the kind that costs an hour.
    @Test("The named store is the one credentials are actually written to")
    func namedStoreMatchesTheFileWritten() throws {
        #expect(ConfigFile.defaultURL.path.hasSuffix("/.openclicky/config.json"))

        // Written and read back through the same value the messages quote, so the name
        // cannot drift from the store it claims to describe.
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-test-value", provider: "anthropic")
        #expect(try config.keys()["anthropic"] == "sk-ant-test-value")
    }
}

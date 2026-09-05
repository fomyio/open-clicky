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
    func nothingAvailable() throws {
        let keychain = scratchKeychain()
        try withEnvironment(["ANTHROPIC_API_KEY": nil, "ANTHROPIC_AUTH_TOKEN": nil]) {
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
}

import Testing
import Foundation
@testable import OpenClickyKit

/// Provider resolution has an order, and picking the wrong source is silent: the
/// request goes to an endpoint the user did not intend, signed by a credential they
/// did not choose, and the only symptom is an error they cannot explain.
///
/// Everything here is driven through injected environment dictionaries and scratch
/// keychains. Nothing reads the real environment and nothing contacts an endpoint.
@Suite("Provider resolution", .serialized)
struct ProviderTests {

    private func scratchKeychain() -> Keychain {
        Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
    }

    /// An empty dictionary, so a variable the developer happens to have exported
    /// cannot change what these assert.
    private let noEnvironment: [String: String] = [:]

    // MARK: - Which provider

    @Test("Nothing configured means Anthropic")
    func defaultsToAnthropic() throws {
        let keychain = scratchKeychain()
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: keychain, environment: ["ANTHROPIC_API_KEY": "sk-ant-test-123456789"]
        )
        #expect(provider.kind == .anthropic)
        #expect(provider.model == DefaultModel.id)
        #expect(provider.baseURL == nil, "Anthropic's endpoint is not configurable")
    }

    @Test("The environment can choose the provider")
    func environmentChoosesTheProvider() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: scratchKeychain(),
            environment: ["OPENCLICKY_PROVIDER": "ollama"]
        )
        #expect(provider.kind == .ollama)
    }

    @Test("An explicit provider beats the environment")
    func flagBeatsEnvironment() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .groq, keychain: scratchKeychain(),
            environment: ["OPENCLICKY_PROVIDER": "ollama", "GROQ_API_KEY": "gsk-test-123"]
        )
        #expect(provider.kind == .groq)
    }

    /// Every provider must have an endpoint to talk to before it is asked anything.
    @Test("Each OpenAI-compatible provider has a default endpoint", arguments: [
        (Provider.Kind.openai, "https://api.openai.com/v1"),
        (.ollama, "http://localhost:11434/v1"),
        (.litellm, "http://localhost:4000"),
        (.groq, "https://api.groq.com/openai/v1"),
    ])
    func defaultEndpoints(scenario: (Provider.Kind, String)) {
        #expect(scenario.0.defaultBaseURL?.absoluteString == scenario.1)
    }

    // MARK: - Which model

    /// The built-in default only ever meant "the default for Anthropic". Carried into
    /// Ollama it is a 404 that reads as a broken install.
    @Test("A model nobody typed belongs to the provider", arguments: [
        (Provider.Kind.anthropic, DefaultModel.id),
        (.openai, "gpt-4o"),
        (.ollama, "llama3.2"),
        (.groq, "llama-3.3-70b-versatile"),
    ])
    func defaultModelFollowsTheProvider(scenario: (Provider.Kind, String)) throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: scenario.0, keychain: scratchKeychain(),
            environment: [
                "ANTHROPIC_API_KEY": "sk-ant-test-123456789",
                "OPENCLICKY_API_KEY": "test-key-123456789",
            ]
        )
        #expect(provider.model == scenario.1)
    }

    @Test("An explicit model wins over the provider's default")
    func explicitModelWins() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, model: "qwen2.5:14b",
            keychain: scratchKeychain(), environment: noEnvironment
        )
        #expect(provider.model == "qwen2.5:14b")
    }

    @Test("OPENCLICKY_MODEL is used when no flag was passed")
    func environmentModelIsUsed() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, keychain: scratchKeychain(),
            environment: ["OPENCLICKY_MODEL": "llava:13b"]
        )
        #expect(provider.model == "llava:13b")
    }

    /// LiteLLM routes by names its own configuration defines, so a guess produces a
    /// 404 that reads as "the proxy is broken".
    @Test("A provider with no defensible default demands a model")
    func litellmDemandsAModel() {
        #expect(throws: Provider.Error.self) {
            _ = try Provider.resolve(config: isolatedConfig(), 
                kind: .litellm, keychain: scratchKeychain(), environment: noEnvironment
            )
        }
    }

    // MARK: - Credentials, in the order Credentials already uses

    @Test("A key in the environment wins over the Keychain")
    func environmentKeyWins() throws {
        let keychain = scratchKeychain()
        try keychain.write("from-keychain", account: Provider.Kind.openai.keychainAccount)
        defer { try? keychain.delete(account: Provider.Kind.openai.keychainAccount) }

        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .openai, keychain: keychain,
            environment: ["OPENAI_API_KEY": "from-environment"]
        )
        guard case let .apiKey(key)? = provider.credentials else {
            Issue.record("expected an API key")
            return
        }
        #expect(key == "from-environment")
    }

    @Test("The Keychain is used when the environment is empty")
    func keychainIsLast() throws {
        let keychain = scratchKeychain()
        try keychain.write("from-keychain", account: Provider.Kind.groq.keychainAccount)
        defer { try? keychain.delete(account: Provider.Kind.groq.keychainAccount) }

        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .groq, keychain: keychain, environment: noEnvironment
        )
        guard case let .apiKey(key)? = provider.credentials else {
            Issue.record("expected the stored key")
            return
        }
        #expect(key == "from-keychain")
    }

    /// An exported-but-empty variable is a common shell accident. Treating it as a
    /// credential sends an unauthenticated request instead of falling through.
    @Test("An empty variable is skipped rather than used")
    func emptyVariablesAreSkipped() throws {
        let keychain = scratchKeychain()
        try keychain.write("from-keychain", account: Provider.Kind.openai.keychainAccount)
        defer { try? keychain.delete(account: Provider.Kind.openai.keychainAccount) }

        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .openai, keychain: keychain,
            environment: ["OPENAI_API_KEY": "", "OPENCLICKY_API_KEY": ""]
        )
        guard case let .apiKey(key)? = provider.credentials else {
            Issue.record("expected to fall through to the Keychain")
            return
        }
        #expect(key == "from-keychain")
    }

    /// One key per provider, under its own account. A shared account would make
    /// `--provider openai` quietly sign with an Anthropic key and 401.
    @Test("Each provider reads its own Keychain account")
    func accountsDoNotCollide() {
        let accounts = Provider.Kind.allCases.map(\.keychainAccount)
        #expect(Set(accounts).count == accounts.count, "two providers share an account")
        #expect(Provider.Kind.anthropic.keychainAccount == Keychain.apiKeyAccount,
                "the existing stored key must keep working")
    }

    @Test("A provider that needs a key and has none says so")
    func missingKeyIsAnError() {
        #expect(throws: Provider.Error.self) {
            _ = try Provider.resolve(config: isolatedConfig(), 
                kind: .openai, keychain: scratchKeychain(), environment: noEnvironment
            )
        }
    }

    /// Only a local daemon can start without one.
    @Test("Ollama runs with no key at all")
    func ollamaNeedsNoKey() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, keychain: scratchKeychain(), environment: noEnvironment
        )
        #expect(provider.credentials == nil)
    }

    /// Every command an error names has to parse, or the first error most people
    /// meet is a dead end.
    @Test("The missing-credentials error names a command that exists")
    func credentialErrorNamesRealCommands() {
        let message = Provider.Error.missingCredentials(.openai).description
        #expect(message.contains("openclicky auth --provider openai"))
        #expect(message.contains("OPENAI_API_KEY"))

        guard case let .success(invocation) =
            Invocation.parse(["auth", "--provider", "openai"]) else {
            Issue.record("the command the error suggests does not parse")
            return
        }
        #expect(invocation.command == .auth)
        #expect(invocation.providerKind == .openai)
    }

    // MARK: - The base URL is untrusted input

    @Test("A base URL without a usable scheme is refused", arguments: [
        "localhost:11434", "file:///etc/passwd", "not a url at all", "ftp://example.com",
    ])
    func badBaseURLsAreRefused(text: String) {
        #expect(throws: Provider.Error.self) {
            _ = try Provider.resolveBaseURL(requested: text, kind: .litellm)
        }
    }

    @Test("A valid base URL overrides the provider's default")
    func baseURLOverrides() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, baseURL: "http://localhost:8080/v1",
            keychain: scratchKeychain(), environment: noEnvironment
        )
        #expect(provider.baseURL?.absoluteString == "http://localhost:8080/v1")
    }

    @Test("OPENCLICKY_BASE_URL is used when no flag was passed")
    func environmentBaseURLIsUsed() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, keychain: scratchKeychain(),
            environment: ["OPENCLICKY_BASE_URL": "http://localhost:9999/v1"]
        )
        #expect(provider.baseURL?.absoluteString == "http://localhost:9999/v1")
    }

    /// A bearer token over plaintext HTTP to anything but loopback is readable by
    /// every hop between here and there. Refused rather than warned about: a warning
    /// about a leak the user cannot see happening is not a control.
    @Test("A key is never sent over plaintext HTTP to a remote host")
    func plaintextRemoteWithAKeyIsRefused() {
        #expect(throws: Provider.Error.self) {
            _ = try Provider.resolve(config: isolatedConfig(), 
                kind: .litellm, baseURL: "http://proxy.example.com:4000",
                model: "gpt-4o", keychain: scratchKeychain(),
                environment: ["LITELLM_API_KEY": "sk-secret-123456789"]
            )
        }
    }

    @Test("Plaintext HTTP to loopback is fine — nothing leaves the machine", arguments: [
        "http://localhost:4000", "http://127.0.0.1:4000",
    ])
    func plaintextLoopbackIsAllowed(base: String) throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .litellm, baseURL: base, model: "gpt-4o",
            keychain: scratchKeychain(),
            environment: ["LITELLM_API_KEY": "sk-secret-123456789"]
        )
        #expect(provider.baseURL?.absoluteString == base)
    }

    @Test("The same remote host over https is fine")
    func httpsRemoteIsAllowed() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .litellm, baseURL: "https://proxy.example.com", model: "gpt-4o",
            keychain: scratchKeychain(),
            environment: ["LITELLM_API_KEY": "sk-secret-123456789"]
        )
        #expect(provider.baseURL?.absoluteString == "https://proxy.example.com")
    }

    /// A keyless run has nothing to leak, so the rule must not block a plain local
    /// Ollama reached by hostname.
    @Test("A keyless provider may use plaintext HTTP anywhere")
    func keylessPlaintextIsAllowed() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            kind: .ollama, baseURL: "http://gpu-box.lan:11434/v1",
            keychain: scratchKeychain(), environment: noEnvironment
        )
        #expect(provider.credentials == nil)
        #expect(provider.baseURL?.host == "gpu-box.lan")
    }

    // MARK: - What comes out of it

    /// The client a provider builds must speak the dialect that endpoint understands.
    /// Anthropic's Messages API and the chat-completions dialect are not
    /// interchangeable, and sending one body to the other is a 400 on every request.
    @Test("Each provider builds a client for its own dialect")
    func clientMatchesTheDialect() async {
        let anthropic = Provider(
            kind: .anthropic, model: DefaultModel.id, baseURL: nil,
            credentials: .apiKey("sk-ant-test-123456789")
        )
        #expect(anthropic.makeClient() is AnthropicClient)

        for kind in [Provider.Kind.openai, .ollama, .litellm, .groq] {
            let provider = Provider(
                kind: kind, model: "gpt-4o", baseURL: kind.defaultBaseURL,
                credentials: .apiKey("test-key-123456789")
            )
            #expect(provider.makeClient() is OpenAICompatibleClient, "\(kind.rawValue)")
        }
    }

    @Test("The summary names the endpoint a run will actually call")
    func summaryNamesTheEndpoint() {
        let provider = Provider(
            kind: .ollama, model: "llama3.2",
            baseURL: URL(string: "http://localhost:11434/v1"), credentials: nil
        )
        #expect(provider.summary.contains("Ollama"))
        #expect(provider.summary.contains("llama3.2"))
        #expect(provider.summary.contains("localhost:11434"))
    }

    // MARK: - Verification

    /// A stubbed client, so verification is exercised without an endpoint.
    private struct Responder: MessagesClient {
        let outcome: @Sendable () throws -> Wire.Response
        func send(_ request: Wire.Request) async throws -> Wire.Response { try outcome() }
    }

    private var okResponse: Wire.Response {
        Wire.Response(
            id: "x", role: .assistant, content: [.text("hi")], model: "m",
            stopReason: "end_turn", stopDetails: nil,
            usage: Wire.Usage(inputTokens: 1, outputTokens: 1,
                              cacheReadInputTokens: nil, cacheCreationInputTokens: nil)
        )
    }

    private var provider: Provider {
        Provider(kind: .ollama, model: "llama3.2",
                 baseURL: URL(string: "http://localhost:11434/v1"), credentials: nil)
    }

    @Test("A successful probe verifies the configuration")
    func verifyWorking() async {
        let result = await provider.verify(using: Responder { self.okResponse })
        #expect(result == .working)
    }

    @Test("A 401 is a rejected credential")
    func verifyRejected() async {
        let result = await provider.verify(using: Responder {
            throw OpenAICompatibleClient.Error.api(
                provider: "Ollama", status: 401, type: "auth", message: "bad key", retryAfter: nil
            )
        })
        #expect(result == .rejected("bad key"))
    }

    /// An unreachable endpoint is not a verdict on the key: a laptop on a train, or
    /// an Ollama daemon that is not running, must not be reported as bad credentials.
    @Test("An unreachable endpoint is not reported as a bad key")
    func verifyUnreachable() async {
        let result = await provider.verify(using: Responder {
            throw OpenAICompatibleClient.Error.transport(
                provider: "Ollama",
                underlying: URLError(.cannotConnectToHost)
            )
        })
        guard case .unreachable = result else {
            Issue.record("a dead daemon was reported as \(result)")
            return
        }
    }

    /// Found by running it: `doctor --provider ollama` reported "verified against
    /// Ollama" against a daemon that was running and a model that had never been
    /// pulled, and the very next command died on a 404. The probe had proved the
    /// endpoint was reachable and unauthenticated — true, and not the question a
    /// diagnostic is asked.
    @Test("A model the endpoint has never heard of is a misconfiguration")
    func verifyUnknownModelIsMisconfigured() async {
        let result = await provider.verify(using: Responder {
            throw OpenAICompatibleClient.Error.api(
                provider: "Ollama", status: 404, type: "not_found",
                message: "model 'llava' not found", retryAfter: nil
            )
        })
        #expect(result == .misconfigured("model 'llava' not found"))
        #expect(result.summary.contains("credential is fine"),
                "it must not send the user looking for a new key")
    }

    /// The same verdict for the Anthropic client, so `--model claude-nonexistent`
    /// is not reported as a working setup either.
    @Test("The Anthropic client reaches the same verdict")
    func anthropicUnknownModelIsMisconfigured() async {
        let anthropic = Provider(
            kind: .anthropic, model: "claude-nonexistent", baseURL: nil,
            credentials: .apiKey("sk-ant-test-123456789")
        )
        let result = await anthropic.verify(using: Responder {
            throw AnthropicClient.Error.api(
                status: 404, type: "not_found_error",
                message: "model: claude-nonexistent", retryAfter: nil
            )
        })
        guard case .misconfigured = result else {
            Issue.record("an unknown model verified as \(result)")
            return
        }
    }

    /// A rate limit says nothing about the configuration, and an auth failure has its
    /// own verdict. Neither may be swept into "misconfigured".
    @Test("Auth failures and rate limits are not misconfigurations", arguments: [401, 403, 429])
    func authAndRateLimitsAreNotMisconfiguration(status: Int) {
        #expect(Provider.misconfiguration(status: status, message: "x") == nil)
    }

    /// And a 5xx is the endpoint's problem, not the configuration's.
    @Test("A server error is not a misconfiguration")
    func serverErrorsAreNotMisconfiguration() {
        #expect(Provider.misconfiguration(status: 500, message: "x") == nil)
        #expect(Provider.misconfiguration(status: 503, message: "x") == nil)
    }

    /// `Credentials.verify` answers a narrower question — does this *key* work — and
    /// keeps its own answer. Widening it would report a machine as broken on the
    /// strength of a model id nobody passed to it.
    @Test("The key-only check is unchanged by the wider one")
    func credentialsVerifyKeepsItsOwnQuestion() {
        #expect(Credentials.interpret(AnthropicClient.Error.api(
            status: 404, type: "not_found_error", message: "model: x", retryAfter: nil
        )) == .working)
    }

    /// A machine the endpoint will not serve is not ready, whatever the key says.
    @Test("A misconfigured endpoint is not a ready machine")
    func misconfiguredIsNotReady() {
        let granted = PermissionStatus(screenRecording: true, accessibility: true)
        #expect(!granted.isReady(credentials: .misconfigured("model not found")))
        #expect(!granted.isReady(credentials: .misconfigured("model not found"), upTo: .shell))
    }

    /// The same rule, read through the same protocol, for the other client — so the
    /// two cannot drift apart on the case that matters.
    @Test("The Anthropic client is read by the same rule")
    func anthropicVerdictsMatch() {
        #expect(Credentials.interpret(AnthropicClient.Error.api(
            status: 403, type: "auth", message: "nope", retryAfter: nil
        )) == .rejected("nope"))
        #expect(Credentials.interpret(AnthropicClient.Error.api(
            status: 400, type: "invalid", message: "bad field", retryAfter: nil
        )) == .working)
    }

    // MARK: - Whether a run is billed

    @Test("A local Ollama endpoint is not billed")
    func loopbackOllamaIsNotBilled() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: scratchKeychain(),
            environment: ["OPENCLICKY_PROVIDER": "ollama"]
        )
        #expect(!provider.isBilled)
        #expect(provider.pricing == .unbilled)
    }

    @Test("Ollama pointed off this machine is billed again")
    func remoteOllamaIsBilled() throws {
        // Decided by the endpoint, not the provider name — the question that stays
        // right when someone points `--base-url` somewhere unexpected.
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: scratchKeychain(),
            environment: [
                "OPENCLICKY_PROVIDER": "ollama",
                "OPENCLICKY_BASE_URL": "https://ollama.example.com/v1",
            ]
        )
        #expect(provider.isBilled)
        #expect(provider.pricing == nil)
    }

    @Test("A proxy on loopback is still billed")
    func loopbackProxyIsStillBilled() throws {
        // LiteLLM on localhost is a proxy that may bill through to OpenAI. Only a
        // model actually served by this machine is free.
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: scratchKeychain(),
            environment: [
                "OPENCLICKY_PROVIDER": "litellm",
                "OPENCLICKY_MODEL": "gpt-4o",
                "OPENCLICKY_API_KEY": "sk-test-123456789",
            ]
        )
        #expect(provider.isBilled)
    }

    @Test("Anthropic is billed")
    func anthropicIsBilled() throws {
        let provider = try Provider.resolve(config: isolatedConfig(), 
            keychain: scratchKeychain(),
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test-123456789"]
        )
        #expect(provider.isBilled)
        #expect(provider.pricing == nil)
    }


    // MARK: - An unattended run must not hang on the Keychain

    // Reading a credential's *data* is gated by an ACL naming the binaries allowed to
    // see it, granted per binary — `swift build` produces a new one every time, so a
    // rebuild asks again. When nobody can answer, `SecItemCopyMatching` does not fail
    // and does not time out: it blocks for as long as the process lives. `doctor`
    // piped to a file printed two lines and then nothing, forever.

    @Test("A readable credential is still read when unattended")
    func readableCredentialIsNotRefused() throws {
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-test-123456789", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        // The first version of this fix refused *any* unattended read of an item that
        // existed, which failed every caller already in the ACL — including this one.
        // Present is not the same as unreadable.
        #expect(try keychain.exists(account: Keychain.apiKeyAccount))
        #expect(try keychain.read(account: Keychain.apiKeyAccount, mayPrompt: false)
            == "sk-ant-test-123456789")
    }

    @Test("An absent credential is absent, not pending approval")
    func absentCredentialIsNotConfusedWithLockedOne() throws {
        // The distinction the unattended path exists to make: "no such credential" and
        // "a credential nobody may read" need different messages, and reporting both
        // as missing sends the user to `auth` to re-enter a key that is already there.
        let keychain = scratchKeychain()
        #expect(try !keychain.exists(account: Keychain.apiKeyAccount))
        #expect(try keychain.read(account: Keychain.apiKeyAccount, mayPrompt: false) == nil)
    }

    @Test("The approval message names the account and the way out")
    func approvalMessageIsActionable() {
        // A user who sees this has a key stored and a binary that cannot read it. The
        // message has to say both, or it reads as "your key is gone".
        let message = Keychain.Error.needsApproval(account: "anthropic-api-key").description
        #expect(message.contains("anthropic-api-key"))
        #expect(message.contains("Always Allow"))
        #expect(message.contains("swift build"), "the rebuild is why it keeps recurring")
    }

    @Test("Resolution passes the prompt policy down to the Keychain")
    func resolvePassesThePolicyThrough() throws {
        // Threading this was the whole fix: the Anthropic branch delegates to
        // `Credentials.resolve`, and that call was the one still allowed to block.
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-test-123456789", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        let provider = try Provider.resolve(config: isolatedConfig(), 
            mayPrompt: false, kind: .anthropic,
            keychain: keychain, environment: noEnvironment
        )
        #expect(provider.kind == .anthropic)
    }


    @Test("A read that never returns is abandoned, not awaited")
    func unattendedReadIsBounded() throws {
        // The behaviour that matters, and the one a real keychain cannot stage: a test
        // cannot create an item it is forbidden to read, because it would have to be
        // the writer. The blocking half is injected instead.
        let keychain = scratchKeychain()
        try keychain.write("sk-ant-test-123456789", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        let started = Date()
        #expect(throws: Keychain.Error.self) {
            _ = try keychain.read(
                account: Keychain.apiKeyAccount,
                mayPrompt: false,
                timeout: .milliseconds(200),
                perform: { _ in
                    // Stands in for a dialog nobody can answer.
                    Thread.sleep(forTimeInterval: 30)
                    return "never reached"
                }
            )
        }
        // Bounded by the timeout, not by the blocked read.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A caller allowed to prompt still waits for the answer")
    func interactiveReadIsNotBounded() throws {
        // In a terminal the dialog is the point. Bounding it there would abandon a
        // read the user was about to approve.
        let keychain = scratchKeychain()
        let value = try keychain.read(
            account: "absent", mayPrompt: true, timeout: .milliseconds(1),
            perform: { _ in
                Thread.sleep(forTimeInterval: 0.3)   // longer than the timeout
                return "answered"
            }
        )
        #expect(value == "answered")
    }

    @Test("A bounded read that finds nothing reports absence, not approval")
    func boundedReadOfAnAbsentItemIsNil() throws {
        // Absent and unreadable need opposite actions, and the timeout path must not
        // collapse them.
        let keychain = scratchKeychain()
        let value = try keychain.read(
            account: "absent", mayPrompt: false, timeout: .milliseconds(200),
            perform: { _ in Thread.sleep(forTimeInterval: 30); return "never" }
        )
        #expect(value == nil, "nothing is stored, so there is nothing to approve")
    }

}

/// The flags that choose a provider, and the run they produce.
@Suite("Provider selection on the command line")
struct ProviderInvocationTests {

    private func parse(_ arguments: String...) throws -> Invocation {
        guard case let .success(invocation) = Invocation.parse(arguments) else {
            throw ParseFailed()
        }
        return invocation
    }
    private struct ParseFailed: Error {}

    @Test("--provider accepts every provider that exists", arguments: Provider.Kind.allCases)
    func providerFlagAcceptsEveryKind(kind: Provider.Kind) throws {
        #expect(try parse("--provider", kind.rawValue, "task").providerKind == kind)
    }

    /// Silently ignoring an unrecognised value would run against Anthropic while the
    /// user believed they had chosen otherwise — and paid for it.
    @Test("An unknown provider is an error, not a fallback")
    func unknownProviderIsRejected() {
        guard case let .failure(error) = Invocation.parse(["--provider", "gemini", "t"]) else {
            Issue.record("an unknown provider was accepted")
            return
        }
        #expect(error.message.contains("ollama"), "the error should list what is valid")
    }

    @Test("--base-url is carried through")
    func baseURLFlagIsCarried() throws {
        #expect(try parse("--base-url", "http://localhost:4000", "t").baseURL
                == "http://localhost:4000")
    }

    @Test("--base-url with no value is an error")
    func baseURLNeedsAValue() {
        #expect(Invocation.parse(["--base-url"]).isFailure)
    }

    /// The distinction the provider default depends on.
    @Test("Whether the model was typed is recorded")
    func modelExplicitnessIsRecorded() throws {
        #expect(try parse("task").modelIsExplicit == false)
        #expect(try parse("--model", "gpt-4o", "task").modelIsExplicit)
    }

    /// Resolution is I/O and lives in the executable; folding its result back in is
    /// what makes the registry, the capabilities and the loop agree about the model.
    @Test("Resolving with a provider replaces the model everything else reads")
    func resolvingSubstitutesTheModel() throws {
        let provider = Provider(
            kind: .ollama, model: "llama3.2",
            baseURL: URL(string: "http://localhost:11434/v1"), credentials: nil
        )
        let resolved = try parse("task").resolved(with: provider)

        #expect(resolved.model == "llama3.2")
        #expect(resolved.capabilities.vision == false)
        #expect(resolved.effectiveMaxTier == .accessibility)
        #expect(resolved.registry["screenshot"] == nil)
        #expect(resolved.loopConfiguration.model == "llama3.2")
    }

    @Test("An explicitly named model survives resolution")
    func explicitModelSurvives() throws {
        let provider = Provider(
            kind: .ollama, model: "llava:13b",
            baseURL: URL(string: "http://localhost:11434/v1"), credentials: nil
        )
        let resolved = try parse("--model", "llava:13b", "task").resolved(with: provider)
        #expect(resolved.registry["screenshot"] != nil, "a vision model keeps tier 3")
    }

    /// A ceiling accepted and then quietly lowered is the same failure as a flag
    /// accepted and then dropped: the run behaves differently and nothing said why.
    @Test("A run capped by the model says so")
    func cappedRunIsAnnounced() throws {
        var invocation = try parse("task")
        invocation.model = "llama3.3"
        let warning = try #require(invocation.cappedTierWarning)
        #expect(warning.contains("llama3.3"))
        #expect(warning.contains("tier 2"))
        #expect(warning.contains("ax_press"), "and what it will do instead")
    }

    /// Warning on every run is noise, and noise is how a real warning stops being read.
    @Test("A run that was not capped says nothing")
    func uncappedRunIsSilent() throws {
        #expect(try parse("task").cappedTierWarning == nil)
        #expect(try parse("--max-tier", "1", "task").cappedTierWarning == nil,
                "a ceiling the user chose is not a surprise")
    }
}

private extension Result where Failure == Invocation.ParseError {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

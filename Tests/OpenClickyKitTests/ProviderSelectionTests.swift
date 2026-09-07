import Testing
import Foundation
@testable import OpenClickyKit

/// The provider, model and planner the app writes and the CLI reads.
///
/// One store and one resolution order, so the two surfaces cannot end up talking to
/// different endpoints from one machine's configuration. Getting this wrong is silent
/// in the worst way: the request goes somewhere the user did not choose, signed by a
/// credential they did not pick, and the only symptom is an error about something else.
@Suite("Stored provider selection")
struct ProviderSelectionTests {

    private let noEnvironment: [String: String] = [:]

    private func scratch() -> ConfigFile {
        ConfigFile(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openclicky-\(UUID().uuidString)")
            .appendingPathComponent("config.json"))
    }

    private func configured(
        _ settings: ConfigFile.Settings, keys: [String: String] = [:]
    ) throws -> ConfigFile {
        let config = scratch()
        for (provider, key) in keys { try config.setKey(key, provider: provider) }
        try config.setSettings(settings)
        return config
    }

    private func clean(_ config: ConfigFile) {
        try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent())
    }

    // MARK: - The stored choice reaches a run

    @Test("A stored provider is used when no flag and no variable says otherwise")
    func storedProviderIsUsed() throws {
        let config = try configured(.init(provider: "ollama"))
        defer { clean(config) }

        let provider = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(provider.kind == .ollama)
        #expect(provider.model == "llama3.2", "the provider's own default, not Anthropic's")
    }

    @Test("A stored model and base URL are used")
    func storedModelAndBaseURLAreUsed() throws {
        let config = try configured(.init(
            provider: "ollama", model: "llava", baseURL: "http://localhost:9999/v1"
        ))
        defer { clean(config) }

        let provider = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(provider.model == "llava")
        #expect(provider.baseURL?.absoluteString == "http://localhost:9999/v1")
    }

    @Test("A stored planner is carried into the run")
    func storedPlannerIsUsed() throws {
        let config = try configured(.init(
            provider: "anthropic", model: DefaultModel.id, planner: "claude-opus-5"
        ), keys: ["anthropic": "sk-ant-test-123456789"])
        defer { clean(config) }

        let provider = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(provider.plannerModel == "claude-opus-5")

        // And all the way through to the loop's configuration, which is the only
        // place it does anything.
        guard case let .success(invocation) = Invocation.parse(["a task"]) else {
            Issue.record("could not parse")
            return
        }
        #expect(invocation.resolved(with: provider).loopConfiguration.planner?.model
                == "claude-opus-5")
    }

    /// A run header that named a planner the run does not use, or omitted one it does,
    /// is the same defect this codebase keeps finding: a sentence assembled from a
    /// value nobody read back.
    @Test("The summary names the planner when there is one")
    func summaryNamesThePlanner() throws {
        let config = try configured(.init(
            provider: "anthropic", planner: "claude-opus-5"
        ), keys: ["anthropic": "sk-ant-test-123456789"])
        defer { clean(config) }

        let planned = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(planned.summary.contains("planned by claude-opus-5"))

        let unplanned = try Provider.resolve(
            config: scratch(), environment: ["ANTHROPIC_API_KEY": "sk-ant-test-123456789"]
        )
        #expect(!unplanned.summary.contains("planned by"))
    }

    // MARK: - What must not be carried across

    /// The rule the whole shape of `Settings` exists for. A model id is meaningful
    /// only beside the endpoint that serves it: `llava` handed to Anthropic is a 404
    /// that reads as a broken install rather than as a stale setting.
    @Test("A stored model for one provider is never given to another")
    func storedModelDoesNotLeakAcrossProviders() throws {
        let config = try configured(
            .init(provider: "ollama", model: "llava",
                  baseURL: "http://localhost:9999/v1", planner: "llama3.2"),
            keys: ["anthropic": "sk-ant-test-123456789"]
        )
        defer { clean(config) }

        let provider = try Provider.resolve(
            config: config, kind: .anthropic, environment: noEnvironment
        )
        #expect(provider.model == DefaultModel.id)
        #expect(provider.plannerModel == nil)
        #expect(provider.baseURL == nil)
    }

    @Test("Settings that name no provider apply to whatever is in play")
    func providerlessSettingsApplyAnywhere() throws {
        // The user expressed an opinion about the model and none about the endpoint.
        let config = try configured(.init(model: "claude-opus-5"),
                                    keys: ["anthropic": "sk-ant-test-123456789"])
        defer { clean(config) }

        let provider = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(provider.model == "claude-opus-5")
    }

    // MARK: - Precedence

    @Test("A flag beats the stored choice")
    func flagBeatsStored() throws {
        let config = try configured(.init(provider: "ollama", model: "llava"))
        defer { clean(config) }

        let provider = try Provider.resolve(
            config: config, kind: .ollama, model: "qwen2.5vl", environment: noEnvironment
        )
        #expect(provider.model == "qwen2.5vl")
    }

    @Test("The environment beats the stored choice", arguments: [
        ("OPENCLICKY_PROVIDER", "groq"), ("OPENCLICKY_MODEL", "llama-3.3-70b-versatile"),
    ])
    func environmentBeatsStored(variable: (String, String)) throws {
        let config = try configured(.init(provider: "ollama", model: "llava"))
        defer { clean(config) }

        let provider = try Provider.resolve(
            config: config,
            environment: [variable.0: variable.1, "OPENCLICKY_API_KEY": "test-key-123"]
        )
        if variable.0 == "OPENCLICKY_PROVIDER" {
            #expect(provider.kind == .groq)
        } else {
            #expect(provider.model == "llama-3.3-70b-versatile")
        }
    }

    @Test("--planner beats a stored planner")
    func plannerFlagWins() throws {
        let config = try configured(.init(provider: "anthropic", planner: "claude-sonnet-5"),
                                    keys: ["anthropic": "sk-ant-test-123456789"])
        defer { clean(config) }

        let provider = try Provider.resolve(
            config: config, planner: "claude-opus-5", environment: noEnvironment
        )
        #expect(provider.plannerModel == "claude-opus-5")

        // And again through the invocation, where the two could disagree.
        guard case let .success(invocation) = Invocation.parse(["--planner", "claude-opus-5", "t"])
        else {
            Issue.record("could not parse")
            return
        }
        var stale = invocation
        stale.plannerModel = "claude-opus-5"
        let resolved = stale.resolved(with: Provider(
            kind: .anthropic, model: DefaultModel.id, baseURL: nil,
            credentials: .apiKey("sk-ant-test-123456789"), plannerModel: "claude-sonnet-5"
        ))
        #expect(resolved.plannerModel == "claude-opus-5")
    }

    @Test("A run with no planner anywhere stays unplanned")
    func nothingMeansUnplanned() throws {
        let config = scratch()
        defer { clean(config) }
        let provider = try Provider.resolve(
            config: config, environment: ["ANTHROPIC_API_KEY": "sk-ant-test-123456789"]
        )
        #expect(provider.plannerModel == nil)

        guard case let .success(invocation) = Invocation.parse(["a task"]) else {
            Issue.record("could not parse")
            return
        }
        #expect(invocation.resolved(with: provider).loopConfiguration.planner == nil)
    }

    /// A settings file this build cannot make sense of must not stop a run: it holds
    /// no credential, and refusing would leave `auth` unreachable to fix it.
    @Test("A provider name this build does not know is ignored, not fatal")
    func unknownStoredProviderFallsBack() throws {
        let config = scratch()
        defer { clean(config) }
        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"settings":{"provider":"gemini","model":"gemini-3"}}"#.utf8)
            .write(to: config.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: config.url.path
        )

        let provider = try Provider.resolve(
            config: config, environment: ["ANTHROPIC_API_KEY": "sk-ant-test-123456789"]
        )
        #expect(provider.kind == .anthropic)
        // The model went with the provider it belonged to, and was not adopted by
        // the fallback.
        #expect(provider.model == DefaultModel.id)
    }

    // MARK: - Switching provider in the picker

    @Test("Switching provider takes nothing across with it")
    func switchingResetsTheModel() {
        let ollama = ProviderSelection(
            kind: .ollama, model: "llava", planner: "llama3.2",
            baseURL: "http://localhost:9999/v1"
        )
        let anthropic = ollama.switching(to: .anthropic)

        #expect(anthropic.model == DefaultModel.id)
        #expect(anthropic.planner.isEmpty)
        #expect(anthropic.baseURL.isEmpty)
    }

    @Test("Switching to the provider already selected changes nothing")
    func switchingToTheSameKindIsInert() {
        // Otherwise a redraw that re-sets the picker would silently discard a model
        // the user had just typed.
        let selection = ProviderSelection(kind: .ollama, model: "qwen2.5vl")
        #expect(selection.switching(to: .ollama) == selection)
    }

    @Test("Anthropic never stores a base URL")
    func anthropicDropsTheBaseURL() {
        // Its endpoint is not configurable — it speaks the Messages API, not this
        // dialect — so a stored value would be a setting that appears to have taken
        // effect and never does.
        let selection = ProviderSelection(
            kind: .anthropic, model: DefaultModel.id, baseURL: "https://example.com"
        )
        #expect(selection.settings.baseURL == nil)
    }

    @Test("A stored selection round-trips through the file")
    func selectionRoundTrips() throws {
        let config = scratch()
        defer { clean(config) }
        let selection = ProviderSelection(
            kind: .openai, model: "gpt-4o", planner: "gpt-5",
            baseURL: "https://proxy.example.com/v1"
        )
        try config.setSettings(selection.settings)
        #expect(try ProviderSelection.stored(config.settings()) == selection)
    }

    @Test("An empty file selects Anthropic at its default model")
    func emptySettingsHaveADefault() {
        let selection = ProviderSelection.stored(ConfigFile.Settings())
        #expect(selection.kind == .anthropic)
        #expect(selection.model == DefaultModel.id)
        #expect(selection.planner.isEmpty)
    }

    /// The file records what the user chose. Writing a default back would freeze it:
    /// a config written today would keep pinning today's model after the built-in one
    /// moved on, without anyone having chosen that.
    @Test("A model nobody chose is filled in for display, not written back")
    func defaultsAreNotPersisted() throws {
        let config = scratch()
        defer { clean(config) }
        try config.setSettings(ConfigFile.Settings(provider: "anthropic"))
        #expect(try config.settings().model == nil)
        #expect(try ProviderSelection.stored(config.settings()).model == DefaultModel.id)
    }
}

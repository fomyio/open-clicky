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
        // OpenAI rather than Ollama, which no longer has a default to fall in: its ids
        // name what a particular machine has pulled. The claim under test is the same —
        // an unchosen model is the *stored provider's*, never Anthropic's.
        let config = try configured(.init(provider: "openai"),
                                    keys: ["openai": "sk-test-123456789"])
        defer { clean(config) }

        let provider = try Provider.resolve(config: config, environment: noEnvironment)
        #expect(provider.kind == .openai)
        #expect(provider.model == "gpt-4o", "the provider's own default, not Anthropic's")
    }

    /// The other half of that, for the provider that has none. A stored `ollama` with
    /// no model must not quietly borrow Anthropic's — nor invent one of its own.
    @Test("A stored provider with no default asks for a model")
    func storedOllamaWithoutAModelRefuses() throws {
        let config = try configured(.init(provider: "ollama"))
        defer { clean(config) }

        #expect(throws: Provider.Error.self) {
            _ = try Provider.resolve(config: config, environment: noEnvironment)
        }
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

    /// The same rule, from the other side — and the one the app actually exercises.
    ///
    /// `select(_:)` hands `switching(to:)`'s result straight to `setSettings`, so a
    /// materialised default written back would freeze it: one click on a provider tab
    /// and that provider's model is pinned forever at whatever the built-in default
    /// was that day, without anyone having chosen it.
    @Test("Switching provider does not pin that provider's default model")
    func switchingDoesNotPersistADefault() {
        let switched = ProviderSelection(kind: .anthropic).switching(to: .openai)
        #expect(switched.model == "gpt-4o", "shown, so the picker has something selected")
        #expect(switched.settings.model == nil, "but absent on disk, so it keeps tracking")
    }

    /// Switching to a provider with no default leaves the choice genuinely unmade,
    /// rather than filling in an id nobody has: Ollama serves what a machine pulled.
    @Test("Switching to a provider with no default chooses nothing")
    func switchingToOllamaChoosesNothing() {
        let switched = ProviderSelection(kind: .anthropic).switching(to: .ollama)
        #expect(switched.model.isEmpty)
        #expect(switched.settings.model == nil)
    }

    @Test("A model the user chose is written even when it matches today's default")
    func anExplicitNonDefaultIsPersisted() {
        // The distinction that matters: an id off the provider's default is a choice,
        // and must survive.
        let chosen = ProviderSelection(kind: .anthropic, model: "claude-opus-5")
        #expect(chosen.settings.model == "claude-opus-5")
    }

    /// A file whose keys are refused still has to say *why* to a passive reader.
    ///
    /// The settings panel resolved with `try?` and rendered the failure as "no key
    /// stored" — an unremarkable empty state, while the CLI refuses to use the file
    /// and says to rotate the key. The exposure went unmentioned in the one surface
    /// most likely to be looked at.
    @Test("An exposed file is reportable without trying to use the key")
    func permissionProblemIsAskableSeparately() throws {
        let config = scratch()
        defer { clean(config) }
        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        #expect(config.permissionProblem() == nil)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )
        guard let problem = config.permissionProblem() else {
            Issue.record("a world-readable key file reported no problem")
            return
        }
        #expect("\(problem)".contains("rotate it"), "it has to say what to do")
        #expect(throws: ConfigFile.Error.self) { _ = try config.keys() }
    }

    @Test("A file that does not exist is not a permission problem")
    func absentFileIsNotAProblem() {
        // The normal state before anyone runs `auth`. Reporting it as an exposure
        // would be the mirror of the bug above.
        #expect(scratch().permissionProblem() == nil)
    }

    /// Explicit, and therefore beats the environment, the stored choice and the
    /// provider's default — so an empty one reaches the endpoint as a request for a
    /// model called nothing, whose error names no cause.
    @Test("An empty --model or --planner is refused rather than treated as unset")
    func emptyModelIsRejected() {
        for arguments in [["--model", "", "task"], ["--planner", "", "task"]] {
            guard case let .failure(error) = Invocation.parse(arguments) else {
                Issue.record("\(arguments[0]) accepted an empty value")
                continue
            }
            #expect(error.message.contains("needs a model id"))
        }
    }
}

/// The picker's own state machine.
///
/// Every case here was reachable only through a `View` before, which is why the
/// escape hatch shipped broken: "is this a custom id" was derived from whether the
/// current value happened to be in the catalogue, so asking to type one changed
/// nothing and the field never appeared.
@Suite("Model picker")
struct ModelPickerTests {

    private var anthropic: [ModelChoice] { ModelCatalog.models(for: .anthropic) }

    @Test("Choosing Custom while a catalogued model is selected opens the field")
    func customIsReachableFromACataloguedValue() {
        // The bug, exactly: this is the common case, because every provider fills in
        // a real default.
        var picker = ModelPicker(value: DefaultModel.id, choices: anthropic, allowsNone: false)
        #expect(!picker.isCustom)

        picker.pick(ModelPicker.customTag)
        #expect(picker.isCustom, "asking to type an id must show the field")
        #expect(picker.tag == ModelPicker.customTag, "and the control must stay on Custom")
    }

    @Test("Moving to the field keeps what was there rather than clearing it")
    func customKeepsTheCurrentValue() {
        var picker = ModelPicker(value: DefaultModel.id, choices: anthropic, allowsNone: false)
        picker.pick(ModelPicker.customTag)
        #expect(picker.value == DefaultModel.id, "the field opens on the current id, ready to edit")
    }

    @Test("Moving to the field is not worth saving")
    func openingTheFieldDoesNotPersist() {
        // Nothing has changed yet, and a save here would write the value the user is
        // about to replace.
        var picker = ModelPicker(value: DefaultModel.id, choices: anthropic, allowsNone: false)
        let openedField = picker.pick(ModelPicker.customTag)
        #expect(openedField == false)
        let chose = picker.pick("claude-opus-5")
        #expect(chose, "an actual choice is")
    }

    @Test("A typed id survives matching the catalogue mid-word")
    func typingPastACatalogueMatchKeepsTheField() {
        // Derived state vanished the instant a prefix matched, taking the field with
        // it — mid-word, while someone was typing into it.
        var picker = ModelPicker(value: "", choices: anthropic, allowsNone: false)
        picker.pick(ModelPicker.customTag)
        picker.type("claude-opus-5")
        #expect(picker.isCustom, "the field must not close under the user")
        #expect(picker.value == "claude-opus-5")
    }

    @Test("Picking from the list again leaves the field")
    func pickingFromTheListClosesTheField() {
        var picker = ModelPicker(value: "some-private-build", choices: anthropic, allowsNone: false)
        #expect(picker.isCustom, "a stored id the catalogue does not list is custom")
        picker.pick("claude-opus-5")
        #expect(!picker.isCustom)
        #expect(picker.tag == "claude-opus-5")
    }

    @Test("A provider with no catalogue is always the text field")
    func emptyCatalogueIsAlwaysCustom() {
        // LiteLLM routes by names its own configuration defines; the field is the only
        // way to say anything at all.
        let picker = ModelPicker(
            value: "", choices: ModelCatalog.models(for: .litellm), allowsNone: false
        )
        #expect(picker.isCustom)
    }

    @Test("None is a choice the planner can make")
    func noneIsSelectable() {
        var picker = ModelPicker(value: "claude-opus-5", choices: anthropic, allowsNone: true)
        let chose = picker.pick(ModelPicker.noneTag)
        #expect(chose)
        #expect(picker.value.isEmpty)
        #expect(!picker.isCustom, "off is not a custom id")
    }

    @Test("The custom entry names what is in the field")
    func customLabelNamesTheValue() {
        var picker = ModelPicker(value: DefaultModel.id, choices: anthropic, allowsNone: false)
        #expect(picker.customLabel == "Custom…")
        picker.pick(ModelPicker.customTag)
        #expect(picker.customLabel == "Custom: \(DefaultModel.id)")
    }
}

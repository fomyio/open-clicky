import Testing
import Foundation
@testable import OpenClickyKit

/// `thinking: {type: "adaptive"}` and `output_config.effort` are rejected with a 400 by
/// families older than Claude 4.6 — not ignored. A request shaped for the wrong model
/// therefore fails every single turn, and the error names the field rather than the
/// model, so it reads like a broken key. These tests exist because the encoder used to
/// send adaptive thinking unconditionally, which was only ever correct by virtue of the
/// default model happening to be Opus 5.
@Suite("Model capabilities shape the request")
struct ModelCapabilityTests {

    private func encoded(model: String, effort: String? = "high") throws -> JSONValue {
        let request = Wire.Request(
            model: model, maxTokens: 1_000, system: [.init("s")],
            messages: [.user("hi")], tools: [], effort: effort
        )
        return try JSONDecoder().decode(
            JSONValue.self, from: try Wire.encoder.encode(request)
        )
    }

    @Test("Pre-4.6 families accept neither field")
    func haikuAcceptsNeither() {
        let capabilities = ModelCapabilities.forModel("claude-haiku-4-5-20251001")
        #expect(capabilities.adaptiveThinking == false)
        #expect(capabilities.effort == false)
    }

    @Test("4.6+ families accept both")
    func modernFamiliesAcceptBoth() {
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-6-20260514"] {
            let capabilities = ModelCapabilities.forModel(model)
            #expect(capabilities.adaptiveThinking, "\(model) should support adaptive thinking")
            #expect(capabilities.effort, "\(model) should support effort")
        }
    }

    /// Omitting the fields is valid on every model; sending them where they are not
    /// understood is a hard failure. So a guess has to err towards off.
    @Test("An unknown model gets the conservative shape")
    func unknownModelOmitsBoth() {
        let capabilities = ModelCapabilities.forModel("some-future-model")
        #expect(capabilities.adaptiveThinking == false)
        #expect(capabilities.effort == false)
    }

    @Test("A Haiku request carries no thinking and no output_config")
    func haikuRequestOmitsBothFields() throws {
        let payload = try encoded(model: "claude-haiku-4-5-20251001")
        #expect(payload["thinking"] == nil, "adaptive thinking would 400 on this family")
        #expect(payload["output_config"] == nil, "effort would 400 on this family")
    }

    @Test("An Opus 5 request still carries both")
    func opusRequestKeepsBothFields() throws {
        let payload = try encoded(model: "claude-opus-5")
        #expect(payload["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(payload["output_config"]?["effort"]?.stringValue == "high")
    }

    /// The desync this gate is built to prevent, exercised directly.
    ///
    /// `capabilities` used to be captured at init, so reassigning `model` left the two
    /// disagreeing and the encoder shaped the request for the *previous* model — the
    /// exact failure the gate exists to stop, reintroduced silently. It is derived on
    /// every read now, and this asserts the derivation rather than the intent.
    @Test("Reassigning the model reshapes the request")
    func mutatingTheModelUpdatesTheShape() throws {
        var request = Wire.Request(
            model: "claude-opus-5", maxTokens: 1_000, system: [.init("s")],
            messages: [.user("hi")], tools: [], effort: "high"
        )
        let asOpus = try JSONDecoder().decode(
            JSONValue.self, from: try Wire.encoder.encode(request)
        )
        #expect(asOpus["thinking"] != nil, "Opus 5 should carry adaptive thinking")

        request.model = "claude-haiku-4-5-20251001"
        let asHaiku = try JSONDecoder().decode(
            JSONValue.self, from: try Wire.encoder.encode(request)
        )
        #expect(asHaiku["thinking"] == nil, "the reshaped request must drop thinking")
        #expect(asHaiku["output_config"] == nil, "and drop effort")
    }

    /// The guarantee that actually matters: whatever the default is, the request the
    /// agent builds for it must be one that model accepts. Pinning only the constant
    /// would let the default move to a family the encoder still shapes wrongly.
    @Test("The default model produces a request the default model accepts")
    func defaultModelIsSelfConsistent() throws {
        let payload = try encoded(model: DefaultModel.id)
        let capabilities = ModelCapabilities.forModel(DefaultModel.id)
        #expect((payload["thinking"] != nil) == capabilities.adaptiveThinking)
        #expect((payload["output_config"] != nil) == capabilities.effort)
    }

    // MARK: - What the model can be trusted to drive

    /// Tier 3 is predicting a coordinate from a picture. Handed to a model that
    /// cannot see the picture it does not produce a refusal — local runtimes
    /// routinely drop the image and answer from the prompt alone — it produces a
    /// confident coordinate for a screen the model never saw.
    @Test("A model that cannot see is capped below the pixel tier", arguments: [
        "llama3.3", "llama-3.3-70b-versatile", "qwen2.5-coder", "mistral",
        "gpt-3.5-turbo", "some-future-model",
    ])
    func textOnlyModelsAreCappedAtTierTwo(model: String) {
        let capabilities = ModelCapabilities.forModel(model)
        #expect(capabilities.vision == false)
        #expect(capabilities.maxTier == .accessibility, "\(model) was offered the pixel tier")
        #expect(capabilities.prefersElementIDs)
    }

    @Test("A model that can see keeps the pixel tier", arguments: [
        "claude-haiku-4-5-20251001", "claude-opus-5", "gpt-4o", "gpt-4.1-mini",
        "llava:13b", "llama3.2-vision:11b",
    ])
    func visionModelsKeepTierThree(model: String) {
        let capabilities = ModelCapabilities.forModel(model)
        #expect(capabilities.vision)
        #expect(capabilities.maxTier == .pixels, "\(model) lost the pixel tier")
    }

    /// The ceiling is a floor as well as a cap: `--max-tier` may lower it further,
    /// but nothing raises it, because the limit is what the model can do rather than
    /// what the user is willing to allow.
    @Test("The effective ceiling is the lower of the two", arguments: [
        ("claude-opus-5", Tier.pixels, Tier.pixels),
        ("claude-opus-5", .script, .script),
        ("llama3.3", .pixels, .accessibility),
        ("llama3.3", .shell, .shell),
    ])
    func effectiveCeilingIsTheLower(scenario: (String, Tier, Tier)) {
        var invocation = Invocation()
        invocation.model = scenario.0
        invocation.maxTier = scenario.1
        #expect(invocation.effectiveMaxTier == scenario.2)
        #expect(invocation.registry.ordered.allSatisfy { $0.tier <= scenario.2 })
    }

    /// A cheap model must not merely be discouraged from clicking. The prompt is
    /// advice; an absent tool is a fact.
    @Test("A text-only model is not handed the pixel tools at all")
    func textOnlyModelHasNoPixelTools() {
        var invocation = Invocation()
        invocation.model = "llama3.3"
        for absent in ["screenshot", "zoom", "click", "drag", "type", "key", "scroll", "wait"] {
            #expect(invocation.registry[absent] == nil, "\(absent) is still reachable")
        }
        #expect(invocation.registry["ax_press"] != nil, "the grounded path must remain")
    }

    // MARK: - Model ids as they arrive

    /// LiteLLM routes by `openai/gpt-4o`, Ollama tags by `llava:13b`. Matching the
    /// raw string meant a working configuration was silently demoted to tier 2 by a
    /// prefix the user did not choose and could not remove.
    @Test("A proxied or tagged id is recognised as its family", arguments: [
        "openai/gpt-4o", "ollama/llava", "llava:13b", "anthropic/claude-opus-5",
        "OpenAI/GPT-4o",
    ])
    func decoratedIdsResolveToTheirFamily(model: String) {
        #expect(ModelCapabilities.forModel(model).vision, "\(model) lost its eyes")
    }

    /// The reasoning families renamed both the system role and the output cap, and
    /// each rename is a 400 rather than a degraded answer.
    @Test("The request keys follow the family", arguments: [
        ("gpt-4o", "system", "max_tokens"),
        ("gpt-5", "developer", "max_completion_tokens"),
        ("o3-mini", "developer", "max_completion_tokens"),
        ("llama3.2", "system", "max_tokens"),
    ])
    func requestKeysFollowTheFamily(scenario: (String, String, String)) {
        let capabilities = ModelCapabilities.forModel(scenario.0)
        #expect(capabilities.systemRole == scenario.1)
        #expect(capabilities.outputTokenField == scenario.2)
    }

    /// The whole point of the extension: the same question — what does this model
    /// accept — answered in one type rather than two that can disagree.
    @Test("Claude's answers are unchanged by the widening")
    func claudeIsUnchanged() {
        let haiku = ModelCapabilities.forModel(DefaultModel.id)
        #expect(haiku.adaptiveThinking == false)
        #expect(haiku.effort == false)
        #expect(haiku.vision)
        #expect(haiku.imageSpace == .anthropic)
        #expect(haiku.maxTier == .pixels)

        let opus = ModelCapabilities.forModel("claude-opus-5")
        #expect(opus.adaptiveThinking)
        #expect(opus.effort)
        #expect(opus.imageSpace == .anthropic)
    }
}

/// A flag that parses, then vanishes before the request is sent, is worse than one
/// that is rejected: the run proceeds, costs the same, and gives the user no reason
/// to doubt that what they asked for happened.
@Suite("Silently dropped flags are announced")
struct IgnoredFlagTests {

    private func parse(_ arguments: [String]) throws -> Invocation {
        guard case let .success(invocation) = Invocation.parse(arguments) else {
            throw ParseFailure()
        }
        return invocation
    }
    private struct ParseFailure: Error {}

    @Test("Explicit effort against a pre-4.6 model is reported")
    func explicitEffortOnHaikuWarns() throws {
        let invocation = try parse(["--effort", "max", "--model", "claude-haiku-4-5-20251001", "t"])
        let warning = try #require(invocation.ignoredFlagWarning)
        #expect(warning.contains("--effort max"), "it must name the flag that was dropped")
        #expect(warning.contains("claude-haiku-4-5-20251001"), "and the model that dropped it")
        #expect(warning.contains("claude-opus-5"), "and what to do instead")
    }

    /// The default is dropped on Haiku too, but nobody asked for it — warning on every
    /// run would be noise, and noise is how a real warning stops being read.
    @Test("The default effort is dropped silently")
    func defaultEffortDoesNotWarn() throws {
        let invocation = try parse(["a task"])
        #expect(invocation.model == DefaultModel.id)
        #expect(invocation.effortIsExplicit == false)
        #expect(invocation.ignoredFlagWarning == nil)
    }

    @Test("Explicit effort against a 4.6+ model is not reported")
    func explicitEffortOnOpusIsSilent() throws {
        let invocation = try parse(["--effort", "max", "--model", "claude-opus-5", "t"])
        #expect(invocation.effortIsExplicit)
        #expect(invocation.ignoredFlagWarning == nil, "the flag reaches the API here")
    }

    /// The warning must describe the request that is actually sent, not the flag in
    /// isolation — the two are only connected through `ModelCapabilities`.
    @Test("The warning agrees with what the encoder does", arguments: [
        "claude-haiku-4-5-20251001", "claude-opus-5", "some-future-model",
    ])
    func warningMatchesTheEncodedRequest(model: String) throws {
        let invocation = try parse(["--effort", "max", "--model", model, "a task"])
        let request = Wire.Request(
            model: model, maxTokens: 1_000, system: [.init("s")],
            messages: [.user("hi")], tools: [], effort: invocation.effort
        )
        let payload = try JSONDecoder().decode(
            JSONValue.self, from: try Wire.encoder.encode(request)
        )
        let wasDropped = payload["output_config"] == nil
        #expect(wasDropped == (invocation.ignoredFlagWarning != nil),
                "\(model): warned=\(invocation.ignoredFlagWarning != nil) dropped=\(wasDropped)")
    }
}

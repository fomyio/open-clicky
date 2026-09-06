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

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

import Testing
import Foundation
@testable import OpenClickyKit

/// What the picker offers, and whether its promises survive contact with the registry.
///
/// A catalogue that says "vision" beside a model the registry then refuses to give the
/// pixel tools to is worse than no catalogue: the user picks it *because* the label
/// said it could see, and the run never takes a screenshot.
@Suite("Model catalogue")
struct ModelCatalogTests {

    @Test("Every offered model resolves to a usable capability set",
          arguments: Provider.Kind.allCases)
    func offeredModelsHaveCapabilities(kind: Provider.Kind) {
        for choice in ModelCatalog.models(for: kind) {
            #expect(!choice.id.isEmpty)
            #expect(!choice.label.isEmpty)
            // The tier ceiling follows from vision, and nothing else may decide it.
            #expect(choice.maxTier == (choice.vision ? .pixels : .accessibility))
        }
    }

    /// The one claim the picker makes that a run can contradict.
    @Test("A model labelled vision actually keeps the pixel tools",
          arguments: Provider.Kind.allCases)
    func visionLabelMatchesTheRegistry(kind: Provider.Kind) throws {
        for choice in ModelCatalog.models(for: kind) {
            var invocation = Invocation()
            invocation.model = choice.id
            let registry = invocation.registry
            if choice.vision {
                #expect(registry["screenshot"] != nil,
                        "\(choice.id) is offered as a vision model and has no screenshot tool")
                #expect(registry["click"] != nil, "\(choice.id)")
            } else {
                #expect(registry["screenshot"] == nil,
                        "\(choice.id) cannot see and must not be offered the pixel tools")
                // And it keeps the tier it can actually drive, rather than nothing.
                #expect(registry["ax_capture"] != nil, "\(choice.id)")
            }
        }
    }

    /// A picker's job is to make the good choice reachable. A provider whose entire
    /// list is text-only would quietly cap every run it offers at tier 2.
    @Test("Each provider that can see the screen offers a way to", arguments: [
        Provider.Kind.anthropic, .openai, .ollama, .groq,
    ])
    func everyProviderOffersAVisionModel(kind: Provider.Kind) {
        let hasVisionModel = ModelCatalog.models(for: kind).contains { $0.vision }
        #expect(hasVisionModel, "\(kind.label)")
    }

    /// LiteLLM routes by names its own configuration defines, so every guess is a 404
    /// that reads as "the proxy is broken". An empty list is the honest answer, and the
    /// UI falls back to a text field.
    @Test("LiteLLM is offered nothing to guess at")
    func litellmHasNoCatalog() {
        #expect(ModelCatalog.models(for: .litellm).isEmpty)
    }

    @Test("A provider's default model is one the picker can show", arguments: [
        Provider.Kind.anthropic, .openai, .ollama, .groq,
    ])
    func defaultsAreInTheCatalog(kind: Provider.Kind) {
        // Otherwise the picker opens on "Custom…" for a machine nobody has configured,
        // which reads as a setting the user made.
        guard let fallback = kind.defaultModel else { return }
        #expect(ModelCatalog.models(for: kind).contains { $0.id == fallback }, "\(kind.label)")
    }

    @Test("A planner is offered only models its own provider serves",
          arguments: Provider.Kind.allCases)
    func plannersComeFromTheSameProvider(kind: Provider.Kind) {
        // The planner runs on the same client with the same credential: one from
        // another provider is a model id this endpoint has never heard of, which is
        // exactly how `--provider ollama --planner claude-opus-5` fails.
        let executors = Set(ModelCatalog.models(for: kind).map(\.id))
        for planner in ModelCatalog.planners(for: kind) {
            #expect(executors.contains(planner.id), "\(planner.id) is not served by \(kind.label)")
        }
    }

    @Test("Planning with the executor's own model is cautioned")
    func selfPlanningIsCautioned() {
        // It costs an extra round-trip and adds no judgement the run would not already
        // have — the one way to pay for planning and receive nothing.
        let caution = ModelCatalog.plannerCaution(
            planner: "claude-opus-5", executor: "claude-opus-5"
        )
        #expect(caution?.contains("same model") == true)
    }

    @Test("A different planner, or none, draws no caution")
    func sensiblePairingsAreQuiet() {
        #expect(ModelCatalog.plannerCaution(planner: "claude-opus-5", executor: DefaultModel.id) == nil)
        #expect(ModelCatalog.plannerCaution(planner: "", executor: DefaultModel.id) == nil)
        #expect(ModelCatalog.plannerCaution(planner: "   ", executor: DefaultModel.id) == nil)
    }

    /// The sentence a settings panel shows. Both halves have to be true of the run
    /// that follows, or it is the confident-and-wrong message this codebase keeps
    /// hunting down.
    @Test("The capability sentence matches the ceiling it describes")
    func capabilitySummaryIsAccurate() {
        let seeing = ModelChoice(id: "claude-opus-5")
        #expect(seeing.capabilitySummary.contains("0–3"))
        #expect(seeing.vision)

        let blind = ModelChoice(id: "llama3.2")
        #expect(blind.capabilitySummary.contains("0–2"))
        #expect(blind.capabilitySummary.contains("accessibility"))
        #expect(!blind.vision)
    }

    /// LiteLLM and Ollama decorate ids on the way through. Matching the raw string
    /// meant `openai/gpt-4o` fell through to the unknown branch and lost its eyes.
    @Test("A decorated id keeps the capabilities of its family", arguments: [
        "openai/gpt-4o", "ollama/llava", "llava:13b",
        "meta-llama/llama-4-scout-17b-16e-instruct",
    ])
    func decoratedIdsKeepVision(id: String) {
        #expect(ModelChoice(id: id).vision, "\(id) lost its eyes to a prefix")
    }
}

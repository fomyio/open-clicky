import Testing
import Foundation
@testable import OpenClickyKit

/// The planner's output budget, and what it says when the budget is the problem.
///
/// Written against a configuration that could never work. `Planner.maxTokens` was 1,000
/// — a budget sized for a model that starts writing immediately. A reasoning model does
/// not: it spends output tokens on reasoning first, and the cap covers both. Measured
/// against the real planner prompt with `gpt-5` at its default effort, a 1,000-token cap
/// produced 1,000 reasoning tokens, `finish_reason: length`, and **zero characters** of
/// plan. The run took 24 seconds, billed a thousand tokens, and reported "the planning
/// model returned no text" — true, and useless.
@Suite("Planner budget")
struct PlannerBudgetTests {

    /// The cap is a ceiling, not a spend. That is what makes raising it the right fix
    /// rather than a trade: a model that does not reason draws nothing extra from it —
    /// `gpt-4.1` used 67 tokens against the old 1,000 cap and uses 67 against this one.
    /// Only a model that needs the room touches it.
    @Test("The default budget leaves a reasoning model room to think and then answer")
    func defaultBudgetFitsAReasoningModel() {
        // Above the worst measured reasoning spend on this prompt (1,536), with room
        // for the plan itself afterwards.
        #expect(Planner.defaultMaxTokens >= 2_000)
        #expect(Planner(model: "gpt-5").maxTokens == Planner.defaultMaxTokens)
    }

    /// The two empty-answer cases need opposite responses, and one message served both.
    /// A model that hit the cap is working — it answered, it was billed, and a bigger
    /// budget or a lighter effort fixes it. Telling someone to raise a limit when the
    /// model simply had nothing to say sends them to the one thing that cannot help.
    @Test("Exhausting the budget is reported as exhausting the budget")
    func budgetExhaustionIsNamed() {
        let hitCap = Planner.emptyReason(stopReason: "max_tokens", model: "gpt-5")
        #expect(hitCap.contains("gpt-5"))
        #expect(hitCap.contains("budget"))
        // The remedy, both halves of it.
        #expect(hitCap.lowercased().contains("raise"))
        #expect(hitCap.lowercased().contains("reasons less"))
    }

    @Test("A model that simply said nothing is not blamed on the budget")
    func ordinaryEmptinessIsNotMisdiagnosed() {
        for stop in ["end_turn", "stop", nil] {
            let reason = Planner.emptyReason(stopReason: stop, model: "gpt-5")
            #expect(reason == "the planning model returned no text")
            #expect(!reason.contains("budget"))
        }
    }

    /// `finish_reason: "length"` is what OpenAI sends; the wire layer translates it.
    /// If that mapping ever changes, the diagnosis above silently reverts to the
    /// unhelpful message — so the two are pinned to each other here rather than left to
    /// agree by coincidence.
    @Test("The diagnosis is keyed to the stop reason the wire layer actually produces")
    func stopReasonMatchesTheWireTranslation() {
        let translated = OpenAIWire.stopReason(
            finishReason: "length", hasToolCalls: false, refusal: nil
        )
        #expect(translated == "max_tokens")
        #expect(Planner.emptyReason(stopReason: translated, model: "m")
            != "the planning model returned no text")
    }
}

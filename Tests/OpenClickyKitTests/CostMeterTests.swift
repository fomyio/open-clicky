import Testing
import Foundation
@testable import OpenClickyKit

@Suite("Cost accounting")
struct CostMeterTests {

    private func usage(
        input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> Wire.Usage {
        let json = """
        {"input_tokens":\(input),"output_tokens":\(output),
         "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}
        """
        return try! JSONDecoder().decode(Wire.Usage.self, from: Data(json.utf8))
    }

    @Test("Opus 5 tokens are priced at the published rates")
    func pricesOpusCorrectly() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 1_000_000, output: 1_000_000))
        // $5/MTok in + $25/MTok out.
        #expect(abs(meter.totalCost - 30.0) < 0.001)
    }

    @Test("Model tiers are priced separately")
    func pricesByTier() {
        #expect(Pricing.forModel("claude-sonnet-5").inputPerMillion == 2.00)
        #expect(Pricing.forModel("claude-haiku-4-5").inputPerMillion == 1.00)
        #expect(Pricing.forModel("claude-fable-5-1").outputPerMillion == 50.00)
        #expect(Pricing.forModel("claude-opus-5").outputPerMillion == 25.00)
    }

    /// Erring high is the safe direction: telling the user a run was cheaper than
    /// it was is worse than the reverse.
    @Test("An unknown model is priced at the Opus tier rather than free")
    func unknownModelErrsHigh() {
        let pricing = Pricing.forModel("claude-something-unreleased")
        #expect(pricing.inputPerMillion == 5.00)
    }

    @Test("Cache reads bill at a tenth of the input rate")
    func cacheReadsAreCheaper() {
        var cached = CostMeter(model: "claude-opus-5")
        cached.record(usage(input: 0, output: 0, cacheRead: 1_000_000))

        var uncached = CostMeter(model: "claude-opus-5")
        uncached.record(usage(input: 1_000_000, output: 0))

        #expect(abs(cached.totalCost - 0.50) < 0.001)
        #expect(abs(uncached.totalCost - 5.00) < 0.001)
    }

    @Test("Usage accumulates across turns")
    func accumulates() {
        var meter = CostMeter(model: "claude-opus-5")
        for _ in 0..<4 { meter.record(usage(input: 1_000, output: 200, cacheRead: 5_000)) }
        #expect(meter.turns == 4)
        #expect(meter.inputTokens == 4_000)
        #expect(meter.outputTokens == 800)
        #expect(meter.cacheReadTokens == 20_000)
    }

    /// A near-zero hit rate over several turns means something volatile leaked into
    /// the cached prefix, so the metric needs to be trustworthy.
    @Test("Cache hit rate reflects the share of input served from cache")
    func computesCacheHitRate() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 200, output: 50, cacheRead: 1_800))
        #expect(abs(meter.cacheHitRate - 0.9) < 0.01)

        var cold = CostMeter(model: "claude-opus-5")
        cold.record(usage(input: 2_000, output: 50))
        #expect(cold.cacheHitRate == 0)
    }

    @Test("An empty meter reports zero rather than dividing by zero")
    func handlesEmptyMeter() {
        let meter = CostMeter(model: "claude-opus-5")
        #expect(meter.cacheHitRate == 0)
        #expect(meter.totalCost == 0)
        #expect(meter.savedByCaching == 0)
    }

    @Test("Caching savings are reported against the uncached price")
    func reportsSavings() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 100, output: 100, cacheRead: 100_000))
        #expect(meter.savedByCaching > 0)
        #expect(meter.totalCost < meter.costWithoutCaching)
    }

    /// A ladder-first task costs a fraction of a cent, which two decimal places
    /// would render as "$0.00".
    @Test("Sub-cent amounts keep their precision")
    func formatsSmallAmounts() {
        #expect(CostMeter.format(0.0023) == "$0.0023")
        #expect(CostMeter.format(0.15) == "$0.150")
        #expect(CostMeter.format(2.5) == "$2.50")
    }

    /// The ladder's justification, quantified: the same task answered by shell
    /// versus by repeated screenshots.
    @Test("The ladder's saving is measurable")
    func ladderSavingIsMeasurable() {
        var shellPath = CostMeter(model: "claude-opus-5")
        shellPath.record(usage(input: 1_200, output: 150, cacheRead: 3_000))

        var screenshotPath = CostMeter(model: "claude-opus-5")
        // Six screenshots, each ~1,500 vision tokens, resent as context grows.
        for turn in 1...6 {
            screenshotPath.record(usage(input: 1_500 * turn, output: 150, cacheRead: 3_000))
        }

        #expect(screenshotPath.totalCost > shellPath.totalCost * 10,
                "escalating to pixels should be an order of magnitude dearer")
    }

    // MARK: - Planning

    // A `--planner claude-opus-5` run in front of a Haiku executor spends most of its
    // money on the planner. Costing those tokens with the executor's pricing, or not
    // costing them at all, understates the bill by the larger half.

    @Test("Planning is priced at the planning model's rate, not the executor's")
    func pricesPlanningSeparately() {
        var meter = CostMeter(model: "claude-haiku-4-5")
        meter.recordPlanning(usage(input: 1_000_000, output: 1_000_000), model: "claude-opus-5")
        // Opus: $5 in + $25 out. Haiku's $1/$5 would have said $6.
        #expect(abs(meter.planningCost - 30.0) < 0.001)
        #expect(abs(meter.totalCost - 30.0) < 0.001)
        #expect(meter.executionCost == 0)
    }

    @Test("The total is execution plus planning")
    func totalIncludesPlanning() {
        var meter = CostMeter(model: "claude-haiku-4-5")
        meter.record(usage(input: 1_000_000, output: 1_000_000))          // $1 + $5
        meter.recordPlanning(usage(input: 1_000_000, output: 0), model: "claude-opus-5") // $5
        #expect(abs(meter.executionCost - 6.0) < 0.001)
        #expect(abs(meter.planningCost - 5.0) < 0.001)
        #expect(abs(meter.totalCost - 11.0) < 0.001)
    }

    @Test("Planning does not drag down the cache hit rate")
    func planningIsOutsideTheCacheRate() {
        // The planner is one call with its own prompt and nothing to read from cache.
        // Counting it would depress the rate and trip the "the cached prefix is being
        // invalidated each turn" warning on a run where nothing of the sort happened.
        var meter = CostMeter(model: "claude-haiku-4-5")
        meter.record(usage(input: 100, output: 10, cacheRead: 900))
        let before = meter.cacheHitRate
        meter.recordPlanning(usage(input: 5_000, output: 200), model: "claude-opus-5")
        #expect(meter.cacheHitRate == before)
        #expect(meter.cacheHitRate == 0.9)
    }

    @Test("Caching savings are measured against execution, not the total")
    func savingsIgnorePlanning() {
        // `costWithoutCaching` counts the executor's tokens only. Measured against a
        // total that includes planning it reports a smaller saving than caching made —
        // and with a cheap executor under an expensive planner, none at all.
        var meter = CostMeter(model: "claude-haiku-4-5")
        meter.record(usage(input: 100, output: 10, cacheRead: 900_000))
        let savedBefore = meter.savedByCaching
        #expect(savedBefore > 0)
        meter.recordPlanning(usage(input: 1_000_000, output: 1_000_000), model: "claude-opus-5")
        #expect(meter.savedByCaching == savedBefore)
    }

    @Test("The summary attributes the extra spend to planning")
    func summaryNamesPlanning() {
        var meter = CostMeter(model: "claude-haiku-4-5")
        meter.record(usage(input: 1_000, output: 100))
        #expect(!meter.summary.contains("planning"))
        meter.recordPlanning(usage(input: 100_000, output: 1_000), model: "claude-opus-5")
        // Attributable, rather than just a bigger number than the same task cost
        // yesterday.
        #expect(meter.summary.contains("planning"))
    }


    // MARK: - Runs nobody bills

    // A live run against a local `deepseek-r1:7b` reported $0.014, because
    // `Pricing.forModel` falls back to the Opus tier for an unrecognised id. Erring
    // high is right for an unknown Anthropic model; for one served from this machine
    // it is an invented number, which is the same class of defect as an invented
    // success.

    @Test("A local run reports no price rather than a small one")
    func localRunIsNotBilled() {
        var meter = CostMeter(model: "deepseek-r1:7b", pricing: .unbilled)
        meter.record(usage(input: 655, output: 489))
        #expect(!meter.isBilled)
        #expect(meter.totalCost == 0)
        // Not "$0.0000": a currency figure is a claim about money, and reads as "very
        // cheap" rather than "nobody charged for this".
        #expect(meter.summary.contains("not billed"))
        #expect(!meter.summary.contains("$"))
    }

    @Test("An unpriced model still errs high when it is billed")
    func unknownBilledModelStillErrsHigh() {
        // The fallback stays: an unrecognised id reaching a paid endpoint should
        // over-estimate rather than under-estimate.
        var meter = CostMeter(model: "some-unreleased-model")
        meter.record(usage(input: 1_000_000, output: 0))
        #expect(meter.isBilled)
        #expect(abs(meter.totalCost - 5.0) < 0.001)
        #expect(meter.summary.contains("$"))
    }

    @Test("An unbilled run reports no planning cost or caching saving either")
    func unbilledRunSuppressesEveryMoneyFigure() {
        var meter = CostMeter(model: "deepseek-r1:7b", pricing: .unbilled)
        meter.record(usage(input: 100, output: 10, cacheRead: 900_000))
        meter.recordPlanning(usage(input: 1_000, output: 100), model: "claude-opus-5")
        #expect(!meter.summary.contains("planning"))
        #expect(!meter.summary.contains("saved"))
        #expect(!meter.summary.contains("$"))
    }

}

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
}

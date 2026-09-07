import Foundation

/// Per-million-token prices for a model.
public struct Pricing: Sendable, Equatable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    /// Cache reads bill at a fraction of the input rate — the reason the stable
    /// system prefix and tool block carry breakpoints.
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(
        inputPerMillion: Double, outputPerMillion: Double,
        cacheReadPerMillion: Double, cacheWritePerMillion: Double
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }

    /// A model served from this machine. Nothing is billed, and no rate applies.
    ///
    /// Distinct from a rate that happens to be zero: `CostMeter` reports "not billed"
    /// rather than "$0.0000", because a currency figure is a claim about money and
    /// there was no transaction to make one about.
    public static let unbilled = Pricing(
        inputPerMillion: 0, outputPerMillion: 0,
        cacheReadPerMillion: 0, cacheWritePerMillion: 0
    )

    /// Published rates as of 2026-09. Cache reads are 10% of the input rate and
    /// cache writes 125%, the standard multipliers.
    public static func forModel(_ model: String) -> Pricing {
        let base: (input: Double, output: Double)
        switch model {
        case let m where m.hasPrefix("claude-opus-5"), let m where m.hasPrefix("claude-opus-4"):
            base = (5.00, 25.00)
        case let m where m.hasPrefix("claude-fable-5"), let m where m.hasPrefix("claude-mythos-5"):
            base = (10.00, 50.00)
        case let m where m.hasPrefix("claude-sonnet-5"):
            base = (2.00, 10.00)
        case let m where m.hasPrefix("claude-sonnet-4"):
            base = (3.00, 15.00)
        case let m where m.hasPrefix("claude-haiku"):
            base = (1.00, 5.00)
        default:
            // Unknown model: assume the Opus tier so an estimate errs high rather
            // than telling the user a task was cheaper than it was.
            base = (5.00, 25.00)
        }
        return Pricing(
            inputPerMillion: base.input,
            outputPerMillion: base.output,
            cacheReadPerMillion: base.input * 0.10,
            cacheWritePerMillion: base.input * 1.25
        )
    }
}

/// Accumulates token usage across a session and prices it.
///
/// Cost is the ladder's whole justification, so it should be visible rather than
/// inferred: a task answered by `shell` and one answered by six screenshots differ
/// by two orders of magnitude, and only a running total makes that legible.
public struct CostMeter: Sendable, Equatable {
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var cacheReadTokens = 0
    public private(set) var cacheWriteTokens = 0
    public private(set) var turns = 0
    public let pricing: Pricing

    /// What the planning model cost, kept apart from the executor's tally.
    ///
    /// Separate rather than summed in, for two reasons. The planner runs on a
    /// different model at a different price, so its tokens cannot be costed with the
    /// executor's `pricing` — and a `--planner claude-opus-5` run reporting only its
    /// Haiku executor's spend understates the bill by most of it, which is the
    /// expensive half being invisible. It is also a separate *decision*: the number a
    /// user needs in order to judge whether planning earned its price is the planning
    /// price on its own, not folded into a total.
    ///
    /// Excluded from `cacheHitRate` deliberately. The planner is one call with its own
    /// prompt and nothing to read from cache, so counting it would drag the rate down
    /// and trip the "the cached prefix is being invalidated" warning on a run where
    /// nothing of the sort happened.
    public private(set) var planningCost: Double = 0
    public private(set) var planningTokens = 0

    /// Whether anyone is charging for these tokens.
    ///
    /// A live run against a local `deepseek-r1:7b` reported **$0.014**, because
    /// `Pricing.forModel` falls back to the Opus tier for an unrecognised id. That
    /// default is deliberate and right for an unknown *Anthropic* model, where erring
    /// high beats telling someone a task was cheaper than it was. For a model served
    /// from this machine it is a fabricated number, and inventing money is the same
    /// class of defect as inventing a success.
    public let isBilled: Bool

    public init(model: String, pricing: Pricing? = nil) {
        self.pricing = pricing ?? .forModel(model)
        self.isBilled = (pricing ?? .forModel(model)) != .unbilled
    }

    public mutating func record(_ usage: Wire.Usage) {
        turns += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadInputTokens ?? 0
        cacheWriteTokens += usage.cacheCreationInputTokens ?? 0
    }

    /// Records a planning call, priced at the planning model's own rate.
    public mutating func recordPlanning(_ usage: Wire.Usage, model: String) {
        // An unbilled run is unbilled for the planner too: the planning call goes to
        // the same endpoint. Pricing it by model here re-introduced the fabricated
        // figure the executor had just stopped producing — a local planned run
        // reported $0.0068 while its own header said "not billed (local)".
        let planPricing = isBilled ? Pricing.forModel(model) : .unbilled
        planningTokens += usage.inputTokens + usage.outputTokens
        planningCost += Double(usage.inputTokens) / 1_000_000 * planPricing.inputPerMillion
            + Double(usage.outputTokens) / 1_000_000 * planPricing.outputPerMillion
            + Double(usage.cacheReadInputTokens ?? 0) / 1_000_000 * planPricing.cacheReadPerMillion
            + Double(usage.cacheCreationInputTokens ?? 0) / 1_000_000 * planPricing.cacheWritePerMillion
    }

    /// The executor's spend alone. `totalCost` is what the run actually cost.
    public var executionCost: Double {
        Double(inputTokens) / 1_000_000 * pricing.inputPerMillion
            + Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
            + Double(cacheReadTokens) / 1_000_000 * pricing.cacheReadPerMillion
            + Double(cacheWriteTokens) / 1_000_000 * pricing.cacheWritePerMillion
    }

    public var totalCost: Double { executionCost + planningCost }

    /// Share of billable input served from cache, 0–1.
    ///
    /// A rate near zero across several turns means something volatile leaked into
    /// the cached prefix and the prompt is being re-billed in full every turn.
    public var cacheHitRate: Double {
        let billable = inputTokens + cacheReadTokens
        guard billable > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(billable)
    }

    /// What the same tokens would have cost with no caching, for comparison.
    public var costWithoutCaching: Double {
        Double(inputTokens + cacheReadTokens + cacheWriteTokens) / 1_000_000 * pricing.inputPerMillion
            + Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
    }

    /// Compared against `executionCost`, not `totalCost`.
    ///
    /// `costWithoutCaching` is computed from the executor's tokens alone, so measuring
    /// it against a total that now includes planning would charge the planner's price
    /// to the cache and report a saving smaller than the one caching actually made —
    /// or, on a cheap executor with an expensive planner, no saving at all.
    public var savedByCaching: Double { max(0, costWithoutCaching - executionCost) }

    /// Formatted for the end of a run.
    /// Groups digits without a locale.
    ///
    /// `Int.formatted()` uses the machine's separator, so 4200 renders as "4.200"
    /// wherever a full stop groups thousands — which reads as four-point-two, in the
    /// one place the number needs to be unambiguous. Token counts are not currency
    /// and have no business varying by region.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + out
    }

    public var summary: String {
        var line = "\(turns) turn\(turns == 1 ? "" : "s") · "
        line += "\(Self.grouped(inputTokens)) in / \(Self.grouped(outputTokens)) out"
        if cacheReadTokens > 0 {
            line += " · \(Int(cacheHitRate * 100))% cached"
        }
        line += isBilled ? " · \(Self.format(totalCost))" : " · not billed (local)"
        if isBilled, planningCost > 0 {
            // Named, so the extra spend is attributable rather than just a larger
            // number than the same task cost yesterday.
            line += " (incl. \(Self.format(planningCost)) planning)"
        }
        if isBilled, savedByCaching >= 0.001 {
            line += " (saved \(Self.format(savedByCaching)))"
        }
        return line
    }

    /// Sub-cent amounts are the common case for a ladder-first task, so they need
    /// more precision than a currency formatter's two decimal places.
    public static func format(_ amount: Double) -> String {
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        if amount < 1 { return String(format: "$%.3f", amount) }
        return String(format: "$%.2f", amount)
    }
}

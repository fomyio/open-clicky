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

    public init(model: String) {
        self.pricing = .forModel(model)
    }

    public mutating func record(_ usage: Wire.Usage) {
        turns += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadInputTokens ?? 0
        cacheWriteTokens += usage.cacheCreationInputTokens ?? 0
    }

    public var totalCost: Double {
        Double(inputTokens) / 1_000_000 * pricing.inputPerMillion
            + Double(outputTokens) / 1_000_000 * pricing.outputPerMillion
            + Double(cacheReadTokens) / 1_000_000 * pricing.cacheReadPerMillion
            + Double(cacheWriteTokens) / 1_000_000 * pricing.cacheWritePerMillion
    }

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

    public var savedByCaching: Double { max(0, costWithoutCaching - totalCost) }

    /// Formatted for the end of a run.
    public var summary: String {
        var line = "\(turns) turn\(turns == 1 ? "" : "s") · "
        line += "\(inputTokens.formatted()) in / \(outputTokens.formatted()) out"
        if cacheReadTokens > 0 {
            line += " · \(Int(cacheHitRate * 100))% cached"
        }
        line += " · \(Self.format(totalCost))"
        if savedByCaching >= 0.001 {
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

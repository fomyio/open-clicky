import Foundation

/// Turns agent events into the lines a user watches during a run.
///
/// In the library rather than the CLI so the output can be rendered and read without
/// an API key. That matters more than it sounds: this is the only view a person has
/// of what the agent is doing to their machine, and until it could be rendered
/// nobody had seen a whole run's worth of it.
///
/// Emits plain text; colour is the caller's business.
public struct RunReport: Sendable {
    /// A line, and how prominent it is.
    public struct Line: Sendable, Equatable {
        public enum Emphasis: Sendable, Equatable {
            /// Progress: what the agent is doing right now.
            case detail
            /// The agent's own words.
            case speech
            case success
            case failure
            /// Needs the user's attention even when they are not watching closely.
            case warning
        }
        public let text: String
        public let emphasis: Emphasis
    }

    /// Whether to include lines that only make sense on a live terminal.
    private let isInteractive: Bool
    private var meter: CostMeter?

    public init(isInteractive: Bool = true) {
        self.isInteractive = isInteractive
    }

    /// The lines this event produces, in order. Most produce one; some produce none.
    public mutating func lines(for event: AgentLoop.Event) -> [Line] {
        switch event {
        case .thinking:
            // Only worth showing where it can be overwritten by what comes next.
            return isInteractive ? [Line(text: "· thinking…", emphasis: .detail)] : []

        case let .assistantText(text):
            return [Line(text: "", emphasis: .detail), Line(text: text, emphasis: .speech)]

        case let .toolStarted(name, tier, summary):
            return [Line(text: "  → [T\(tier.rawValue)] \(name): \(summary)", emphasis: .detail)]

        case let .toolFinished(_, ok, detail):
            return [Line(text: "    \(ok ? "✓" : "✗") \(detail)",
                         emphasis: ok ? .success : .failure)]

        case let .toolDenied(name, reason):
            return [Line(text: "    ✗ \(name) denied — \(reason)", emphasis: .failure)]

        case let .toolSkipped(name):
            return [Line(text: "    · \(name) skipped (earlier action failed)", emphasis: .detail)]

        case .interrupted:
            return [Line(text: "    ■ stopped — no further actions will run", emphasis: .warning)]

        case .usage:
            // The cost line carries the same numbers with the price attached.
            return []

        case let .cost(meter):
            self.meter = meter
            return isInteractive ? [Line(text: "  \(meter.summary)", emphasis: .detail)] : []

        case let .finished(reason):
            var lines = [
                Line(text: "", emphasis: .detail),
                Line(text: "── \(reason)", emphasis: .detail),
            ]
            if let meter {
                lines.append(Line(text: "   \(meter.summary)", emphasis: .detail))
                // A cold cache across several turns means something volatile reached
                // the cached prefix and the whole prompt is being re-billed each turn.
                if meter.turns > 1, meter.cacheHitRate < 0.1 {
                    lines.append(Line(
                        text: "   note: cache hit rate is \(Int(meter.cacheHitRate * 100))% — "
                            + "the cached prefix may be being invalidated each turn.",
                        emphasis: .warning
                    ))
                }
            }
            return lines
        }
    }
}

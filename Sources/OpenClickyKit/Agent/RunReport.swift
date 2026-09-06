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
    /// What the run changed, delivered one event before `.finished`.
    private var outcome: RunOutcome?

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

        case let .retrying(attempt, total, delay, reason):
            // Shown even when not interactive. A rate limit with Retry-After: 60 and
            // three retries is three minutes of silence, which reads as a hang — and
            // the reasonable response to a hang is to kill the run.
            return [Line(
                text: "    … \(reason) — retrying in \(Int(delay.rounded()))s "
                    + "(attempt \(attempt) of \(total))",
                emphasis: .warning
            )]

        case .interrupted:
            return [Line(text: "    ■ stopped — no further actions will run", emphasis: .warning)]

        case .usage:
            // The cost line carries the same numbers with the price attached.
            return []

        case let .cost(meter):
            self.meter = meter
            return isInteractive ? [Line(text: "  \(meter.summary)", emphasis: .detail)] : []

        case let .outcome(outcome):
            // Held, not drawn. The closing block is one visual unit and the outcome
            // belongs at the top of it, so it waits for `.finished` rather than
            // printing a line of its own above the blank separator.
            self.outcome = outcome
            return []

        case let .finished(reason):
            // An unfulfilled run is the one case where the closing line is not a
            // neutral status: the agent has just written a paragraph that reads like a
            // report, and the only thing distinguishing it from a real one is this
            // line. It gets warning emphasis for the same reason the retry line does —
            // it has to survive a user who is not reading closely.
            let unfulfilled = outcome?.isUnfulfilled == true
            var lines = [
                Line(text: "", emphasis: .detail),
                Line(text: "── \(outcome?.report ?? reason)",
                     emphasis: unfulfilled ? .warning : .detail),
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

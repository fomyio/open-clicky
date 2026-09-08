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

    /// The waiting line, at a given elapsed time.
    ///
    /// Shared so the first draw and every redraw cannot drift apart in width — a
    /// redraw shorter than the line under it leaves the tail of the old one on screen,
    /// which is how a progress indicator ends up reading `· thinking… 9s…`.
    public static func waitingLine(seconds: Int) -> String {
        seconds <= 0 ? "· thinking…" : "· thinking… \(seconds)s"
    }

    /// Whether the caller is already showing assistant text as it streams in.
    ///
    /// Found by running it: with streaming wired up and this absent, every reply
    /// appeared twice — once a fragment at a time, then again in full when the turn
    /// closed. The renderer cannot detect that for itself, because both paths carry
    /// the same bytes and only the caller knows whether it drew the first one.
    private let streamsText: Bool

    public init(isInteractive: Bool = true, streamsText: Bool = false) {
        self.isInteractive = isInteractive
        self.streamsText = streamsText
    }

    /// The lines this event produces, in order. Most produce one; some produce none.
    public mutating func lines(for event: AgentLoop.Event) -> [Line] {
        switch event {
        case .thinking:
            // Only worth showing where it can be overwritten by what comes next.
            //
            // A bare "· thinking…" is the same silence the retry notice exists to
            // break, just shorter: the recorded turns run 15–35 seconds against a
            // local model and one reached 62 against Anthropic, and for every second
            // of that the line said exactly what it said at the start. A caller that
            // can redraw is given the seconds instead — see `Waiting`.
            return isInteractive ? [Line(text: Self.waitingLine(seconds: 0), emphasis: .detail)] : []

        case let .assistantText(text):
            // Already on screen, drawn a fragment at a time. All that is left is to
            // close the line the stream was writing into.
            guard !streamsText else { return [Line(text: "", emphasis: .detail)] }
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

        case let .planned(model, plan):
            // Shown in full. The plan shapes everything the run does next, and a user
            // who cannot see it cannot tell a good run from a lucky one — nor spot
            // that the expensive model proposed something they would have vetoed.
            return [Line(text: "", emphasis: .detail),
                    Line(text: "plan · \(model)", emphasis: .detail),
                    Line(text: plan, emphasis: .speech)]

        case let .planningFailed(model, reason):
            // A warning, not a detail line. The user typed `--planner` and is about to
            // watch a run that did not plan; if this scrolls past unnoticed they will
            // judge the planner by a run it took no part in.
            return [Line(text: "", emphasis: .detail),
                    Line(text: "    ! no plan — \(model) was unreachable: \(reason.truncated(120))",
                         emphasis: .warning),
                    Line(text: "      continuing without one.", emphasis: .warning)]

        case let .outcome(outcome):
            // Held, not drawn. The closing block is one visual unit and the outcome
            // belongs at the top of it, so it waits for `.finished` rather than
            // printing a line of its own above the blank separator.
            self.outcome = outcome
            return []

        case let .finished(reason):
            // An incomplete run is the one case where the closing line is not a
            // neutral status: the agent has just written a paragraph that reads like a
            // report, and the only thing distinguishing it from a real one is this
            // line. It gets warning emphasis for the same reason the retry line does —
            // it has to survive a user who is not reading closely.
            //
            // Both failures earn the emphasis, not just the zero-action one. A run cut
            // off at the turn limit signs off with the model's last paragraph, which
            // was written mid-task and reads no differently from a closing summary.
            let incomplete = outcome?.isIncomplete == true
            var lines = [
                Line(text: "", emphasis: .detail),
                Line(text: "── \(outcome?.report ?? reason)",
                     emphasis: incomplete ? .warning : .detail),
            ]
            if let meter {
                lines.append(Line(text: "   \(meter.summary)", emphasis: .detail))
                // A cold cache across several turns means something volatile reached
                // the cached prefix and the whole prompt is being re-billed each turn.
                if meter.turns > 1, meter.cacheHitRate < 0.1 {
                    // Two situations, opposite responses. A prompt below the model's
                    // caching floor is nothing to fix — measured, a `--max-tier 0` run
                    // sends ~1,089 tokens against Haiku's 2,048 floor — and telling
                    // that user their prefix is being invalidated sends them hunting
                    // for drift that does not exist.
                    let note = meter.isBelowCacheFloor
                        ? "   note: nothing was cached — this prompt is under the "
                            + "\(CostMeter.grouped(meter.pricing.minimumCacheableTokens))-token "
                            + "minimum this model caches. Not a fault; a larger tier "
                            + "ceiling or a longer prompt would cross it."
                        : "   note: cache hit rate is \(Int(meter.cacheHitRate * 100))% — "
                            + "the cached prefix may be being invalidated each turn."
                    lines.append(Line(text: note, emphasis: .warning))
                }
            }
            return lines
        }
    }
}

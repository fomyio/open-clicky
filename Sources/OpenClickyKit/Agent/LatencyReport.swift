import Foundation

/// Where a run's wall-clock time actually went.
///
/// Nothing measured time. `CostMeter` counts tokens and prices them, which answers
/// "what did that cost" and says nothing about "why did that take a minute" — and the
/// ladder's whole argument is that `ax_capture` is ~26ms where a screenshot is ~1s, a
/// claim no part of this codebase could check.
///
/// It needs no new instrumentation, because the record already has it: `Transcript`
/// stamps every entry, so every run ever recorded is a latency measurement nobody
/// read as one. Deriving rather than instrumenting means a baseline exists for runs
/// that happened before anyone thought to measure them, which is the only kind of
/// before-and-after that cannot be gamed by measuring after the change.
public struct LatencyReport: Sendable, Equatable {

    /// One request/response round-trip and the tool work that followed it.
    public struct Turn: Sendable, Equatable {
        public let index: Int
        /// Request built to response received. The API round-trip, plus any retries
        /// the client made inside it — see `retriesAreInvisible`.
        public let modelSeconds: Double
        /// Response received to the next request, net of any wait on the user.
        /// `nil` on the closing turn, which ran no tools.
        ///
        /// Separating this from `gateSeconds` is not a nicety. Both recorded sessions
        /// showed 3.4s and 7.1s in this window for `pgrep -l Code` and
        /// `open -a Spotify` — commands that run in ~25ms under `sandbox-exec`,
        /// measured. Reported together, the machine gets credit for the user's
        /// reaction time, and the first conclusion anyone draws is that Tier 0 is slow.
        public let toolSeconds: Double?

        /// Time the permission gate spent waiting for the user to answer.
        ///
        /// Not a cost to optimise: this is the run doing exactly what it should. It is
        /// measured so it can be *excluded*, not reduced.
        public let gateSeconds: Double

        /// Backoffs the client made inside this turn's single request, and the seconds
        /// they were told to wait.
        ///
        /// A turn's time has always included these; until they were recorded there was
        /// no way to tell a slow response from a fast one behind a `Retry-After: 60`.
        /// The recorded 62-second cold turn is exactly that ambiguity.
        public let retries: Int
        public let retrySeconds: Double

        /// Seconds from the request going out to the model's first token, when the
        /// run streamed. Nil on a buffered turn, where the moment does not exist.
        ///
        /// The number that splits a slow turn into its two unrelated causes: waiting
        /// to start, and taking a while to finish. They have opposite fixes, and
        /// `modelSeconds` alone cannot tell them apart.
        public let timeToFirstToken: Double?

        /// Seconds spent generating, once the model began. Nil for the same reason.
        public var generationSeconds: Double? {
            timeToFirstToken.map { max(0, modelSeconds - $0) }
        }
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int

        /// No cached prefix was read, so the whole system prompt was re-billed and
        /// re-processed. Expected on turn 0 of the first run against a model; on any
        /// later turn it means something volatile reached the cached prefix.
        public var isColdCache: Bool { cacheReadTokens == 0 }

        public init(
            index: Int, modelSeconds: Double, toolSeconds: Double?, gateSeconds: Double = 0,
            retries: Int = 0, retrySeconds: Double = 0, timeToFirstToken: Double? = nil,
            inputTokens: Int, outputTokens: Int, cacheReadTokens: Int
        ) {
            self.retries = retries
            self.retrySeconds = retrySeconds
            self.timeToFirstToken = timeToFirstToken
            self.index = index
            self.modelSeconds = modelSeconds
            self.toolSeconds = toolSeconds
            self.gateSeconds = gateSeconds
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
        }
    }

    public let sessionID: String
    public let task: String
    public let turns: [Turn]

    /// How many tool calls the run made at each tier, lowest first.
    ///
    /// The ladder's central claim is that a task answered by `shell` and one answered
    /// by six screenshots differ by two orders of magnitude, and that the model should
    /// therefore reach for the cheapest tier that can do the job. Nothing measured
    /// whether it does. The prompt says it, the tier costs are documented, and the
    /// only evidence a run actually stayed low was the bill.
    ///
    /// Counted from the tool names in the recorded assistant turns, so it works on
    /// every session already on disk rather than needing new instrumentation — the
    /// same reason `bench` derives its timings instead of measuring them.
    public let tierCounts: [Tier: Int]

    /// What produced the run: model, planner, mode. Nil for a session recorded
    /// before runs described themselves.
    ///
    /// The label a comparison is made against. Two timings mean nothing without it.
    public let configuration: Configuration?

    /// The configuration a recorded run was started with.
    public struct Configuration: Sendable, Equatable {
        public let model: String
        /// The planning model, or nil if the run was unplanned.
        public let planner: String?
        public let mode: String
        /// The highest tier the run could reach. Nil on a record written before this
        /// was part of the label.
        ///
        /// In the label because it changes the prompt: the tool list, the ladder and
        /// the acting advice are all built from the ceiling, so a tier-0 run and a
        /// tier-3 run send materially different numbers of tokens. It was recorded in
        /// the run note from the start and left out of the label, which meant two runs
        /// differing only in ceiling were pooled as one configuration — the same
        /// confounded comparison the block already refuses across tasks, in a
        /// dimension the record was carrying all along.
        public let maxTier: Int?

        public init(model: String, planner: String?, mode: String, maxTier: Int? = nil) {
            self.model = model
            self.planner = planner
            self.mode = mode
            self.maxTier = maxTier
        }

        /// e.g. `claude-haiku-4-5 · planned by claude-opus-5 · ask · tiers 0–3`
        public var label: String {
            var parts = [model]
            if let planner { parts.append("planned by \(planner)") }
            parts.append(mode)
            if let maxTier { parts.append("tiers 0–\(maxTier)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Whether this session recorded how long the gate waited on the user.
    ///
    /// Runs recorded before that instrumentation existed cannot have their tool time
    /// separated from their prompt time after the fact — the record simply does not
    /// contain it. Rather than quietly attributing the whole window to tools, a
    /// report says which kind of session it is reading. A measurement that cannot
    /// state its own provenance is one that will be quoted as if it could.
    public let hasGateAccounting: Bool

    /// Whether this session could have recorded a retry.
    ///
    /// Not "did it retry" — a healthy run records none, and a run written before
    /// retries were recorded also records none. The two are indistinguishable from the
    /// notes alone, so the `run` note doubles as the marker: a session that describes
    /// its configuration was written by a binary that also records retries. Without
    /// that, a clean modern run would keep printing a caveat about data it does have.
    public var hasRetryAccounting: Bool { configuration != nil }

    public init(
        sessionID: String, task: String, turns: [Turn], totalSeconds: Double,
        hasGateAccounting: Bool = false, configuration: Configuration? = nil,
        tierCounts: [Tier: Int] = [:]
    ) {
        self.tierCounts = tierCounts
        self.sessionID = sessionID
        self.task = task
        self.turns = turns
        self.totalSeconds = totalSeconds
        self.hasGateAccounting = hasGateAccounting
        self.configuration = configuration
    }

    /// Time from the task being accepted to the last recorded entry.
    ///
    /// Not the sum of the turns: it also covers the gate waiting on a human, and
    /// whatever the loop did between them.
    public let totalSeconds: Double

    // MARK: - Derivation

    /// Reads timings out of a parsed session.
    ///
    /// Walks in `sequence` order, never timestamp order. The transcript's own note on
    /// `Entry.sequence` is the reason: several entries a turn are written inside the
    /// same millisecond, ISO8601's finest resolution, so sorting by time genuinely
    /// reorders them. A zero-second interval here is therefore a real reading — the
    /// assistant entry is appended immediately after the usage note — and not a bug.
    ///
    /// The boundaries are the two message kinds the loop appends: a `user` entry is
    /// the task or a batch of tool results, and is the moment the next request can be
    /// built; an `assistant` entry is the response that batch answers. Everything
    /// between an assistant entry and the next user entry is tool execution and the
    /// gate. Other kinds — `denied`, `interrupted`, `truncated`, `usage` — are notes
    /// alongside that spine, not points on it.
    public static func derive(sessionID: String, entries: [Transcript.Entry]) -> LatencyReport? {
        let ordered = entries.sorted { $0.sequence < $1.sequence }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        var turns: [Turn] = []
        /// Gate waits accumulated since the last response, in seconds.
        ///
        /// A turn can hold a batch of calls and stop to ask on several of them, so
        /// these add up rather than replace each other.
        var gateWaitThisTurn = 0.0
        // Retries land between the request being sent and the response arriving, so
        // they accumulate against the turn that is still open.
        var retriesThisTurn = 0
        var retrySecondsThisTurn = 0.0
        var firstTokenThisTurn: Double?
        var sawGateNote = false
        var configuration: Configuration?
        var tierCounts: [Tier: Int] = [:]
        /// The last point at which a request could have been sent.
        ///
        /// Nil until the first `user` entry, rather than seeded from entry zero. Entry
        /// zero used to be the task; it is now the `run` note describing the
        /// configuration, and seeding from it silently measured turn 0 from before the
        /// task had even been appended.
        var requestSentAt: Date?
        /// The response the tools now running are answering, and its index.
        var pendingResponse: (at: Date, turnIndex: Int)?
        /// Usage is noted just before the assistant entry it describes, so it is held
        /// until that entry arrives rather than guessing which turn it belongs to.
        var pendingUsage: Transcript.Entry?

        func closePendingTool(at boundary: Date) {
            guard let pending = pendingResponse, pending.turnIndex < turns.count else { return }
            let turn = turns[pending.turnIndex]
            let window = boundary.timeIntervalSince(pending.at)
            // Clamped at zero: the gate's own clock is monotonic and the transcript's
            // is wall-clock, so a clock adjustment mid-prompt could make the recorded
            // wait exceed the window it sits inside. A negative duration in a report
            // is worse than a zero one — it reads as a bug in the whole measurement.
            turns[pending.turnIndex] = Turn(
                index: turn.index,
                modelSeconds: turn.modelSeconds,
                toolSeconds: max(0, window - gateWaitThisTurn),
                gateSeconds: min(gateWaitThisTurn, window),
                retries: turn.retries,
                retrySeconds: turn.retrySeconds,
                timeToFirstToken: turn.timeToFirstToken,
                inputTokens: turn.inputTokens,
                outputTokens: turn.outputTokens,
                cacheReadTokens: turn.cacheReadTokens
            )
            pendingResponse = nil
            gateWaitThisTurn = 0
        }

        // Every entry, not `dropFirst()`. That skipped entry zero on the assumption
        // it was the task and carried no information — which stopped being true the
        // moment a run started describing itself in the first line.
        for entry in ordered {
            switch entry.kind {
            case "usage":
                pendingUsage = entry

            case "run":
                if let model = entry.payload["model"]?.stringValue {
                    configuration = Configuration(
                        model: model,
                        planner: entry.payload["planner"]?.stringValue,
                        mode: entry.payload["mode"]?.stringValue ?? "?",
                        maxTier: entry.payload["max_tier"]?.doubleValue.map(Int.init)
                    )
                }

            case "first_token":
                firstTokenThisTurn = entry.payload["seconds"]?.doubleValue

            case "retry":
                retriesThisTurn += 1
                retrySecondsThisTurn += entry.payload["delay_seconds"]?.doubleValue ?? 0

            case "gate":
                sawGateNote = true
                gateWaitThisTurn += entry.payload["seconds"]?.doubleValue ?? 0

            case "assistant" where entry.payload["content"]?.arrayValue != nil:
                for block in entry.payload["content"]?.arrayValue ?? []
                where block["type"]?.stringValue == "tool_use" {
                    guard let name = block["name"]?.stringValue,
                          let tier = Tier.forToolNamed(name) else { continue }
                    tierCounts[tier, default: 0] += 1
                }
                fallthrough

            case "assistant":
                // The round-trip ends here. Without a preceding user entry there is no
                // start to measure from, which happens only in a truncated record.
                guard let sentAt = requestSentAt else { break }
                let usage = pendingUsage?.payload
                turns.append(Turn(
                    index: turns.count,
                    modelSeconds: entry.timestamp.timeIntervalSince(sentAt),
                    toolSeconds: nil,
                    retries: retriesThisTurn,
                    retrySeconds: retrySecondsThisTurn,
                    timeToFirstToken: firstTokenThisTurn,
                    inputTokens: usage?["input_tokens"]?.doubleValue.map(Int.init) ?? 0,
                    outputTokens: usage?["output_tokens"]?.doubleValue.map(Int.init) ?? 0,
                    cacheReadTokens: usage?["cache_read_tokens"]?.doubleValue.map(Int.init) ?? 0
                ))
                pendingResponse = (at: entry.timestamp, turnIndex: turns.count - 1)
                retriesThisTurn = 0
                retrySecondsThisTurn = 0
                firstTokenThisTurn = nil
                pendingUsage = nil
                requestSentAt = nil

            case "user":
                // Tool results: closes the previous turn's tool window and opens the
                // next request.
                closePendingTool(at: entry.timestamp)
                requestSentAt = entry.timestamp

            default:
                break
            }
        }

        return LatencyReport(
            sessionID: sessionID,
            task: firstTask(in: ordered),
            turns: turns,
            totalSeconds: last.timestamp.timeIntervalSince(first.timestamp),
            hasGateAccounting: sawGateNote,
            configuration: configuration,
            tierCounts: tierCounts
        )
    }

    /// Reads a session file straight from disk.
    public static func derive(at url: URL) throws -> LatencyReport? {
        derive(
            sessionID: url.deletingPathExtension().lastPathComponent,
            entries: try TranscriptReport.entries(at: url)
        )
    }

    /// The task text, with the environment probe the loop prepends stripped off.
    ///
    /// Found by kind rather than by position: the first entry is the `run` note now,
    /// and the task is in the first `user` message whatever precedes it.
    private static func firstTask(in entries: [Transcript.Entry]) -> String {
        let text = entries.first { $0.kind == "user" }?
            .payload["content"]?.arrayValue?
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: " ") ?? ""
        // The probe is `<environment>…</environment>\n\n<task>`. Splitting on the
        // closing tag is exact where searching for a blank line is not — a probe with
        // no display attached still ends with the tag.
        let afterProbe: String
        if let range = text.range(of: "</environment>") {
            afterProbe = String(text[range.upperBound...])
        } else {
            afterProbe = text
        }
        // The planner's brief is appended to this same message. It has to come off, or
        // a planned run and its unplanned twin are two different tasks to `comparison`
        // and never appear side by side.
        let withoutPlan = afterProbe.components(separatedBy: Planner.briefMarker).first ?? afterProbe
        return withoutPlan.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Aggregates

    public var modelSeconds: Double { turns.reduce(0) { $0 + $1.modelSeconds } }
    public var toolSeconds: Double { turns.reduce(0) { $0 + ($1.toolSeconds ?? 0) } }
    /// Time the run spent waiting on the person at the keyboard.
    public var gateSeconds: Double { turns.reduce(0) { $0 + $1.gateSeconds } }
    public var retries: Int { turns.reduce(0) { $0 + $1.retries } }
    public var retrySeconds: Double { turns.reduce(0) { $0 + $1.retrySeconds } }

    /// Share of the run spent waiting on the API rather than on the machine.
    ///
    /// The number that decides which lever is worth pulling: streaming and model
    /// routing act on the first, tier routing and subprocess overhead on the second.
    /// Gate time is excluded from the denominator, not counted as machine time: the
    /// question this answers is where the *agent's* time went, and a run that waited
    /// four minutes for someone to come back from lunch has not become slow.
    public var modelShare: Double {
        let measured = modelSeconds + toolSeconds
        return measured > 0 ? modelSeconds / measured : 0
    }

    /// Tool calls the run made, at any tier.
    public var toolCalls: Int { tierCounts.values.reduce(0, +) }

    /// Share of tool calls that stayed below the pixel tier, 0–1.
    ///
    /// The ladder in one number. A screenshot is ~2,000 vision tokens and roughly a
    /// second where an `ax_capture` is ~1,000 and ~30ms, so a run that answers from
    /// tiers 0–2 is not marginally cheaper, it is a different order of cost. `nil`
    /// when the run made no tool calls: a run that did nothing has no discipline to
    /// report, and printing 100% for it would flatter exactly the runs this project
    /// spent the session learning to distrust.
    public var ladderDiscipline: Double? {
        guard toolCalls > 0 else { return nil }
        let escalated = tierCounts[.pixels] ?? 0
        return Double(toolCalls - escalated) / Double(toolCalls)
    }

    /// e.g. `T0×3 T2×1` — omitting tiers the run never used.
    public var tierSummary: String {
        Tier.allCases
            .compactMap { tier in
                guard let count = tierCounts[tier], count > 0 else { return nil }
                return "T\(tier.rawValue)×\(count)"
            }
            .joined(separator: " ")
    }

    /// The slowest turn, which is usually the one worth explaining.
    public var slowestTurn: Turn? { turns.max { $0.modelSeconds < $1.modelSeconds } }

    /// Cached prefix tokens as a share of all input tokens.
    ///
    /// The same canary as `CostMeter.cacheHitRate`, computed from the record rather
    /// than from a live meter, so it can be checked after the fact.
    public var cacheHitRate: Double {
        let cached = turns.reduce(0) { $0 + $1.cacheReadTokens }
        let fresh = turns.reduce(0) { $0 + $1.inputTokens }
        let total = cached + fresh
        return total > 0 ? Double(cached) / Double(total) : 0
    }

    /// Why an older record's turn time cannot be trusted as response time.
    public static let retriesWereNotRecorded = """
        this run predates retry recording, so a slow turn here may be a slow response \
        or a fast one behind a rate-limit backoff.
        """

    /// A turn's time can hide a retry, and the transcript does not record one.
    ///
    /// `AnthropicClient` backs off and retries inside a single `send`, reporting it
    /// only to the observer — which draws to the terminal and is gone. So a 62-second
    /// turn and a 2-second turn that was retried twice behind a `Retry-After: 30` are
    /// the same reading here, and there is no way to tell them apart after the fact.
    /// Stated on the type because a measurement whose limits are only in someone's
    /// head gets quoted without them.
    /// Why an older record's tool figure cannot be trusted as tool time.
    public static let gateWasNotSeparated = """
        this run predates gate timing, so its tool figure still includes any time the \
        permission prompt spent waiting for you.
        """

    public static let retriesAreInvisible = """
        a turn's time includes any retries the client made inside it, and \
        retries are not recorded — a slow turn may be a slow response or a fast one \
        behind a rate-limit backoff.
        """
}

// MARK: - Rendering

public extension LatencyReport {
    /// The per-session block, as lines.
    ///
    /// In the kit rather than the CLI for the same reason `RunReport` is: output that
    /// can only be produced by running the real thing is output nobody has read.
    func rendered() -> [String] {
        var lines = ["\(sessionID.prefix(8))  \(task.truncated(64))"]
        if let configuration {
            lines.append("  \(configuration.label)")
        }
        guard !turns.isEmpty else {
            return lines + ["  (no completed turns recorded)"]
        }
        // The header names what the column actually contains. Before the gate was
        // timed there was no way to take it out of the tool figure, so a report over
        // an older record says "gate+tools" rather than quietly calling a human's
        // reaction time tool execution.
        // A dagger, not a wider header: the column has to stay the width of the
        // numbers under it, and the note directly below defines the mark. Widening it
        // to spell "gate+tools" put the header out of line with every row.
        let toolHeader = hasGateAccounting ? "    tools     gate" : "   tools†"
        lines.append("  turn    model\(toolHeader)      in     out   cache")
        for turn in turns {
            // A cold turn is marked rather than left for the reader to spot in the
            // cache column, because it is the single largest explanation for an
            // outlier and the column it lives in is the last one.
            let cold = turn.isColdCache ? " cold" : ""
            // Appended to the row rather than given a column: retries are rare, and a
            // column that is empty on every healthy run is a column that trains the
            // reader to stop looking at it.
            // Shown as the split, not as one more number: "4.3s" beside "62.1s" is
            // arithmetic the reader has to do, and the whole point is the ratio.
            let split = turn.timeToFirstToken.map { ttft in
                " · \(seconds(ttft)) to first token, \(seconds(turn.generationSeconds ?? 0)) generating"
            } ?? ""
            let backoff = turn.retries > 0
                ? " · \(turn.retries) retr\(turn.retries == 1 ? "y" : "ies") "
                    + "waiting \(seconds(turn.retrySeconds))"
                : ""
            let window = turn.toolSeconds.map { hasGateAccounting ? $0 : $0 + turn.gateSeconds }
            var row = "  \(String(turn.index).leftPadded(4))  "
                + "\(seconds(turn.modelSeconds).leftPadded(7))  "
                + "\((window.map(seconds) ?? "—").leftPadded(7))"
            if hasGateAccounting { row += "  \(seconds(turn.gateSeconds).leftPadded(7))" }
            row += "  \(String(turn.inputTokens).leftPadded(6))  "
                + "\(String(turn.outputTokens).leftPadded(6))  "
                + "\(String(turn.cacheReadTokens).leftPadded(6))\(cold)\(split)\(backoff)"
            lines.append(row)
        }
        if toolCalls > 0, let discipline = ladderDiscipline {
            lines.append("  tiers \(tierSummary) — \(percent(discipline)) below pixels")
        }
        var total = "  total \(seconds(totalSeconds)) — model \(percent(modelShare)) · "
            + "tools\(hasGateAccounting ? "" : "†") \(percent(1 - modelShare))"
        if hasGateAccounting, gateSeconds > 0 {
            total += " · waited on you \(seconds(gateSeconds))"
        }
        total += " · cache hit \(percent(cacheHitRate))"
        lines.append(total)
        if !hasGateAccounting {
            // Said per session, because a directory can hold both kinds and the
            // caveat belongs against the rows it applies to.
            lines.append("  † " + LatencyReport.gateWasNotSeparated)
        }
        if !hasRetryAccounting {
            lines.append("  † " + LatencyReport.retriesWereNotRecorded)
        }
        return lines
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2fs", value) }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Several sessions read together, which is the only way the numbers mean anything.
///
/// One run is an anecdote: the first request against a model pays a cold cache and
/// whatever the network was doing, and quoting it as a baseline is how a change gets
/// credited with an improvement it did not make.
public struct LatencyBenchmark: Sendable {
    public let sessions: [LatencyReport]

    public init(sessions: [LatencyReport]) { self.sessions = sessions }

    /// Every recorded session in a directory, newest first.
    public static func load(from directory: URL) -> LatencyBenchmark {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "jsonl" }
        let reports = files.compactMap { try? LatencyReport.derive(at: $0) }.compactMap { $0 }
        return LatencyBenchmark(sessions: reports.sorted { $0.sessionID < $1.sessionID })
    }

    public var allTurns: [LatencyReport.Turn] { sessions.flatMap(\.turns) }
    public var modelSeconds: Double { sessions.reduce(0) { $0 + $1.modelSeconds } }
    public var toolSeconds: Double { sessions.reduce(0) { $0 + $1.toolSeconds } }
    public var gateSeconds: Double { sessions.reduce(0) { $0 + $1.gateSeconds } }

    /// Whether *every* session read could separate gate time from tool time.
    ///
    /// All, not any: a total mixing one accounted session with one unaccounted one is
    /// not a tool figure, and reporting it as though the majority settles the matter
    /// is how a caveat gets lost in an average.
    public var hasGateAccounting: Bool {
        !sessions.isEmpty && sessions.allSatisfy(\.hasGateAccounting)
    }

    /// All, not any — same reasoning as `hasGateAccounting`.
    public var hasRetryAccounting: Bool {
        !sessions.isEmpty && sessions.allSatisfy(\.hasRetryAccounting)
    }

    /// Median seconds to the first token, over streamed turns.
    ///
    /// Reported separately from the turn median because it answers a different
    /// question, and pooling it with buffered turns that have no such moment would
    /// average a number with its own absence.
    public var medianTimeToFirstToken: Double? {
        let sorted = allTurns.compactMap(\.timeToFirstToken).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    public var retries: Int { sessions.reduce(0) { $0 + $1.retries } }
    public var retrySeconds: Double { sessions.reduce(0) { $0 + $1.retrySeconds } }

    /// Median, not mean.
    ///
    /// A single 62-second cold start across five turns moves a mean by twelve seconds
    /// and a median by nothing — and the median is the honest answer to "how long does
    /// a turn take", because the mean here is a statement about the outlier.
    public var medianModelSeconds: Double {
        let sorted = allTurns.map(\.modelSeconds).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Median tool-execution time per turn, over turns that ran tools.
    public var medianToolSeconds: Double {
        let sorted = allTurns.compactMap(\.toolSeconds).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Medians per configuration, when there is more than one to compare.
    ///
    /// The whole point of labelling runs. One configuration is a measurement; two are
    /// a comparison, and a comparison is what a change has to produce to be called an
    /// improvement. Silent when every session ran the same way, because a table with
    /// one row invites the reader to compare it against a number they remember.
    ///
    /// Medians per group, not a pooled median: pooling a fast configuration with a
    /// slow one produces a figure that describes neither.
    public func comparison() -> [String] {
        let labelled = sessions.filter { $0.configuration != nil }
        let configurations = Set(labelled.compactMap { $0.configuration?.label })
        guard configurations.count > 1 else { return [] }

        // Only tasks that were actually run more than one way.
        //
        // Grouping by configuration alone produced a table that looked like a
        // comparison and was not: "open spotify" under one configuration against
        // "format the markdown file" under another differ by the task as much as by
        // the configuration, and the number that comes out is attributable to
        // neither. A/B needs the same A. Anything else is two measurements printed
        // near each other, which is worse than one measurement, because it invites
        // the subtraction.
        let byTask = Dictionary(grouping: labelled) { $0.task }
        let compared = byTask
            .filter { Set($0.value.compactMap { $0.configuration?.label }).count > 1 }
            .sorted { $0.key < $1.key }

        var lines = ["", "BY CONFIGURATION"]
        guard !compared.isEmpty else {
            // Said plainly rather than by omitting the section: a reader who ran two
            // configurations and sees nothing will assume the tool failed, and go
            // looking for the comparison somewhere else.
            lines.append("  \(configurations.count) configurations recorded, but no task was run "
                + "under more than one.")
            lines.append("  Nothing here is comparable — run the same task each way, then look again.")
            return lines
        }

        for (task, runs) in compared {
            lines.append("  \(task.truncated(60))")
            let byConfiguration = Dictionary(grouping: runs) { $0.configuration!.label }
            for label in byConfiguration.keys.sorted() {
                let group = LatencyBenchmark(sessions: byConfiguration[label] ?? [])
                let count = group.sessions.count
                // The split, per configuration, because that is the question a
                // comparison is usually asked: a change that moves the wait and one
                // that moves the generating are different changes, and a single
                // turn median hides which happened.
                let split = group.medianTimeToFirstToken.map {
                    String(format: " (%.2fs wait)", $0)
                } ?? ""
                lines.append(String(
                    format: "    %@ — %d run%@, median turn %.2fs%@, %.1fs total",
                    label, count, count == 1 ? "" : "s",
                    group.medianModelSeconds, split,
                    group.modelSeconds + group.toolSeconds
                ))
            }
        }

        let uncompared = labelled.count - compared.reduce(0) { $0 + $1.value.count }
        if uncompared > 0 {
            lines.append("  (\(uncompared) run\(uncompared == 1 ? "" : "s") of tasks tried only "
                + "one way, not compared)")
        }
        if labelled.count < sessions.count {
            let unlabelled = sessions.count - labelled.count
            // Named rather than dropped: a comparison quietly computed over half the
            // sessions is worse than one that says which half it used.
            lines.append("  (\(unlabelled) older session\(unlabelled == 1 ? "" : "s") "
                + "recorded no configuration and are not compared)")
        }
        return lines
    }

    public func rendered() -> [String] {
        guard !sessions.isEmpty else {
            return ["No recorded sessions to measure. Run a task first."]
        }
        var lines: [String] = []
        for session in sessions {
            lines.append(contentsOf: session.rendered())
            lines.append("")
        }
        let measured = modelSeconds + toolSeconds
        let share = measured > 0 ? modelSeconds / measured : 0
        let counted = "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"
        lines.append("ACROSS \(counted), \(allTurns.count) turns")
        let mark = hasGateAccounting ? "" : "†"
        lines.append(String(
            format: "  model %.1fs (%d%%) · tools%@ %.1fs (%d%%)",
            modelSeconds, Int((share * 100).rounded()),
            mark, toolSeconds, Int(((1 - share) * 100).rounded())
        ))
        if hasGateAccounting, gateSeconds > 0 {
            lines.append(String(format: "  waited on you %.1fs, excluded above", gateSeconds))
        }
        let allTiers = sessions.reduce(into: [Tier: Int]()) { total, session in
            for (tier, count) in session.tierCounts { total[tier, default: 0] += count }
        }
        let calls = allTiers.values.reduce(0, +)
        if calls > 0 {
            let escalated = allTiers[.pixels] ?? 0
            let below = Double(calls - escalated) / Double(calls)
            let summary = Tier.allCases.compactMap { tier -> String? in
                guard let count = allTiers[tier], count > 0 else { return nil }
                return "T\(tier.rawValue)×\(count)"
            }.joined(separator: " ")
            lines.append("  tiers \(summary) — \(Int((below * 100).rounded()))% of calls below pixels")
        }
        lines.append(String(
            format: "  median turn: model %.2fs · tools%@ %.2fs",
            medianModelSeconds, mark, medianToolSeconds
        ))
        if !hasGateAccounting {
            lines.append("  † " + LatencyReport.gateWasNotSeparated)
        }
        lines.append(contentsOf: comparison())
        if let ttft = medianTimeToFirstToken {
            lines.append(String(
                format: "  median wait before the first token: %.2fs (streamed turns only)", ttft
            ))
        }
        if retries > 0 {
            lines.append(String(
                format: "  %d retr%@ across all runs, %.1fs of it waiting on a backoff",
                retries, retries == 1 ? "y" : "ies", retrySeconds
            ))
        }
        // Only where it is still true. A caveat printed under data that answers it
        // teaches the reader that caveats here are boilerplate.
        if !hasRetryAccounting {
            lines.append("  note: " + LatencyReport.retriesAreInvisible)
        }
        return lines
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

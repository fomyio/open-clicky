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
        /// Response received to the next request being sent: every tool in the batch,
        /// plus the permission gate if it stopped to ask. `nil` on the closing turn,
        /// which ran no tools.
        public let toolSeconds: Double?
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int

        /// No cached prefix was read, so the whole system prompt was re-billed and
        /// re-processed. Expected on turn 0 of the first run against a model; on any
        /// later turn it means something volatile reached the cached prefix.
        public var isColdCache: Bool { cacheReadTokens == 0 }
    }

    public let sessionID: String
    public let task: String
    public let turns: [Turn]

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
        /// The last point at which a request could have been sent.
        var requestSentAt: Date? = first.timestamp
        /// The response the tools now running are answering, and its index.
        var pendingResponse: (at: Date, turnIndex: Int)?
        /// Usage is noted just before the assistant entry it describes, so it is held
        /// until that entry arrives rather than guessing which turn it belongs to.
        var pendingUsage: Transcript.Entry?

        func closePendingTool(at boundary: Date) {
            guard let pending = pendingResponse, pending.turnIndex < turns.count else { return }
            let turn = turns[pending.turnIndex]
            turns[pending.turnIndex] = Turn(
                index: turn.index,
                modelSeconds: turn.modelSeconds,
                toolSeconds: boundary.timeIntervalSince(pending.at),
                inputTokens: turn.inputTokens,
                outputTokens: turn.outputTokens,
                cacheReadTokens: turn.cacheReadTokens
            )
            pendingResponse = nil
        }

        for entry in ordered.dropFirst() {
            switch entry.kind {
            case "usage":
                pendingUsage = entry

            case "assistant":
                // The round-trip ends here. Without a preceding user entry there is no
                // start to measure from, which happens only in a truncated record.
                guard let sentAt = requestSentAt else { break }
                let usage = pendingUsage?.payload
                turns.append(Turn(
                    index: turns.count,
                    modelSeconds: entry.timestamp.timeIntervalSince(sentAt),
                    toolSeconds: nil,
                    inputTokens: usage?["input_tokens"]?.doubleValue.map(Int.init) ?? 0,
                    outputTokens: usage?["output_tokens"]?.doubleValue.map(Int.init) ?? 0,
                    cacheReadTokens: usage?["cache_read_tokens"]?.doubleValue.map(Int.init) ?? 0
                ))
                pendingResponse = (at: entry.timestamp, turnIndex: turns.count - 1)
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
            task: firstTask(in: first),
            turns: turns,
            totalSeconds: last.timestamp.timeIntervalSince(first.timestamp)
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
    private static func firstTask(in entry: Transcript.Entry) -> String {
        let text = entry.payload["content"]?.arrayValue?
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: " ") ?? ""
        // The probe is `<environment>…</environment>\n\n<task>`. Splitting on the
        // closing tag is exact where searching for a blank line is not — a probe with
        // no display attached still ends with the tag.
        if let range = text.range(of: "</environment>") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Aggregates

    public var modelSeconds: Double { turns.reduce(0) { $0 + $1.modelSeconds } }
    public var toolSeconds: Double { turns.reduce(0) { $0 + ($1.toolSeconds ?? 0) } }

    /// Share of the run spent waiting on the API rather than on the machine.
    ///
    /// The number that decides which lever is worth pulling: streaming and model
    /// routing act on the first, tier routing and subprocess overhead on the second.
    public var modelShare: Double {
        let measured = modelSeconds + toolSeconds
        return measured > 0 ? modelSeconds / measured : 0
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

    /// A turn's time can hide a retry, and the transcript does not record one.
    ///
    /// `AnthropicClient` backs off and retries inside a single `send`, reporting it
    /// only to the observer — which draws to the terminal and is gone. So a 62-second
    /// turn and a 2-second turn that was retried twice behind a `Retry-After: 30` are
    /// the same reading here, and there is no way to tell them apart after the fact.
    /// Stated on the type because a measurement whose limits are only in someone's
    /// head gets quoted without them.
    public static let retriesAreInvisible = """
        note: a turn's time includes any retries the client made inside it, and \
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
        guard !turns.isEmpty else {
            return lines + ["  (no completed turns recorded)"]
        }
        lines.append("  turn    model    tools      in     out   cache")
        for turn in turns {
            // A cold turn is marked rather than left for the reader to spot in the
            // cache column, because it is the single largest explanation for an
            // outlier and the column it lives in is the last one.
            let cold = turn.isColdCache ? " cold" : ""
            lines.append(
                "  \(String(turn.index).leftPadded(4))  "
                + "\(seconds(turn.modelSeconds).leftPadded(7))  "
                + "\((turn.toolSeconds.map(seconds) ?? "—").leftPadded(7))  "
                + "\(String(turn.inputTokens).leftPadded(6))  "
                + "\(String(turn.outputTokens).leftPadded(6))  "
                + "\(String(turn.cacheReadTokens).leftPadded(6))\(cold)"
            )
        }
        lines.append(
            "  total \(seconds(totalSeconds)) — model \(percent(modelShare)) · "
            + "tools \(percent(1 - modelShare)) · cache hit \(percent(cacheHitRate))"
        )
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
        lines.append(String(
            format: "  model %.1fs (%d%%) · tools %.1fs (%d%%)",
            modelSeconds, Int((share * 100).rounded()),
            toolSeconds, Int(((1 - share) * 100).rounded())
        ))
        lines.append(String(
            format: "  median turn: model %.2fs · tools %.2fs",
            medianModelSeconds, medianToolSeconds
        ))
        lines.append("  \(LatencyReport.retriesAreInvisible)")
        return lines
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

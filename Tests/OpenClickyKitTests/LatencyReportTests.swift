import Testing
import Foundation
@testable import OpenClickyKit

/// Reading wall-clock time back out of a recorded session.
///
/// Every fixture here is synthetic. A test that measured a real run would be
/// measuring the machine it happens to be running on, and would fail on a slow CI box
/// for a reason that has nothing to do with the code — the same trap as a test that
/// assumes the real screen holds still.
@Suite("Latency report")
struct LatencyReportTests {

    /// Builds a session the way the loop writes one: user, then per turn a usage note,
    /// an assistant entry, and — unless it was the last — a user entry of tool results.
    private func entry(
        _ sequence: Int, _ kind: String, at offset: Double, payload: JSONValue = .object([:])
    ) -> Transcript.Entry {
        Transcript.Entry(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_000_000 + offset),
            kind: kind,
            payload: payload
        )
    }

    private func usage(input: Int, output: Int, cacheRead: Int) -> JSONValue {
        .object([
            "input_tokens": .number(Double(input)),
            "output_tokens": .number(Double(output)),
            "cache_read_tokens": .number(Double(cacheRead)),
        ])
    }

    private func userMessage(_ text: String) -> JSONValue {
        .object(["role": .string("user"), "content": .array([
            .object(["type": .string("text"), "text": .string(text)]),
        ])])
    }

    /// The two-turn shape both real recorded sessions have: one tool batch, then a
    /// closing turn that runs nothing.
    private var twoTurnSession: [Transcript.Entry] {
        [
            entry(0, "user", at: 0, payload: userMessage(
                "<environment>\ntime: now\n</environment>\n\nopen spotify"
            )),
            entry(1, "usage", at: 4.0, payload: usage(input: 489, output: 64, cacheRead: 0)),
            entry(2, "assistant", at: 4.0),
            entry(3, "user", at: 11.0, payload: userMessage("(tool results)")),
            entry(4, "usage", at: 14.5, payload: usage(input: 567, output: 30, cacheRead: 5099)),
            entry(5, "assistant", at: 14.5),
        ]
    }

    // MARK: - Derivation

    @Test("Model and tool time are attributed to the right turn")
    func attributesTimeCorrectly() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))

        #expect(report.turns.count == 2)
        // Turn 0: request sent at the user entry, response at the assistant entry.
        #expect(report.turns[0].modelSeconds == 4.0)
        // …then seven seconds of tools before the next request could be built.
        #expect(report.turns[0].toolSeconds == 7.0)
        // Turn 1: 14.5 - 11.0.
        #expect(report.turns[1].modelSeconds == 3.5)
        // The closing turn ran no tools at all, which is not the same as running them
        // in zero seconds — hence optional rather than 0.
        #expect(report.turns[1].toolSeconds == nil)
        #expect(report.totalSeconds == 14.5)
    }

    @Test("Usage is attached to the turn it describes")
    func attachesUsage() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(report.turns[0].inputTokens == 489)
        #expect(report.turns[0].cacheReadTokens == 0)
        #expect(report.turns[1].inputTokens == 567)
        #expect(report.turns[1].cacheReadTokens == 5099)
    }

    @Test("A turn that read no cached prefix is marked cold")
    func detectsColdCache() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(report.turns[0].isColdCache)
        #expect(!report.turns[1].isColdCache)
    }

    @Test("Entries are walked in sequence order, not timestamp order")
    func ordersBySequence() throws {
        // The transcript's own documentation is explicit that several entries a turn
        // share one millisecond stamp, so sorting by time genuinely reorders them.
        // Here every entry after the first shares a timestamp — sorting by time would
        // scramble the spine and mis-pair every turn.
        let flat = [
            entry(0, "user", at: 0, payload: userMessage("do the thing")),
            entry(1, "usage", at: 5, payload: usage(input: 10, output: 2, cacheRead: 1)),
            entry(2, "assistant", at: 5),
            entry(3, "user", at: 5, payload: userMessage("(results)")),
            entry(4, "usage", at: 5, payload: usage(input: 20, output: 4, cacheRead: 1)),
            entry(5, "assistant", at: 5),
        ]
        let shuffled = flat.reversed()
        let report = try #require(
            LatencyReport.derive(sessionID: "abc", entries: Array(shuffled))
        )
        #expect(report.turns.count == 2)
        #expect(report.turns[0].modelSeconds == 5)
        // Zero here is a real reading, not a missing one: nothing happened between
        // the assistant entry and the tool results in the same millisecond.
        #expect(report.turns[0].toolSeconds == 0)
        #expect(report.turns[1].modelSeconds == 0)
    }

    @Test("The environment probe is stripped from the task")
    func stripsProbe() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(report.task == "open spotify")
    }

    @Test("A task recorded without a probe is read whole")
    func toleratesMissingProbe() throws {
        let entries = [
            entry(0, "user", at: 0, payload: userMessage("open spotify")),
            entry(1, "usage", at: 1, payload: usage(input: 1, output: 1, cacheRead: 0)),
            entry(2, "assistant", at: 1),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.task == "open spotify")
    }

    @Test("Notes alongside the spine do not become turns")
    func ignoresNonSpineEntries() throws {
        // `denied`, `interrupted` and `truncated` are notes about a turn, not points
        // on it. Counting them would inflate the turn count and split one round-trip
        // into several.
        var entries = twoTurnSession
        entries.append(entry(6, "denied", at: 14.5))
        entries.append(entry(7, "interrupted", at: 14.6))
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns.count == 2)
    }

    @Test("An empty or headless record yields nothing rather than crashing")
    func toleratesEmptyRecord() {
        #expect(LatencyReport.derive(sessionID: "abc", entries: []) == nil)
    }

    @Test("A record truncated mid-turn keeps the turns it completed")
    func toleratesTruncatedRecord() throws {
        // A killed run leaves exactly this: a request sent and no response recorded.
        // It is the session someone most wants to measure, so it must not be refused.
        var entries = twoTurnSession
        entries.append(entry(6, "user", at: 20, payload: userMessage("(results)")))
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns.count == 2)
        #expect(report.turns[1].toolSeconds == 5.5)
    }

    // MARK: - Aggregates

    @Test("Model share separates waiting on the API from waiting on the machine")
    func computesModelShare() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        // 7.5s model, 7.0s tools.
        #expect(abs(report.modelSeconds - 7.5) < 0.001)
        #expect(abs(report.toolSeconds - 7.0) < 0.001)
        #expect(abs(report.modelShare - 7.5 / 14.5) < 0.001)
    }

    @Test("The median resists a cold-start outlier where a mean would not")
    func medianResistsOutliers() {
        // The real 0EBB2922 shape: one 62s cold turn among fast ones. The mean says a
        // turn takes 15s and no turn in the run took anything like that.
        let turns = [62.0, 4.0, 5.0, 6.0, 3.0].enumerated().map { index, value in
            LatencyReport.Turn(
                index: index, modelSeconds: value, toolSeconds: 1,
                inputTokens: 100, outputTokens: 10, cacheReadTokens: 0
            )
        }
        let benchmark = LatencyBenchmark(sessions: [
            LatencyReport(sessionID: "a", task: "t", turns: turns, totalSeconds: 80),
        ])
        #expect(benchmark.medianModelSeconds == 5.0)
        let mean = benchmark.modelSeconds / Double(turns.count)
        #expect(mean == 16.0)
    }

    @Test("An even number of turns takes the midpoint of the middle two")
    func medianOfEvenCount() {
        let turns = [2.0, 4.0, 6.0, 8.0].enumerated().map { index, value in
            LatencyReport.Turn(
                index: index, modelSeconds: value, toolSeconds: nil,
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0
            )
        }
        let benchmark = LatencyBenchmark(sessions: [
            LatencyReport(sessionID: "a", task: "t", turns: turns, totalSeconds: 20),
        ])
        #expect(benchmark.medianModelSeconds == 5.0)
    }

    @Test("Cache hit rate is computed from the record")
    func computesCacheHitRate() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        // 5099 cached against 1056 fresh input.
        #expect(abs(report.cacheHitRate - 5099.0 / (5099 + 1056)) < 0.001)
    }

    // MARK: - Rendering

    @Test("An empty benchmark says so rather than printing an empty table")
    func rendersEmptyBenchmark() {
        let lines = LatencyBenchmark(sessions: []).rendered()
        #expect(lines.count == 1)
        #expect(lines[0].contains("No recorded sessions"))
    }

    @Test("The rendered report carries the retry caveat")
    func rendersRetryCaveat() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        let lines = LatencyBenchmark(sessions: [report]).rendered()
        // A limit that lives only in a comment gets quoted without it.
        #expect(lines.contains { $0.contains("retries are not recorded") })
        #expect(lines.contains { $0.contains("cold") })
    }

    @Test("A session with no completed turns renders a reason, not a blank block")
    func rendersTurnlessSession() {
        let report = LatencyReport(sessionID: "abc", task: "t", turns: [], totalSeconds: 0)
        #expect(report.rendered().contains { $0.contains("no completed turns") })
    }

    @Test("The session count is grammatical")
    func pluralisesSessionCount() {
        // "1 sessions" is the same defect as "1 turns" and "one tiers", both already
        // fixed here once.
        let one = LatencyReport(sessionID: "a", task: "t", turns: [], totalSeconds: 0)
        let lines = LatencyBenchmark(sessions: [one]).rendered()
        #expect(lines.contains { $0.contains("ACROSS 1 session,") })
    }

    // MARK: - Gate accounting

    // `sandbox-exec` was measured at ~5ms of overhead and `pgrep -l Code` at ~25ms
    // end to end, against the 3.43s the record showed in that window. The difference
    // was a human reading a permission prompt. Reported together, the machine gets
    // credit for the user's reaction time and Tier 0 looks slow.

    /// The same two-turn session, with the gate noting a wait on the tool call.
    private func gatedSession(gateWait: Double) -> [Transcript.Entry] {
        [
            entry(0, "user", at: 0, payload: userMessage("open spotify")),
            entry(1, "usage", at: 4.0, payload: usage(input: 489, output: 64, cacheRead: 0)),
            entry(2, "assistant", at: 4.0),
            entry(3, "gate", at: 4.0, payload: .object([
                "tool": .string("shell"), "seconds": .number(gateWait),
            ])),
            entry(4, "user", at: 11.0, payload: userMessage("(tool results)")),
            entry(5, "usage", at: 14.5, payload: usage(input: 567, output: 30, cacheRead: 5099)),
            entry(6, "assistant", at: 14.5),
        ]
    }

    @Test("Time spent waiting on the user is not counted as tool time")
    func separatesGateWait() throws {
        let report = try #require(
            LatencyReport.derive(sessionID: "abc", entries: gatedSession(gateWait: 6.8))
        )
        #expect(report.hasGateAccounting)
        // The window was 7s; 6.8s of it was the prompt.
        #expect(abs((report.turns[0].toolSeconds ?? 0) - 0.2) < 0.001)
        #expect(report.turns[0].gateSeconds == 6.8)
        #expect(abs(report.toolSeconds - 0.2) < 0.001)
        #expect(report.gateSeconds == 6.8)
    }

    @Test("Several waits in one turn add up")
    func accumulatesGateWaitsWithinATurn() throws {
        // A turn can hold a batch and stop to ask on more than one of its calls.
        var entries = gatedSession(gateWait: 2.0)
        entries.insert(entry(4, "gate", at: 4.0, payload: .object([
            "tool": .string("shell"), "seconds": .number(3.0),
        ])), at: 4)
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns[0].gateSeconds == 5.0)
        #expect(abs((report.turns[0].toolSeconds ?? 0) - 2.0) < 0.001)
    }

    @Test("A wait longer than the window it sits in never yields a negative tool time")
    func clampsImpossibleGateWait() throws {
        // The gate measures with a monotonic clock and the transcript stamps with a
        // wall clock. An adjustment mid-prompt can make the recorded wait exceed the
        // window, and a negative duration in a report reads as a broken measurement.
        let report = try #require(
            LatencyReport.derive(sessionID: "abc", entries: gatedSession(gateWait: 99))
        )
        #expect(report.turns[0].toolSeconds == 0)
        #expect(report.turns[0].gateSeconds == 7.0)
    }

    @Test("A session recorded before gate timing says so rather than guessing")
    func flagsRecordsWithoutGateAccounting() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(!report.hasGateAccounting)
        // The whole window is still reported — just not as tool execution.
        #expect(report.turns[0].toolSeconds == 7.0)
        #expect(report.turns[0].gateSeconds == 0)
        let rendered = report.rendered()
        #expect(rendered.contains { $0.contains("tools†") })
        #expect(rendered.contains { $0.contains("predates gate timing") })
    }

    @Test("A gated session drops the caveat and shows the wait")
    func rendersGatedSessionWithoutCaveat() throws {
        let report = try #require(
            LatencyReport.derive(sessionID: "abc", entries: gatedSession(gateWait: 6.8))
        )
        let rendered = report.rendered()
        #expect(!rendered.contains { $0.contains("predates gate timing") })
        #expect(rendered.contains { $0.contains("gate") })
        #expect(rendered.contains { $0.contains("waited on you") })
    }

    @Test("One unaccounted session makes the whole aggregate unaccounted")
    func mixedBenchmarkKeepsTheCaveat() throws {
        // All, not any. A total that mixes an accounted session with an unaccounted
        // one is not a tool figure, and letting the majority settle it is how a
        // caveat disappears into an average.
        let gated = try #require(
            LatencyReport.derive(sessionID: "a", entries: gatedSession(gateWait: 6.8))
        )
        let ungated = try #require(
            LatencyReport.derive(sessionID: "b", entries: twoTurnSession)
        )
        #expect(!LatencyBenchmark(sessions: [gated, ungated]).hasGateAccounting)
        #expect(LatencyBenchmark(sessions: [gated]).hasGateAccounting)
        #expect(!LatencyBenchmark(sessions: []).hasGateAccounting)

        let lines = LatencyBenchmark(sessions: [gated, ungated]).rendered()
        #expect(lines.contains { $0.contains("predates gate timing") })
    }


    // MARK: - What produced the run

    // A recorded session said what it did and never what it was. Comparing planned
    // against unplanned, or Haiku against Opus, meant remembering which session was
    // which — so "measure before and after" rested on the measurer's memory.

    private func configuredSession(model: String, planner: String?) -> [Transcript.Entry] {
        let plannerField = planner.map { "\"\($0)\"" } ?? "null"
        let run = entry(0, "run", at: 0, payload: .object([
            "model": .string(model),
            "planner": planner.map { JSONValue.string($0) } ?? .null,
            "mode": .string("ask"),
            "max_tier": .number(3),
        ]))
        _ = plannerField
        return [run,
                entry(1, "user", at: 0, payload: userMessage("open spotify")),
                entry(2, "usage", at: 4, payload: usage(input: 10, output: 2, cacheRead: 1)),
                entry(3, "assistant", at: 4)]
    }

    @Test("A run reports the configuration that produced it")
    func readsTheConfiguration() throws {
        let report = try #require(LatencyReport.derive(
            sessionID: "abc", entries: configuredSession(model: "claude-haiku-4-5", planner: "claude-opus-5")
        ))
        let config = try #require(report.configuration)
        #expect(config.model == "claude-haiku-4-5")
        #expect(config.planner == "claude-opus-5")
        #expect(config.label.contains("planned by claude-opus-5"))
        #expect(report.rendered().contains { $0.contains("planned by claude-opus-5") })
    }

    @Test("An unplanned run says so by omission, not by claiming a planner")
    func unplannedConfigurationHasNoPlanner() throws {
        let report = try #require(LatencyReport.derive(
            sessionID: "abc", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))
        let config = try #require(report.configuration)
        #expect(config.planner == nil)
        #expect(!config.label.contains("planned by"))
    }

    @Test("A session recorded before runs described themselves has no configuration")
    func historicalSessionHasNoConfiguration() throws {
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(report.configuration == nil)
    }

    @Test("The same task run two ways is a comparison; one configuration is not")
    func comparesConfigurations() throws {
        // One configuration is a measurement. Two are a comparison, and only a
        // comparison can call a change an improvement.
        let planned = try #require(LatencyReport.derive(
            sessionID: "a", entries: configuredSession(model: "claude-haiku-4-5", planner: "claude-opus-5")
        ))
        let plain = try #require(LatencyReport.derive(
            sessionID: "b", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))

        #expect(LatencyBenchmark(sessions: [planned]).comparison().isEmpty)
        let both = LatencyBenchmark(sessions: [planned, plain]).comparison()
        #expect(both.contains { $0.contains("BY CONFIGURATION") })
        #expect(both.contains { $0.contains("planned by claude-opus-5") })
        #expect(both.filter { $0.contains("median turn") }.count == 2)
        // Both fixtures use the same task, so they are genuinely comparable.
        #expect(both.contains { $0.contains("open spotify") })
    }

    @Test("Different tasks under different configurations are not called a comparison")
    func refusesToCompareDifferentTasks() throws {
        // Grouping by configuration alone produced a table that looked like a
        // comparison and was not: two configurations over two different tasks differ
        // by the task as much as by the configuration, and the difference is
        // attributable to neither. Printing them near each other invites the
        // subtraction, which is worse than printing one number.
        var plannedEntries = configuredSession(model: "claude-haiku-4-5", planner: "claude-opus-5")
        plannedEntries[1] = entry(1, "user", at: 0, payload: userMessage("format the markdown"))
        let planned = try #require(LatencyReport.derive(sessionID: "a", entries: plannedEntries))
        let plain = try #require(LatencyReport.derive(
            sessionID: "b", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))

        let lines = LatencyBenchmark(sessions: [planned, plain]).comparison()
        #expect(lines.contains { $0.contains("no task was run") })
        #expect(lines.contains { $0.contains("Nothing here is comparable") })
        // Nothing that reads as a per-configuration result.
        #expect(!lines.contains { $0.contains("median turn") })
    }

    @Test("A task tried only one way is named as uncompared, not dropped")
    func namesUncomparedRuns() throws {
        var otherEntries = configuredSession(model: "claude-haiku-4-5", planner: nil)
        otherEntries[1] = entry(1, "user", at: 0, payload: userMessage("something else"))
        let other = try #require(LatencyReport.derive(sessionID: "c", entries: otherEntries))
        let planned = try #require(LatencyReport.derive(
            sessionID: "a", entries: configuredSession(model: "claude-haiku-4-5", planner: "claude-opus-5")
        ))
        let plain = try #require(LatencyReport.derive(
            sessionID: "b", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))

        let lines = LatencyBenchmark(sessions: [planned, plain, other]).comparison()
        #expect(lines.contains { $0.contains("open spotify") })
        #expect(lines.contains { $0.contains("tried only one way") })
    }

    @Test("Sessions with no configuration are named, not silently dropped")
    func unlabelledSessionsAreDeclared() throws {
        // A comparison quietly computed over half the sessions is worse than one that
        // says which half it used.
        let planned = try #require(LatencyReport.derive(
            sessionID: "a", entries: configuredSession(model: "claude-haiku-4-5", planner: "claude-opus-5")
        ))
        let plain = try #require(LatencyReport.derive(
            sessionID: "b", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))
        let old = try #require(LatencyReport.derive(sessionID: "c", entries: twoTurnSession))

        let lines = LatencyBenchmark(sessions: [planned, plain, old]).comparison()
        #expect(lines.contains { $0.contains("1 older session") })
    }


    // MARK: - Which tiers a run actually used

    // The ladder's central claim is that a task answered by `shell` and one answered
    // by six screenshots differ by two orders of magnitude. The prompt says it and the
    // costs are documented, but nothing measured whether the model complies — the only
    // evidence a run stayed low was the bill.

    private func assistantWithTools(_ names: [String], sequence: Int, at offset: Double)
        -> Transcript.Entry {
        let blocks = names.map { name in
            JSONValue.object([
                "type": .string("tool_use"), "id": .string("t\(name)"),
                "name": .string(name), "input": .object([:]),
            ])
        }
        return entry(sequence, "assistant", at: offset, payload: .object([
            "role": .string("assistant"), "content": .array(blocks),
        ]))
    }

    @Test("Tool calls are counted against the tier they belong to")
    func countsTiers() throws {
        let entries = [
            entry(0, "user", at: 0, payload: userMessage("do the thing")),
            entry(1, "usage", at: 1, payload: usage(input: 1, output: 1, cacheRead: 0)),
            assistantWithTools(["shell", "read_file", "ax_press", "click"], sequence: 2, at: 1),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.tierCounts[.shell] == 2)
        #expect(report.tierCounts[.accessibility] == 1)
        #expect(report.tierCounts[.pixels] == 1)
        #expect(report.tierCounts[.script] == nil)
        #expect(report.toolCalls == 4)
        #expect(report.tierSummary == "T0×2 T2×1 T3×1")
    }

    @Test("Ladder discipline is the share of calls that avoided pixels")
    func measuresLadderDiscipline() throws {
        let entries = [
            entry(0, "user", at: 0, payload: userMessage("do the thing")),
            entry(1, "usage", at: 1, payload: usage(input: 1, output: 1, cacheRead: 0)),
            assistantWithTools(["shell", "shell", "shell", "screenshot"], sequence: 2, at: 1),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.ladderDiscipline == 0.75)
        #expect(report.rendered().contains { $0.contains("75% below pixels") })
    }

    @Test("A run that called no tools reports no discipline rather than a perfect one")
    func noToolCallsMeansNoDiscipline() throws {
        // 100% for a run that did nothing would flatter exactly the runs this project
        // spent the session learning to distrust.
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: twoTurnSession))
        #expect(report.toolCalls == 0)
        #expect(report.ladderDiscipline == nil)
        #expect(!report.rendered().contains { $0.contains("below pixels") })
    }

    @Test("A tool name this build does not know is not given a made-up tier")
    func unknownToolIsNotCounted() throws {
        // A session recorded by an older or newer binary. Guessing would put an
        // invented number in a report about tier discipline.
        let entries = [
            entry(0, "user", at: 0, payload: userMessage("do the thing")),
            entry(1, "usage", at: 1, payload: usage(input: 1, output: 1, cacheRead: 0)),
            assistantWithTools(["shell", "teleport"], sequence: 2, at: 1),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.toolCalls == 1)
        #expect(Tier.forToolNamed("teleport") == nil)
    }

    @Test("Every shipped tool maps to the tier its registry gives it")
    func tierLookupAgreesWithTheRegistry() {
        // Two places that must not disagree: the lookup a report uses on a tool name,
        // and the tier the tool itself declares.
        for tool in ToolRegistry.standard(maxTier: .pixels).ordered {
            #expect(Tier.forToolNamed(tool.name) == tool.tier, "\(tool.name)")
        }
    }


    // MARK: - Retries

    // Until they were recorded, a turn's time could not be read as response time: the
    // 62-second cold turn in the wild is indistinguishable from a fast response behind
    // a `Retry-After: 60`. Every report had to carry a caveat saying so.

    @Test("A backoff is attributed to the turn it happened in")
    func attributesRetriesToTheTurn() throws {
        let entries = [
            entry(0, "run", at: 0, payload: .object([
                "model": .string("claude-haiku-4-5"), "mode": .string("ask"),
            ])),
            entry(1, "user", at: 0, payload: userMessage("open spotify")),
            entry(2, "retry", at: 1, payload: .object([
                "attempt": .number(1), "of": .number(3),
                "delay_seconds": .number(30), "reason": .string("rate limited"),
            ])),
            entry(3, "retry", at: 31, payload: .object([
                "attempt": .number(2), "of": .number(3),
                "delay_seconds": .number(30), "reason": .string("rate limited"),
            ])),
            entry(4, "usage", at: 62, payload: usage(input: 489, output: 64, cacheRead: 0)),
            entry(5, "assistant", at: 62),
            entry(6, "user", at: 62, payload: userMessage("(results)")),
            entry(7, "usage", at: 66, payload: usage(input: 500, output: 20, cacheRead: 5099)),
            entry(8, "assistant", at: 66),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        // The 62-second turn is now explained: 60s of it was backoff.
        #expect(report.turns[0].retries == 2)
        #expect(report.turns[0].retrySeconds == 60)
        #expect(report.turns[0].modelSeconds == 62)
        // …and the next turn does not inherit them.
        #expect(report.turns[1].retries == 0)
        #expect(report.turns[1].retrySeconds == 0)
        #expect(report.retries == 2)
    }

    @Test("A turn's retries survive the tool window being closed")
    func retriesSurviveTheToolClose() throws {
        // `closePendingTool` rebuilds the turn to subtract gate time; a field it forgot
        // to carry would be silently zeroed on every turn that ran a tool.
        let entries = [
            entry(0, "run", at: 0, payload: .object([
                "model": .string("claude-haiku-4-5"), "mode": .string("ask"),
            ])),
            entry(1, "user", at: 0, payload: userMessage("open spotify")),
            entry(2, "retry", at: 1, payload: .object([
                "attempt": .number(1), "of": .number(3),
                "delay_seconds": .number(10), "reason": .string("rate limited"),
            ])),
            entry(3, "usage", at: 12, payload: usage(input: 1, output: 1, cacheRead: 0)),
            entry(4, "assistant", at: 12),
            entry(5, "gate", at: 12, payload: .object([
                "tool": .string("shell"), "seconds": .number(3),
            ])),
            entry(6, "user", at: 16, payload: userMessage("(results)")),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns[0].retries == 1)
        #expect(report.turns[0].retrySeconds == 10)
        #expect(report.turns[0].gateSeconds == 3)
    }

    @Test("The retry caveat is dropped once a session can record them")
    func caveatOnlyWhereItIsStillTrue() throws {
        // A caveat printed under data that answers it teaches the reader that caveats
        // here are boilerplate.
        let modern = try #require(LatencyReport.derive(
            sessionID: "a", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))
        #expect(modern.hasRetryAccounting)
        #expect(!modern.rendered().contains { $0.contains("predates retry recording") })
        #expect(!LatencyBenchmark(sessions: [modern]).rendered()
            .contains { $0.contains("retries are not recorded") })

        let old = try #require(LatencyReport.derive(sessionID: "b", entries: twoTurnSession))
        #expect(!old.hasRetryAccounting)
        #expect(old.rendered().contains { $0.contains("predates retry recording") })
        #expect(LatencyBenchmark(sessions: [old]).rendered()
            .contains { $0.contains("retries are not recorded") })
    }

    @Test("One session without retry accounting marks the whole aggregate")
    func mixedRetryAccountingKeepsTheCaveat() throws {
        let modern = try #require(LatencyReport.derive(
            sessionID: "a", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))
        let old = try #require(LatencyReport.derive(sessionID: "b", entries: twoTurnSession))
        #expect(!LatencyBenchmark(sessions: [modern, old]).hasRetryAccounting)
    }

    @Test("Retries are shown on the row they belong to")
    func rendersRetriesOnTheRow() throws {
        let entries = [
            entry(0, "run", at: 0, payload: .object([
                "model": .string("claude-haiku-4-5"), "mode": .string("ask"),
            ])),
            entry(1, "user", at: 0, payload: userMessage("open spotify")),
            entry(2, "retry", at: 1, payload: .object([
                "attempt": .number(1), "of": .number(3),
                "delay_seconds": .number(30), "reason": .string("rate limited"),
            ])),
            entry(3, "usage", at: 62, payload: usage(input: 1, output: 1, cacheRead: 0)),
            entry(4, "assistant", at: 62),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.rendered().contains { $0.contains("1 retry waiting 30.00s") })
        // Healthy turns carry nothing, so the column cannot train the eye to skip it.
        let clean = try #require(LatencyReport.derive(
            sessionID: "d", entries: configuredSession(model: "claude-haiku-4-5", planner: nil)
        ))
        #expect(!clean.rendered().contains { $0.contains("retr") })
    }


    @Test("A planned run's task is what was asked, not the plan appended to it")
    func planIsNotPartOfTheTask() throws {
        // Found in a live listing: the plan block was being shown as the task. Worse
        // than ugly — `comparison` matches runs by task text, so a planned run whose
        // task carried the plan could never match its unplanned twin, and the A/B the
        // flag exists to enable was impossible by construction.
        let opening = "<environment>\ntime: x\n</environment>\n\ncount the files in /tmp"
            + "\n\n" + Planner.brief("1. Tier 0 shell: ls /tmp | wc -l")
        let entries = [
            entry(0, "user", at: 0, payload: userMessage(opening)),
            entry(1, "usage", at: 2, payload: usage(input: 10, output: 2, cacheRead: 0)),
            entry(2, "assistant", at: 2),
        ]
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.task == "count the files in /tmp")
        #expect(!report.task.contains("<plan>"))
    }

    @Test("A planned and an unplanned run of one task are comparable")
    func plannedAndUnplannedMatchOnTask() throws {
        // The consequence that matters. These must land in the same group.
        func session(id: String, planner: String?, planned: Bool) throws -> LatencyReport {
            var opening = "<environment>\ntime: x\n</environment>\n\ncount the files in /tmp"
            if planned { opening += "\n\n" + Planner.brief("1. shell") }
            let entries = [
                entry(0, "run", at: 0, payload: .object([
                    "model": .string("deepseek-r1:7b"),
                    "planner": planner.map { JSONValue.string($0) } ?? .null,
                    "mode": .string("read-only"),
                ])),
                entry(1, "user", at: 0, payload: userMessage(opening)),
                entry(2, "usage", at: 2, payload: usage(input: 10, output: 2, cacheRead: 0)),
                entry(3, "assistant", at: 2),
            ]
            return try #require(LatencyReport.derive(sessionID: id, entries: entries))
        }
        let planned = try session(id: "a", planner: "deepseek-r1:7b", planned: true)
        let plain = try session(id: "b", planner: nil, planned: false)
        #expect(planned.task == plain.task)

        let lines = LatencyBenchmark(sessions: [planned, plain]).comparison()
        #expect(lines.contains { $0.contains("count the files in /tmp") })
        #expect(!lines.contains { $0.contains("no task was run") })
        #expect(lines.filter { $0.contains("median turn") }.count == 2)
    }


    // MARK: - Time to first token

    // `modelSeconds` conflates two problems with opposite fixes. Measured live against
    // deepseek-r1:7b: a 31.71s turn that was 22.70s waiting and 9.01s generating —
    // 71% of it before the model said anything. A terser prompt would barely touch
    // that run; nothing in the record could previously say so.

    private func streamedSession(
        modelSeconds: Double, firstToken: Double?
    ) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = [
            entry(0, "run", at: 0, payload: .object([
                "model": .string("deepseek-r1:7b"), "mode": .string("read-only"),
            ])),
            entry(1, "user", at: 0, payload: userMessage("count the files in /tmp")),
        ]
        if let firstToken {
            entries.append(entry(2, "first_token", at: firstToken,
                                 payload: .object(["seconds": .number(firstToken)])))
        }
        entries.append(entry(3, "usage", at: modelSeconds,
                             payload: usage(input: 656, output: 616, cacheRead: 0)))
        entries.append(entry(4, "assistant", at: modelSeconds))
        return entries
    }

    @Test("A streamed turn splits into waiting and generating")
    func splitsWaitFromGeneration() throws {
        let report = try #require(LatencyReport.derive(
            sessionID: "abc", entries: streamedSession(modelSeconds: 31.71, firstToken: 22.70)
        ))
        let turn = report.turns[0]
        #expect(turn.timeToFirstToken == 22.70)
        #expect(abs((turn.generationSeconds ?? 0) - 9.01) < 0.001)
        #expect(report.rendered().contains { $0.contains("to first token") })
    }

    @Test("A buffered turn has no such moment and claims none")
    func bufferedTurnHasNoFirstToken() throws {
        let report = try #require(LatencyReport.derive(
            sessionID: "abc", entries: streamedSession(modelSeconds: 4.0, firstToken: nil)
        ))
        #expect(report.turns[0].timeToFirstToken == nil)
        #expect(report.turns[0].generationSeconds == nil)
        // And the row says nothing rather than implying instant generation.
        #expect(!report.rendered().contains { $0.contains("to first token") })
    }

    @Test("A first token later than the turn never yields negative generation")
    func generationNeverGoesNegative() throws {
        // The note is written by the CLI from a monotonic clock and the turn is
        // derived from wall-clock stamps; they can disagree at the edges.
        let report = try #require(LatencyReport.derive(
            sessionID: "abc", entries: streamedSession(modelSeconds: 5, firstToken: 9)
        ))
        #expect(report.turns[0].generationSeconds == 0)
    }

    @Test("The wait does not leak into the following turn")
    func firstTokenDoesNotLeak() throws {
        var entries = streamedSession(modelSeconds: 10, firstToken: 3)
        entries.append(entry(5, "user", at: 10, payload: userMessage("(results)")))
        entries.append(entry(6, "usage", at: 14, payload: usage(input: 10, output: 2, cacheRead: 1)))
        entries.append(entry(7, "assistant", at: 14))
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns[0].timeToFirstToken == 3)
        #expect(report.turns[1].timeToFirstToken == nil)
    }

    @Test("The wait survives the tool window being closed")
    func firstTokenSurvivesToolClose() throws {
        // `closePendingTool` rebuilds the turn; a field it forgets is silently zeroed
        // on every turn that ran a tool. Retries were caught this way once already.
        var entries = streamedSession(modelSeconds: 10, firstToken: 3)
        entries.append(entry(5, "user", at: 14, payload: userMessage("(results)")))
        let report = try #require(LatencyReport.derive(sessionID: "abc", entries: entries))
        #expect(report.turns[0].timeToFirstToken == 3)
        #expect(report.turns[0].toolSeconds == 4)
    }

    @Test("The median covers streamed turns only, and is absent without them")
    func medianOverStreamedTurnsOnly() throws {
        // Pooling with buffered turns would average a number against its own absence.
        let streamed = try #require(LatencyReport.derive(
            sessionID: "a", entries: streamedSession(modelSeconds: 31.71, firstToken: 22.70)
        ))
        let buffered = try #require(LatencyReport.derive(
            sessionID: "b", entries: streamedSession(modelSeconds: 4, firstToken: nil)
        ))
        #expect(LatencyBenchmark(sessions: [streamed, buffered]).medianTimeToFirstToken == 22.70)
        #expect(LatencyBenchmark(sessions: [buffered]).medianTimeToFirstToken == nil)
        #expect(LatencyBenchmark(sessions: [buffered]).rendered()
            .allSatisfy { !$0.contains("first token") })
    }

}

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
}

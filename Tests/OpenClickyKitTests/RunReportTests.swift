import Testing
import Foundation
@testable import OpenClickyKit

/// The run display is the only view a person has of what the agent is doing to their
/// machine. Nothing could render it until it moved out of the CLI, and rendering a
/// whole run immediately showed two defects that no test would have caught.
@Suite("Run display")
struct RunReportTests {

    private func usage(input: Int, output: Int, cached: Int = 0) -> Wire.Usage {
        try! JSONDecoder().decode(Wire.Usage.self, from: Data("""
        {"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cached)}
        """.utf8))
    }

    private func render(_ events: [AgentLoop.Event], interactive: Bool = true) -> [RunReport.Line] {
        var report = RunReport(isInteractive: interactive)
        return events.flatMap { report.lines(for: $0) }
    }

    /// `Int.formatted()` uses the machine's separator, so 4,200 tokens rendered as
    /// "4.200" on this machine — which reads as four-point-two, in the one place the
    /// number has to be unambiguous.
    @Test("Token counts read the same in every locale", arguments: [
        (0, "0"), (90, "90"), (999, "999"), (1_000, "1,000"),
        (4_200, "4,200"), (15_000, "15,000"), (1_234_567, "1,234,567"),
    ])
    func tokenCountsAreLocaleIndependent(pair: (Int, String)) {
        #expect(CostMeter.grouped(pair.0) == pair.1)
    }

    @Test("A cost line never renders a count as a decimal")
    func costLineIsUnambiguous() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 4_200, output: 90))
        let summary = meter.summary

        #expect(summary.contains("4,200 in"))
        #expect(!summary.contains("4.200"), "reads as 4.2: \(summary)")
    }

    /// A tool result with a newline left its second line unindented and unmarked,
    /// among the agent's own words.
    @Test("Every line of the display is a single line")
    func linesAreSingleLines() {
        let lines = render([
            .toolStarted(name: "shell", tier: .shell, summary: "ls -la"),
            .toolFinished(name: "shell", ok: true, detail: "one ⏎ two ⏎ three"),
            .toolDenied(name: "write_file", reason: "The user declined this action."),
            .toolSkipped(name: "shell"),
            .interrupted,
        ])
        for line in lines {
            #expect(!line.text.contains("\n"), "wrapped: \(line.text)")
        }
    }

    // MARK: - What the user sees

    @Test("A failure is marked as one, and a success as one")
    func outcomesAreDistinguishable() {
        let ok = render([.toolFinished(name: "shell", ok: true, detail: "done")])
        let bad = render([.toolFinished(name: "shell", ok: false, detail: "no such file")])

        #expect(ok.first?.emphasis == .success)
        #expect(bad.first?.emphasis == .failure)
        #expect(render([.toolDenied(name: "shell", reason: "declined")]).first?.emphasis == .failure)
    }

    /// A stop the user asked for must be visible; it is the feedback that Escape
    /// worked, on a tool that is moving the pointer.
    @Test("An interruption is surfaced prominently")
    func interruptionIsProminent() {
        let lines = render([.interrupted])
        #expect(lines.count == 1)
        #expect(lines[0].emphasis == .warning)
        #expect(lines[0].text.contains("stopped"))
    }

    @Test("The agent's own words are not dimmed into the noise")
    func speechIsDistinct() {
        let lines = render([.assistantText("Your Downloads folder is 1.6 GB.")])
        #expect(lines.contains { $0.emphasis == .speech && $0.text.contains("1.6 GB") })
    }

    /// A cold cache over several turns means something volatile reached the cached
    /// prefix and the whole prompt is being re-billed. It is worth interrupting for.
    @Test("A cold cache is warned about at the end of a run")
    func coldCacheIsWarned() {
        var cold = CostMeter(model: "claude-opus-5")
        cold.record(usage(input: 4_000, output: 100))
        cold.record(usage(input: 4_000, output: 100))

        let lines = render([.cost(cold), .finished(reason: "end_turn")])
        #expect(lines.contains { $0.emphasis == .warning && $0.text.contains("cache hit rate") })
    }

    @Test("A warm cache is not warned about")
    func warmCacheIsQuiet() {
        var warm = CostMeter(model: "claude-opus-5")
        warm.record(usage(input: 200, output: 100, cached: 4_000))
        warm.record(usage(input: 200, output: 100, cached: 4_000))

        let lines = render([.cost(warm), .finished(reason: "end_turn")])
        #expect(!lines.contains { $0.text.contains("cache hit rate") })
    }

    @Test("A single turn is never warned about, however cold")
    func singleTurnIsNotWarned() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 4_000, output: 100))
        let lines = render([.cost(meter), .finished(reason: "end_turn")])
        #expect(!lines.contains { $0.text.contains("cache hit rate") },
                "one turn has nothing to have cached yet")
    }

    /// Progress chatter belongs on a terminal that can overwrite it, not in a log.
    @Test("Non-interactive output drops the progress noise")
    func nonInteractiveIsQuieter() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 100, output: 10))

        let piped = render([.thinking, .cost(meter),
                            .assistantText("Done.")], interactive: false)
        #expect(!piped.contains { $0.text.contains("thinking") })
        #expect(piped.contains { $0.emphasis == .speech })
    }

    @Test("The closing summary still reports cost when piped")
    func finalSummarySurvivesPiping() {
        var meter = CostMeter(model: "claude-opus-5")
        meter.record(usage(input: 100, output: 10))
        let lines = render([.cost(meter), .finished(reason: "end_turn")], interactive: false)
        #expect(lines.contains { $0.text.contains("$") }, "the total should survive")
    }
}

import Testing
import Foundation
@testable import OpenClickyKit

/// `--mode` and `--max-tier` decide whether the agent asks before acting and whether
/// it can see the screen at all. Both lived in `main` where no test could reach them,
/// so a flag silently ignored would have run at the default while the user believed
/// they had restricted it.
@Suite("Command line invocation")
struct InvocationTests {

    private func parse(_ arguments: String...) throws -> Invocation {
        switch Invocation.parse(arguments) {
        case let .success(invocation): return invocation
        case let .failure(error): throw error
        }
    }

    private func failure(_ arguments: String...) -> Invocation.ParseError? {
        if case let .failure(error) = Invocation.parse(arguments) { return error }
        return nil
    }

    // MARK: - Defaults

    /// Every default that decides a safety question falls on the cautious side.
    @Test("The defaults ask before acting and confine the shell")
    func defaultsAreCautious() throws {
        let invocation = try parse("do something")
        #expect(invocation.mode == .ask, "the default must prompt")
        #expect(invocation.sandbox == .enabled, "the shell must be confined by default")
        // The literal, not `DefaultModel.id`: this pins the choice of a cheap model
        // as a decision, so changing it has to be deliberate rather than incidental.
        #expect(invocation.model == "claude-haiku-4-5-20251001")
        #expect(invocation.effort == "high", "computer use is measurably better here")
    }

    // MARK: - Commands

    @Test("A bare task is a run")
    func bareTaskRuns() throws {
        #expect(try parse("what is my disk usage").command == .run(task: "what is my disk usage"))
    }

    @Test("Words are rejoined into one task")
    func wordsRejoin() throws {
        #expect(try parse("open", "the", "repo").command == .run(task: "open the repo"))
    }

    @Test("Subcommands and help are recognised", arguments: [
        (["auth"], Invocation.Command.auth),
        (["doctor"], .doctor),
        (["bench"], .bench),
        (["--help"], .help),
        (["-h"], .help),
        ([], .help),
    ])
    func subcommands(scenario: ([String], Invocation.Command)) {
        guard case let .success(invocation) = Invocation.parse(scenario.0) else {
            Issue.record("failed to parse \(scenario.0)")
            return
        }
        #expect(invocation.command == scenario.1)
    }

    // MARK: - Staying open

    // Opt-in, and it has to stay opt-in: `openclicky "<task>"` exits 2 when it did not
    // finish and scripts chain off that, so a default that waited for a prompt would
    // hang every one of them. These pin both halves — the flag works, and its absence
    // changes nothing.

    @Test("--interactive opens a session, in either spelling", arguments: ["--interactive", "-i"])
    func interactiveParses(flag: String) throws {
        #expect(try parse(flag, "open my notes").command == .interactive(task: "open my notes"))
    }

    /// The one thing `.run` cannot express. `openclicky -i` with nothing after it goes
    /// straight to the prompt; `openclicky` with nothing after it is a plea for help.
    @Test("A task is optional with --interactive and absent without it", arguments: ["--interactive", "-i"])
    func interactiveMakesTheTaskOptional(flag: String) throws {
        #expect(try parse(flag).command == .interactive(task: nil))
        #expect(try parse().command == .help, "a bare invocation must still print the help")
    }

    @Test("Without the flag a task is still a one-shot run")
    func oneShotIsUnchanged() throws {
        #expect(try parse("open my notes").command == .run(task: "open my notes"))
    }

    @Test("--interactive combines with the other flags")
    func interactiveCombinesWithFlags() throws {
        let invocation = try parse("-i", "--mode", "auto", "--max-tier", "1", "check my mail")
        #expect(invocation.command == .interactive(task: "check my mail"))
        #expect(invocation.mode == .auto)
        #expect(invocation.maxTier == .script)
    }

    /// Refused rather than ignored, which is this parser's whole discipline: a flag
    /// accepted and then silently dropped runs a different program than the one asked
    /// for. There is nothing `openclicky doctor -i` could sensibly mean.
    @Test("--interactive on a subcommand is an error, not a no-op",
          arguments: [["doctor", "-i"], ["auth", "--interactive"], ["bench", "-i"]])
    func interactiveRejectsASubcommand(arguments: [String]) {
        guard case let .failure(error) = Invocation.parse(arguments) else {
            Issue.record("\(arguments) was accepted")
            return
        }
        #expect(error.message.contains("--interactive"))
    }

    @Test("Flags may precede the task")
    func flagsBeforeTask() throws {
        let invocation = try parse("--mode", "auto", "--max-tier", "1", "check my mail")
        #expect(invocation.mode == .auto)
        #expect(invocation.maxTier == .script)
        #expect(invocation.command == .run(task: "check my mail"))
    }

    // MARK: - The safety flags

    @Test("Every permission mode is selectable", arguments: PermissionMode.allCases)
    func everyModeParses(mode: PermissionMode) throws {
        #expect(try parse("--mode", mode.rawValue, "task").mode == mode)
    }

    /// The ceiling has to be a ceiling: a capped tool must be absent from the
    /// registry, not merely discouraged, or the model can still reach it.
    @Test("A tier cap removes the tools above it", arguments: [
        (0, ["shell", "read_file", "write_file"]),
        (1, ["app_script", "run_shortcut"]),
        (2, ["ax_capture", "ax_press", "ax_set_value"]),
    ])
    func tierCapRemovesHigherTools(scenario: (Int, [String])) throws {
        let invocation = try parse("--max-tier", String(scenario.0), "task")
        let registry = invocation.registry

        for name in scenario.1 {
            #expect(registry[name] != nil, "\(name) belongs at or below tier \(scenario.0)")
        }
        for name in ["screenshot", "zoom", "click", "type", "key"] where scenario.0 < 3 {
            #expect(registry[name] == nil, "\(name) is above tier \(scenario.0) and must be absent")
        }
        #expect(registry.ordered.allSatisfy { $0.tier.rawValue <= scenario.0 })
    }

    @Test("--max-tier 1 cannot see the screen")
    func tierOneCannotSeeTheScreen() throws {
        let registry = try parse("--max-tier", "1", "task").registry
        #expect(registry["screenshot"] == nil)
        #expect(registry["ax_capture"] == nil)
        #expect(registry.maxTier == .script)
    }

    @Test("The default permits every tier")
    func defaultPermitsEverything() throws {
        let registry = try parse("task").registry
        #expect(registry.ordered.count == 17)
        #expect(registry.maxTier == .pixels)
    }

    @Test("--no-sandbox is the only way to unconfine the shell")
    func sandboxIsOptOut() throws {
        #expect(try parse("task").sandbox == .enabled)
        #expect(try parse("--no-sandbox", "task").sandbox == .disabled)
    }

    // MARK: - Rejection

    /// Silently ignoring an unrecognised value would run at the default while the
    /// user believed they had restricted it — the one mistake this must never make.
    @Test("Unrecognised values are refused rather than defaulted", arguments: [
        ["--mode", "yolo", "task"],
        ["--max-tier", "9", "task"],
        ["--max-tier", "-1", "task"],
        ["--max-tier", "two", "task"],
        ["--effort", "extreme", "task"],
        ["--max-turns", "0", "task"],
        ["--max-turns", "-5", "task"],
        ["--max-turns", "many", "task"],
        ["--bogus", "task"],
    ])
    func badValuesAreRefused(arguments: [String]) {
        guard case .failure = Invocation.parse(arguments) else {
            Issue.record("\(arguments) should not have parsed")
            return
        }
    }

    /// A flag whose value is missing must not swallow the next flag and leave the
    /// user with settings they did not ask for.
    @Test("A flag with a missing value does not consume the next flag")
    func missingValuesDoNotEatFlags() {
        #expect(failure("--mode", "--max-tier", "1", "task") != nil)
        #expect(failure("--model") != nil)
        #expect(failure("--effort") != nil)
    }

    @Test("The error names the offending flag and its valid values")
    func errorsAreInstructive() {
        let mode = failure("--mode", "yolo", "task")
        #expect(mode?.message.contains("read-only") == true)
        #expect(mode?.message.contains("bypass") == true)

        let tier = failure("--max-tier", "9", "task")
        #expect(tier?.message.contains("shell") == true)
        #expect(tier?.message.contains("pixels") == true)

        #expect(failure("--bogus", "task")?.message.contains("--bogus") == true)
    }

    // MARK: - Loop configuration

    @Test("The loop configuration reflects the flags")
    func loopConfigurationCarriesTheFlags() throws {
        let configuration = try parse(
            "--model", "claude-sonnet-5", "--effort", "low", "--max-turns", "7", "task"
        ).loopConfiguration

        #expect(configuration.model == "claude-sonnet-5")
        #expect(configuration.effort == "low")
        #expect(configuration.maxTurns == 7)
    }

    // MARK: - One tool list

    /// The CLI built its tool list in `Invocation` and the menu bar app built its own
    /// in `AppDelegate`. They agreed, but nothing made them: a tool added to one and
    /// forgotten in the other would simply be absent from that surface, with no error
    /// anywhere and no test that could notice.
    @Test("The standard registry is what an invocation uses")
    func invocationUsesTheStandardRegistry() {
        let fromInvocation = Invocation().registry.ordered.map(\.name)
        let fromFactory = ToolRegistry.standard().ordered.map(\.name)
        #expect(fromInvocation == fromFactory)
        #expect(fromInvocation.count == 17, "a tool was added or lost")
    }

    /// The parameters are exactly what differs between the two callers, so each must
    /// actually do something.
    @Test("The factory honours its tier cap", arguments: [
        (Tier.shell, 4), (.script, 6), (.accessibility, 9), (.pixels, 17),
    ])
    func factoryHonoursTheCap(pair: (Tier, Int)) {
        let registry = ToolRegistry.standard(maxTier: pair.0)
        #expect(registry.ordered.count == pair.1)
        #expect(registry.ordered.allSatisfy { $0.tier <= pair.0 })
    }

    @Test("The factory passes the sandbox through to shell")
    func factoryPassesTheSandbox() throws {
        let confined = try #require(ToolRegistry.standard(sandbox: .enabled)["shell"])
        let open = try #require(ToolRegistry.standard(sandbox: .disabled)["shell"])
        #expect(confined.description.contains("confined by `sandbox-exec`"))
        #expect(open.description.contains("**not** confined"))
    }

    /// The app passes its own bundle so the agent does not photograph its own overlay.
    @Test("The factory passes excluded bundles through to screenshot")
    func factoryPassesExclusions() throws {
        let tool = ToolRegistry.standard(excludedBundleIDs: ["com.example.overlay"])["screenshot"]
        let screenshot = try #require(tool as? ScreenshotTool)
        #expect(screenshot.excludedBundleIDs == ["com.example.overlay"])
    }

    /// Seven tools call `Verified.act`, and every one of them has to know which
    /// surfaces belong to the agent — a tool that missed the parameter would keep
    /// scoring its own terminal's scrollback as proof that a keystroke landed.
    @Test("The factory passes self bundles through to every action tool")
    func factoryPassesSelfBundles() throws {
        let registry = ToolRegistry.standard(selfBundleIDs: ["com.apple.Terminal"])
        let expected = ["com.apple.Terminal"]
        #expect((registry["ax_press"] as? AXPressTool)?.selfBundleIDs == expected)
        #expect((registry["ax_set_value"] as? AXSetValueTool)?.selfBundleIDs == expected)
        #expect((registry["click"] as? ClickTool)?.selfBundleIDs == expected)
        #expect((registry["drag"] as? DragTool)?.selfBundleIDs == expected)
        #expect((registry["type"] as? TypeTool)?.selfBundleIDs == expected)
        #expect((registry["key"] as? KeyTool)?.selfBundleIDs == expected)
        #expect((registry["scroll"] as? ScrollTool)?.selfBundleIDs == expected)
    }

    /// The CLI's host terminal only helps if it survives the trip from the executable
    /// into the tools; `registry` is the one join between them.
    @Test("An invocation's self bundles reach its registry")
    func invocationCarriesSelfBundles() throws {
        var invocation = Invocation()
        #expect((invocation.registry["key"] as? KeyTool)?.selfBundleIDs == [])
        invocation.selfBundleIDs = ["com.googlecode.iterm2"]
        #expect((invocation.registry["key"] as? KeyTool)?.selfBundleIDs
                == ["com.googlecode.iterm2"])
    }

    // MARK: - Listing a page of sessions

    /// `transcripts 50` reads as naturally as `transcript <id>`, and avoids a flag for
    /// the one thing anyone wants to vary about a listing.
    @Test("A count after transcripts is a page size")
    func transcriptsTakesACount() throws {
        guard case let .success(invocation) = Invocation.parse(["transcripts", "50"]),
              case let .transcripts(limit) = invocation.command
        else { Issue.record("transcripts 50 did not parse"); return }
        #expect(limit == 50)
    }

    @Test("transcripts alone takes the default page")
    func transcriptsDefaultsToAPage() throws {
        guard case let .success(invocation) = Invocation.parse(["transcripts"]),
              case let .transcripts(limit) = invocation.command
        else { Issue.record("transcripts did not parse"); return }
        #expect(limit == nil)
    }

    /// A count that is not one must say so rather than silently listing everything —
    /// `transcripts 0` quietly showing 25 sessions is worse than an error.
    @Test("A count that is not a positive number is refused", arguments: ["zero", "0", "1.5"])
    func badCountIsRefused(count: String) {
        guard case let .failure(error) = Invocation.parse(["transcripts", count]) else {
            Issue.record("transcripts \(count) was accepted")
            return
        }
        #expect(error.message.contains("positive count"))
    }

    /// A negative number is refused earlier, as an unknown option — a different
    /// message, and the right outcome. Asserted so the two paths cannot both be
    /// removed under the impression the other still covers it.
    @Test("A negative count is refused as an option")
    func negativeCountIsRefused() {
        guard case let .failure(error) = Invocation.parse(["transcripts", "-3"]) else {
            Issue.record("transcripts -3 was accepted")
            return
        }
        #expect(error.message.contains("Unknown option"))
    }

    /// `forget` deletes irreversibly, so a missing or malformed count must be refused
    /// rather than defaulted — there is no safe default for "how much to delete".
    @Test("forget needs an explicit number of days", arguments: [
        [String](["forget"]), ["forget", "soon"], ["forget", "-5"], ["forget", "1.5"],
    ])
    func forgetRequiresDays(arguments: [String]) {
        guard case let .failure(error) = Invocation.parse(arguments) else {
            Issue.record("\(arguments) was accepted")
            return
        }
        #expect(!error.message.isEmpty)
    }

    @Test("forget takes a day count", arguments: [0, 1, 30, 365])
    func forgetTakesDays(days: Int) throws {
        guard case let .success(invocation) = Invocation.parse(["forget", "\(days)"]),
              case let .forget(parsed) = invocation.command
        else { Issue.record("forget \(days) did not parse"); return }
        #expect(parsed == days)
    }

    @Test("--planner selects a planning model and is off by default")
    func plannerFlag() throws {
        #expect(try parse("do the thing").plannerModel == nil)
        #expect(try parse("do the thing").loopConfiguration.planner == nil)

        let planned = try parse("--planner", "claude-opus-5", "do the thing")
        #expect(planned.plannerModel == "claude-opus-5")
        #expect(planned.loopConfiguration.planner?.model == "claude-opus-5")
        // The executor's own model is untouched by naming a planner.
        #expect(planned.model == DefaultModel.id)
    }

    @Test("--planner without a value is an error, not a silent default")
    func plannerFlagNeedsAValue() {
        guard case .failure = Invocation.parse(["--planner"]) else {
            Issue.record("--planner with no value should not parse")
            return
        }
    }

}

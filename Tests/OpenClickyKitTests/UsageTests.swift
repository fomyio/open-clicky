import Testing
import Foundation
@testable import OpenClickyKit

/// The help text is a promise about what the program accepts. A flag it names that
/// does not parse, or an example that fails, is documentation of a different program
/// — and it is the first thing a new user reads.
@Suite("Documented invocations")
struct UsageTests {

    /// Exactly the examples printed under EXAMPLES.
    private let documentedExamples = [
        ["what's taking up space in my Downloads folder?"],
        ["--max-tier", "1", "how many unread emails do I have?"],
        ["--mode", "auto", "open the OpenClicky repo in Finder"],
    ]

    @Test("Every example in the help text parses and runs a task")
    func examplesParse() {
        for example in documentedExamples {
            switch Invocation.parse(example) {
            case let .success(invocation):
                guard case .run = invocation.command else {
                    Issue.record("\(example) did not resolve to a task")
                    continue
                }
            case let .failure(error):
                Issue.record("\(example) failed: \(error.message)")
            }
        }
    }

    @Test("The second example really does restrict the agent to tier 1")
    func tierExampleDoesWhatItSays() throws {
        guard case let .success(invocation) = Invocation.parse(
            ["--max-tier", "1", "how many unread emails do I have?"]
        ) else {
            Issue.record("the documented example does not parse")
            return
        }
        // "how many unread emails" is a Tier 1 question, so the example should leave
        // app_script available and the screen unreachable — which is its whole point.
        #expect(invocation.registry["app_script"] != nil)
        #expect(invocation.registry["screenshot"] == nil)
        #expect(invocation.registry["ax_capture"] == nil)
    }

    @Test("The third example really does stop prompting for writes")
    func modeExampleDoesWhatItSays() {
        guard case let .success(invocation) = Invocation.parse(
            ["--mode", "auto", "open the OpenClicky repo in Finder"]
        ) else {
            Issue.record("the documented example does not parse")
            return
        }
        #expect(invocation.mode == .auto)
    }

    /// Each flag the help lists, with each value it offers.
    @Test("Every documented flag and value is accepted", arguments: [
        ["--mode", "read-only"], ["--mode", "ask"], ["--mode", "auto"], ["--mode", "bypass"],
        ["--max-tier", "0"], ["--max-tier", "1"], ["--max-tier", "2"], ["--max-tier", "3"],
        ["--effort", "low"], ["--effort", "medium"], ["--effort", "high"],
        ["--effort", "xhigh"], ["--effort", "max"],
        ["--model", "claude-opus-5"], ["--max-turns", "40"], ["--no-sandbox"],
    ])
    func documentedFlagsAreAccepted(flag: [String]) {
        guard case .success = Invocation.parse(flag + ["a task"]) else {
            Issue.record("\(flag) is documented but rejected")
            return
        }
    }

    /// The defaults the help prints must be the defaults the parser applies.
    @Test("The documented defaults are the real ones")
    func documentedDefaultsAreReal() {
        guard case let .success(invocation) = Invocation.parse(["a task"]) else {
            Issue.record("a bare task should parse")
            return
        }
        #expect(invocation.mode == .ask, "help says default: ask")
        #expect(invocation.maxTier == .pixels, "help says default: 3")
        #expect(invocation.model == "claude-opus-5", "help says default: claude-opus-5")
        #expect(invocation.effort == "high", "help says default: high")
        #expect(invocation.maxTurns == 40, "help says default: 40")
        #expect(invocation.sandbox == .enabled, "help describes --no-sandbox as opt-out")
    }
}

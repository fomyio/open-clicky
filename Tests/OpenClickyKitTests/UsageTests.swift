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

    // MARK: - The README

    /// The help text has been checked against the code since it was written; the
    /// README never was. It is the first thing anyone reads and the last thing anyone
    /// updates, and today it was four commands and several behaviours out of date.
    private var readme: String {
        get throws {
            // Walk up from this file to the package root, so the test does not depend
            // on the working directory a runner happens to use.
            var directory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("README.md")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return try String(contentsOf: candidate, encoding: .utf8)
                }
                directory = directory.deletingLastPathComponent()
            }
            throw CocoaError(.fileNoSuchFile)
        }
    }

    @Test("The README documents the real defaults")
    func readmeDefaultsAreReal() throws {
        let text = try readme
        let defaults = Invocation()
        #expect(text.contains("(default: \(defaults.mode.rawValue))"))
        #expect(text.contains("(default: \(defaults.model))"))
        #expect(text.contains("(default: \(defaults.effort))"))
        #expect(text.contains("(default: \(defaults.loopConfiguration.maxTurns))"))
    }

    /// Every command the README tells someone to run must exist. It listed three
    /// while the program had six.
    @Test("Every command the README names is a command", arguments: [
        "auth", "doctor", "transcripts", "transcript", "forget",
    ])
    func readmeCommandsExist(name: String) throws {
        #expect(try readme.contains("openclicky \(name)"), "the README does not mention \(name)")

        let arguments = name == "forget" ? [name, "30"] : [name]
        guard case .success = Invocation.parse(arguments) else {
            Issue.record("the README names `\(name)`, which does not parse")
            return
        }
    }

    /// And every flag it documents must be accepted, for the same reason the help
    /// text's are checked: a flag in the docs that the parser rejects is a reader
    /// following instructions into an error.
    @Test("Every flag the README documents is accepted")
    func readmeFlagsAreAccepted() throws {
        let text = try readme
        let flags = ["--mode", "--max-tier", "--model", "--effort", "--max-turns", "--no-sandbox"]
        for flag in flags {
            #expect(text.contains(flag), "the README omits \(flag)")
        }

        let sample = ["--mode", "auto", "--max-tier", "2", "--model", "claude-opus-5",
                      "--effort", "high", "--max-turns", "10", "--no-sandbox", "a task"]
        guard case .success = Invocation.parse(sample) else {
            Issue.record("the flags the README documents do not parse together")
            return
        }
    }
}

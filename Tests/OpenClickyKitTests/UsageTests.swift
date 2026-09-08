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
        ["--planner", "claude-opus-5"], ["--interactive"], ["-i"],
        ["--provider", "anthropic"], ["--provider", "openai"], ["--provider", "ollama"],
        ["--provider", "litellm"], ["--provider", "groq"],
        ["--base-url", "http://localhost:11434/v1"],
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
        #expect(invocation.model == DefaultModel.id, "help interpolates DefaultModel.id")
        #expect(invocation.effort == "high", "help says default: high")
        #expect(invocation.maxTurns == 40, "help says default: 40")
        #expect(invocation.sandbox == .enabled, "help describes --no-sandbox as opt-out")
    }

    /// The provider example the help offers has to run as written — it is the one
    /// line anyone trying a local model will copy.
    @Test("The local-model example does what it says")
    func providerExampleDoesWhatItSays() throws {
        guard case let .success(parsed) = Invocation.parse(
            ["--provider", "ollama", "--model", "llama3.2", "which windows are open?"]
        ) else {
            Issue.record("the documented example does not parse")
            return
        }
        #expect(parsed.providerKind == .ollama)
        #expect(parsed.modelIsExplicit)

        // And the claim the help makes beside `--model`: a model that cannot be sent
        // images caps the run at tier 2.
        #expect(parsed.effectiveMaxTier == .accessibility)
        #expect(parsed.registry["ax_press"] != nil)
        #expect(parsed.registry["click"] == nil)
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

    // MARK: - Which build is this

    /// A bug report that cannot name a build is a bug report about an unknown
    /// program. The version existed only inside `Scripts/bundle.sh`, written straight
    /// into the app's Info.plist, so the CLI could not report it and nothing could
    /// disagree with the app because nothing else knew it.
    @Test("--version names the build, the architecture and the OS")
    func versionLineIsUseful() {
        let line = OpenClicky.versionLine
        #expect(line.contains("openclicky \(OpenClicky.version)"))
        #expect(line.contains("macOS"))
        #expect(line.contains("arm64") || line.contains("x86_64"))
    }

    @Test("Every spelling of the version flag is accepted", arguments: ["--version", "-v", "version"])
    func versionFlagsParse(argument: String) {
        guard case let .success(invocation) = Invocation.parse([argument]),
              case .version = invocation.command
        else { Issue.record("\(argument) did not parse as the version command"); return }
    }

    /// The app bundle and the CLI must not disagree about which build they are. The
    /// script reads the same definition; this asserts it still can, because a `sed`
    /// that silently matches nothing would ship an app with an empty version.
    @Test("The bundle script reads the version the library defines")
    func bundleScriptFindsTheVersion() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 where !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Scripts/bundle.sh").path
        ) {
            directory = directory.deletingLastPathComponent()
        }

        let script = try String(
            contentsOf: directory.appendingPathComponent("Scripts/bundle.sh"), encoding: .utf8
        )
        #expect(script.contains("Version.swift"), "the script no longer reads the definition")
        #expect(!script.contains("<string>\(OpenClicky.version)</string>"),
                "the version was hardcoded back into the plist")

        let source = try String(
            contentsOf: directory.appendingPathComponent(
                "Sources/OpenClickyKit/Support/Version.swift"), encoding: .utf8
        )
        #expect(source.contains("static let version = \"\(OpenClicky.version)\""),
                "the script's `sed` pattern would no longer match")
    }

    // MARK: - Derived from the text, so the list cannot go stale

    // The list above is hand-maintained, and it had already drifted: `--planner` was
    // added, documented, and never added here, so "every documented flag is accepted"
    // was true of a smaller set than the help prints. Deriving the flags from the text
    // itself removes the second place to remember.

    @Test("Every flag the help text names is accepted by the parser")
    func flagsDerivedFromTheTextAllParse() {
        // Values that make each flag parseable, so the test exercises the flag rather
        // than the absence of its operand.
        let values = [
            "--mode": "auto", "--max-tier": "2", "--model": "claude-opus-5",
            "--effort": "high", "--max-turns": "5", "--planner": "claude-opus-5",
            "--provider": "ollama", "--base-url": "http://localhost:11434/v1",
        ]
        let flags = Usage.documentedFlags
        #expect(!flags.isEmpty, "no flags were found in the help text")

        for flag in flags {
            var arguments = [flag]
            if let value = values[flag] { arguments.append(value) }
            guard case .success = Invocation.parse(arguments + ["a task"]) else {
                Issue.record("the help documents \(flag), which the parser rejects")
                continue
            }
        }
        // Every flag that takes a value must be listed above, or it is being parsed
        // bare and proving nothing about itself. The exceptions are the switches, which
        // take none — named here so that a flag which quietly stops taking a value
        // still has to be noticed by someone.
        let switches: Set<String> = ["--no-sandbox", "--interactive"]
        for flag in flags where !switches.contains(flag) {
            #expect(values[flag] != nil, "\(flag) has no sample value")
        }
    }

    @Test("The derivation finds the flags actually shipped")
    func derivationFindsTheRealFlags() {
        // Pins the extraction. A change that silently found nothing would make the
        // test above vacuously true — the failure mode of every derived check.
        #expect(Set(Usage.documentedFlags) == Set([
            "--mode", "--max-tier", "--model", "--effort", "--max-turns",
            "--planner", "--provider", "--base-url", "--no-sandbox", "--interactive",
        ]))
    }

    @Test("The help carries no styling of its own")
    func stylingIsTheCallersChoice() {
        // The CLI passes ANSI bold and a piped terminal passes none. The kit must not
        // decide, or the help carries escape codes into a log.
        #expect(!Usage.text().contains("\u{001B}["))
        #expect(Usage.text(bold: { "<<\($0)>>" }).contains("<<openclicky>>"))
    }


    @Test("Every subcommand the help names is a subcommand, not a task")
    func documentedSubcommandsAreRecognised() {
        // `forget-key` was promised by `auth`'s output, documented nowhere and
        // implemented not at all — so running it was parsed as a task and sent to a
        // model. Being read as a task is the specific failure: it does not error, it
        // bills.
        let needsValue = ["forget": "30"]
        let subcommands = Usage.documentedSubcommands
        #expect(!subcommands.isEmpty, "no subcommands were found in the help text")

        for word in subcommands {
            var arguments = [word]
            if let value = needsValue[word] { arguments.append(value) }
            guard case let .success(invocation) = Invocation.parse(arguments) else {
                Issue.record("the help documents `\(word)`, which the parser rejects")
                continue
            }
            if case let .run(task) = invocation.command {
                Issue.record("`\(word)` is documented but was read as the task \(task)")
            }
        }
    }

    @Test("The subcommand derivation finds the ones shipped")
    func derivationFindsTheRealSubcommands() {
        // Pins the extraction, so the test above cannot pass by finding nothing.
        #expect(Set(Usage.documentedSubcommands) == Set([
            "auth", "doctor", "transcripts", "transcript", "forget", "bench", "forget-key",
        ]))
    }

}

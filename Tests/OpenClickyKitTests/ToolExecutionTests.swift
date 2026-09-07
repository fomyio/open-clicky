import Testing
import ApplicationServices
import Foundation
import CoreGraphics
@testable import OpenClickyKit

/// Exercises the tools against the real machine. These are deliberately not mocked:
/// the whole point of Tiers 0–2 is that they talk to macOS, and a mocked version
/// would prove nothing about whether `osascript` or the accessibility API works.
/// Everything here is read-only or confined to a temporary directory.
@Suite("Tool execution", .serialized)
struct ToolExecutionTests {

    private func text(_ output: ToolOutput) -> String {
        output.content.compactMap {
            if case let .text(t) = $0 { return t }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Tier 0

    @Test("shell runs a command and returns stdout")
    func shellRuns() async throws {
        let output = try await ShellTool().run(.object(["command": .string("echo hello-openclicky")]))
        #expect(!output.isError)
        #expect(text(output).contains("hello-openclicky"))
    }

    @Test("shell reports a failing command as an error, with stderr")
    func shellSurfacesFailure() async throws {
        let output = try await ShellTool().run(
            .object(["command": .string("ls /nonexistent-openclicky-path")])
        )
        #expect(output.isError)
        #expect(text(output).contains("exit code"))
    }

    @Test("shell refuses a deny-listed command before running it")
    func shellRefusesDenied() async {
        await #expect(throws: Policy.Violation.self) {
            try await ShellTool().run(.object(["command": .string("rm -rf /")]))
        }
    }

    @Test("shell honours its timeout")
    func shellTimesOut() async throws {
        let output = try await ShellTool().run(.object([
            "command": .string("sleep 10"),
            "timeout_seconds": .number(1),
        ]))
        #expect(output.isError)
        #expect(text(output).contains("timeout"))
    }

    /// A child inheriting the terminal blocks forever on `cat` or `sort` with no
    /// file — and worse, competes with the approval prompt for the user's keystrokes,
    /// swallowing the y/n meant for the permission gate.
    @Test("A command that reads stdin finishes instead of blocking", arguments: [
        "cat", "sort", "wc -l", "head",
    ])
    func stdinReadersDoNotBlock(command: String) async throws {
        let start = ContinuousClock.now
        let output = try await ShellTool().run(.object([
            "command": .string(command), "timeout_seconds": .number(5),
        ]))
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(3), "'\(command)' took \(elapsed)")
        #expect(!text(output).contains("timeout"))
    }

    @Test("Supplied input still reaches the command")
    func stdinIsStillDelivered() async throws {
        let result = try await Subprocess.run(
            executable: "/bin/cat", arguments: [], stdin: "round-tripped", timeout: 5
        )
        #expect(result.stdout == "round-tripped")
    }

    @Test("The sandbox profile confines writes to system locations")
    func sandboxBlocksSystemWrites() async throws {
        let output = try await ShellTool(sandbox: .enabled).run(
            .object(["command": .string("touch /usr/openclicky-should-not-exist")])
        )
        #expect(output.isError, "sandbox-exec should have refused a write to /usr")
        #expect(!FileManager.default.fileExists(atPath: "/usr/openclicky-should-not-exist"))
    }

    /// Output is capped so one command cannot exhaust the context: `ps aux` and
    /// `find /usr/share` both exceed 100KB, which was ~25,000 tokens from a single
    /// result. Head-only truncation also lost the end, which for command output is
    /// usually where the summary or the error is.
    @Test("Large output is capped and keeps both ends")
    func largeOutputKeepsBothEnds() async throws {
        let output = try await ShellTool().run(
            .object(["command": .string("find /usr/share -type f")])
        )
        let result = text(output)

        #expect(result.count < 20_000, "one result must not dominate the context")
        #expect(result.contains("omitted from the middle"))
        #expect(result.contains("Narrow the command"), "and say what to do instead")

        let lines = result.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count > 2)
        #expect(lines.first?.hasPrefix("/usr/share") == true, "the head survives")
        #expect(lines.last?.hasPrefix("/usr/share") == true, "and so does the tail")
    }

    @Test("Output under the cap is passed through untouched")
    func smallOutputIsVerbatim() async throws {
        let output = try await ShellTool().run(.object(["command": .string("echo exact")]))
        #expect(text(output).trimmingCharacters(in: .whitespacesAndNewlines) == "exact")
    }

    @Test("Abbreviation is byte-safe on multi-byte content")
    func abbreviationHandlesUnicode() {
        let unicode = Data(String(repeating: "日本語テキスト ", count: 2_000).utf8)
        let abbreviated = Subprocess.abbreviate(unicode, to: 400)
        #expect(abbreviated.contains("omitted from the middle"))
        #expect(abbreviated.contains("日本"), "content on both sides survives")
    }

    /// sandbox-exec drops setgid privileges, so /bin/ps fails with a bare
    /// "operation not permitted". Unexplained, the model reads that as transient and
    /// retries the same command forever.
    @Test("A sandbox denial explains itself and names a working alternative")
    func sandboxDenialIsExplained() async throws {
        let output = try await ShellTool(sandbox: .enabled).run(
            .object(["command": .string("ps aux")])
        )
        #expect(output.isError)
        let result = text(output)
        #expect(result.contains("the sandbox refusing"))
        #expect(result.contains("pgrep"), "with something that actually works")
    }

    @Test("An ordinary failure is not dressed up as a sandbox problem")
    func ordinaryFailuresAreUnchanged() async throws {
        let output = try await ShellTool(sandbox: .enabled).run(
            .object(["command": .string("ls /nonexistent-openclicky-path")])
        )
        #expect(output.isError)
        #expect(!text(output).contains("privileges that the sandbox drops"))
    }

    @Test("read_file and write_file round-trip")
    func fileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-tests-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("note.txt").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try await WriteFileTool().run(.object([
            "path": .string(path), "content": .string("ladder"),
        ]))
        #expect(!written.isError)

        let read = try await ReadFileTool().run(.object(["path": .string(path)]))
        #expect(text(read) == "ladder")
    }

    @Test("read_file refuses credential paths")
    func readFileRefusesCredentials() async {
        await #expect(throws: Policy.Violation.self) {
            try await ReadFileTool().run(.object(["path": .string("~/.ssh/id_rsa")]))
        }
    }

    @Test("Overwriting an existing file is classified destructive")
    func overwriteIsDangerous() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-overwrite-\(UUID().uuidString).txt")
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let input = JSONValue.object(["path": .string(url.path), "content": .string("new")])
        guard case .dangerous = WriteFileTool().risk(for: input) else {
            Issue.record("overwriting an existing file should be destructive")
            return
        }
        guard case .write = WriteFileTool().risk(
            for: .object(["path": .string(url.path + ".new"), "content": .string("x")])
        ) else {
            Issue.record("creating a new file should be a plain write")
            return
        }
    }

    // MARK: - Tier 1

    @Test("app_script evaluates AppleScript")
    func appleScriptRuns() async throws {
        let output = try await AppleScriptTool().run(
            .object(["script": .string("return 6 * 7")])
        )
        #expect(!output.isError)
        #expect(text(output).trimmingCharacters(in: .whitespacesAndNewlines) == "42")
    }

    @Test("app_script evaluates JXA")
    func jxaRuns() async throws {
        let output = try await AppleScriptTool().run(.object([
            "script": .string("'open' + 'clicky'"),
            "language": .string("javascript"),
        ]))
        #expect(!output.isError)
        #expect(text(output).contains("openclicky"))
    }

    @Test("app_script reads live system state without any screenshot")
    func appleScriptReadsSystemState() async throws {
        let output = try await AppleScriptTool().run(.object([
            "script": .string("tell application \"System Events\" to return name of first process whose frontmost is true"),
        ]))
        // Needs Automation consent for System Events; a refusal is a valid outcome
        // in CI, so assert on the shape rather than a specific app name.
        if !output.isError { #expect(!text(output).isEmpty) }
    }

    /// The recipes in a tool's description are instructions the model copies
    /// verbatim, so a wrong one is a wrong instruction shipped to every session.
    /// These were unguarded — `tell application "Mail" to …` launches Mail — and one
    /// of them hung for two minutes on a consent dialog when first run.
    @Test("The documented patterns are syntactically valid AppleScript")
    func documentedPatternsCompile() async throws {
        // Compile-only: `osascript -e` with a syntax error fails without running, so
        // this checks the recipes parse without launching anything or asking consent.
        let patterns = [
            #"tell application "System Events" to name of first process whose frontmost is true"#,
            #"tell application "System Events" to get name of every process whose background only is false"#,
            "output volume of (get volume settings)",
            #"tell application "Notes" to make new note with properties {name:"x", body:"y"}"#,
            #"tell application "Safari" to return URL of current tab of front window"#,
            "if application \"Mail\" is running then\n\ttell application \"Mail\" to return unread count of inbox\nend if\nreturn \"not running\"",
        ]
        for pattern in patterns {
            let result = try await Subprocess.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", pattern, "-o", "/dev/null"],
                timeout: 10
            )
            // A syntax error is reported before execution; anything else (including a
            // permission refusal) means it parsed.
            #expect(!result.stderr.contains("syntax error"), "\(pattern) -> \(result.stderr)")
        }
    }

    @Test("The description teaches the guard rather than the launching form")
    func descriptionTeachesTheGuard() {
        let description = AppleScriptTool().description
        #expect(description.contains("is running"), "the guard pattern must be shown")
        #expect(description.contains("launches"), "and why it matters")
        #expect(description.contains("consent dialog"), "and that a first call blocks")
    }

    /// Without this the model sees a bare timeout, concludes its script is wrong, and
    /// rewrites something that was correct.
    @Test("A timeout blames the consent dialog and names the app")
    func timeoutExplainsConsent() {
        let message = AppleScriptTool.explain(
            .timedOut(seconds: 30),
            script: #"tell application "Notes" to count of notes"#
        )
        #expect(message.contains("consent dialog"))
        #expect(message.contains("Notes"), "naming the app tells the user what to look for")
        #expect(message.contains("Rewriting it will not help"))
    }

    @Test("Other failures are not blamed on consent")
    func otherFailuresAreUnchanged() {
        let message = AppleScriptTool.explain(
            .launchFailed("no such file"), script: "return 1"
        )
        #expect(!message.contains("consent dialog"))
    }

    /// The failure the model has to be told is tier-local.
    ///
    /// A run asked to open the VS Code command palette sent
    /// `keystroke "p" using {command down, shift down}` and got "osascript is not
    /// allowed to send keystrokes. (1002)". `key` and `ax_press` were both in its
    /// registry and Accessibility was granted, but the raw stderr reads as "this
    /// machine will not let me send keys", so the model told the user to press the
    /// chord themselves and ended the turn.
    private static let keystrokeDenial = """
        96:142: execution error: System Events got an error: osascript is not \
        allowed to send keystrokes. (1002)
        """

    @Test("A keystroke denial points at the tier above, and keeps the raw error")
    func keystrokeDenialSuggestsSyntheticInput() async throws {
        let tool = AppleScriptTool(
            runner: FailingRunner(stderr: Self.keystrokeDenial), maxTier: .pixels
        )
        let output = try await tool.run(.object([
            "script": .string("tell application \"System Events\" to keystroke \"p\" using {command down, shift down}"),
        ]))
        let message = text(output)

        #expect(output.isError)
        #expect(message.contains("osascript is not allowed to send keystrokes"),
                "osascript's own error is still the diagnostic")
        #expect(message.contains("`key`"), "the tool that would have worked must be named")
        #expect(message.contains("ax_press"), "and the better route for a named control")
        #expect(message.contains("specific to the AppleScript"),
                "the denial must be stated as route-local, not machine-wide")
    }

    /// Naming a tool the ceiling removed is the same defect as a prompt describing
    /// tiers a run does not have: it sends the model after "no tool named key".
    @Test("Below tier 2 the denial is reported as a real limit, naming nothing absent")
    func keystrokeDenialUnderALowCeilingNamesNoTools() async throws {
        let tool = AppleScriptTool(
            runner: FailingRunner(stderr: Self.keystrokeDenial), maxTier: .script
        )
        let message = text(try await tool.run(.object(["script": .string("keystroke \"p\"")])))

        #expect(!message.contains("`key`"), "that tool is not in this run")
        #expect(!message.contains("ax_press"), "neither is that one")
        #expect(message.contains("above this run's tier ceiling"))
        #expect(message.contains("limit to report"))
    }

    @Test("At tier 2 the denial points at the accessibility route only")
    func keystrokeDenialAtTierTwoNamesAXOnly() async throws {
        let tool = AppleScriptTool(
            runner: FailingRunner(stderr: Self.keystrokeDenial), maxTier: .accessibility
        )
        let message = text(try await tool.run(.object(["script": .string("keystroke \"p\"")])))

        #expect(message.contains("ax_press"))
        #expect(message.contains("ax_capture"))
        #expect(!message.contains("`key`"), "tier 3 is not in this run")
    }

    /// The other denial by the same principal, with its own code and wording.
    @Test("The Apple-events denial is recognised too")
    func appleEventsDenialIsRecognised() async throws {
        let stderr = """
            execution error: Not authorized to send Apple events to Notes. (-1743)
            """
        let tool = AppleScriptTool(runner: FailingRunner(stderr: stderr), maxTier: .pixels)
        let message = text(try await tool.run(.object([
            "script": .string("tell application \"Notes\" to count of notes"),
        ])))

        #expect(message.contains("-1743"), "the raw error stays")
        #expect(message.contains("specific to the AppleScript"))
        #expect(message.contains("`key`"))
    }

    /// The guard that keeps the hint worth reading. A syntax error is the model's own
    /// bug; escalating past it only moves the same mistake to a more expensive tier.
    @Test("An ordinary script failure gets no escalation advice")
    func ordinaryFailureIsNotBlamedOnPermissions() async throws {
        let stderr = "96:104: syntax error: Expected end of line but found identifier. (-2741)"
        let tool = AppleScriptTool(runner: FailingRunner(stderr: stderr), maxTier: .pixels)
        let message = text(try await tool.run(.object([
            "script": .string("this is not applescript at all"),
        ])))

        #expect(message.contains("syntax error"), "the real diagnostic is untouched")
        #expect(!message.contains("specific to the AppleScript"))
        #expect(!message.contains("`key`"))
        #expect(!message.contains("ax_press"))
    }

    /// Runs nothing: the point is what the tool does with osascript's exit status.
    private struct FailingRunner: ScriptRunning {
        let stderr: String
        func run(arguments: [String], script: String, timeout: Int) async throws -> Subprocess.Result {
            Subprocess.Result(stdout: "", stderr: stderr, exitCode: 1)
        }
    }

    @Test("app_script surfaces a syntax error rather than pretending to succeed")
    func appleScriptReportsErrors() async throws {
        let output = try await AppleScriptTool().run(
            .object(["script": .string("this is not applescript at all")])
        )
        #expect(output.isError)
        #expect(text(output).contains("Script failed"))
    }

    @Test("Mutating and outward-facing scripts are classified higher than queries")
    func scriptRiskClassification() {
        let tool = AppleScriptTool()
        guard case .read = tool.risk(for: .object([
            "script": .string("tell application \"Mail\" to unread count of inbox")
        ])) else { Issue.record("a query should be read-only"); return }

        guard case .write = tool.risk(for: .object([
            "script": .string("tell application \"Notes\" to make new note")
        ])) else { Issue.record("creating a note should be a write"); return }

        guard case .dangerous = tool.risk(for: .object([
            "script": .string("tell application \"Mail\" to send outgoing message 1")
        ])) else { Issue.record("sending mail should be destructive"); return }
    }

    /// `shortcuts run` writes results to `--output-path` and prints nothing useful to
    /// stdout, so the tool was discarding whatever the shortcut produced while its own
    /// description promised to return it.
    @Test("Running a shortcut asks for its output on disk")
    func shortcutRunRequestsOutput() async throws {
        // A name that cannot exist, so nothing of the user's runs.
        let output = try await ShortcutsTool().run(
            .object(["name": .string("OpenClickyNoSuchShortcut-\(UUID().uuidString)")])
        )
        #expect(output.isError, "a missing shortcut is a failure, not silence")
        #expect(text(output).lowercased().contains("find") || text(output).lowercased().contains("error"))
    }

    @Test("run_shortcut lists the user's shortcuts")
    func shortcutsLists() async throws {
        let output = try await ShortcutsTool().run(.object([:]))
        #expect(!output.isError)
    }

    // MARK: - Tier 2

    @Test("ax_capture reads the frontmost window, or explains why it cannot")
    func axCaptureWorks() async throws {
        let output = try await AXCaptureTool().run(.object([:]))
        if AXCapture.shared.isTrusted {
            #expect(!output.isError, "accessibility is granted, so a capture should succeed")
            #expect(text(output).contains("elements"))
        } else {
            #expect(output.isError)
            #expect(text(output).contains("Accessibility permission"))
        }
    }

    /// The accessibility tier is the ladder's grounding layer, so its cost decides
    /// whether the model reaches for it or escalates to a screenshot. Attributes are
    /// fetched in one batched round trip per node rather than nine separate ones;
    /// this pins that the capture stays fast and complete.
    @Test("A capture is fast and returns well-formed nodes",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func captureIsFastAndComplete() async throws {
        _ = try? await AXCapture.shared.capture()

        let start = ContinuousClock.now
        let capture = try await AXCapture.shared.capture()
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(400), "capture took \(elapsed)")
        // An empty capture means the frontmost window exposes nothing to inspect,
        // which is a legitimate state but leaves nothing here to verify — say so
        // rather than passing silently.
        try #require(!capture.nodes.isEmpty, "frontmost window exposed no elements")

        // Batched reads return values positionally, so a mis-indexed attribute would
        // show up as roles going missing or landing in the wrong field.
        #expect(capture.nodes.allSatisfy { !$0.role.isEmpty })
        #expect(capture.nodes.contains { $0.role.hasPrefix("AX") }, "roles keep their AX prefix")
        #expect(capture.nodes.filter { $0.frame != nil }.count > capture.nodes.count / 2,
                "most nodes should have a frame")
        #expect(capture.nodes.allSatisfy { $0.frame.map { $0.width >= 0 && $0.height >= 0 } ?? true },
                "a frame built from mismatched position/size values would be malformed")
    }

    /// The action names offered in `ax_press`'s schema were a fixed enum under strict
    /// tool use, so anything outside it was impossible to invoke — and a live window
    /// advertises `AXRaise`, which was not on the list. Elements now report their own
    /// actions, which is a better source of valid values than any list can be.
    @Test("A capture names each element's actions beyond a plain press",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func captureNamesElementActions() async throws {
        let capture = try await AXCapture.shared.capture()

        for node in capture.nodes where node.isInteractive {
            let extras = node.actions.filter { $0 != "AXPress" }
            if extras.isEmpty {
                #expect(!node.line.contains("[AX"), "\(node.line) lists actions it does not have")
            } else {
                for action in extras {
                    #expect(node.line.contains(action), "\(action) missing from \(node.line)")
                }
            }
        }
    }

    @Test("The action argument is open, not a closed list")
    func actionArgumentIsOpen() {
        let schema = AXPressTool().inputSchema
        let action = schema["properties"]?["action"]
        #expect(action?["enum"] == nil, "a closed enum cannot express every element's actions")
        #expect(action?["description"]?.stringValue?.contains("ax_capture") == true,
                "it should point at where the valid values come from")
    }

    @Test("ax_press documents that a non-press element will refuse")
    func axPressDocumentsItsLimits() {
        let description = AXPressTool().description
        #expect(description.contains("AXShowMenu"), "showing the bracket form by example")
        #expect(description.contains("will fail"), "and that pressing the wrong thing does not silently work")
    }

    /// Targeting a named app is how the model inspects a window that is not in front
    /// — checking a dialog behind the current one, say. Untested until now, and a
    /// wrong bundle identifier must fail rather than silently capture whatever
    /// happens to be frontmost.
    @Test("A capture can target a named application",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func captureTargetsANamedApp() async throws {
        // Finder is always running, so this is stable wherever the test runs.
        let output = try await AXCaptureTool().run(
            .object(["bundle_identifier": .string("com.apple.finder")])
        )
        if !output.isError {
            #expect(text(output).contains("Finder"), "the capture should name the app it read")
        }

        let missing = try await AXCaptureTool().run(
            .object(["bundle_identifier": .string("com.example.definitely-not-running")])
        )
        #expect(missing.isError, "a bundle id that is not running must fail")
        #expect(!text(missing).contains("Finder"),
                "and must not fall back to whatever is frontmost")
    }

    /// A tool that reports success without doing anything is worse than one that
    /// fails: the model proceeds believing the field is filled. Found by mutation —
    /// `ax_set_value` could skip the write entirely and nothing objected.
    @Test("Setting a value on an unknown element fails rather than reporting success")
    func setValueOnUnknownElementFails() async throws {
        let output = try await AXSetValueTool().run(.object([
            "element_id": .string("e999999"), "value": .string("anything"),
        ]))
        #expect(output.isError, "a write that could not happen must not report success")
        #expect(text(output).contains("ax_capture again") || text(output).contains("No element"),
                "and must say why")
    }

    /// Approval prompts name the element being acted on — "AXPress on Button
    /// \"Delete\" (#e12)" — which requires the capture to publish those labels. Without
    /// them the prompt degrades to a bare id the user cannot consent to, silently.
    @Test("A capture publishes labels for the elements it found",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func capturePublishesLabels() async throws {
        let capture = try await AXCapture.shared.capture()
        guard let interactive = capture.nodes.first(where: { $0.isInteractive }) else { return }

        let described = AXCapture.labels.describe(interactive.id)
        #expect(described != interactive.id,
                "the label fell back to the bare id, so approvals cannot name the element")
        #expect(described.contains(interactive.id), "and it should still identify which one")

        // An id from no capture describes as itself rather than inventing something.
        #expect(AXCapture.labels.describe("e999999") == "e999999")
    }

    /// Found by reading a capture: leaves with no label, no value and nothing to press
    /// contributed lines saying only "a StaticText exists here" — tokens spent on
    /// nothing, in the tool whose cost decides whether the model grounds on the tree
    /// or gives up and screenshots.
    @Test("A node with nothing to say is judged uninformative")
    func uninformativeNodesAreIdentified() {
        func node(role: String, title: String? = nil, value: String? = nil,
                  actions: [String] = []) -> AXNode {
            AXNode(id: "e1", role: role, subrole: nil, title: title, value: value,
                   help: nil, enabled: true, frame: nil, depth: 0, actions: actions)
        }

        #expect(!node(role: "AXStaticText").isInformative, "a label with no label")
        #expect(!node(role: "AXImage").isInformative)
        #expect(node(role: "AXStaticText", value: "Delete everything?").isInformative)
        #expect(node(role: "AXButton", title: "Save").isInformative)
        #expect(node(role: "AXButton", actions: ["AXPress"]).isInformative,
                "pressable, so it matters even unlabelled")
    }

    /// The message in a dialog is what the model is being asked to read. Truncating it
    /// at 60 characters like a text field's contents lost the question being asked.
    @Test("Prose values are given room; field values are not")
    func proseValuesAreNotTruncatedShort() {
        let message = String(repeating: "This is the dialog's question. ", count: 8)
        func line(role: String) -> String {
            AXNode(id: "e1", role: role, subrole: nil, title: nil, value: message,
                   help: nil, enabled: true, frame: nil, depth: 0, actions: []).line
        }

        #expect(line(role: "AXStaticText").count > 200, "a dialog's message must survive")
        #expect(line(role: "AXTextField").count < 120, "a field's contents only need recognising")
    }

    /// A container is kept even when it says nothing, because its nesting is the
    /// structure the model reads the tree by.
    @Test("Filtering keeps containers and drops empty leaves",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func capturePrunesOnlyEmptyLeaves() async throws {
        let capture = try await AXCapture.shared.capture()
        guard capture.nodes.count > 1 else { return }

        for (index, node) in capture.nodes.enumerated() where !node.isInformative {
            let next = index + 1 < capture.nodes.count ? capture.nodes[index + 1] : nil
            #expect(next.map { $0.depth > node.depth } ?? false,
                    "kept an uninformative leaf: \(node.line)")
        }
    }

    @Test("Acting on a stale element id fails loudly instead of hitting the wrong thing")
    func staleElementIsRejected() async throws {
        let output = try await AXPressTool().run(.object(["element_id": .string("e99999")]))
        #expect(output.isError)
    }

    // MARK: - Tier 3 argument handling

    /// Every other tool speaks the last screenshot's pixel space. Having `zoom` alone
    /// want screen points put the conversion on the model's side of the boundary,
    /// which is exactly where coordinate errors come from.
    @Test("zoom rejects a degenerate region rather than capturing something else")
    func zoomRejectsDegenerateRegions() async throws {
        for (width, height) in [(0, 100), (100, 0), (-5, 50)] {
            let output = try await ZoomTool().run(.object([
                "x": .number(0), "y": .number(0),
                "width": .number(Double(width)), "height": .number(Double(height)),
            ]))
            #expect(output.isError)
        }
    }

    /// Without a prior screenshot there is no mapping from image pixels to the
    /// screen, and guessing one would crop somewhere plausible but wrong. Asserted
    /// against a fresh context rather than the shared one, so the outcome does not
    /// depend on what another test happened to capture first.
    @Test("zoom refuses to convert coordinates it has no mapping for")
    func zoomNeedsAScreenshot() async throws {
        let context = ScreenContext()
        await #expect(throws: ScreenToolError.self) {
            try await context.screenPoint(fromImage: CGPoint(x: 10, y: 10))
        }
    }

    @Test("zoom and click describe the same coordinate space")
    func zoomAndClickAgreeOnSpace() {
        let zoomSchema = ZoomTool().inputSchema
        let clickSchema = ClickTool().inputSchema
        for key in ["x", "y"] {
            let zoomDescription = zoomSchema["properties"]?[key]?["description"]?.stringValue ?? ""
            let clickDescription = clickSchema["properties"]?[key]?["description"]?.stringValue ?? ""
            #expect(zoomDescription.contains("pixel space"))
            #expect(clickDescription.contains("pixel space"))
        }
    }

    /// Records what a tool asked for, so the arguments can be checked without Screen
    /// Recording. Each of these fails silently if dropped: the agent photographs its
    /// own overlay, or captures the wrong region of the wrong display.
    /// An actor, not a lock: `capture` is async, and holding a lock across a
    /// suspension point is what Swift 6 refuses to compile.
    private actor CaptureSpy: ScreenCapturing {
        struct Request {
            let displayID: CGDirectDisplayID?
            let region: CGRect?
            let space: ImageSpace
            let quality: CGFloat
            let excluding: [String]
        }
        private(set) var requests: [Request] = []

        func capture(
            displayID: CGDirectDisplayID?, region: CGRect?, space: ImageSpace,
            quality: CGFloat, excludingBundleIDs: [String]
        ) async throws -> Screenshot {
            requests.append(.init(displayID: displayID, region: region, space: space,
                                  quality: quality, excluding: excludingBundleIDs))
            return Screenshot(
                jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
                screenRect: region ?? CGRect(x: 0, y: 0, width: 100, height: 100),
                displayID: displayID ?? 1, space: space
            )
        }
    }

    /// The agent must not photograph its own overlay and react to it. The panels also
    /// set `sharingType = .none`, so this is the second of two independent guards —
    /// but a guard nothing checks is one that quietly stops existing.
    @Test("A screenshot excludes the windows it was told to exclude")
    func screenshotHonoursExclusions() async throws {
        let spy = CaptureSpy()
        _ = try await ScreenshotTool(
            excludedBundleIDs: ["com.openclicky.app"], capture: spy, context: ScreenContext()
        ).run(.object([:]))

        let request = try #require(await spy.requests.first)
        #expect(request.excluding == ["com.openclicky.app"])
    }

    @Test("A screenshot forwards the region and display it was given")
    func screenshotForwardsItsTarget() async throws {
        let spy = CaptureSpy()
        _ = try await ScreenshotTool(capture: spy, context: ScreenContext()).run(.object([
            "region": .string("100,200,300,400"),
            "display_id": .number(7),
        ]))

        let request = try #require(await spy.requests.first)
        #expect(request.region == CGRect(x: 100, y: 200, width: 300, height: 400))
        #expect(request.displayID == 7)
    }

    /// Zoom exists to recover detail, so it must ask for higher fidelity than the
    /// overview — and it must ask inside the same provider space, because a crop
    /// sized for a different cap would be resampled on arrival and every coordinate
    /// read off it would be scaled by a ratio nothing recorded.
    @Test("Zoom asks for higher quality inside the run's image space")
    func zoomRequestsFullFidelity() async throws {
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1
        ))

        let spy = CaptureSpy()
        _ = try await ZoomTool(capture: spy, context: context, space: .openAI).run(.object([
            "x": .number(10), "y": .number(10), "width": .number(20), "height": .number(20),
        ]))

        let request = try #require(await spy.requests.first)
        #expect(request.space == .openAI)
        #expect(request.quality == ZoomTool.detailQuality)
        #expect(request.quality > 0.75, "a zoom compressed like the overview reads no better")
    }

    // MARK: - Registry

    @Test("The registry orders tools by tier so the cheapest are described first")
    func registryOrdersByTier() {
        let registry = ToolRegistry([
            ScreenshotTool(), ShellTool(), AXCaptureTool(), AppleScriptTool(),
        ])
        #expect(registry.ordered.map(\.tier) == [.shell, .script, .accessibility, .pixels])
    }

    @Test("Capping the tier removes the tools above it")
    func tierCapExcludesHigherTiers() {
        let all: [any Tool] = [
            ShellTool(), AppleScriptTool(), AXCaptureTool(), ScreenshotTool(), ClickTool(),
        ]
        let capped = ToolRegistry(all.filter { $0.tier <= .script })
        #expect(capped.maxTier == .script)
        #expect(capped["screenshot"] == nil)
        #expect(capped["click"] == nil)
        #expect(capped["app_script"] != nil)
    }

    @Test("Every tool has a unique name and a non-trivial description")
    func toolMetadataIsSound() {
        let all: [any Tool] = [
            ShellTool(), ReadFileTool(), WriteFileTool(), AppleScriptTool(), ShortcutsTool(),
            AXCaptureTool(), AXPressTool(), AXSetValueTool(), ScreenshotTool(), ZoomTool(),
            ClickTool(), DragTool(), TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
        ]
        let names = all.map(\.name)
        #expect(Set(names).count == names.count, "tool names must be unique")
        for tool in all {
            #expect(tool.description.count > 40, "\(tool.name) needs a real description")
            #expect(tool.inputSchema["additionalProperties"]?.boolValue == false, "\(tool.name) schema must be closed for strict mode")
        }
    }

    // MARK: - Errors the model has to recover from

    /// An AXError is the agent's only signal about *why* an action failed, and the
    /// codes are not interchangeable: one says re-capture, one says wait, one says
    /// this element will never accept that action. Rendered as a bare number they
    /// were indistinguishable, so the only available response was to repeat the call
    /// — which is exactly how a run gets stuck.
    @Test("Distinct accessibility failures give distinct advice", arguments: [
        (AXError.actionUnsupported, "brackets"),
        (.invalidUIElement, "ax_capture again"),
        (.cannotComplete, "wait"),
        (.attributeUnsupported, "type"),
        (.apiDisabled, "System Settings"),
    ])
    func axErrorsExplainTheirRecovery(pair: (AXError, String)) {
        let text = AXCapture.Error.actionFailed("AXPress", pair.0).description
        #expect(text.contains(pair.1), "no recovery named in: \(text)")
        #expect(!text.contains("\(pair.0.rawValue)"), "still leaking a bare error code")
    }

    @Test("No two recoverable accessibility failures read the same")
    func axErrorAdviceIsDistinct() {
        let codes: [AXError] = [.actionUnsupported, .invalidUIElement, .cannotComplete,
                                .attributeUnsupported, .apiDisabled, .illegalArgument]
        let advice = Set(codes.map { AXCapture.Error.explain($0) })
        #expect(advice.count == codes.count, "two codes collapsed to the same advice")
    }

    /// Every model-facing failure has to say what to do next, not only what went wrong.
    @Test("A failure that cannot be acted on is not a useful failure")
    func errorsNameAnAction() {
        let errors: [any CustomStringConvertible] = [
            AXCapture.Error.notTrusted,
            AXCapture.Error.noFocusedApplication,
            AXCapture.Error.unknownElement("e9"),
            InputInjector.Error.notTrusted,
            InputInjector.Error.unknownKey("splat"),
        ]
        for error in errors {
            let text = error.description.lowercased()
            #expect(text.contains("try") || text.contains("use") || text.contains("call")
                    || text.contains("grant") || text.contains("activate"),
                    "no next step offered: \(error.description)")
        }
    }

    // MARK: - The description must match the configuration

    /// The confinement sentence was fixed text, so `--no-sandbox` still told the model
    /// its commands ran confined. Not a harmless falsehood: it steers away from `ps`
    /// for a reason that no longer holds, and gives the model a wrong picture of its
    /// own containment while it is deciding what is safe to run.
    @Test("A sandboxed run says so, and an unsandboxed one says the opposite")
    func shellDescriptionMatchesTheSandbox() {
        let sandboxed = ShellTool(sandbox: .enabled).description
        #expect(sandboxed.contains("confined by `sandbox-exec`"))
        #expect(sandboxed.contains("pgrep"), "the ps workaround only applies when confined")
        #expect(!sandboxed.contains("--no-sandbox"))

        let open = ShellTool(sandbox: .disabled).description
        #expect(open.contains("**not** confined"))
        #expect(open.contains("--no-sandbox"))
        #expect(!open.contains("confined by `sandbox-exec`"),
                "an unsandboxed run must not claim confinement")
    }

    /// Everything that is true either way must survive the split — it would be easy to
    /// lose the actual usage guidance while rewriting the one paragraph that varies.
    @Test("Both forms keep the guidance that does not depend on the sandbox",
          arguments: [ShellSandbox.enabled, .disabled])
    func shellDescriptionKeepsSharedGuidance(sandbox: ShellSandbox) {
        let description = ShellTool(sandbox: sandbox).description
        for expected in ["/bin/zsh -c", "100KB", "mdfind", "system_profiler",
                         "prefer it over looking at the screen"] {
            #expect(description.contains(expected), "\(sandbox) lost \(expected)")
        }
    }

    // MARK: - Explaining a sandbox refusal

    /// The check was `contains("operation not permitted")` against output that says
    /// "Operation not permitted" — one capital, the same mistake this project already
    /// recorded about path comparison — and writes are refused as "Permission denied",
    /// which it never matched at all. The explanation had therefore never once
    /// appeared: the model saw a bare denial with no reason to suspect the sandbox,
    /// and the obvious next move from there is `sudo`.
    @Test("Both shapes of refusal are recognised", arguments: [
        "touch: /Library/x: Permission denied",
        "wc: /private/var/db/x: Operation not permitted",
        "ps: operation not permitted",
        "sandbox-exec: deny file-write-create",
    ])
    func sandboxRefusalsAreExplained(failure: String) {
        let explained = ShellSandbox.enabled.explain(failure: failure)
        #expect(explained.contains("the sandbox refusing"), "not explained: \(failure)")
        #expect(explained.contains(failure), "the original message must survive")
    }

    /// A failure that has nothing to do with the sandbox must not be blamed on it —
    /// an explanation attached to every error is an explanation worth nothing.
    @Test("An ordinary failure is passed through untouched", arguments: [
        "fatal: not a git repository",
        "ls: /nope: No such file or directory",
        "zsh: command not found: frobnicate",
    ])
    func ordinaryFailuresAreNotExplained(failure: String) {
        #expect(ShellSandbox.enabled.explain(failure: failure) == failure)
    }

    /// An unsandboxed run cannot be refused by a sandbox it is not using.
    @Test("A disabled sandbox explains nothing")
    func disabledSandboxExplainsNothing() {
        let failure = "touch: /Library/x: Permission denied"
        #expect(ShellSandbox.disabled.explain(failure: failure) == failure)
    }

    /// The first version inferred the cause from the wording, and got `ps aux` wrong
    /// immediately: it fails as "zsh:1: operation not permitted: ps", which names
    /// neither a process nor a path. Both remedies are given now — two short lines
    /// that are always right beat one that is sometimes confidently wrong.
    @Test("Both remedies are offered, whatever the wording", arguments: [
        "touch: /Library/x: Permission denied",
        "zsh:1: operation not permitted: ps",
    ])
    func bothRemediesAreOffered(failure: String) {
        let explained = ShellSandbox.enabled.explain(failure: failure)
        #expect(explained.contains("pgrep"))
        #expect(explained.contains("confined to the user's own files"))
    }

    /// Reaching for `sudo` is the natural next move from an unexplained denial, and
    /// it is destructive — the message should close that door explicitly.
    @Test("The explanation names the user's decision, not a workaround")
    func explanationDoesNotInviteSudo() {
        let explained = ShellSandbox.enabled.explain(failure: "touch: /Library/x: Permission denied")
        #expect(explained.contains("--no-sandbox"))
        #expect(explained.contains("not something to work around with `sudo`"))
    }

    /// The environment probe is captured once, at the start of a run, and goes stale
    /// the moment anything activates a different app. That is only safe because every
    /// capture names the app it actually read — otherwise a model oriented by a stale
    /// probe could reason about the wrong window with nothing to correct it. The
    /// design depends on this line, so the line is asserted.
    @Test("A capture names the app it read",
          .enabled(if: AXCapture.shared.isTrusted, "needs Accessibility"))
    func captureNamesItsApp() async throws {
        let output = try await AXCaptureTool().run(.object([:]))
        let first = try #require(text(output).split(separator: "\n").first)
        #expect(first.contains("—"), "expected '<app> — <n> elements', got \(first)")
        #expect(first.contains("elements"))

        let capture = try await AXCapture.shared.capture()
        #expect(first.hasPrefix(capture.app),
                "the first line should name the captured app: \(first)")
    }

    /// The third place this same belief was written down. `shell`'s own description
    /// and the system prompt's Judgement section were each made conditional when the
    /// bug was found in them; `app_script` still told the model to prefer `shell`
    /// "because it is confined", which `--no-sandbox` makes untrue — and preferring a
    /// tool for a property it does not have is worse advice than no advice.
    @Test("app_script describes the confinement that exists", arguments: [
        (ShellSandbox.enabled, "outside the sandbox that confines"),
        (.disabled, "not confined either"),
    ])
    func appScriptDescribesRealConfinement(pair: (ShellSandbox, String)) {
        let description = AppleScriptTool(sandbox: pair.0).description
        #expect(description.contains(pair.1), "expected \(pair.1)")
    }

    /// Both forms must keep the part that is true either way: a shell escape is
    /// arbitrary code execution and always prompts.
    @Test("Both forms still say a shell escape always prompts",
          arguments: [ShellSandbox.enabled, .disabled])
    func appScriptAlwaysWarnsAboutEscapes(sandbox: ShellSandbox) {
        let description = AppleScriptTool(sandbox: sandbox).description
        #expect(description.contains("always require explicit approval"))
        #expect(description.contains("do shell script"))
    }

    /// And the registry has to pass the setting through, or the tool describes a
    /// default that has nothing to do with the run.
    @Test("The registry gives app_script the run's sandbox")
    func registryPassesSandboxToAppScript() throws {
        var invocation = Invocation()
        invocation.sandbox = .disabled
        let tool = try #require(invocation.registry["app_script"])
        #expect(tool.description.contains("not confined either"))
    }

    /// Same failure one level up: the tool can only name an alternative that exists
    /// if the registry tells it what this run's ceiling is.
    @Test("The registry gives app_script the run's tier ceiling")
    func registryPassesMaxTierToAppScript() throws {
        var invocation = Invocation()
        invocation.maxTier = .script
        let tool = try #require(invocation.registry["app_script"] as? AppleScriptTool)
        #expect(tool.maxTier == .script)
        #expect(AppleScriptTool().maxTier == .pixels, "the default is the full ladder")
    }

    /// Values read through the accessibility API come from whatever app the user
    /// happens to have open, and an app is free to return a string where the API
    /// documents an element. A force-cast on that takes the whole agent down mid-run,
    /// with a crash log naming an app the user was merely looking at. Four such casts
    /// were guarded and three were not — the usual distribution.
    @Test("A value that is not an element is declined, not bridged")
    func nonElementValuesAreRejected() {
        #expect(AXCapture.asElement("a window title" as AnyObject) == nil,
                "a string was bridged as an element")
        #expect(AXCapture.asElement(NSNumber(value: 42)) == nil)
        #expect(AXCapture.asElement(nil) == nil)

        // And a real element still passes, or the guard would simply break capture.
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        #expect(AXCapture.asElement(app) != nil, "a genuine element was refused")
    }

    /// The frame helper is the other path that reads foreign values; it must decline
    /// the same way rather than force-casting.
    @Test("A frame built from non-AXValue inputs is nil, not a crash")
    func frameRejectsWrongTypes() {
        #expect(AXCapture.frame(position: "not a value" as AnyObject,
                                size: "neither" as AnyObject) == nil)
        #expect(AXCapture.frame(position: nil, size: nil) == nil)
    }
}

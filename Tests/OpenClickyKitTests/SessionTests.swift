import Testing
import Foundation
@testable import OpenClickyKit

@Suite("Hotkey parsing")
struct HotKeyTests {

    @Test("A combination parses to modifiers and a key")
    func parsesCombination() throws {
        let combo = try HotKey.parse("opt+space")
        #expect(combo.display.contains("⌥"))
        #expect(combo.carbonModifiers != 0)
    }

    @Test("Modifier aliases agree", arguments: [
        ("cmd+k", "command+k"), ("opt+k", "option+k"), ("opt+k", "alt+k"), ("ctrl+k", "control+k"),
    ])
    func aliasesAgree(pair: (String, String)) throws {
        #expect(try HotKey.parse(pair.0).carbonModifiers == HotKey.parse(pair.1).carbonModifiers)
    }

    @Test("Modifiers combine and render in order")
    func combinesModifiers() throws {
        let combo = try HotKey.parse("cmd+shift+k")
        #expect(combo.display.contains("⌘"))
        #expect(combo.display.contains("⇧"))
        #expect(combo.display.hasSuffix("K"))
    }

    /// A global hotkey with no modifier fires while the user is typing in any
    /// application — worse than having no hotkey at all.
    @Test("A bare key is refused", arguments: ["space", "k", "Return", "F5"])
    func refusesBareKeys(combo: String) {
        #expect(throws: HotKey.Error.self) { try HotKey.parse(combo) }
    }

    @Test("The refusal explains why", arguments: ["space"])
    func explainsBareKeyRefusal(combo: String) {
        do {
            _ = try HotKey.parse(combo)
            Issue.record("expected a throw")
        } catch let error as HotKey.Error {
            #expect(error.description.contains("while you were typing"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test("Unknown modifiers and keys are refused", arguments: ["hyper+k", "cmd+Frobnicate"])
    func refusesNonsense(combo: String) {
        #expect(throws: HotKey.Error.self) { try HotKey.parse(combo) }
    }

    /// `cmd+` was reported as having no modifier, which is both wrong and
    /// unactionable — it has one, and needs a key. The guard that was supposed to
    /// catch the genuine no-modifier case turned out to be unreachable: an earlier
    /// check rejected every single-part combination first, so it read as a guard
    /// while guarding nothing. Found by mutating it and seeing nothing fail.
    @Test("A failure says which half is missing", arguments: [
        ("cmd+", "no key"),
        ("cmd", "no key"),
        ("shift+ctrl", "no key"),
        ("space", "no modifier"),
        ("+k", "no modifier"),
    ])
    func failuresNameTheMissingHalf(scenario: (String, String)) {
        do {
            _ = try HotKey.parse(scenario.0)
            Issue.record("'\(scenario.0)' should not have parsed")
        } catch let error as HotKey.Error {
            switch scenario.1 {
            case "no key":
                #expect(error == .missingKey(scenario.0), "got: \(error)")
                #expect(error.description.contains("no key"))
            default:
                #expect(error == .noModifier(scenario.0), "got: \(error)")
                #expect(error.description.contains("no modifier"))
            }
        } catch { Issue.record("unexpected: \(error)") }
    }

    @Test("A repeated modifier is not doubled in the display")
    func repeatedModifiersRenderOnce() throws {
        #expect(try HotKey.parse("cmd+command+k").display == "\u{2318}K")
    }
}

@Suite("Session state machine", .serialized)
struct SessionControllerTests {

    private func makeController() -> (SessionController, Recorder) {
        let recorder = Recorder()
        let controller = SessionController { state in await recorder.record(state) }
        return (controller, recorder)
    }

    private actor Recorder {
        private(set) var states: [SessionState] = []
        func record(_ state: SessionState) { states.append(state) }
    }

    @Test("The hotkey opens the input")
    func summonOpensInput() async {
        let (controller, _) = makeController()
        await controller.summon()
        #expect(await controller.state == .accepting(draft: ""))
        #expect(await controller.state.isVisible)
    }

    /// Pressing the hotkey again mid-run must not throw away the run.
    @Test("The hotkey does not reset work in progress")
    func summonDoesNotResetRunningWork() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("do something")
        #expect(await controller.state == .working(activity: "Thinking…"))

        await controller.summon()
        #expect(await controller.state == .working(activity: "Thinking…"), "the run must survive a second hotkey press")
    }

    @Test("An empty task is not submitted", arguments: ["", "   ", "\n"])
    func emptyTaskIsRejected(draft: String) async {
        let (controller, _) = makeController()
        await controller.summon()
        #expect(await controller.submit(draft) == nil)
        #expect(await controller.state == .accepting(draft: draft))
    }

    /// The app could not run a task at all: the text field held the draft, the
    /// controller held its own copy that nothing updated, and `submit` read the empty
    /// one. Every piece worked; the wiring between them did not exist. Requiring the
    /// text as an argument makes that unrepresentable — this test would not compile
    /// against the old signature.
    @Test("Submitting requires the text, so it cannot be lost in the wiring")
    func submitTakesTheTaskExplicitly() async {
        let (controller, _) = makeController()
        await controller.summon()

        // Nothing has called updateDraft, exactly as in the app.
        #expect(await controller.submit("check my disk usage") == "check my disk usage")
        #expect(await controller.state == .working(activity: "Thinking…"))
    }

    @Test("Submitting outside the accepting state does nothing")
    func submitOnlyFromAccepting() async {
        let (controller, _) = makeController()
        #expect(await controller.submit("task") == nil, "dormant")

        await controller.summon()
        _ = await controller.submit("first")
        #expect(await controller.submit("second") == nil, "already working")
    }

    @Test("A submitted task is trimmed")
    func submittedTaskIsTrimmed() async {
        let (controller, _) = makeController()
        await controller.summon()
        #expect(await controller.submit("  open Finder  ") == "open Finder")
    }

    /// Escape means two different things depending on state, and getting it
    /// backwards either strands a running agent or dismisses nothing.
    @Test("Escape dismisses when idle and stops when working")
    func escapeIsContextual() async {
        let (controller, _) = makeController()

        await controller.summon()
        #expect(await controller.escape() == false, "idle: dismiss, nothing to cancel")
        #expect(await controller.state == .dormant)

        await controller.summon()
        _ = await controller.submit("task")
        #expect(await controller.escape() == true, "working: cancel the run")
        #expect(await controller.state == .stopped(reason: "Stopped."))
    }

    @Test("Escape during an approval also stops the run")
    func escapeDuringApprovalStops() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("task")
        await controller.handle(.toolStarted(name: "shell", tier: .shell, summary: "rm x"))

        // Simulate being parked in an approval.
        let approved = await controller.requestApproval(
            tool: "shell", summary: "rm x", isDestructive: true
        ) {
            #expect(await controller.state.isInterruptible)
            return false
        }
        #expect(approved == false)
    }

    @Test("Agent events drive the visible activity")
    func agentEventsDriveActivity() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("task")

        await controller.handle(.toolStarted(name: "shell", tier: .shell, summary: "ls -la"))
        #expect(await controller.state == .working(activity: "[T0] shell: ls -la"))

        await controller.handle(.toolFinished(name: "shell", ok: true, detail: "…"))
        #expect(await controller.state == .working(activity: "shell ✓"))

        await controller.handle(.assistantText("Looking at your Downloads."))
        #expect(await controller.state == .working(activity: "Looking at your Downloads."))
    }

    @Test("Completion carries the cost summary")
    func completionCarriesCost() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("task")

        var meter = CostMeter(model: "claude-opus-5")
        let usage = try! JSONDecoder().decode(
            Wire.Usage.self,
            from: Data(#"{"input_tokens":1000,"output_tokens":200}"#.utf8)
        )
        meter.record(usage)
        await controller.handle(.cost(meter))
        await controller.handle(.finished(reason: "end_turn"))

        guard case let .finished(_, cost) = await controller.state else {
            Issue.record("expected a finished state")
            return
        }
        #expect(cost?.contains("$") == true)
    }

    /// An interruption is the user's own doing; reporting it as a completion with a
    /// reason attached reads as though the agent decided to stop.
    @Test("An interruption reads as stopped, not as finished")
    func interruptionReadsAsStopped() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("task")
        await controller.handle(.finished(reason: "interrupted by the user"))
        #expect(await controller.state == .stopped(reason: "Stopped."))
    }

    @Test("An approval restores the previous activity afterwards")
    func approvalRestoresPreviousState() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("task")
        await controller.handle(.toolStarted(name: "shell", tier: .shell, summary: "ls"))
        let before = await controller.state

        _ = await controller.requestApproval(tool: "shell", summary: "ls", isDestructive: false) { true }
        #expect(await controller.state == before, "the run should resume where it paused")
    }

    @Test("Only the dormant state is hidden")
    func visibilityMatchesState() {
        #expect(!SessionState.dormant.isVisible)
        #expect(SessionState.accepting(draft: "").isVisible)
        #expect(SessionState.working(activity: "x").isVisible)
        #expect(SessionState.finished(summary: "done", cost: nil).isVisible)
    }

    /// The overlay decided between "stopped" and "finished" with
    /// `reason.contains("interrupted")` — a control-flow decision resting on wording
    /// owned by another module. Rephrasing the loop's message to "Interrupted by the
    /// user" would have silently turned every stopped run into a completed one, with
    /// nothing anywhere to fail.
    @Test("An interrupted run reads as stopped, matched on the constant")
    func interruptionIsMatchedOnAConstant() async {
        let controller = SessionController { _ in }
        await controller.handle(.finished(reason: AgentLoop.Event.interruptedReason))

        let state = await controller.state
        guard case let .stopped(reason) = state else {
            Issue.record("an interruption reported as \(state)")
            return
        }
        #expect(reason == "Stopped.")
    }

    /// And an ordinary completion must not be mistaken for one — the old substring
    /// would have matched a reason that merely mentioned the word.
    @Test("An ordinary completion still reads as finished", arguments: [
        "turn limit (40) reached",
        "end_turn",
        "the task was interrupted by a dialog the user dismissed",
    ])
    func ordinaryCompletionsAreNotStopped(reason: String) async {
        let controller = SessionController { _ in }
        await controller.handle(.finished(reason: reason))

        let state = await controller.state
        guard case .finished = state else {
            Issue.record("\(reason) reported as \(state)")
            return
        }
    }
}

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

    /// The whole promise of a persistent overlay, at the surface. A finished task used
    /// to dismiss itself after four seconds, so the follow-up instruction had nowhere
    /// to go — and the loop that would have understood it had been thrown away.
    @Test("A finished task accepts the next instruction")
    func finishedStateAcceptsTheNextInstruction() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("what is my hostname")
        await controller.handle(.finished(reason: "end_turn"))
        guard case .finished = await controller.state else {
            Issue.record("expected a finished state")
            return
        }

        #expect(await controller.submit("how many characters is that") == "how many characters is that")
        #expect(await controller.state == .working(activity: "Thinking…"))
    }

    /// A stopped task is a conversation too. Losing the thread because one instruction
    /// was interrupted is exactly the moment the user least wants to start again.
    @Test("A stopped task accepts the next instruction")
    func stoppedStateAcceptsTheNextInstruction() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("open Safari")
        _ = await controller.escape()
        #expect(await controller.state == .stopped(reason: "Stopped."))

        #expect(await controller.submit("try again") == "try again")
    }

    /// Which states take an instruction is one rule, used by the controller to decide
    /// whether to accept and by the overlay to decide whether to draw a field. Two
    /// copies would disagree on the day one of them learned about a new state.
    @Test("Only the idle states take an instruction")
    func readinessMatchesState() {
        #expect(SessionState.accepting(draft: "").isReadyForInput)
        #expect(SessionState.finished(summary: "done", cost: nil).isReadyForInput)
        #expect(SessionState.stopped(reason: "Stopped.").isReadyForInput)
        #expect(!SessionState.dormant.isReadyForInput)
        #expect(!SessionState.working(activity: "x").isReadyForInput)
        #expect(!SessionState.awaitingApproval(
            .init(tool: "shell", summary: "rm", isDestructive: true)
        ).isReadyForInput)
    }

    /// Four commits exist to make the per-task verdict honest. A keypress that only
    /// asked for the input field must not be what removes it from the screen — the
    /// field is already there.
    @Test("Nothing that only asks for the field clears the last verdict")
    func theVerdictSurvivesAnIdleKeypress() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("count my downloads")
        await controller.handle(.finished(reason: "end_turn"))
        let verdict = await controller.state

        await controller.summon()
        #expect(await controller.state == verdict, "the hotkey re-focuses; it does not reset")

        #expect(await controller.submit("   ") == nil)
        #expect(await controller.state == verdict, "a bare Return asked for nothing")
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

    /// The one control that is *supposed* to lose the last verdict, next to a hotkey
    /// that must not. A session with no way back to a blank sheet grows its context
    /// without bound and keeps answering out of a thread the user has moved on from.
    @Test("Starting over clears the screen back to an empty input")
    func startOverClearsTheScreen() async {
        let (controller, _) = makeController()
        await controller.summon()
        _ = await controller.submit("count my downloads")
        await controller.handle(.finished(reason: "end_turn"))

        await controller.startOver()
        #expect(await controller.state == .accepting(draft: ""))
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

    // MARK: - What a stray keypress can authorise

    /// The overlay bound Return to Approve for every action, including one it had
    /// just labelled "This is destructive". The CLI requires typing "y" and treats a
    /// bare Return as denial — so the graphical surface was the more permissive of the
    /// two at exactly the moment that matters most, and a keypress arrived at by habit
    /// could authorise an irreversible command.
    @Test("A destructive action cannot be approved by a bare Return")
    func destructiveNeedsADeliberateKey() {
        let destructive = SessionState.Approval(
            tool: "shell", summary: "rm -rf ~/Documents", isDestructive: true
        )
        #expect(!destructive.acceptsBareReturn)
    }

    /// And an ordinary action must stay cheap to approve, or the prompt becomes
    /// something people click through without reading.
    @Test("An ordinary action is approved by Return")
    func ordinaryActionAcceptsReturn() {
        let ordinary = SessionState.Approval(
            tool: "write_file", summary: "create ~/notes.txt", isDestructive: false
        )
        #expect(ordinary.acceptsBareReturn)
    }

    /// The two surfaces should agree about what counts as consent.
    ///
    /// Written a commit ago, this re-implemented the CLI's `switch` rather than
    /// calling it — in a test whose stated purpose was that the pair could not drift
    /// apart unnoticed. It had already drifted: the copy still said "a" is
    /// `.allowAlways` for every action, which stopped being true when "a" was made a
    /// denial for destructive ones. It passed anyway, because it only ever fed it
    /// empty answers. Calling the real parser is the whole point.
    @Test("A bare Return is not consent in either surface", arguments: ["", " ", "\n", "\t"])
    func bareReturnIsNotConsentInTheCLI(answer: String) {
        #expect(PermissionGate.parse(answer, isDestructive: false) == .deny)
        #expect(PermissionGate.parse(answer, isDestructive: true) == .deny)
    }

    /// The overlay and the CLI must agree on the harder half too: neither accepts an
    /// answer it did not offer for a destructive action.
    @Test("Neither surface takes an unadvertised answer as consent")
    func surfacesAgreeOnDestructive() {
        let destructive = SessionState.Approval(
            tool: "shell", summary: "rm -rf ~/Documents", isDestructive: true
        )
        #expect(!destructive.acceptsBareReturn, "the overlay would take a stray Return")
        #expect(PermissionGate.parse("a", isDestructive: true) == .deny,
                "the CLI would take an unoffered key")
    }
}

/// The retained record of what a run did, which the overlay's panel renders.
///
/// The two properties worth defending are the ones that fail silently: it must stay
/// bounded, because the session it belongs to can run for hours; and it must never
/// hold a string the transcript deliberately does not.
@Suite("Activity log", .serialized)
struct ActivityLogTests {

    @Test("Every tool event is recorded, in the order it happened")
    func recordsEveryToolEventInOrder() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("look at something")

        await controller.handle(.toolStarted(name: "shell", tier: .shell, summary: "ls -la"))
        await controller.handle(.toolFinished(name: "shell", ok: true, detail: "three files"))
        await controller.handle(.toolStarted(name: "click", tier: .pixels, summary: "click 10,10"))
        await controller.handle(.toolFinished(name: "click", ok: false, detail: "no observable change"))

        let log = await controller.activity
        #expect(log.entries.map(\.kind) == [.instruction, .started, .succeeded, .started, .failed])
        #expect(log.entries.map(\.tool) == ["", "shell", "shell", "click", "click"])
        #expect(log.entries[0].detail == "look at something")
        #expect(log.entries[1].tier == .shell)
        #expect(log.entries[3].tier == .pixels)
        #expect(log.entries[4].detail == "no observable change")
    }

    /// The tier of a finish is recovered from the tool's name, because the event does
    /// not carry one — and honestly left nil for a name this build has never heard of
    /// rather than guessed at.
    @Test("A finish recovers its tier from the tool name, or admits it cannot")
    func finishRecoversTier() {
        var log = ActivityLog()
        log.record(.toolFinished(name: "ax_press", ok: true, detail: "pressed"))
        log.record(.toolFinished(name: "not_a_tool", ok: true, detail: "?"))
        #expect(log.entries[0].tier == .accessibility)
        #expect(log.entries[1].tier == nil)
    }

    /// The narration has a home on screen already. A log that carried it too would
    /// answer "what did it do" worse than one that does not.
    @Test("Prose, cost and the verdict are not steps")
    func ignoresNonActions() {
        var log = ActivityLog()
        #expect(log.record(.thinking) == false)
        #expect(log.record(.assistantText("I will look at your Downloads.")) == false)
        #expect(log.record(.usage(input: 10, output: 2, cacheRead: 8)) == false)
        #expect(log.record(.finished(reason: "end_turn")) == false)
        #expect(log.isEmpty)
    }

    /// A run that was refused something is exactly what the panel is watched for, and
    /// a skip is how the user learns the rest of a batch never happened.
    @Test("A denial and a skip are both visible")
    func denialsAndSkipsAreVisible() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("delete everything")

        await controller.handle(.toolDenied(name: "shell", reason: "You declined this action."))
        await controller.handle(.toolSkipped(name: "click"))

        let log = await controller.activity
        #expect(log.entries.map(\.kind) == [.instruction, .denied, .skipped])
        #expect(log.entries[1].detail.contains("declined"))
        #expect(log.entries[2].detail.contains("earlier action"))
    }

    /// The session is persistent — one loop, one overlay, for as long as it is left
    /// running — so a log that only ever grew would be a leak measured in hours.
    @Test("The log stays bounded, and says how much it dropped")
    func staysBoundedAndSaysSo() {
        var log = ActivityLog()
        let total = ActivityLog.capacity * 3
        for index in 0..<total {
            log.record(.toolFinished(name: "shell", ok: true, detail: "result \(index)"))
        }

        #expect(log.entries.count == ActivityLog.capacity)
        #expect(log.elided == total - ActivityLog.capacity)
        #expect(log.totalRecorded == total)
        // Trimmed from the front, so what remains is contiguous and ends at the
        // present. A cap that dropped the newest would freeze the panel on minute one.
        #expect(log.entries.last?.detail == "result \(total - 1)")
        #expect(log.entries.first?.detail == "result \(total - ActivityLog.capacity)")
        // Identities are never reused, or SwiftUI would animate a trim as though every
        // surviving row had changed into a different one.
        #expect(Set(log.entries.map(\.id)).count == ActivityLog.capacity)
        #expect(log.entries.map(\.id) == Array(log.entries.map(\.id)).sorted())
    }

    /// Per conversation, not per task: "now close it" is judged against what the last
    /// instruction actually did, and clearing at each `.finished` would throw that
    /// away at exactly the moment the next instruction is typed.
    @Test("The log survives a task boundary")
    func survivesTaskBoundary() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("open Safari")
        await controller.handle(.toolStarted(name: "app_script", tier: .script, summary: "activate Safari"))
        await controller.handle(.toolFinished(name: "app_script", ok: true, detail: "ok"))
        await controller.handle(.finished(reason: "end_turn"))

        _ = await controller.submit("now close it")
        let log = await controller.activity
        #expect(log.entries.filter { $0.kind == .instruction }.map(\.detail)
                == ["open Safari", "now close it"])
        #expect(log.entries.contains { $0.tool == "app_script" },
                "the previous task's calls are what the next instruction is read against")
    }

    /// The one place losing it is the point — the same place the last task's verdict
    /// is deliberately lost, because the thread it belonged to is over.
    @Test("Starting a new conversation empties the log")
    func startOverClearsTheLog() async {
        let controller = SessionController { _ in }
        await controller.summon()
        _ = await controller.submit("open Safari")
        await controller.handle(.toolFinished(name: "app_script", ok: true, detail: "ok"))
        #expect(await controller.activity.isEmpty == false)

        await controller.startOver()
        let log = await controller.activity
        #expect(log.isEmpty)
        #expect(log.elided == 0)
    }

    /// `transition` does nothing when the state is unchanged, and two identical
    /// results in a row *are* the same state — so the log needs its own channel or the
    /// panel drops exactly the repetition it exists to make visible.
    @Test("The log is delivered even when the state does not change")
    func deliveredWhenStateIsUnchanged() async {
        let recorder = LogRecorder()
        let controller = SessionController(
            onChange: { _ in },
            onActivity: { log in await recorder.record(log) }
        )
        await controller.summon()
        _ = await controller.submit("do it twice")
        await controller.handle(.toolFinished(name: "shell", ok: true, detail: "same"))
        await controller.handle(.toolFinished(name: "shell", ok: true, detail: "same"))

        #expect(await recorder.counts == [1, 2, 3], "the instruction and both results")
    }

    private actor LogRecorder {
        private(set) var counts: [Int] = []
        func record(_ log: ActivityLog) { counts.append(log.entries.count) }
    }
}

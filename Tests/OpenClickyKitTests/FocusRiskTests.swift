import Testing
import Foundation
@testable import OpenClickyKit

/// The gate's newest arm, and the argument that it is narrow enough to be there.
///
/// `.focus` never prompts. That is a hole in the only containment this project has
/// unless it is earned twice — once on effect and once on argument — so most of this
/// suite is about the second half: that a `FocusChange` cannot be conjured, and that the
/// one mode whose promise is "nothing changes" still refuses it.
@Suite("Focus risk")
struct FocusRiskTests {

    private func entry(_ identifier: String = "com.apple.Safari", name: String = "Safari")
        -> AppCatalogue.Entry
    {
        AppCatalogue.Entry(
            bundleIdentifier: identifier,
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            isRunning: false
        )
    }

    /// Records whether the gate ever put anything to the user. The same shape
    /// `PermissionGateTests` uses, for the same reason.
    private final class PromptSpy: @unchecked Sendable {
        private(set) var callCount = 0
        var prompt: PermissionGate.Prompt {
            { [self] _, _, _ in callCount += 1; return .allow }
        }
    }

    // MARK: - The mode table

    /// The one mode that must still say no. Read-only promises that nothing changes, and
    /// a process starting and a window coming forward is a change — a small, reversible
    /// one, but the promise is not "small changes are fine".
    @Test("A focus change is refused in read-only mode")
    func readOnlyRefuses() async {
        let spy = PromptSpy()
        let gate = PermissionGate(mode: .readOnly, prompt: spy.prompt)
        let decision = await gate.decide(
            tool: "activate_app", risk: .focus(.activate(entry()))
        )
        guard case let .deny(reason) = decision else {
            Issue.record("read-only allowed a focus change")
            return
        }
        #expect(reason.contains("read-only"))
        #expect(spy.callCount == 0, "read-only asked instead of refusing")
    }

    /// The point of the class. Classified `.write`, a voice session in `.ask` would
    /// prompt every time somebody said "open Safari" — spending the gate's only asset,
    /// the user's attention, on a call that cannot hurt them.
    @Test("A focus change runs unasked in every mode that acts", arguments: [
        PermissionMode.ask, .auto, .bypass,
    ])
    func actingModesAllowSilently(mode: PermissionMode) async {
        let spy = PromptSpy()
        let gate = PermissionGate(mode: mode, prompt: spy.prompt)
        let decision = await gate.decide(
            tool: "activate_app", risk: .focus(.activate(entry()))
        )
        #expect(decision == .allow)
        #expect(spy.callCount == 0, "\(mode) prompted for a focus change")
    }

    /// The task allowlist exists so a *repeated* prompt can be silenced. A call that
    /// never prompts has nothing to remember, and an entry would be a standing grant
    /// established by a call that never asked for one.
    @Test("A focus change never leaves a standing grant behind")
    func focusLeavesNoAllowlistEntry() async {
        // If the focus decision inserted "activate_app" into the allowlist, a *write*
        // by the same tool would now run unasked.
        let spy = PromptSpy()
        let gate = PermissionGate(mode: .ask, prompt: spy.prompt)
        await gate.beginTask()
        _ = await gate.decide(tool: "activate_app", risk: .focus(.activate(entry())))
        _ = await gate.decide(
            tool: "activate_app", risk: .write(summary: "something else entirely")
        )
        #expect(spy.callCount == 1,
                "a focus change silently authorised a write by the same tool")
    }

    // MARK: - Escalation

    /// Bringing an app forward grants no permission by itself. But it is the setup for
    /// the click that does, performed by a call that never prompts — so the check that
    /// reads the live frontmost app has to cover it.
    @Test("A focus change onto a security surface is escalated")
    func escalatesOnSecuritySurface() {
        let escalated = Policy.escalate(
            .focus(.activate(entry())),
            frontmostBundleIdentifier: "com.apple.systempreferences"
        )
        guard case .dangerous = escalated else {
            Issue.record("a focus change onto a security dialog stayed unprompted")
            return
        }
    }

    @Test("A focus change anywhere ordinary is left alone")
    func doesNotEscalateElsewhere() {
        let risk = Risk.focus(.activate(entry()))
        let unchanged = Policy.escalate(risk, frontmostBundleIdentifier: "com.apple.Safari")
        #expect(unchanged == risk)
    }

    // MARK: - The argument, which is the half that rots

    /// The type is the guarantee. If `FocusChange` ever gains a public initialiser, any
    /// tool can return `.focus` from free text and exempt itself from the only prompt
    /// the user relies on — and it would be one plausible line in a diff.
    @Test("A focus change carries what it acted on, not a sentence about it")
    func identityComesFromTheCatalogue() {
        let change = FocusChange.activate(entry("com.apple.Safari", name: "Safari"))
        #expect(change.identity == "activate:com.apple.Safari")
        #expect(change.summary.contains("Safari"))

        // Two entries, two identities — this is what stops one turn's action being
        // mistaken for another's when a sentence is classified several times as it is
        // spoken.
        let other = FocusChange.activate(entry("com.google.Chrome", name: "Google Chrome"))
        #expect(change.identity != other.identity)
    }

    /// A display name comes off the disk, so it is content — and a summary carrying an
    /// escape sequence can overwrite the badge printed above it and change what the user
    /// believes they are approving.
    @Test("A focus summary is sanitised on the way to a prompt")
    func summaryIsSanitised() {
        let hostile = entry("com.example.Evil", name: "Evil\u{001B}[2KApp")
        let risk = Risk.focus(.activate(hostile))
        #expect(!risk.summary.contains("\u{001B}"),
                "an escape sequence from an app's own name reached the prompt")
    }

    // MARK: - The sites that take a new case silently

    /// `AgentLoop` counts with `if case .read`, so `.focus` joins the `else` without
    /// anyone deciding it should. It is the right bucket — bringing an app forward is
    /// something the run did, not something it saw — and this pins that it stays so.
    @Test("A focus change counts as an action, not an observation")
    func focusIsAnAction() {
        let risk = Risk.focus(.activate(entry()))
        if case .read = risk {
            Issue.record("a focus change started reading as an observation")
        }
    }

    /// The approval prompts branch on `if case .dangerous`. `.focus` is not destructive,
    /// and in fact can never reach a prompt at all: read-only denies it and every other
    /// mode allows it, so the only way it is ever put to a user is after
    /// `Policy.escalate` has already turned it into `.dangerous`.
    @Test("A focus change is never put to the user as a destructive call")
    func focusIsNotDestructive() {
        let risk = Risk.focus(.activate(entry()))
        if case .dangerous = risk {
            Issue.record("a focus change presents as destructive")
        }
    }
}

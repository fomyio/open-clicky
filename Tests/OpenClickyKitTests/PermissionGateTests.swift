import Testing
@testable import OpenClickyKit

@Suite("Permission gate")
struct PermissionGateTests {

    /// A prompt that records whether it was consulted, so tests can assert on
    /// silence as well as on the decision.
    private final class PromptSpy: @unchecked Sendable {
        private(set) var callCount = 0
        private let answer: Bool
        init(answer: Bool) { self.answer = answer }
        var prompt: PermissionGate.Prompt {
            { [self] _, _, _ in callCount += 1; return answer }
        }
    }

    @Test("Reads never prompt, in any mode", arguments: PermissionMode.allCases)
    func readsAreAlwaysAllowed(mode: PermissionMode) async {
        let spy = PromptSpy(answer: false)
        let gate = PermissionGate(mode: mode, prompt: spy.prompt)
        #expect(await gate.decide(tool: "ax_capture", risk: .read) == .allow)
        #expect(spy.callCount == 0)
    }

    @Test("read-only mode refuses writes without asking")
    func readOnlyRefusesWrites() async {
        let spy = PromptSpy(answer: true)
        let gate = PermissionGate(mode: .readOnly, prompt: spy.prompt)
        let decision = await gate.decide(tool: "shell", risk: .write(summary: "touch x"))
        guard case .deny = decision else { Issue.record("expected deny, got \(decision)"); return }
        #expect(spy.callCount == 0)
    }

    @Test("auto mode allows writes silently but still asks before destructive actions")
    func autoModeEscalatesOnlyForDangerous() async {
        let spy = PromptSpy(answer: true)
        let gate = PermissionGate(mode: .auto, prompt: spy.prompt)

        #expect(await gate.decide(tool: "shell", risk: .write(summary: "mkdir x")) == .allow)
        #expect(spy.callCount == 0)

        #expect(await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -r x")) == .allow)
        #expect(spy.callCount == 1)
    }

    @Test("bypass mode never prompts")
    func bypassNeverPrompts() async {
        let spy = PromptSpy(answer: false)
        let gate = PermissionGate(mode: .bypass, prompt: spy.prompt)
        #expect(await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -r x")) == .allow)
        #expect(spy.callCount == 0)
    }

    @Test("A declined prompt denies the action")
    func declineDenies() async {
        let spy = PromptSpy(answer: false)
        let gate = PermissionGate(mode: .ask, prompt: spy.prompt)
        let decision = await gate.decide(tool: "click", risk: .write(summary: "click at (10,10)"))
        guard case .deny = decision else { Issue.record("expected deny, got \(decision)"); return }
    }

    @Test("Always-allow suppresses later prompts for that tool")
    func sessionAllowlistSuppressesPrompts() async {
        let spy = PromptSpy(answer: true)
        let gate = PermissionGate(mode: .ask, prompt: spy.prompt)

        #expect(await gate.decide(tool: "shell", risk: .write(summary: "a")) == .allow)
        #expect(spy.callCount == 1)

        await gate.alwaysAllow("shell")
        #expect(await gate.decide(tool: "shell", risk: .write(summary: "b")) == .allow)
        #expect(spy.callCount == 1, "an allowlisted tool should not prompt again")
    }

    /// "Always allow shell" is a statement about routine commands. Letting it
    /// cover a destructive call would turn one approval into a blank cheque.
    @Test("Always-allow does not extend to destructive actions")
    func allowlistDoesNotCoverDangerous() async {
        let spy = PromptSpy(answer: true)
        let gate = PermissionGate(mode: .ask, prompt: spy.prompt)
        await gate.alwaysAllow("shell")

        _ = await gate.decide(tool: "shell", risk: .dangerous(summary: "rm -rf build"))
        #expect(spy.callCount == 1, "destructive actions must prompt even when allowlisted")
    }
}

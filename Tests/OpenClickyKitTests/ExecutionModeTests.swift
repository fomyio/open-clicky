import Testing
import Foundation
@testable import OpenClickyKit

/// Auto-approval turns the permission gate — the only containment this project has —
/// into a setting. What is defended here is that it can only ever fail *closed*, that a
/// value the user chose survives a round trip through the file, and that changing it
/// takes effect on the next instruction rather than the next launch.
@Suite("Execution mode")
struct ExecutionModeTests {

    // MARK: - Resolving what was stored

    @Test("A stored mode is honoured", arguments: PermissionMode.allCases)
    func storedModeIsHonoured(mode: PermissionMode) {
        let settings = ConfigFile.Settings(executionMode: mode.rawValue)
        #expect(PermissionMode.stored(settings) == mode)
    }

    /// The direction that matters. A config file written by a newer build, hand-edited,
    /// or half-truncated by a crash has to leave an agent that asks too often — never
    /// one that has quietly stopped asking. Every one of these inputs is a way that file
    /// can realistically arrive.
    @Test("Anything unreadable falls back to asking", arguments: [
        "", "   ", "Auto", "AUTO", "bypasss", "yes", "true", "1", "read-only!",
        "auto bypass", "readonly", "-", "null",
    ])
    func unrecognisedModesFailClosed(raw: String) {
        let settings = ConfigFile.Settings(executionMode: raw)
        #expect(PermissionMode.stored(settings) == .ask,
                "'\(raw)' resolved to something other than the restrictive default")
    }

    /// Surrounding whitespace is trimmed on the way in, like every other stored field.
    /// This is the one direction where being lenient is right: the file is documented as
    /// hand-editable, and a trailing newline from an editor is not a person asking for
    /// a different permission.
    @Test("A hand-edited value with stray whitespace still resolves",
          arguments: ["auto\n", " auto", "auto ", "\tauto\n"])
    func surroundingWhitespaceIsTrimmed(raw: String) {
        #expect(PermissionMode.stored(ConfigFile.Settings(executionMode: raw)) == .auto)
    }

    @Test("A settings file that names no mode leaves the agent asking")
    func absentModeFailsClosed() {
        #expect(PermissionMode.stored(ConfigFile.Settings()) == .ask)
        #expect(PermissionMode.stored(ConfigFile.Settings(provider: "anthropic")) == .ask)
    }

    // MARK: - Surviving the file

    @Test("The mode round-trips through the config file")
    func modeRoundTrips() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(executionMode: PermissionMode.auto.rawValue))
        #expect(PermissionMode.stored(try config.settings()) == .auto)
    }

    /// The regression the settings panel had. `ProviderSelection.settings` describes the
    /// provider half only, so handing it to `setSettings` wrote `executionMode: nil` —
    /// and picking a model silently reset the agent to asking. A permission that a
    /// *different* setting can switch off is worse than one that was never offered.
    @Test("Changing the provider does not silently reset the mode")
    func providerChangeKeepsTheMode() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        var stored = ConfigFile.Settings(
            provider: "anthropic", model: "claude-haiku-4-5",
            executionMode: PermissionMode.auto.rawValue
        )
        try config.setSettings(stored)

        // What the panel now writes: the provider half, with the mode folded back in.
        let selection = ProviderSelection.stored(try config.settings())
            .switching(to: .ollama)
        stored = selection.settings
        stored.executionMode = PermissionMode.stored(try config.settings()).rawValue
        try config.setSettings(stored)

        #expect(PermissionMode.stored(try config.settings()) == .auto,
                "picking a provider turned auto-approval off")
    }

    @Test("A file holding only a mode still decodes")
    func modeAloneIsAValidFile() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(executionMode: PermissionMode.auto.rawValue))
        let read = try config.settings()
        #expect(read.provider == nil)
        #expect(read.executionMode == PermissionMode.auto.rawValue)
        #expect(!read.isEmpty, "a settings value carrying a mode is not empty")
    }

    // MARK: - A file other accounts can write

    /// The rest of `Settings` answers "which endpoint answers". `executionMode` answers
    /// "may the agent act without asking", which makes a *writable* config file a way to
    /// switch the gate off — with no code execution as this user, which is the bar the
    /// file's own header treats as the line worth defending. A home directory left
    /// group-writable by a restored backup or a recursive `chmod` is enough.
    @Test("A mode stored in a file other accounts can reach is not honoured",
          arguments: [0o604, 0o606, 0o620, 0o660, 0o666, 0o640, 0o642])
    func permissiveFileLosesItsMode(mode: Int) throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(
            provider: "anthropic", model: "claude-haiku-4-5",
            executionMode: PermissionMode.bypass.rawValue
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: config.url.path
        )

        let settings = try config.settings()
        #expect(settings.executionMode == nil, "mode \(String(format: "%03o", mode)) kept its mode")
        #expect(PermissionMode.stored(settings) == .ask)
        // Dropped, not thrown: the settings window has to stay usable at the one moment
        // it is needed to repair the file.
        #expect(settings.model == "claude-haiku-4-5", "the rest of the file stopped being readable")
    }

    @Test("A correctly protected file keeps its mode")
    func protectedFileKeepsItsMode() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(executionMode: PermissionMode.auto.rawValue))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: config.url.path
        )
        #expect(PermissionMode.stored(try config.settings()) == .auto)
    }

    /// Writing repairs the file, so the choice can be made again immediately rather than
    /// only after the user finds a shell. `setSettings` goes past the gate for the same
    /// reason `setKey` does.
    @Test("Saving from the window repairs the file and restores the choice")
    func savingRepairsAWidenedFile() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(executionMode: PermissionMode.auto.rawValue))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666], ofItemAtPath: config.url.path
        )
        #expect(PermissionMode.stored(try config.settings()) == .ask)

        try config.setSettings(ConfigFile.Settings(executionMode: PermissionMode.auto.rawValue))
        #expect(config.permissionProblem() == nil, "the write did not restore the mode bits")
        #expect(PermissionMode.stored(try config.settings()) == .auto)
    }

    // MARK: - Taking effect

    /// `AgentLoop` takes its mode at construction and hands the same value to
    /// `SystemPrompt.session`. A loop built while the setting said Manual keeps
    /// prompting for the rest of the session however many times the switch is flipped,
    /// and the model keeps being told it will be asked — so the mode has to be part of
    /// what decides whether the loop may be reused.
    @Test("Changing the mode starts a new conversation")
    func modeChangeRebuildsTheLoop() {
        let provider = Provider(
            kind: .anthropic, model: "claude-haiku-4-5", baseURL: nil,
            credentials: .apiKey("sk-test-123456789"), source: .configFile, plannerModel: nil
        )
        var conversation = Conversation()
        _ = conversation.begin(SessionConfiguration(provider: provider, mode: .ask))
        let next = conversation.begin(SessionConfiguration(provider: provider, mode: .auto))

        guard case let .startedOver(reason) = next else {
            Issue.record("the loop was carried forward across a permission change")
            return
        }
        #expect(reason?.contains("execution mode") == true)
    }

    /// The direction that matters more: a conversation carried forward under a stale
    /// permissive mode would keep acting without asking after the user turned it off.
    @Test("Turning auto-approval off takes effect on the next instruction")
    func turningItOffRebuildsToo() {
        let provider = Provider(
            kind: .anthropic, model: "claude-haiku-4-5", baseURL: nil,
            credentials: .apiKey("sk-test-123456789"), source: .configFile, plannerModel: nil
        )
        var conversation = Conversation()
        _ = conversation.begin(SessionConfiguration(provider: provider, mode: .auto))
        let next = conversation.begin(SessionConfiguration(provider: provider, mode: .ask))
        guard case .startedOver = next else {
            Issue.record("auto-approval survived being switched off")
            return
        }
    }

    @Test("An unchanged mode carries the conversation forward")
    func unchangedModeCarriesForward() {
        let provider = Provider(
            kind: .anthropic, model: "claude-haiku-4-5", baseURL: nil,
            credentials: .apiKey("sk-test-123456789"), source: .configFile, plannerModel: nil
        )
        var conversation = Conversation()
        _ = conversation.begin(SessionConfiguration(provider: provider, mode: .auto))
        let next = conversation.begin(SessionConfiguration(provider: provider, mode: .auto))
        #expect(next == .carriedForward(instruction: 2))
    }

    // MARK: - What the window offers

    /// The UI's two positions map onto gate modes that still prompt for the
    /// irreversible set. Nothing on the window reaches `.bypass`, which prompts for
    /// nothing at all — that is a different feature from an auto-pilot and must not be
    /// reachable by misreading a two-position switch.
    @Test("No offered choice removes the destructive backstop")
    func offeredChoicesKeepTheDestructiveGate() async {
        for choice in ExecutionModeChoice.allCases {
            #expect(choice.mode != .bypass, "\(choice.title) reaches the ungated mode")

            let asked = AskedSpy()
            let gate = PermissionGate(mode: choice.mode) { tool, _, _ in
                await asked.record(tool)
                return .deny
            }
            let decision = await gate.decide(
                tool: "key", risk: .dangerous(summary: "press cmd+q")
            )
            #expect(decision == .deny(reason: "The user declined this action."))
            #expect(await asked.tools == ["key"],
                    "\(choice.title) ran a destructive call without asking")
        }
    }

    /// Auto has to actually be automatic, or it is a setting that does nothing. Every
    /// `CGEvent` action is classified `.write`, so this is the case that decides whether
    /// the feature works at all.
    @Test("Auto runs a state-changing action without asking")
    func autoDoesNotPromptForWrites() async {
        let asked = AskedSpy()
        let gate = PermissionGate(mode: ExecutionModeChoice.auto.mode) { tool, _, _ in
            await asked.record(tool)
            return .deny
        }
        let decision = await gate.decide(tool: "click", risk: .write(summary: "click (12, 40)"))
        #expect(decision == .allow)
        #expect(await asked.tools.isEmpty, "Auto stopped to ask about an ordinary action")
    }

    @Test("Manual asks before a state-changing action")
    func manualPromptsForWrites() async {
        let asked = AskedSpy()
        let gate = PermissionGate(mode: ExecutionModeChoice.manual.mode) { tool, _, _ in
            await asked.record(tool)
            return .allow
        }
        _ = await gate.decide(tool: "click", risk: .write(summary: "click (12, 40)"))
        #expect(await asked.tools == ["click"])
    }

    /// The badge and the picker both read this, so a mode with no choice of its own
    /// must still describe itself as something rather than crashing or defaulting to
    /// the permissive end.
    @Test("Every mode maps onto a choice, and the CLI-only ones read as the safer side")
    func everyModeDescribesItself() {
        #expect(ExecutionModeChoice.describing(.ask) == .manual)
        #expect(ExecutionModeChoice.describing(.readOnly) == .manual)
        #expect(ExecutionModeChoice.describing(.auto) == .auto)
        #expect(ExecutionModeChoice.describing(.bypass) == .auto)
        for choice in ExecutionModeChoice.allCases {
            #expect(ExecutionModeChoice.describing(choice.mode) == choice, "\(choice.title)")
        }
    }

    private actor AskedSpy {
        private(set) var tools: [String] = []
        func record(_ tool: String) { tools.append(tool) }
    }
}

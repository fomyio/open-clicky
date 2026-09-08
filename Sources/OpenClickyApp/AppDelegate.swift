import AppKit
import SwiftUI
import OpenClickyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: OverlayPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var phantomCursor: PhantomCursor?
    /// Incremented on every run, so callbacks from a superseded run can recognise
    /// that they are stale rather than acting on the current one's state.
    private var runGeneration = 0
    private let model = OverlayModel()
    private let settings = SettingsModel()
    private lazy var settingsWindow = SettingsWindow(model: settings)
    private var controller: SessionController?
    private var run: Task<Void, Never>?

    /// The loop every instruction of the current conversation runs on.
    ///
    /// Held for the life of the conversation rather than rebuilt per submission, which
    /// is the whole of "a finished task does not end the run": `AgentLoop.run(task:)`
    /// appends to the transcript it was given and captures a fresh environment probe on
    /// each call, so a second instruction on the same loop carries the entire prior
    /// conversation for free — and "now close it" has something to resolve against. A
    /// new loop per submission is what made every summon a first summon.
    ///
    /// Nil until the first task, and dropped whenever `conversation` says the thread
    /// ended — see `startRun`.
    private var loop: AgentLoop?

    /// How many instructions this conversation has carried, and what it is carrying
    /// them against. The rule lives in the library; this is the app's copy of the
    /// answer. See `Conversation`.
    private var conversation = Conversation()

    /// The generation of the task currently inside `loop`, or nil when it is idle.
    ///
    /// The loop outlives any one run now, so its observer cannot capture the generation
    /// it belongs to at construction the way a per-run closure could. A cancelled task
    /// keeps emitting for as long as it takes to unwind, and those events would
    /// otherwise paint the previous task's activity — and its *verdict* — over the one
    /// the user is watching.
    private var loopGeneration: Int?

    /// Resolves the pending approval prompt.
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Whether a `requestApproval` is in flight and therefore owed an answer.
    ///
    /// The continuation is created on the session controller's executor and hops here
    /// to register itself, so there is a window in which an approval exists and
    /// `approvalContinuation` is still nil. Cancelling inside that window used to
    /// resume nothing, and the loop would then wait forever for an answer no surface
    /// could give — wedging not just that task but every task after it, because the
    /// next one waits for this one to unwind.
    private var approvalIsExpected = false
    /// Set when an approval was cancelled before its continuation had registered, so
    /// the registration can answer it immediately instead of hanging. Only ever set
    /// while `approvalIsExpected`, or it would poison the *next* task's first approval.
    private var approvalWasCancelled = false

    private let hotKeyCombo = UserDefaults.standard.string(forKey: "hotkey") ?? "opt+space"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The delegate is @MainActor-isolated and therefore Sendable, so the state
        // callback can hop to it directly rather than nesting a MainActor.run —
        // which would capture the weak binding across a concurrency domain.
        let controller = SessionController { [weak self] state in
            guard let self else { return }
            await self.render(state)
        }
        self.controller = controller

        model.onSubmit = { [weak self] task in self?.startRun(task) }
        model.onEscape = { [weak self] in self?.handleEscape() }
        model.onApproval = { [weak self] approved in
            self?.resolvePendingApproval(approved)
        }
        model.onStartOver = { [weak self] in self?.startFreshConversation() }

        panel = OverlayPanel { OverlayView(model: self.model) }

        // The agent's pointer, so its clicks are visible before they land.
        let cursor = PhantomCursor()
        phantomCursor = cursor
        Task { await CursorStage.shared.install(cursor) }
        installStatusItem()
        installHotKey()
        requestMissingPermissions()
        // Shown before the first task rather than after it fails: the overlay is one
        // line of text, and "which model is about to do this" is the question it
        // could never answer.
        refreshConfigurationLine()
        refreshConversationLine()
    }

    // MARK: - Chrome

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays", accessibilityDescription: "OpenClicky"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Ask OpenClicky  \(hotKeyDisplay)", action: #selector(summon), keyEquivalent: "")
        // The second home of "start fresh". The overlay carries the button, because a
        // control the user cannot see is not an answer to "I am stuck in an old
        // thread" — this is here for the moment the overlay is not on screen, and so
        // that the session's lifetime is stated somewhere permanent.
        menu.addItem(withTitle: "New Conversation", action: #selector(startFreshConversation), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(openPrivacySettings), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal Session Logs", action: #selector(revealLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OpenClicky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private var hotKeyDisplay: String {
        (try? HotKey.parse(hotKeyCombo))?.display ?? hotKeyCombo
    }

    private func installHotKey() {
        do {
            let combination = try HotKey.parse(hotKeyCombo)
            hotKey = try HotKey(combination) { [weak self] in
                Task { @MainActor in self?.summon() }
            }
        } catch {
            // A missing hotkey is a degraded product, not a broken one — the menu
            // bar item still works, so say so rather than refusing to launch.
            notifyAtLaunch(
                title: "OpenClicky could not register its hotkey",
                body: "\(error) Use the menu bar icon instead."
            )
        }
    }

    /// Asks the system for what is missing, rather than only reporting it.
    ///
    /// The status was being shown to the user with instructions to go and find
    /// System Settings themselves — while macOS has a one-click prompt for exactly
    /// this, and the API to raise it was sitting unused. Requesting first means the
    /// common case is a single dialog; the fallback text is for when they decline or
    /// the grant needs a relaunch to take effect.
    private func requestMissingPermissions() {
        let before = PermissionStatus.current()
        guard !before.allGranted else { return }

        let alert = NSAlert()
        alert.messageText = "OpenClicky needs permission to see and control your Mac"
        alert.informativeText = """
        Accessibility lets it read windows, click and type. Screen Recording lets it \
        take screenshots. Without them only shell commands and AppleScript work.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Grant Permissions")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Each call raises the system's own prompt for that permission.
        if !before.accessibility { AXCapture.shared.requestTrust() }
        if !before.screenRecording { ScreenCapture.shared.requestPermission() }

        // Screen Recording only takes effect after a relaunch, so say so rather than
        // leaving the user to discover that screenshots still fail.
        if !before.screenRecording {
            let followUp = NSAlert()
            followUp.messageText = "Restart OpenClicky after granting Screen Recording"
            followUp.informativeText = "macOS only applies that permission to a fresh launch."
            followUp.alertStyle = .informational
            followUp.runModal()
        }
    }

    // MARK: - Actions

    @objc private func summon() {
        Task {
            await controller?.summon()
            model.draft = ""
            // Re-read on every summon, not cached at launch: the settings window
            // writes the file, and a stale line under the input would name a model
            // the run is not about to use.
            refreshConfigurationLine()
            refreshConversationLine()
            panel?.present()
        }
    }

    @objc private func showSettings() {
        settingsWindow.present()
    }

    /// The one-line answer to "what is about to run this", for the overlay.
    ///
    /// Resolved through the same call a run makes, so it cannot describe a
    /// configuration the run would not use — including the failure: an unresolvable
    /// provider says so here, where there is a Settings window one click away, rather
    /// than after the user has typed a task.
    private func refreshConfigurationLine() {
        do {
            let provider = try Provider.resolve(config: ConfigFile())
            let tier = provider.capabilities.maxTier
            model.configuration =
                "\(provider.summary) · tiers 0–\(tier.rawValue)"
                + (provider.capabilities.vision ? "" : " · no vision")
            model.configurationIsUsable = true
        } catch {
            model.configuration = "Not configured — open Settings from the menu bar."
            model.configurationIsUsable = false
        }
    }

    /// What the next instruction will carry, in one line, and whether there is a
    /// conversation for the overlay's "New conversation" control to clear.
    ///
    /// Read from `Conversation` rather than assembled here: the same value decides
    /// whether the loop is reused, so the line and the behaviour cannot disagree. An
    /// overlay claiming to carry context that the next request does not contain is the
    /// same defect as a run reporting success it did not earn, one surface along.
    private func refreshConversationLine() {
        model.conversation = conversation.summary ?? ""
        model.carriesContext = conversation.carriesContext
    }

    /// Ends the conversation. The next instruction starts from nothing.
    ///
    /// Cancels a run in flight rather than refusing: the control is reachable from the
    /// menu bar while the agent is working, and "start fresh" cannot mean "start fresh
    /// after this finishes" without leaving the user to guess which of the two states
    /// they are in.
    @objc private func startFreshConversation() {
        // Bumped first, so anything the outgoing run says on its way out is recognised
        // as belonging to a conversation that no longer exists.
        runGeneration &+= 1
        run?.cancel()
        resolvePendingApproval(false)
        // The transcript goes with the loop: a new conversation writes a new session
        // file rather than appending to one whose earlier tasks it will never be sent.
        loop = nil
        loopGeneration = nil
        conversation.startOver()
        model.draft = ""
        refreshConfigurationLine()
        refreshConversationLine()
        Task {
            // `startOver`, not `summon`: the hotkey deliberately preserves whatever is
            // on screen, and here the whole point is that it should not.
            await controller?.startOver()
            panel?.present()
        }
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLogs() {
        // The library's definition, not a second copy of the path. A menu item that
        // opens the wrong folder fails silently — Finder simply shows nothing, and
        // the user concludes no sessions were recorded.
        let directory = Transcript.defaultDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    private func handleEscape() {
        Task {
            let shouldCancel = await controller?.escape() ?? false
            if shouldCancel {
                run?.cancel()
                // A pending approval must not be left hanging when the run is
                // cancelled, or the loop would wait on a prompt nobody can answer —
                // and with one loop serving every instruction, that is not one wedged
                // task but every task after it, since each waits for the last to unwind.
                resolvePendingApproval(false)
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    private func render(_ state: SessionState) {
        model.state = state
        if !state.isVisible { panel?.orderOut(nil) }

        // A finished task used to linger four seconds and dismiss itself. It no longer
        // dismisses at all: the end of a task is "ready for the next instruction", and
        // an overlay that walked off screen took the conversation's only visible handle
        // with it. The outcome stays exactly where it was, with the input field under
        // it — `SessionState.isReadyForInput` is the same rule the controller uses to
        // decide whether to accept a submission, so the field cannot appear where a
        // task would be refused.
        //
        // Escape is still the way out, from here as from anywhere idle: it dismisses
        // rather than cancelling once nothing is running. Nothing has become
        // undismissable; what has gone is the dismissal nobody asked for.
        switch state {
        case .finished, .stopped:
            // The instruction that produced this verdict has been carried out; leaving
            // it in the field would make the obvious next keystroke resubmit it.
            model.draft = ""
            refreshConversationLine()
            // Re-read rather than trusted from the start of the run: the Settings
            // window may have been used while the task ran, and the line under the
            // input is a claim about what the *next* instruction will use.
            refreshConfigurationLine()
            // Deliberately not `panel?.present()`. Taking key focus here would pull it
            // out of whatever the agent just finished acting on, at the exact moment
            // the user is looking at the result — the hotkey is one press away and
            // presents without activating the app.
        default:
            break
        }
    }

    // MARK: - Running

    private func startRun(_ draft: String) {
        guard let controller else { return }
        // Bumped before anything can observe it, so every callback still in flight from
        // the outgoing run can tell that it is answering a question nobody asked.
        runGeneration &+= 1
        let generation = runGeneration
        let superseded = run
        superseded?.cancel()
        // Resumed synchronously, here, rather than inside the task below: a run
        // suspended inside the permission gate is not cancellable — it is waiting on a
        // continuation, not on a `Task.sleep` — so an unanswered approval would keep
        // the old task alive forever, and the new one waits for the old one.
        resolvePendingApproval(false)

        run = Task { [weak self] in
            guard let self, let task = await controller.submit(draft) else { return }

            // One loop, one task at a time. `AgentLoop` is an actor and its methods
            // suspend on every request, so a second `run(task:)` entered while the
            // first is awaiting the network would interleave two tasks over one
            // transcript, one outcome and one turn counter. A fresh loop per
            // submission hid that; reusing one does not, so the new instruction waits
            // for the cancelled one to finish unwinding. It is normally instant — the
            // loop stops at the next action boundary — and the overlay says "Thinking…"
            // meanwhile, which is true of an instruction that is queued.
            await superseded?.value
            // Superseded in turn while waiting. Whoever bumped the generation is
            // already waiting on this task, so leaving is the whole of the handover.
            guard generation == self.runGeneration else { return }

            do {
                // The same resolution the CLI performs, so the app and the CLI
                // cannot end up talking to different endpoints from one machine's
                // configuration. The registry follows from it too: a model that
                // cannot be sent images must not be handed the pixel tools here
                // either, and its screenshots need its own provider's image space.
                let provider = try Provider.resolve(config: ConfigFile())
                // Written back so the overlay's line and the run cannot disagree
                // about which model answered.
                self.refreshConfigurationLine()

                // Everything the loop is made of comes from that resolution, and none
                // of it can be changed after construction. So the loop may only be
                // reused while the configuration it was built from is still the one a
                // task would resolve to now — otherwise a model picked in Settings
                // half an hour ago would still be answering, from the old endpoint,
                // with the old tool set, and the only sign would be an overlay line
                // that disagreed with the transcript.
                switch self.conversation.begin(SessionConfiguration(provider: provider)) {
                case .carriedForward:
                    break
                case .startedOver:
                    // Dropped, not mutated. A new conversation gets a new transcript
                    // too: appending a task to a session file whose earlier turns will
                    // never be sent again would make the record claim a continuity the
                    // requests do not have.
                    self.loop = nil
                }
                self.refreshConversationLine()

                let loop: AgentLoop
                if let existing = self.loop {
                    loop = existing
                } else {
                    loop = try self.makeLoop(for: provider, controller: controller)
                    self.loop = loop
                }

                // Claimed immediately before the loop is entered and left set
                // afterwards: it is what tells the observer which run its events
                // belong to, and the loop is idle by the time anything else looks.
                self.loopGeneration = generation
                _ = try await loop.run(task: task)
            } catch is CancellationError {
                await self.deliver(
                    .finished(reason: AgentLoop.Event.interruptedReason), from: generation
                )
            } catch {
                await self.deliver(.finished(reason: "\(error)"), from: generation)
            }
        }
    }

    /// The loop this conversation runs on, and everything baked into it.
    ///
    /// Built once per conversation rather than once per task. The gate goes in here
    /// too: its standing "always allow" grants are cleared at the top of
    /// `AgentLoop.runToCompletion`, per task, so a gate that outlives one instruction
    /// does not hand the next one an authority granted to the first.
    private func makeLoop(for provider: Provider, controller: SessionController) throws -> AgentLoop {
        let gate = PermissionGate(mode: .ask) { [weak self] tool, summary, risk in
            // The overlay offers approve or deny only. "Always allow" needs a
            // third button and a way to show which tools carry a standing
            // grant, or it becomes a permission the user cannot see or revoke.
            await self?.requestApproval(tool: tool, summary: summary, risk: risk) == true
                ? .allow : .deny
        }
        // Hoisted out of the `AgentLoop` init so the retry closure can reach
        // it. The client is built before the loop and reports its backoffs
        // straight to the observer, so this is the only place in the app that
        // can put one in the record.
        let transcript = try Transcript()
        return AgentLoop(
            client: provider.makeClient { [weak self] attempt, total, delay, reason in
                await transcript.noteRetry(
                    attempt: attempt, of: total, delay: delay, reason: reason
                )
                await self?.forward(.retrying(
                    attempt: attempt, of: total, delay: delay, reason: reason
                ))
            },
            registry: Self.registry(for: provider),
            gate: gate,
            transcript: transcript,
            mode: .ask,
            // Named, not defaulted: the loop shapes its request and its
            // system prompt from this, and a default that disagreed with the
            // provider's model is the desync every other layer here avoids.
            //
            // The planner comes from the same resolution as the model, for the
            // same reason: it runs on this client with this credential, so a
            // planner chosen anywhere else would be a model id this endpoint
            // has never heard of.
            config: .init(
                model: provider.model,
                planner: provider.plannerModel.map { Planner(model: $0) }
            ),
            observer: { [weak self] event in await self?.forward(event) }
        )
    }

    /// An event from the shared loop, dropped if the task that produced it is no longer
    /// the one on screen.
    ///
    /// A cancelled task keeps emitting until it unwinds, and one of the last things it
    /// emits is its verdict. Rendered against the instruction the user has just typed,
    /// that verdict would be a claim about the wrong task — the failure the per-task
    /// outcome work exists to prevent, reintroduced by a stale callback rather than by
    /// stale bookkeeping.
    private func forward(_ event: AgentLoop.Event) async {
        guard let loopGeneration else { return }
        await deliver(event, from: loopGeneration)
    }

    private func deliver(_ event: AgentLoop.Event, from generation: Int) async {
        guard generation == runGeneration, let controller else { return }
        await controller.handle(event)
    }

    /// Answers the outstanding approval, from wherever the answer came from.
    ///
    /// One funnel for three callers — the buttons, Escape, and the start of the next
    /// run — because the hazard is the same in all three and the fix is not the obvious
    /// one: an approval can exist before its continuation has registered itself here,
    /// and resuming nothing in that window leaves the loop waiting for an answer that
    /// has already been given.
    private func resolvePendingApproval(_ approved: Bool) {
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            continuation.resume(returning: approved)
            return
        }
        // Only while one is actually owed. Setting this speculatively would deny the
        // *next* task's first approval, which the user would experience as the agent
        // refusing an action nobody was asked about.
        if approvalIsExpected { approvalWasCancelled = true }
    }

    private func requestApproval(tool: String, summary: String, risk: Risk) async -> Bool {
        guard let controller else { return false }
        let isDestructive: Bool
        if case .dangerous = risk { isDestructive = true } else { isDestructive = false }

        // Set here, on the main actor, before anything can be cancelled: this is the
        // only point at which "an approval is owed" is known synchronously.
        approvalIsExpected = true
        defer {
            approvalIsExpected = false
            approvalWasCancelled = false
        }

        return await controller.requestApproval(
            tool: tool, summary: summary, isDestructive: isDestructive
        ) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self.register(continuation)
                }
            }
        }
    }

    /// Registers the continuation the overlay's buttons will resume, or answers it
    /// immediately if the run was cancelled while it was on its way here.
    private func register(_ continuation: CheckedContinuation<Bool, Never>) {
        guard !approvalWasCancelled else {
            approvalWasCancelled = false
            continuation.resume(returning: false)
            return
        }
        approvalContinuation = continuation
        panel?.present()
    }

    /// Every tool the model can actually drive, since the overlay has no tier flag;
    /// the gate does the rest of the limiting. The overlay is excluded from capture at
    /// the window level too, but naming the bundle here covers the case where the
    /// panel is not the only window.
    ///
    /// Built per run rather than once, because the ceiling and the image space are
    /// the provider's to decide and the provider is resolved when a task starts.
    private static func registry(for provider: Provider) -> ToolRegistry {
        .standard(
            maxTier: provider.capabilities.maxTier,
            excludedBundleIDs: [Bundle.main.bundleIdentifier ?? ""],
            // The overlay is also a surface the agent must not verify itself against:
            // its own panel taking focus is not evidence that a click landed in the
            // app being driven. Same list, different question — see
            // `UIFingerprint.isSelfNoise`.
            selfBundleIDs: [Bundle.main.bundleIdentifier].compactMap { $0 },
            imageSpace: provider.capabilities.imageSpace
        )
    }

    /// A blocking alert. Launch-time only, deliberately.
    ///
    /// Everything else about this app avoids stealing focus, but a missing
    /// permission or hotkey has to be seen — a banner the user misses leaves them
    /// with a tool that silently does not work. Do not reuse this mid-run.
    private func notifyAtLaunch(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }
}

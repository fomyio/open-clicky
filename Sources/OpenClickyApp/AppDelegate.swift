import AppKit
import OSLog
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

    /// The app the user was working in when they last summoned the agent.
    ///
    /// The whole of "tell the model which app the user meant". `AgentLoop` reads this
    /// once per task through a closure rather than being handed a value at
    /// construction, because one loop serves a whole conversation and the second
    /// instruction may well have been summoned from a different app than the first.
    ///
    /// Lock-backed and in the library: the loop's lookup is a `@Sendable` closure and
    /// this delegate is `@MainActor`, so a plain property here could not be read from
    /// there — and the rule about *what* is worth remembering is decidable, which means
    /// it belongs where tests can reach it. See `SummonedApp`.
    private let summonMemory = SummonedApp.Memory()

    /// The same app, as something that can be activated again.
    ///
    /// Held separately from `summonMemory` and deliberately not part of it. That value
    /// is what the model is told; this is a handle to a process, only ever used to hand
    /// focus back. Keeping them apart means the thing crossing into the library stays a
    /// pair of strings.
    private var summonedFromApplication: NSRunningApplication?

    /// The generation of the task currently inside `loop`, or nil when it is idle.
    ///
    /// The loop outlives any one run now, so its observer cannot capture the generation
    /// it belongs to at construction the way a per-run closure could. A cancelled task
    /// keeps emitting for as long as it takes to unwind, and those events would
    /// otherwise paint the previous task's activity — and its *verdict* — over the one
    /// the user is watching.
    private var loopGeneration: Int?

    /// The approval prompt the run is suspended on, if any.
    ///
    /// The continuation is created on the session controller's executor and hops here
    /// to register itself, so there is a window in which an approval exists and nothing
    /// is resumable yet. Cancelling inside that window resumed nothing, and the loop
    /// would then wait forever for an answer no surface could give — wedging not just
    /// that task but every task after it, because the next one waits for this one to
    /// unwind. `PendingReply` is that fix, and it is generic because the question below
    /// is subject to the identical race: two copies of it would be one copy that can be
    /// corrected alone.
    private let pendingApproval = PendingReply<Bool>(whenCancelled: false)

    /// The question the run is suspended inside, if any.
    ///
    /// Cancelled with `unavailable` and never with an empty answer, and the difference
    /// is not cosmetic. An empty answer is a *skip* — the user was there, read the
    /// question and had no preference — and `ask_user` tells the model to take the
    /// reversible option and carry on. That is exactly the wrong instruction to hand a
    /// run the user has just stopped. `unavailable` says nobody answered, do not wait
    /// and do not assume what they would have said.
    private let pendingAnswer = PendingReply<AskUserTool.Answer>(
        whenCancelled: .unavailable(reason: AppDelegate.stoppedBeforeAnswering)
    )

    /// Why a question went unanswered when the run was torn down under it.
    private static let stoppedBeforeAnswering =
        "the run was stopped before the question could be answered"

    private let hotKeyCombo = UserDefaults.standard.string(forKey: "hotkey") ?? "opt+space"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The delegate is @MainActor-isolated and therefore Sendable, so the state
        // callback can hop to it directly rather than nesting a MainActor.run —
        // which would capture the weak binding across a concurrency domain.
        let controller = SessionController { [weak self] state in
            guard let self else { return }
            await self.render(state)
        } onActivity: { [weak self] activity in
            guard let self else { return }
            await self.show(activity)
        }
        self.controller = controller

        model.onSubmit = { [weak self] task in self?.startRun(task) }
        model.onEscape = { [weak self] in self?.handleEscape() }
        model.onApproval = { [weak self] approved in
            self?.pendingApproval.resolve(approved)
        }
        // The overlay can only ever produce an answer, never an "unavailable" — a
        // surface being looked at by the person it is asking is the one place nobody
        // being there cannot be true. Empty is a skip; the tool reads that as "no
        // preference", which is a different thing again from a cancellation.
        model.onAnswer = { [weak self] text in
            self?.resolvePendingAnswer(.answered(text))
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
        // First, and synchronously, before anything can suspend and before the panel is
        // on screen. One `await` here and the answer would be our own overlay: this is
        // the only moment at which "what is the user working in" has the user's answer.
        rememberFrontmostApp()
        Task {
            await controller?.summon()
            model.draft = ""
            // Re-read on every summon, not cached at launch: the settings window
            // writes the file, and a stale line under the input would name a model
            // the run is not about to use.
            refreshConfigurationLine()
            refreshConversationLine()
            // Activating, because the user pressed the hotkey in order to type and a
            // prompt that cannot take a keystroke is not a prompt. Safe to do now, and
            // only now: `rememberFrontmostApp` has already recorded the app they meant,
            // so taking focus no longer destroys the answer. `startRun` hands focus
            // straight back. See `OverlayPanel`.
            panel?.present(activating: true)
        }
    }

    /// Records the app the user was in, for the model, and a handle to it, for focus.
    ///
    /// Nil-safe in both directions: OpenClicky itself is not remembered — the hotkey is
    /// pressed while the overlay is already up, or the Settings window has focus, or a
    /// finished task left the panel on screen, and in all of those the frontmost
    /// application really is us. `SummonedApp.remembered` returns nil there, and the
    /// environment block then says nothing rather than the falsehood a recorded session
    /// actually opened with: `frontmost app: OpenClicky (com.openclicky.app)`, while the
    /// user was asking for the VS Code command palette.
    ///
    /// A summon from our own overlay leaves what is already remembered exactly as it
    /// was, rather than clearing it: the user's app has not changed, only our window is
    /// in front of it. See `SummonedApp.Memory.rememberSummon`.
    private func rememberFrontmostApp() {
        // An app that has since quit is not somewhere the user is working. Dropped
        // before the new reading rather than after, so a summon that supplies nothing
        // leaves nothing behind either.
        if summonedFromApplication?.isTerminated == true {
            summonMemory.remember(nil)
            summonedFromApplication = nil
        }

        let front = NSWorkspace.shared.frontmostApplication
        // False when the summon came from our own overlay, in which case the memory is
        // deliberately left alone — the user's app has not changed, only our window is
        // in front of it. The handle must be left alone with it, or focus would be
        // "returned" to ourselves. See `SummonedApp.Memory.rememberSummon`.
        let arrived = summonMemory.rememberSummon(
            from: front?.localizedName,
            bundleIdentifier: front?.bundleIdentifier,
            ownBundleIdentifiers: [Bundle.main.bundleIdentifier].compactMap { $0 }
        )
        if arrived { summonedFromApplication = front }
    }

    /// Hands the active application back to whoever had it when we were summoned.
    ///
    /// Not politeness. While OpenClicky is the active application, the `type` and `key`
    /// tools post their events into *this overlay* — the agent typing its instruction
    /// into its own input field, which is the same family of defect as an action
    /// verifying itself against our terminal (1a79362). It also matters to the gate:
    /// `Policy.escalate` reads the live frontmost app, and leaving ourselves in front
    /// for the length of a run would blind that check to whatever the user actually has
    /// on screen.
    ///
    /// The panel stays up regardless — `hidesOnDeactivate` is false and it sits at
    /// `.statusBar` level — so progress and approvals remain visible.
    private func returnFocusToSummoningApp() {
        guard let application = summonedFromApplication, !application.isTerminated else {
            return
        }
        _ = application.activate()
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
        // Before anything else, for the same reason `summon` does it first: this ends
        // with the input field on screen, so it is a summon in every sense that
        // matters, and the app the user was in has to be captured while it is still
        // the frontmost one. Reached from the menu bar, where the frontmost app is
        // whatever they were using — and from the overlay's own button, where it is us,
        // and `SummonedApp.remembered` correctly declines to remember that.
        rememberFrontmostApp()
        // Bumped first, so anything the outgoing run says on its way out is recognised
        // as belonging to a conversation that no longer exists.
        runGeneration &+= 1
        run?.cancel()
        // Both prompts, not just the approval: the loop may be parked inside
        // `ask_user`, and a conversation that ended under a question would leave it
        // suspended there with nothing on screen that could answer it.
        cancelPendingPrompts()
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
            // Activating for the same reason the hotkey does: this control exists so
            // the user can type the next instruction from nothing.
            panel?.present(activating: true)
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
                // A pending prompt must not be left hanging when the run is
                // cancelled, or the loop would wait on a prompt nobody can answer —
                // and with one loop serving every instruction, that is not one wedged
                // task but every task after it, since each waits for the last to unwind.
                // Both kinds: this is the path the Stop button takes as well, and Stop
                // over a question is the case where the run is not merely working but
                // blocked inside a tool call.
                cancelPendingPrompts()
            } else {
                panel?.orderOut(nil)
                // Dismissing our own window while we are the active application leaves
                // focus nowhere: no Dock icon, no other window, and the user's next
                // keystroke lands in an app they cannot see. Put them back where they
                // were.
                returnFocusToSummoningApp()
            }
        }
    }

    /// Hands the activity log to the view.
    ///
    /// Its own channel rather than a field on the state, because the two change at
    /// different times: `SessionController.transition` deliberately does nothing when
    /// the state is unchanged, and two identical results in a row *are* the same
    /// state — the repetition the panel exists to make visible is precisely what that
    /// channel drops.
    private func show(_ activity: ActivityLog) {
        model.activity = activity
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
        // The user has finished typing, so the reason we took focus is spent. Handed
        // back here, synchronously, before any tool can run: a `type` or `key` call
        // made while OpenClicky is the active application types into our own overlay,
        // and `Policy.escalate` reads the live frontmost app, which must be the user's
        // screen and not our panel. The remembered app — the one the model is told
        // about — is untouched by this and outlives it.
        returnFocusToSummoningApp()
        // Bumped before anything can observe it, so every callback still in flight from
        // the outgoing run can tell that it is answering a question nobody asked.
        runGeneration &+= 1
        let generation = runGeneration
        let superseded = run
        superseded?.cancel()
        // Resumed synchronously, here, rather than inside the task below: a run
        // suspended inside the permission gate or inside `ask_user` is not cancellable
        // — it is waiting on a continuation, not on a `Task.sleep` — so an unanswered
        // prompt would keep the old task alive forever, and the new one waits for the
        // old one.
        cancelPendingPrompts()

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
            // The asker is passed in rather than reached for, because `registry(for:)`
            // is static and cannot see this delegate — and it stays static on purpose:
            // a type method cannot capture the app by accident, which is the whole
            // reason the tool set could never be built from stale instance state. What
            // it needs from the instance arrives as an argument.
            registry: Self.registry(
                for: provider,
                asker: { [weak self] question in
                    guard let self else {
                        return .unavailable(reason: "the overlay is gone, so nobody can answer")
                    }
                    return await self.requestAnswer(question)
                },
                yieldFocus: { [weak self] in await self?.yieldKeyboardFocus() }
            ),
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
            observer: { [weak self] event in await self?.forward(event) },
            // The remembered app, and only for the environment block. The two
            // `…BundleIdentifier` arguments above it are left at their defaults on
            // purpose: those are read live, at the moment a risk is classified, and
            // are what the gate sees. Passing this value to either of them would
            // classify an action against a security surface from a snapshot taken
            // before that surface was on screen.
            summonedFrom: { [memory = summonMemory] in memory.current }
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

    /// Answers everything the run is suspended on, because it is being torn down.
    ///
    /// Every path that ends a run goes through here, and there are four: Escape and the
    /// Stop button (both `handleEscape`), a superseding instruction (`startRun`), and
    /// ending the conversation from the overlay's button or the menu bar
    /// (`startFreshConversation`, which is also the only caller of
    /// `SessionController.startOver`). Missing one is not a cosmetic bug: the loop is
    /// parked inside a gate or inside `ask_user`, waiting on a continuation rather than
    /// on anything cancellation can interrupt, so a prompt left unanswered is a run
    /// that cannot be stopped — and with one loop serving the whole conversation, every
    /// instruction after it waits on that.
    ///
    /// A question left hanging is the worse of the two. An unanswered approval at least
    /// leaves the loop somewhere the user was told about; an unanswered question leaves
    /// it inside a tool call with an overlay that has already moved on.
    private func cancelPendingPrompts() {
        pendingApproval.cancel()
        pendingAnswer.cancel()
        // The half-typed reply belonged to a question that no longer exists.
        model.answer = ""
    }

    /// Answers the outstanding question, and clears the field it was typed into.
    private func resolvePendingAnswer(_ answer: AskUserTool.Answer) {
        model.answer = ""
        pendingAnswer.resolve(answer)
    }

    private func requestApproval(tool: String, summary: String, risk: Risk) async -> Bool {
        guard let controller else { return false }
        let isDestructive: Bool
        if case .dangerous = risk { isDestructive = true } else { isDestructive = false }

        // Entered here, on the main actor, before anything can be cancelled: this is
        // the only point at which "an approval is owed" is known synchronously.
        return await pendingApproval.expecting {
            await controller.requestApproval(
                tool: tool, summary: summary, isDestructive: isDestructive
            ) {
                // Presented only once the continuation is resumable, which is what
                // `onRegistered` is for. Without activating: taking focus mid-run pulls
                // it out of the app being driven, and this prompt is answered by
                // clicking a button, which a `.nonactivatingPanel` takes without being
                // the active application.
                await self.pendingApproval.wait { self.panel?.present() }
            }
        }
    }

    /// Puts one question from the agent to the user and waits for the reply.
    ///
    /// The mirror of `requestApproval`, on the same mechanism, and different in exactly
    /// two places. The frame is the tool's — this hands `Question` through untouched,
    /// because everything that keeps it from reading as a permission prompt is built
    /// into that value and re-describing it here would be a second, driftable copy.
    ///
    /// And it activates. Every other mid-run presentation deliberately does not, but
    /// this one is answered by *typing*, and a `.nonactivatingPanel` hosting a SwiftUI
    /// `TextField` has a long history of not receiving keys while its app is inactive —
    /// see `OverlayPanel`. A question you cannot type into is a blocked run. The focus
    /// is handed straight back on the way out, before the loop resumes, for the reason
    /// `startRun` gives: while OpenClicky is the active application a `type` or `key`
    /// call posts its keystrokes into our own overlay, and `Policy.escalate` classifies
    /// against the live frontmost app.
    private func requestAnswer(_ question: AskUserTool.Question) async -> AskUserTool.Answer {
        guard let controller else {
            return .unavailable(reason: "the overlay is not running, so nobody can answer")
        }
        // A reply left over from a previous question must not appear pre-filled under
        // this one.
        model.answer = ""
        let answer = await pendingAnswer.expecting {
            await controller.requestAnswer(question) {
                await self.pendingAnswer.wait { self.panel?.present(activating: true) }
            }
        }
        returnFocusToSummoningApp()
        return answer
    }

    /// Every tool the model can actually drive, since the overlay has no tier flag;
    /// the gate does the rest of the limiting. The overlay is excluded from capture at
    /// the window level too, but naming the bundle here covers the case where the
    /// panel is not the only window.
    ///
    /// Built per run rather than once, because the ceiling and the image space are
    /// the provider's to decide and the provider is resolved when a task starts.
    private static func registry(
        for provider: Provider,
        asker: @escaping AskUserTool.Asker,
        yieldFocus: @escaping Verified.FocusYield
    ) -> ToolRegistry {
        .standard(
            maxTier: provider.capabilities.maxTier,
            excludedBundleIDs: [Bundle.main.bundleIdentifier ?? ""],
            // The overlay is also a surface the agent must not verify itself against:
            // its own panel taking focus is not evidence that a click landed in the
            // app being driven. Same list, different question — see
            // `UIFingerprint.isSelfNoise`.
            selfBundleIDs: [Bundle.main.bundleIdentifier].compactMap { $0 },
            imageSpace: provider.capabilities.imageSpace,
            // The overlay's own question panel — see `AppDelegate.requestAnswer`. It
            // used to decline here, which was honest while there was nothing to draw,
            // and is not the same thing as being answerable: a question deferred into
            // the reply is one the model has stopped waiting on, so "navigate there,
            // then ask whether to change it" collapsed back into narrating or doing.
            asker: asker,
            // The overlay panel becomes key to answer an approval with Return, which
            // is keyboard focus held while this application stays *inactive*. Nothing
            // observable reports that: the menu bar names the user's app, a screenshot
            // shows it frontmost, and every keystroke we post lands in our own panel.
            // See `yieldKeyboardFocus`.
            yieldFocus: yieldFocus
        )
    }

    /// Hands the keyboard back to the app on screen before synthetic input is posted.
    ///
    /// Not `returnFocusToSummoningApp`. That handle is set once, when the hotkey is
    /// pressed, and is never updated when the agent legitimately opens something else —
    /// so using it here would have yanked focus to the app the user *started* in and
    /// posted the keystroke there. The live frontmost application is the only correct
    /// answer mid-run, and re-activating the app that is already frontmost is what
    /// takes key status back from our panel.
    /// The last application that was frontmost and was not us.
    ///
    /// The app the agent is actually driving, which is not `summonedFromApplication`
    /// (fixed at summon, stale the moment the agent opens something else) and is not
    /// always `frontmostApplication` either — when our own overlay is in front, that
    /// answers with us, and "us" is the one app the keyboard must not go to.
    private var lastNonSelfApplication: NSRunningApplication?

    @MainActor
    private func yieldKeyboardFocus() async {
        let own = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != own, !front.isTerminated {
            lastNonSelfApplication = front
        }
        // Unconditional, deliberately.
        //
        // The first version asked `NSApp.keyWindow != nil` first, on the reasoning that
        // it names our panel exactly when the panel holds the keyboard. AppKit
        // documents that property as nil *while the application is inactive*, which is
        // this case precisely — so the guard was false at every moment it was meant to
        // fire, and a run went on posting `cmd+F` and a search string into our own
        // panel while System Settings sat unchanged behind it. Re-activating an app
        // that is already active is a no-op at the window server, so asking every time
        // costs a few milliseconds and removes a condition that cannot be checked.
        guard let target = lastNonSelfApplication ?? summonedFromApplication,
              !target.isTerminated, target.bundleIdentifier != own else {
            Self.focusLog.error("no app to hand the keyboard to; input may land in our own panel")
            return
        }
        let activated = target.activate()
        // The window server has to process the change before the event is posted; an
        // event sent in the same runloop turn still lands in the old key window.
        try? await Task.sleep(for: .milliseconds(50))
        Self.focusLog.info(
            """
            yielded to \(target.bundleIdentifier ?? "?", privacy: .public)             activated=\(activated, privacy: .public)             wasFrontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier             ?? "nil", privacy: .public)
            """
        )
    }

    /// Why this is logged at all: whether our panel holds the keyboard is invisible to
    /// every observation the agent makes — the menu bar, the screenshots and
    /// `frontmostApplication` all name the user's app while the keystroke goes
    /// elsewhere. Two rounds of this were diagnosed by inference from pixel diffs. Read
    /// it with:
    ///
    ///     log stream --predicate 'subsystem == "com.openclicky.app"'
    static let focusLog = Logger(subsystem: "com.openclicky.app", category: "focus")

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

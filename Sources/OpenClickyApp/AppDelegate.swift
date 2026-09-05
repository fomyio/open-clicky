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
    private var controller: SessionController?
    private var run: Task<Void, Never>?
    /// Resolves the pending approval prompt.
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

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

        model.onSubmit = { [weak self] _ in self?.startRun() }
        model.onEscape = { [weak self] in self?.handleEscape() }
        model.onApproval = { [weak self] approved in
            self?.approvalContinuation?.resume(returning: approved)
            self?.approvalContinuation = nil
        }

        panel = OverlayPanel { OverlayView(model: self.model) }

        // The agent's pointer, so its clicks are visible before they land.
        let cursor = PhantomCursor()
        phantomCursor = cursor
        Task { await CursorStage.shared.install(cursor) }
        installStatusItem()
        installHotKey()
        requestMissingPermissions()
    }

    // MARK: - Chrome

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays", accessibilityDescription: "OpenClicky"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Ask OpenClicky  \(hotKeyDisplay)", action: #selector(summon), keyEquivalent: "")
        menu.addItem(.separator())
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
            panel?.present()
        }
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLogs() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclicky/sessions")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
    }

    private func handleEscape() {
        Task {
            let shouldCancel = await controller?.escape() ?? false
            if shouldCancel {
                run?.cancel()
                // A pending approval must not be left hanging when the run is
                // cancelled, or the loop would wait on a prompt nobody can answer.
                approvalContinuation?.resume(returning: false)
                approvalContinuation = nil
            } else {
                panel?.orderOut(nil)
            }
        }
    }

    private func render(_ state: SessionState) {
        model.state = state
        if !state.isVisible { panel?.orderOut(nil) }

        // Finished and stopped states linger briefly so the outcome is readable, then
        // dismiss themselves. The generation token matters: if the user summons and
        // submits a new task inside that window, this timer belongs to the previous
        // run and must not dismiss the overlay out from under the new one — which
        // would leave an agent working invisibly, with no way to see or stop it.
        switch state {
        case .finished, .stopped:
            let generation = runGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.runGeneration == generation else { return }
                await self.controller?.dismiss()
            }
        default:
            break
        }
    }

    // MARK: - Running

    private func startRun() {
        guard let controller else { return }
        runGeneration &+= 1
        run?.cancel()
        // Defensive: a run cannot start while an approval is pending today, because
        // the input field only exists in the `.accepting` state. That is an invariant
        // held by the view layer, not by this function — and an unresolved
        // continuation would leak, then crash if it were ever resumed twice.
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        run = Task { [weak self] in
            guard let self, let task = await controller.submit() else { return }
            do {
                let credentials = try Credentials.resolve()
                let gate = PermissionGate(mode: .ask) { tool, summary, risk in
                    await self.requestApproval(tool: tool, summary: summary, risk: risk)
                }
                let loop = AgentLoop(
                    client: AnthropicClient(credentials: credentials),
                    registry: Self.registry,
                    gate: gate,
                    transcript: try Transcript(),
                    mode: .ask,
                    observer: { event in await controller.handle(event) }
                )
                _ = try await loop.run(task: task)
            } catch is CancellationError {
                await controller.handle(.finished(reason: "interrupted"))
            } catch {
                await controller.handle(.finished(reason: "\(error)"))
            }
        }
    }

    private func requestApproval(tool: String, summary: String, risk: Risk) async -> Bool {
        guard let controller else { return false }
        let isDestructive: Bool
        if case .dangerous = risk { isDestructive = true } else { isDestructive = false }

        return await controller.requestApproval(
            tool: tool, summary: summary, isDestructive: isDestructive
        ) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self.approvalContinuation = continuation
                    self.panel?.present()
                }
            }
        }
    }

    /// Every tool, since the overlay has no tier flag; the gate does the limiting.
    private static let registry = ToolRegistry([
        ShellTool(), ReadFileTool(), WriteFileTool(),
        AppleScriptTool(), ShortcutsTool(),
        AXCaptureTool(), AXPressTool(), AXSetValueTool(),
        // The overlay is excluded from capture at the window level too, but naming
        // the bundle here covers the case where the panel is not the only window.
        ScreenshotTool(excludedBundleIDs: [Bundle.main.bundleIdentifier ?? ""]),
        ZoomTool(), ClickTool(), DragTool(),
        TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
    ])

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

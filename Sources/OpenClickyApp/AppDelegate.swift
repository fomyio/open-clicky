import AppKit
import SwiftUI
import OpenClickyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: OverlayPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let model = OverlayModel()
    private var controller: SessionController?
    private var run: Task<Void, Never>?
    /// Resolves the pending approval prompt.
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    private let hotKeyCombo = UserDefaults.standard.string(forKey: "hotkey") ?? "opt+space"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = SessionController { [weak self] state in
            await MainActor.run { self?.render(state) }
        }
        self.controller = controller

        model.onSubmit = { [weak self] _ in self?.startRun() }
        model.onEscape = { [weak self] in self?.handleEscape() }
        model.onApproval = { [weak self] approved in
            self?.approvalContinuation?.resume(returning: approved)
            self?.approvalContinuation = nil
        }

        panel = OverlayPanel { OverlayView(model: self.model) }
        installStatusItem()
        installHotKey()
        warnAboutMissingPermissions()
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
            notify(
                title: "OpenClicky could not register its hotkey",
                body: "\(error) Use the menu bar icon instead."
            )
        }
    }

    private func warnAboutMissingPermissions() {
        let permissions = PermissionStatus.current()
        guard let advice = permissions.advice else { return }
        notify(title: "OpenClicky needs permission", body: advice)
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
        // Finished and stopped states linger briefly so the outcome is readable.
        switch state {
        case .finished, .stopped:
            Task {
                try? await Task.sleep(for: .seconds(4))
                if case .accepting = self.model.state { return }
                await self.controller?.dismiss()
            }
        default:
            break
        }
    }

    // MARK: - Running

    private func startRun() {
        guard let controller else { return }
        run?.cancel()
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

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
    }
}

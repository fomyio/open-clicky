import AppKit
import SwiftUI

/// The settings panel's window.
///
/// A plain titled window rather than the overlay: the overlay is a heads-up prompt
/// that must not steal focus from the app the agent is about to act on, and a form
/// with text fields is the opposite — it wants focus, it wants a title bar, and it
/// wants to be closable without ending a run.
///
/// `.accessory` activation means this app has no Dock icon to click, so opening the
/// window has to activate the app explicitly or it appears behind everything.
@MainActor
final class SettingsWindow {

    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func present() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenClicky Settings"
            // A window released on close leaves this reference dangling, and the
            // second ⌘, crashes rather than reopening it.
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

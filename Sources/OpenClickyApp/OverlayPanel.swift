import AppKit
import SwiftUI

/// The translucent panel the agent lives in.
///
/// An `NSPanel` rather than a window, configured `.nonactivatingPanel`: pressing the
/// hotkey must not steal focus from whatever the user is working in, because the
/// agent's whole job is to act on *that* app. Stealing focus would change the very
/// state it was summoned to look at.
final class OverlayPanel: NSPanel {

    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Above full-screen apps and other floating windows, so it is reachable from
        // wherever the user summoned it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Excluded from screen capture, so the agent never sees — and reacts to —
        // its own overlay in a screenshot.
        sharingType = .none

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting
    }

    /// A borderless panel is not key by default, but the input field needs to be.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Centres horizontally on the screen holding the pointer, a third of the way
    /// down — where a heads-up prompt is expected, rather than dead centre over
    /// whatever the user is reading.
    func positionNearPointer() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = self.frame.size
        setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.origin.y + frame.height * 0.62
        ))
    }

    func present() {
        positionNearPointer()
        // orderFrontRegardless, not makeKeyAndOrderFront on the app: we want key
        // status for the text field without activating the whole application.
        orderFrontRegardless()
        makeKey()
    }
}

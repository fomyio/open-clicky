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
        // The panel grows to whatever SwiftUI needs. Its initial 160pt fits the input
        // row, but an approval prompt is a header, a scroll area of up to 120pt, a
        // button row and 36pt of padding — around 224pt — so Approve and Deny sat
        // below the bottom edge of a fixed panel. An approval whose buttons are off
        // screen is not an approval.
        //
        // `sizingOptions` is the supported way to let the hosting view drive the
        // window; the previous `translatesAutoresizingMaskIntoConstraints = false` on
        // a contentView added no constraints to replace what it switched off.
        hosting.sizingOptions = [.preferredContentSize]
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

import AppKit
import SwiftUI

/// The translucent panel the agent lives in.
///
/// An `NSPanel` rather than a window, configured `.nonactivatingPanel`, so that
/// presenting it *mid-run* — for an approval, or when a task finishes — cannot pull
/// focus out of the app the agent is in the middle of driving.
///
/// The original reason for the style mask was broader than that: the hotkey must not
/// steal focus from whatever the user is working in, because the agent's whole job is
/// to act on *that* app, and activating would change the very state it was summoned to
/// look at. That argument no longer holds for the summon itself, and it was buying
/// something the panel could not pay for. What the agent acts on is no longer inferred
/// from what happens to be frontmost when a task starts — the app the user was in is
/// captured at the moment the hotkey fires and carried explicitly (see `SummonedApp`),
/// so the target survives our own window taking focus. The old arrangement was
/// preserving a frontmost app that the environment block was already reporting as
/// `frontmost app: OpenClicky (com.openclicky.app)` in a real recorded session, which
/// is to say it was preserving it for nobody.
///
/// So a user-initiated summon activates, and the panel is key beyond argument. A
/// `.nonactivatingPanel` that is `canBecomeKey` is documented to take keyboard input
/// without its app being active, and that is what this did — but it is a contract with
/// a long history of not surviving contact with a SwiftUI `TextField`'s focus engine,
/// and a prompt you cannot type into is not a prompt. Every *other* presentation still
/// goes through `present()` without activation, so the only thing that ever takes focus
/// is the thing the user just asked for.
///
/// Activation is handed back before the run starts — see `AppDelegate.startRun` — for a
/// reason that is not cosmetic: while OpenClicky is the active application, a `type` or
/// `key` tool posts its keystrokes into *this* overlay.
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

    /// Keeps the panel on the screen, whatever height the content asks for.
    ///
    /// The height is not this class's to choose — `sizingOptions` hands it to the
    /// hosting view — and the content has now grown a second way: an expandable
    /// activity list adds up to ~190pt at the press of a chevron, on top of an
    /// approval prompt that is already ~224pt. The panel is positioned by its
    /// bottom-left corner, so every one of those points goes *upward*, and from 62%
    /// of the way up the screen there is not that much upward left. The approval
    /// prompt has already been through the mirror image of this once, with Approve
    /// and Deny below the bottom edge of a fixed panel; an input field pushed off the
    /// top is the same failure and just as silent.
    ///
    /// Clamped here rather than at each call site because there is no list of call
    /// sites: SwiftUI resizes this window whenever its content changes, from inside
    /// the layout pass. Everything that moves or resizes the panel goes through
    /// `setFrame(_:display:)`, so this is the one place that cannot be skipped.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.clamped(frameRect, onScreensFrom: NSScreen.screens), display: flag)
    }

    /// Fits a proposed frame inside the visible area of the screen it lands on.
    ///
    /// Static and taking its screens as an argument so the arithmetic is separable
    /// from the window server; the sizes it deals in are the ones that put a control
    /// off the edge of a display.
    static func clamped(_ proposed: NSRect, onScreensFrom screens: [NSScreen]) -> NSRect {
        // The screen it overlaps most, not the first it touches: a panel straddling
        // two displays belongs to the one showing most of it.
        let screen = screens.max { a, b in
            a.frame.intersection(proposed).area < b.frame.intersection(proposed).area
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame, visible.width > 0, visible.height > 0 else {
            return proposed
        }
        var rect = proposed
        // Size first. Nudging the origin of a frame that is taller than the screen
        // just moves which end falls off it.
        rect.size.width = min(rect.width, visible.width)
        rect.size.height = min(rect.height, visible.height)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        return rect
    }

    /// Centres horizontally on the screen holding the pointer, a third of the way
    /// down — where a heads-up prompt is expected, rather than dead centre over
    /// whatever the user is reading.
    func positionNearPointer() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = self.frame.size
        // `setFrame`, not `setFrameOrigin`: the clamp lives on the former, and a tall
        // panel positioned two-thirds of the way up would otherwise be placed off the
        // top of the screen and only pulled back the next time its content resized it.
        setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.origin.y + frame.height * 0.62,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    /// Puts the panel on screen.
    ///
    /// - Parameter activating: whether to make OpenClicky the active application first.
    ///   True only for a presentation the user just asked for — the hotkey, the menu
    ///   item, "New conversation" — where they are about to type and the field has to
    ///   be able to receive it. False everywhere else, and especially for the approval
    ///   prompt: taking focus in the middle of a run pulls it out of the app being
    ///   driven, at the one moment the user is watching what happens to it.
    ///
    ///   Order matters. Activating after ordering front leaves a window that is in
    ///   front of an app that is not, briefly, and the first keystrokes go to the old
    ///   app; activating first means the panel is ordered into an application that is
    ///   already the active one.
    func present(activating: Bool = false) {
        positionNearPointer()
        if activating {
            // `NSApp.activate()`, not the deprecated `ignoringOtherApps:` spelling.
            // An `.accessory` app has no Dock icon and no app-switcher entry, and
            // activating one is ordinary — it is how every Spotlight-alike works.
            NSApplication.shared.activate()
        }
        // orderFrontRegardless, not makeKeyAndOrderFront: the panel has to appear over
        // a full-screen app whether or not this application is the active one.
        orderFrontRegardless()
        makeKey()
    }
}

private extension NSRect {
    /// Zero for an empty intersection, which is what `NSRect.null` reports as NaN.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

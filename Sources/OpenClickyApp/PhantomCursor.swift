import AppKit
import OpenClickyKit

/// The agent's visible pointer.
///
/// A tiny click-through panel that follows the path the agent is about to take. It
/// is deliberately not a real cursor image: the point is that the user can tell the
/// difference between their pointer and the agent's at a glance.
@MainActor
final class PhantomCursor: NSObject, CursorPresenting {

    private let panel: NSPanel
    private static let diameter: CGFloat = 22

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver          // above everything, including the overlay
        panel.ignoresMouseEvents = true     // must never intercept the real pointer
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none           // excluded from the agent's own screenshots

        let view = CursorView(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        panel.contentView = view
    }

    // MARK: - CursorPresenting

    nonisolated func show(at point: CGPoint) async {
        await MainActor.run {
            guard let flipped = Self.appKitY(forQuartzY: point.y) else { return }
            panel.setFrameOrigin(NSPoint(
                x: point.x - Self.diameter / 2,
                y: flipped - Self.diameter / 2
            ))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// Converts a Quartz global y (used by CGEvent) to an AppKit global y.
    ///
    /// Both spaces are anchored to the *primary* display — the one with the menu bar,
    /// which is always `NSScreen.screens.first` — with Quartz measuring downward from
    /// its top edge and AppKit upward from its bottom. The flip therefore always uses
    /// the primary display's height, whatever screen the point lands on.
    ///
    /// Deriving it from the screen the point happens to be over is wrong the moment a
    /// second display has a different height or a vertical offset: the cursor renders
    /// at the wrong y, or off-screen entirely. On a single-display Mac the two are
    /// indistinguishable, which is exactly why this needed writing down.
    @MainActor
    static func appKitY(forQuartzY quartzY: CGFloat) -> CGFloat? {
        guard let primary = NSScreen.screens.first else { return nil }
        return primary.frame.maxY - quartzY
    }

    nonisolated func hide() async {
        await MainActor.run { panel.orderOut(nil) }
    }
}

/// A ring with a dot — readable against light and dark backgrounds alike, and
/// obviously not the system pointer.
private final class CursorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)

        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: inset).fill()

        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(ovalIn: inset)
        ring.lineWidth = 2
        ring.stroke()

        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: bounds.width / 2 - 2.5, dy: bounds.height / 2 - 2.5)).fill()
    }
}

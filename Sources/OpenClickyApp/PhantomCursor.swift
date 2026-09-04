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
            // CGEvent coordinates are top-left origin; AppKit windows are bottom-left.
            guard let screen = NSScreen.screens.first(where: {
                NSPointInRect(NSPoint(x: point.x, y: $0.frame.maxY - point.y), $0.frame)
            }) ?? NSScreen.main else { return }

            let flipped = screen.frame.maxY - point.y
            panel.setFrameOrigin(NSPoint(
                x: point.x - Self.diameter / 2,
                y: flipped - Self.diameter / 2
            ))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
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

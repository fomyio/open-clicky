import Foundation
import CoreGraphics

/// Geometry for the animated cursor.
///
/// The agent moving the pointer invisibly is the thing that makes a computer-use
/// tool feel untrustworthy: the user cannot tell what it is about to do, or where,
/// until it has already happened. Animating along a visible arc turns each action
/// into something legible and — crucially — interruptible, because the user can see
/// it coming and hit Escape.
///
/// Kept as pure geometry so the timing and shape are testable without a window.
public enum CursorPath {

    /// Cubic ease-in-out.
    ///
    /// Linear motion reads as mechanical and, oddly, as *faster* than it is —
    /// acceleration and deceleration are what make the movement legible.
    public static func ease(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped < 0.5
            ? 4 * clamped * clamped * clamped
            : 1 - pow(-2 * clamped + 2, 3) / 2
    }

    /// Points along a quadratic bézier from `start` to `end`.
    ///
    /// The arc bows perpendicular to the straight line by `curvature` of its length.
    /// A hand does not travel in a straight line, and the bow also makes the
    /// destination readable before arrival — the curve points at where it is going.
    public static func arc(
        from start: CGPoint, to end: CGPoint,
        steps: Int = 28, curvature: CGFloat = 0.18
    ) -> [CGPoint] {
        guard steps > 1 else { return [end] }

        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        guard distance > 1 else { return [end] }

        // Perpendicular to the travel direction, so the bow is always sideways
        // regardless of which way the pointer is heading.
        let normal = CGPoint(x: -delta.y / distance, y: delta.x / distance)
        let bow = min(distance * curvature, 120)
        let control = CGPoint(
            x: (start.x + end.x) / 2 + normal.x * bow,
            y: (start.y + end.y) / 2 + normal.y * bow
        )

        return (0...steps).map { step in
            let t = ease(Double(step) / Double(steps))
            let inverse = 1 - t
            return CGPoint(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
        }
    }

    /// How long a travel of `distance` points should take.
    ///
    /// Roughly Fitts-like: longer moves take longer, but sub-linearly, and the whole
    /// thing is capped. A cursor animation the user has to wait on stops being a
    /// courtesy and becomes an obstacle.
    public static func duration(forDistance distance: CGFloat) -> Duration {
        let milliseconds = min(max(120.0, Double(distance) * 0.45), 520.0)
        return .milliseconds(Int(milliseconds))
    }
}

/// Draws the agent's pointer. Implemented by the app; absent in the CLI.
public protocol CursorPresenting: AnyObject, Sendable {
    /// Places the phantom cursor at a screen point.
    func show(at point: CGPoint) async
    /// Hides it — called immediately before the real click, so the overlay is never
    /// between the synthetic event and its target.
    func hide() async
}

/// Routes action tools to a cursor presenter, when one is installed.
///
/// A no-op by default, so the CLI and the tests behave exactly as before and nothing
/// depends on a window server existing.
public actor CursorStage {
    public static let shared = CursorStage()

    private weak var presenter: (any CursorPresenting)?
    private var lastPoint: CGPoint?

    /// Where the next arc will start from. Readable so a cancelled travel can be
    /// shown not to have moved it.
    var lastPointForTesting: CGPoint? { lastPoint }

    public func install(_ presenter: any CursorPresenting) {
        self.presenter = presenter
    }

    /// Points this stage has been asked to travel to, for tests to inspect.
    ///
    /// Kept because nothing else could observe whether a tool animated before acting:
    /// removing the call left every test passing while the agent moved the pointer
    /// invisibly again.
    private(set) var visited: [CGPoint] = []

    /// How many travels are remembered. Nothing in production reads `visited`, so an
    /// unbounded record of every point the agent has ever moved to is a list that
    /// only grows — small, but it grows for as long as the process runs, and a test
    /// has never needed more than the last few.
    private static let visitedLimit = 64

    /// Animates to `point`, then hides so the click lands unobstructed.
    public func travel(to point: CGPoint) async {
        visited.append(point)
        if visited.count > Self.visitedLimit { visited.removeFirst() }
        guard let presenter else { return }

        let start = lastPoint ?? InputInjector.cursorPosition
        let path = CursorPath.arc(from: start, to: point)
        let total = CursorPath.duration(forDistance: hypot(point.x - start.x, point.y - start.y))
        // Duration divides by a scalar directly. Reaching into `.components` and
        // dividing the attoseconds would silently drop the whole-seconds part, which
        // is invisible only while `duration(forDistance:)` stays capped under a second.
        let perStep = max(total / max(path.count, 1), .milliseconds(1))

        for step in path {
            // The whole point of animating is that the user can see the click coming
            // and stop it. Swallowing cancellation here would animate out the full
            // path after they had already pressed Escape.
            if Task.isCancelled { break }
            await presenter.show(at: step)
            try? await Task.sleep(for: perStep)
        }
        // Only where it actually arrived. Recording the destination after a
        // cancellation would make the next arc start from a place the cursor was
        // never at, so the following action appears to leap in from nowhere — during
        // an interruption, which is exactly when the user is watching closely.
        if !Task.isCancelled { lastPoint = point }
        await presenter.hide()
    }
}

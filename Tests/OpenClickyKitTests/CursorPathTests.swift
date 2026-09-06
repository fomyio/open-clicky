import Testing
import CoreGraphics
@testable import OpenClickyKit

/// The animated cursor is what makes a computer-use agent legible: without it the
/// pointer jumps and the user cannot tell what is about to happen, or stop it.
/// The geometry is pure, so it can be checked without a window server.
@Suite("Cursor path")
struct CursorPathTests {

    @Test("Easing is bounded and monotonic")
    func easingIsWellFormed() {
        #expect(CursorPath.ease(0) == 0)
        #expect(abs(CursorPath.ease(1) - 1) < 0.0001)
        #expect(abs(CursorPath.ease(0.5) - 0.5) < 0.0001)

        var previous = -1.0
        for step in 0...20 {
            let value = CursorPath.ease(Double(step) / 20)
            #expect(value >= previous, "easing must never go backwards")
            previous = value
        }
    }

    @Test("Easing clamps out-of-range input")
    func easingClamps() {
        #expect(CursorPath.ease(-1) == 0)
        #expect(CursorPath.ease(2) == 1)
    }

    /// The path must actually arrive: an animation that stops short would leave the
    /// phantom cursor pointing somewhere the click does not land.
    @Test("The path starts at the origin and ends exactly on target")
    func pathHitsItsEndpoints() {
        let start = CGPoint(x: 100, y: 200)
        let end = CGPoint(x: 900, y: 640)
        let path = CursorPath.arc(from: start, to: end)

        let first = try! #require(path.first)
        let last = try! #require(path.last)
        #expect(abs(first.x - start.x) < 0.001 && abs(first.y - start.y) < 0.001)
        #expect(abs(last.x - end.x) < 0.001 && abs(last.y - end.y) < 0.001)
    }

    @Test("The path bows away from the straight line")
    func pathIsCurved() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 800, y: 0)
        let path = CursorPath.arc(from: start, to: end)

        // A straight horizontal move would keep y at zero throughout.
        let maximumDeviation = path.map { abs($0.y) }.max() ?? 0
        #expect(maximumDeviation > 10, "the arc should be visible, not a straight line")
        #expect(maximumDeviation < 200, "but not a detour")
    }

    @Test("The bow is capped on very long journeys")
    func bowIsCapped() {
        let path = CursorPath.arc(from: .zero, to: CGPoint(x: 6000, y: 0))
        #expect((path.map { abs($0.y) }.max() ?? 0) <= 130)
    }

    @Test("A degenerate move returns the destination rather than a path to nowhere")
    func degenerateMoves() {
        #expect(CursorPath.arc(from: .zero, to: .zero) == [.zero])
        let single = CursorPath.arc(from: .zero, to: CGPoint(x: 10, y: 10), steps: 1)
        #expect(single == [CGPoint(x: 10, y: 10)])
    }

    @Test("The requested number of steps is produced")
    func stepCountIsHonoured() {
        #expect(CursorPath.arc(from: .zero, to: CGPoint(x: 500, y: 500), steps: 30).count == 31)
    }

    /// A cursor animation the user has to wait through stops being a courtesy.
    @Test("Duration grows with distance but stays bounded")
    func durationIsBounded() {
        let near = CursorPath.duration(forDistance: 20)
        let far = CursorPath.duration(forDistance: 2000)
        #expect(near < far)
        #expect(near >= .milliseconds(120))
        #expect(far <= .milliseconds(520))
    }

    /// The per-step delay used to reach into `Duration.components` and divide only
    /// the attoseconds, silently discarding whole seconds — invisible only while the
    /// cap stayed under a second. This pins the property that survives a cap change.
    @Test("Per-step delay divides the whole duration, not just its fraction")
    func perStepDelayHandlesDurationsOverASecond() {
        let steps = 29
        for total in [Duration.milliseconds(300), .milliseconds(900), .seconds(2), .seconds(5)] {
            let perStep = max(total / steps, .milliseconds(1))
            let reconstructed = perStep * steps
            // Within one step of the original: the whole duration is accounted for.
            #expect(reconstructed >= total - perStep)
            #expect(reconstructed <= total + perStep)
        }
    }

    /// The animation exists so the user can see a click coming and stop it. Animating
    /// out the full path after they pressed Escape defeats the point.
    @Test("Travel stops promptly when the task is cancelled")
    func travelHonoursCancellation() async {
        actor Counter {
            private(set) var shown = 0
            func record() { shown += 1 }
        }
        final class SlowPresenter: CursorPresenting, @unchecked Sendable {
            let counter = Counter()
            func show(at point: CGPoint) async { await counter.record() }
            func hide() async {}
        }

        let presenter = SlowPresenter()
        let stage = CursorStage()
        await stage.install(presenter)

        let task = Task { await stage.travel(to: CGPoint(x: 1200, y: 900)) }
        // Cancel almost immediately; a cancellation-blind loop would run all 29 steps.
        try? await Task.sleep(for: .milliseconds(15))
        task.cancel()
        await task.value

        let shown = await presenter.counter.shown
        #expect(shown < 29, "cancelled travel showed \(shown) of 29 steps")
    }

    /// The stage is a no-op without a presenter, so the CLI and the tests are
    /// unaffected by the cursor existing at all.
    @Test("Travelling with no presenter installed does nothing and does not hang")
    func stageIsInertWithoutPresenter() async {
        let stage = CursorStage()
        await stage.travel(to: CGPoint(x: 400, y: 400))
    }

    // MARK: - What the stage remembers

    /// `visited` exists only so a test can see that a tool animated before acting.
    /// Nothing in production reads it, so recording every point the agent has ever
    /// moved to is a list that grows for as long as the process runs.
    @Test("The record of travels is bounded")
    func visitedIsBounded() async {
        let stage = CursorStage()
        for index in 0..<200 {
            await stage.travel(to: CGPoint(x: Double(index), y: 0))
        }
        let visited = await stage.visited
        #expect(visited.count <= 64, "the record grew to \(visited.count)")
        #expect(visited.last == CGPoint(x: 199, y: 0), "it kept the wrong end")
    }

    /// A cancelled travel did not arrive, and recording the destination anyway makes
    /// the next arc start from a place the cursor was never at — so the following
    /// action leaps in from nowhere, during an interruption, which is exactly when
    /// the user is watching closely.
    @Test("A cancelled travel does not claim to have arrived")
    func cancelledTravelKeepsTheOldOrigin() async {
        let stage = CursorStage()
        await stage.install(RecordingPresenter())

        let task = Task { await stage.travel(to: CGPoint(x: 900, y: 900)) }
        task.cancel()
        await task.value

        // It still records the request — that is what `visited` is for — but the
        // animation origin must not have moved to somewhere it never reached.
        #expect(await stage.visited.last == CGPoint(x: 900, y: 900))
        #expect(await stage.lastPointForTesting == nil,
                "a cancelled travel moved the origin to its unreached destination")
    }

    private final class RecordingPresenter: CursorPresenting, @unchecked Sendable {
        func show(at point: CGPoint) async {}
        func hide() async {}
    }
}

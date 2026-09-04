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

    /// The stage is a no-op without a presenter, so the CLI and the tests are
    /// unaffected by the cursor existing at all.
    @Test("Travelling with no presenter installed does nothing and does not hang")
    func stageIsInertWithoutPresenter() async {
        let stage = CursorStage()
        await stage.travel(to: CGPoint(x: 400, y: 400))
    }
}

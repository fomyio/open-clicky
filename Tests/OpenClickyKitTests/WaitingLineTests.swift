import Testing
import Foundation
@testable import OpenClickyKit

/// The line a user watches during the longest part of a run.
///
/// A bare "· thinking…" is the same silence the retry notice exists to break, just
/// shorter: recorded turns run 15–35 seconds against a local model and one reached 62
/// against Anthropic, and for every second of that the line said what it said at the
/// start.
@Suite("Waiting line", .serialized)
struct WaitingLineTests {

    /// Collects what was drawn, in order.
    private final class Pen: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        func write(_ text: String) { lock.lock(); written.append(text); lock.unlock() }
        var output: [String] { lock.lock(); defer { lock.unlock() }; return written }
    }

    /// Waits until `pen` has drawn at least `count` ticks, or gives up.
    ///
    /// Polled rather than slept: the suite runs in parallel, and a fixed sleep that
    /// assumes N ticks passes alone and fails under load — which is the flaky test
    /// this project spent a day removing from the mutation sweep, reintroduced by
    /// hand. A generous deadline with an early exit is fast when the machine is idle
    /// and correct when it is not.
    private func waitForTicks(_ count: Int, from pen: Pen) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if pen.output.filter({ $0.contains("thinking") }).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The line redraws with the seconds elapsed")
    func ticksWithElapsedSeconds() async throws {
        let pen = Pen()
        let waiting = WaitingLine(enabled: true, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        try await waitForTicks(3, from: pen)
        await waiting.stop()

        let ticks = pen.output.filter { $0.contains("thinking") }
        #expect(ticks.count >= 3, "expected several redraws, got \(pen.output.count)")
        // Each redraw returns to the start of the line rather than adding one.
        #expect(ticks.allSatisfy { $0.hasPrefix("\r") })
        #expect(ticks.allSatisfy { !$0.contains("\n") })
        // And the seconds ascend.
        #expect(ticks[0].contains("1s"))
        #expect(ticks[1].contains("2s"))
    }

    @Test("Disabled draws nothing at all")
    func disabledIsSilent() async throws {
        // In a pipe or a log `\r` does not overwrite, and this would emit one line a
        // second forever.
        let pen = Pen()
        let waiting = WaitingLine(enabled: false, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        // Nothing to wait for, so this sleeps — but it only has to be long enough to
        // catch a ticker that should not exist, and a false pass here is caught by
        // the enabled tests above.
        try await Task.sleep(for: .milliseconds(150))
        await waiting.stop()
        #expect(pen.output.isEmpty)
    }

    @Test("Stopping blanks the line so the next write starts clean")
    func stopClearsTheLine() async throws {
        let pen = Pen()
        let waiting = WaitingLine(enabled: true, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        try await waitForTicks(1, from: pen)
        await waiting.stop()

        let last = try #require(pen.output.last)
        // Padded, not a bare carriage return: a shorter next line would otherwise
        // leave the tail of this one underneath it.
        #expect(last.hasPrefix("\r"))
        #expect(last.hasSuffix("\r"))
        #expect(last.contains("    "))
        #expect(!last.contains("thinking"))
    }

    @Test("Starting twice runs one ticker, and stopping twice is harmless")
    func startAndStopAreIdempotent() async throws {
        // The observer calls these on every event, so both have to tolerate repeats.
        let pen = Pen()
        let waiting = WaitingLine(enabled: true, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        await waiting.start()
        #expect(await waiting.isRunning)
        try await waitForTicks(1, from: pen)
        await waiting.stop()
        #expect(await !waiting.isRunning)
        let after = pen.output.count
        await waiting.stop()
        #expect(pen.output.count == after, "a second stop should draw nothing")
    }

    @Test("Nothing is drawn after stopping")
    func noTicksAfterStop() async throws {
        // A ticker that outlived its turn would overwrite the agent's own output.
        let pen = Pen()
        let waiting = WaitingLine(enabled: true, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        try await waitForTicks(1, from: pen)
        await waiting.stop()
        let atStop = pen.output.count
        // Several intervals' worth: a ticker that survived cancellation would draw.
        try await Task.sleep(for: .milliseconds(200))
        #expect(pen.output.count == atStop)
    }

    @Test("The first line and its redraws agree on shape")
    func firstDrawMatchesRedraws() {
        // `RunReport` draws second zero and the ticker draws the rest; two spellings
        // would make the line jump on its first redraw.
        #expect(RunReport.waitingLine(seconds: 0) == "· thinking…")
        #expect(RunReport.waitingLine(seconds: 7) == "· thinking… 7s")
        var report = RunReport(isInteractive: true)
        #expect(report.lines(for: .thinking).first?.text == RunReport.waitingLine(seconds: 0))
    }

    @Test("Stopping from another task while it ticks is safe and immediate")
    func stopsFromAConcurrentTask() async throws {
        // The streamed path's usage: the ticker runs while the request is in flight,
        // and the first arriving fragment stops it from the client's context, not the
        // observer's. Whichever gets there first must leave the line blank and the
        // ticker gone.
        let pen = Pen()
        let waiting = WaitingLine(enabled: true, interval: .milliseconds(20)) { pen.write($0) }
        await waiting.start()
        try await waitForTicks(1, from: pen)

        // Several racers, as a burst of fragments would be.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await waiting.stop() } }
        }
        #expect(await !waiting.isRunning)

        let atStop = pen.output.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(pen.output.count == atStop, "no tick may survive the stop")
        // Exactly one blanking write, however many callers asked.
        #expect(pen.output.filter { !$0.contains("thinking") }.count == 1)
    }

}

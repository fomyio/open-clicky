import Foundation

/// Times how long a turn waits before the model says anything.
///
/// `bench` reports whole-turn model time, which conflates two problems with opposite
/// fixes. A 62-second turn that spent 60 of them before the first token is a cold
/// start, a queue, or weights loading — none of which get shorter by asking for less
/// output. A 62-second turn that produced its first token in two and spent the rest
/// generating is output-bound, and a terser prompt fixes it. Measured against
/// `deepseek-r1:7b` on this machine the wait was **18 seconds**, and nothing in the
/// record could say so.
///
/// Separate from `WaitingLine`, which has exactly the right lifecycle and the wrong
/// job: that one is disabled off a TTY, and a measurement that only happens when
/// someone is watching is not a measurement.
public actor TurnClock {

    private var startedAt: ContinuousClock.Instant?
    private var reported = false

    public init() {}

    /// Begins a turn. Called when the request goes out.
    public func start() {
        startedAt = ContinuousClock.now
        reported = false
    }

    /// Seconds until the first token, or nil if this is not the first token of a turn.
    ///
    /// Answers once per turn: a streamed response calls this on every fragment, and
    /// the second one is not news. Returning nil rather than a duration means a caller
    /// can write `if let` and record exactly one note per turn without tracking that
    /// itself.
    public func firstToken() -> Double? {
        guard let startedAt, !reported else { return nil }
        reported = true
        let elapsed = ContinuousClock.now - startedAt
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}

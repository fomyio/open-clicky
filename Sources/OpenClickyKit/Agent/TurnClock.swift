import Foundation

/// Times how long a turn waits before the model says anything.
///
/// `bench` reports whole-turn model time, which is two different quantities added
/// together: how long the model took to say anything, and how long it then spent
/// saying it. They do not respond to the same changes — asking for less output cannot
/// shorten the first — so a single figure cannot tell you which one moved.
///
/// What the wait *consists of* is deliberately not claimed here. Measured against
/// `deepseek-r1:7b` on one machine it ran 11–24 seconds against a ~650-token prompt
/// while a four-token prompt answered in half a second, and three plausible
/// explanations were each tested and refuted: doubling the prompt to ~1,220 tokens
/// changed it by less than the run-to-run variance; a cold run with the model unloaded
/// was not the slowest of four back-to-back runs; and the model is not withholding
/// content behind reasoning tokens, since the first delta it sends is content. So the
/// cause on that setup is unidentified, and this type reports the number rather than
/// a story about it.
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

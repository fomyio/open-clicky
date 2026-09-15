import Foundation

/// Notices that the microphone is open and carrying nothing.
///
/// This exists because of a defect it would have caught on the first session.
/// `setVoiceProcessingEnabled(true)` reconfigured the input node into a nine-channel
/// layout that `AVAudioConverter` has no downmix for, so every buffer handed to the
/// transcriber was digital silence — frames of the right length, at the right rate,
/// full of zeroes. Deepgram answered with empty transcripts, which the parse correctly
/// drops, so the session sat in `.listening` looking entirely healthy and heard nothing.
/// Nothing threw. Nothing logged. The user's report was "the voice mode doesn't work",
/// and there was no surface anywhere that could have said more.
///
/// The rule it encodes is the one that makes the detection honest: **a quiet room is
/// never exactly zero.** A real microphone has a noise floor — a laptop's is around
/// −60 dBFS — so a continuous run of exact zeroes is a claim about the *stream*, not
/// about the room. That is why this cannot be built on the level meter, whose −50 dB
/// floor reports a quiet room as zero on purpose.
///
/// A value type with no clock and no device, for the same reason `VoiceSession` is one:
/// the audio stack cannot be driven by a test, and a rule that can only be checked by
/// talking to the machine is a rule that gets checked once.
public struct SilenceWatchdog: Sendable, Equatable {

    /// How long the stream must be dead before it is worth saying so.
    ///
    /// Four seconds. Long enough that a genuine gap — a muted call, a device switching
    /// mid-session, the moment between plugging in a headset and it coming up — passes
    /// without a warning, and short enough that someone who has just started talking to
    /// a session that cannot hear them finds out while they are still talking rather
    /// than after they have given up.
    public let threshold: TimeInterval

    /// How much uninterrupted silence has been seen.
    public private(set) var silentFor: TimeInterval = 0
    /// Whether it has already fired. It fires once per session.
    public private(set) var hasWarned = false

    public init(threshold: TimeInterval = 4) {
        self.threshold = threshold
    }

    /// Feeds one buffer's worth of audio.
    ///
    /// - Parameters:
    ///   - isSilent: whether every sample in the buffer was exactly zero.
    ///   - duration: how many seconds of audio that buffer held.
    /// - Returns: `true` exactly once, on the buffer that carries the total past the
    ///   threshold. Once, and not on every buffer afterwards: this reaches a surface the
    ///   user is looking at, and a warning repeated fifty times a second is noise that
    ///   buries the session it is describing.
    public mutating func observe(isSilent: Bool, duration: TimeInterval) -> Bool {
        guard isSilent else {
            // One live buffer clears the count. A stream that is working intermittently
            // is a different complaint — and not one this can tell apart from ordinary
            // pauses — so it says nothing rather than guessing.
            silentFor = 0
            return false
        }
        guard !hasWarned else { return false }
        silentFor += max(0, duration)
        guard silentFor >= threshold else { return false }
        hasWarned = true
        return true
    }

    /// Forgets everything, including that it has warned.
    ///
    /// For a session restarting on the same instance — a new device, a new socket. The
    /// warning is once *per session*, and a session that was restarted to fix this is
    /// one that has to be able to report it again if the fix did not take.
    public mutating func reset() {
        silentFor = 0
        hasWarned = false
    }
}

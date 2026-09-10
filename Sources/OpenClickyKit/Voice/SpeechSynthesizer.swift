import Foundation
import AVFoundation

/// The agent's voice.
///
/// A protocol for the same reason `SpeechTranscriber` is one, and with a sharper
/// requirement behind it: **`stop()` has to be immediate**. Barge-in is worthless if the
/// sentence keeps playing after the run has been cancelled — a user who talks over the
/// agent and then listens to it finish anyway has been told, clearly, that interrupting
/// does not work. That requirement is what decided the implementation below, not
/// convenience.
public protocol SpeechSynthesizer: Sendable {
    /// Queues an utterance. Returns immediately; speech happens elsewhere.
    func speak(_ text: String)
    /// Silences whatever is playing and drops whatever is queued.
    func stop()
    /// Whether anything is currently being spoken.
    var isSpeaking: Bool { get }
}

/// `AVSpeechSynthesizer`, which is the right answer here for two specific reasons rather
/// than because it is built in.
///
/// **It stops instantly.** `stopSpeaking(at: .immediate)` cuts the current utterance and
/// empties the queue in one call. A network TTS returns audio in buffers that a player is
/// partway through when barge-in fires, so "stop" means unwinding a queue, a decoder and
/// a playback node — every one of which is somewhere the last half-second can escape from
/// and be heard after the agent was told to be quiet.
///
/// **It starts instantly.** Narration is spoken *before* a tool runs, so its latency is
/// added to every action the user watches. A REST round-trip per utterance would put a
/// few hundred milliseconds in front of each one, which is precisely the gap between an
/// assistant that is talking to you and one that is buffering.
///
/// It sounds less natural than a hosted voice, and that is a real trade rather than an
/// oversight — the seam above is here so a Deepgram Aura or OpenAI voice can be dropped
/// in, at the cost of both properties above.
///
/// Speech runs on the synthesiser's own thread and nothing here waits on it, which is
/// what lets the agent click and type while it is talking.
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizer, @unchecked Sendable {

    private let synthesizer = AVSpeechSynthesizer()
    private let rate: Float
    private let voice: AVSpeechSynthesisVoice?
    /// Called on the main actor when the queue drains, so the session can hand the floor
    /// back. Without it a session stays in `.speaking` forever and the microphone stays
    /// gated on a device with no echo cancellation.
    private let onFinished: @Sendable () -> Void

    /// - Parameter rate: slightly above `AVSpeechUtteranceDefaultSpeechRate`. The default
    ///   reads as a screen reader dictating rather than a person saying what they are
    ///   about to do, and every extra second of narration is a second of an action the
    ///   user is waiting on.
    public init(
        rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.08,
        voiceIdentifier: String? = nil,
        onFinished: @escaping @Sendable () -> Void = {}
    ) {
        self.rate = rate
        self.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        self.onFinished = onFinished
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = voice
        // No pre- or post-delay. The narration is already timed by the loop: it is said
        // immediately before an action, and a pause between the sentence and the click
        // reads as hesitation rather than as punctuation.
        synthesizer.speak(utterance)
    }

    public func stop() {
        // `.immediate`, never `.word`. Finishing the current word is the difference
        // between an assistant that stops when you talk over it and one that gets the
        // last word in — and `.word` on a long word is most of a second.
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        // Only when the queue is actually empty. A turn's narration can be several
        // utterances, and reporting after each one would hand the floor back mid-thought
        // — lifting the microphone gate while the next sentence is still to come.
        guard !synthesizer.isSpeaking else { return }
        onFinished()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        // A cancellation is barge-in, and the session has already moved on — it moved
        // first, which is what asked for the stop. Reporting "finished" here would send
        // it back to `.listening` from a phase it deliberately left.
    }
}

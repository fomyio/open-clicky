import Foundation

/// A live transcript of whoever is talking, as it arrives.
///
/// A protocol rather than a concrete Deepgram client because the choice of vendor is
/// the least durable decision in this file. Deepgram is the one wired up — its
/// interim/final split and its VAD events are what barge-in is built on — but the
/// session above it only knows the three events below, and the whole audio stack is
/// unreachable by a test either way. The seam is what lets `VoiceSessionTests` drive
/// every rule that matters without a device, a grant or a network.
public protocol SpeechTranscriber: Sendable {
    /// The sample rate this vendor has been told to expect.
    ///
    /// On the protocol rather than fixed in `AudioFormat` because the two vendors wired
    /// up disagree: Deepgram is told 16 kHz in its query string, and the Realtime API's
    /// `pcm16` *means* 24 kHz. A vendor told the wrong rate does not fail — it
    /// transcribes noise, confidently — so the rate has to travel with the choice of
    /// vendor rather than being a constant the capture assumes.
    ///
    /// `nonisolated` so an actor can satisfy it with a stored property and the capture
    /// can read it synchronously while setting up the converter.
    nonisolated var sampleRate: Int { get }
    /// Opens the stream. Events arrive on the callback until `finish()`.
    func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws
    /// Feeds one buffer of PCM. Called continuously while the mic is open.
    func send(_ audio: Data) async
    /// Closes the stream. Safe to call when it was never opened.
    func finish() async
}

/// What a transcriber tells the session.
public enum TranscriptEvent: Sendable, Equatable {
    /// Voice activity, ahead of any words.
    ///
    /// Separate from `transcript` and emitted first, because barge-in acts on this:
    /// waiting for a transcript puts a sentence of latency between someone talking
    /// over the agent and the agent stopping.
    case speechDetected
    /// Words. `isFinal` marks the end of an utterance; interim results are a running
    /// guess at the same span, not a prefix of it.
    case transcript(String, isFinal: Bool)
    /// The stream died. The session stays up — a dropped socket is a reconnect, not a
    /// reason to stop listening — but a run in flight is nobody's to cancel from here.
    case failed(String)
}

/// The audio format the transcriber is fed.
///
/// Fixed rather than negotiated. 16 kHz mono 16-bit PCM is what every streaming STT
/// vendor accepts, it is a quarter the bytes of 44.1 kHz stereo on a socket that is
/// open for as long as the session is, and speech carries nothing above 8 kHz that a
/// recogniser uses. The capture side converts into it once, at the tap.
public enum AudioFormat {
    /// The rate used when nobody says otherwise. Deepgram's, and the cheapest of the
    /// two on a socket that stays open for the length of a session.
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bitsPerSample = 16
}

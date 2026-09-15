import Testing
import Foundation
@testable import OpenClickyKit

/// The second transcriber behind `SpeechTranscriber`, and the first real test of that
/// seam. Two halves sit behind a websocket a test cannot open — the frames sent and the
/// frames parsed — and both fail quietly: a misspelled field is accepted by being
/// ignored, and a delta forwarded raw reads as three separate hearings of one sentence.
@Suite("OpenAI realtime transcription")
struct OpenAIRealtimeTests {

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: - What is sent

    /// A conversational realtime session would hold the conversation itself, which would
    /// replace `AgentLoop` and take the prompt cache, the tier ladder, the permission
    /// gate and the verbatim-replay transcript with it. Transcription intent is the
    /// architectural decision the whole file rests on.
    @Test("The socket asks for transcription, not a conversation")
    func endpointAsksForTranscriptionOnly() {
        let url = OpenAIRealtimeTranscriber.endpoint(
            base: URL(string: "wss://api.openai.com/v1/realtime")!
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "intent" }?.value == "transcription")
    }

    @Test("A custom base URL is honoured, for a proxy or a test double")
    func baseURLIsHonoured() {
        let url = OpenAIRealtimeTranscriber.endpoint(base: URL(string: "ws://localhost:8080/rt")!)
        #expect(url.absoluteString.hasPrefix("ws://localhost:8080/rt?"))
    }

    /// Every field here degrades silently when it is wrong. `server_vad` in particular is
    /// what produces `speech_started`, which is the *only* signal barge-in can act on
    /// early enough to feel like an interruption rather than a delay.
    @Test("The session update declares the format, the model and server-side VAD")
    func sessionUpdateCarriesEveryLoadBearingField() throws {
        let frame = try decode(OpenAIRealtimeTranscriber.sessionUpdate(model: "gpt-4o-transcribe"))
        #expect(frame["type"]?.stringValue == "transcription_session.update")

        let session = try #require(frame["session"])
        #expect(session["input_audio_format"]?.stringValue == "pcm16")
        #expect(session["input_audio_transcription"]?["model"]?.stringValue == "gpt-4o-transcribe")
        #expect(session["turn_detection"]?["type"]?.stringValue == "server_vad")
        #expect(session["turn_detection"]?["silence_duration_ms"]?.doubleValue != nil)
    }

    /// Audio is a field on a message here, not a binary frame — a raw binary frame is
    /// silently ignored, which is a session that connects, stays up, and hears nothing.
    @Test("Audio is base64 on a JSON message, and survives the round trip")
    func audioIsBase64OnAMessage() throws {
        let pcm = Data([0x01, 0x02, 0xFF, 0x7F, 0x00, 0x80])
        let frame = try decode(OpenAIRealtimeTranscriber.audioFrame(pcm))
        #expect(frame["type"]?.stringValue == "input_audio_buffer.append")
        let encoded = try #require(frame["audio"]?.stringValue)
        #expect(Data(base64Encoded: encoded) == pcm)
    }

    // MARK: - What comes back

    /// The whole difference from Deepgram. A delta is a *continuation*; Deepgram's
    /// interim is a running guess at the same span. Forwarded raw, "open"/" my"/
    /// " calendar" would reach `VoiceSession` as three separate hearings of one sentence
    /// and `heard` would show the last fragment rather than the utterance.
    @Test("Deltas accumulate into a running utterance rather than arriving as fragments")
    func deltasAccumulate() {
        var partial = ""
        var seen: [TranscriptEvent] = []
        for fragment in ["open", " my", " calendar"] {
            seen += OpenAIRealtimeTranscriber.events(
                in: #"{"type":"conversation.item.input_audio_transcription.delta","delta":"\#(fragment)"}"#,
                transcript: &partial
            )
        }
        #expect(seen == [
            .transcript("open", isFinal: false),
            .transcript("open my", isFinal: false),
            .transcript("open my calendar", isFinal: false),
        ])
    }

    /// Barge-in acts on this and nothing else. Waiting for a word puts most of a second
    /// between someone talking over the agent and the agent stopping.
    @Test("Speech detection arrives ahead of any words, and clears the previous utterance")
    func speechStartedIsTheEarliestSignal() {
        var partial = "left over from last time"
        let events = OpenAIRealtimeTranscriber.events(
            in: #"{"type":"input_audio_buffer.speech_started"}"#, transcript: &partial
        )
        #expect(events == [.speechDetected])
        // Cleared here rather than on the first delta, so the first word of a new
        // utterance never appears appended to the tail of the previous one.
        #expect(partial.isEmpty)
    }

    /// The completion is authoritative: the model revises, so the concatenated deltas are
    /// not always the text. Preferring the accumulator would submit a task the user did
    /// not say.
    @Test("The completed turn wins over the accumulated deltas")
    func completionIsAuthoritative() {
        var partial = "open my calender"
        let events = OpenAIRealtimeTranscriber.events(
            in: #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"open my calendar"}"#,
            transcript: &partial
        )
        #expect(events == [.transcript("open my calendar", isFinal: true)])
        #expect(partial.isEmpty)
    }

    /// A final that says nothing is a cough, a door, or the end of a pause — and
    /// `VoiceSession` would otherwise churn its phase on every one.
    @Test("An empty turn is dropped rather than submitted")
    func emptyCompletionIsDropped() {
        var partial = ""
        #expect(OpenAIRealtimeTranscriber.events(
            in: #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"   "}"#,
            transcript: &partial
        ).isEmpty)

        #expect(OpenAIRealtimeTranscriber.events(
            in: #"{"type":"conversation.item.input_audio_transcription.delta","delta":""}"#,
            transcript: &partial
        ).isEmpty)
    }

    /// Passed through verbatim. The realtime surface moves, and the sentence naming the
    /// field the server rejected is worth more to whoever is debugging this than any
    /// summary written ahead of time.
    @Test("The server's own words for a refusal reach the user")
    func errorsCarryTheServersText() {
        var partial = ""
        let events = OpenAIRealtimeTranscriber.events(
            in: #"{"type":"error","error":{"message":"Unknown parameter: session.foo","code":"unknown_parameter"}}"#,
            transcript: &partial
        )
        #expect(events == [.failed("Unknown parameter: session.foo (unknown_parameter)")])
    }

    @Test("A failed transcription is reported and does not leave a half utterance behind")
    func failedTranscriptionResets() {
        var partial = "half a sen"
        let events = OpenAIRealtimeTranscriber.events(
            in: #"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"audio too short"}}"#,
            transcript: &partial
        )
        #expect(events == [.failed("audio too short")])
        #expect(partial.isEmpty)
    }

    /// The API sends a great many event types this does not act on. Every one of them
    /// must be ignored rather than parsed into something — and malformed input must not
    /// throw on the receive loop.
    @Test("Unknown and malformed frames are ignored without disturbing the utterance")
    func noiseIsIgnored() {
        var partial = "open my"
        for frame in [
            #"{"type":"session.created"}"#,
            #"{"type":"input_audio_buffer.speech_stopped"}"#,
            #"{"type":"rate_limits.updated"}"#,
            "not json at all",
            "{}",
            "",
        ] {
            #expect(OpenAIRealtimeTranscriber.events(in: frame, transcript: &partial).isEmpty,
                    "frame should have been ignored: \(frame)")
        }
        #expect(partial == "open my")
    }

    // MARK: - Credentials

    @Test("An empty key is refused before a socket is opened")
    func emptyKeyIsRefused() async {
        let transcriber = OpenAIRealtimeTranscriber(apiKey: "   ")
        await #expect(throws: MissingVoiceCredentials.self) {
            try await transcriber.start { _ in }
        }
    }
}

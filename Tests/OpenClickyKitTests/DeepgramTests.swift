import Testing
import Foundation
@testable import OpenClickyKit

/// The two parts of the transcriber that sit behind a websocket a test cannot open:
/// the query the socket is opened with, and the parse of what comes back. Both fail
/// quietly — a mis-declared format transcribes noise confidently, and a missed flag
/// degrades into a session that half works — which is the same argument
/// `StreamAssembler` makes for the chat-completions dialect.
@Suite("Deepgram transcription")
struct DeepgramTests {

    private func query(_ url: URL) -> [String: String] {
        var found: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            found[item.name] = item.value
        }
        return found
    }

    // MARK: - The socket's query

    /// Deepgram trusts what it is told about the audio and does not check. A rate or a
    /// width that disagrees with what the tap actually sends produces fluent
    /// transcription of nothing, which is worse than an error.
    @Test("The declared format matches what the capture layer actually sends")
    func declaredFormatMatchesTheTap() {
        let items = query(DeepgramTranscriber.endpoint(
            base: URL(string: "wss://api.deepgram.com/v1/listen")!
        ))
        #expect(items["encoding"] == "linear16")
        #expect(items["sample_rate"] == String(AudioFormat.sampleRate))
        #expect(items["channels"] == String(AudioFormat.channels))
        #expect(AudioFormat.bitsPerSample == 16, "linear16 is a claim about this")
    }

    /// Both of these are what make the session feel live rather than polite:
    /// `vad_events` is the earliest possible barge-in signal, and `interim_results` is
    /// what puts words on screen while someone is still talking.
    @Test("Voice activity and interim results are both asked for")
    func liveSignalsAreRequested() {
        let items = query(DeepgramTranscriber.endpoint(
            base: URL(string: "wss://api.deepgram.com/v1/listen")!
        ))
        #expect(items["vad_events"] == "true")
        #expect(items["interim_results"] == "true")
        #expect(items["endpointing"] != nil, "without endpointing nothing is ever final")
        // Deepgram sends `UtteranceEnd` only when this is asked for, and without it
        // `SpeechStarted` has no counterpart: a cough fires the VAD, never becomes a
        // transcript, and parks `VoiceSession` in `.hearing` — where the agent refuses
        // to speak — for the rest of the session.
        #expect(items["utterance_end_ms"] != nil, "a noise that never became words is a trap")
        // The vendor requires interim results for it, and refuses the socket otherwise.
        #expect(items["interim_results"] == "true")
    }

    @Test("A custom base URL is honoured, keeping its host and path")
    func baseURLIsHonoured() {
        let url = DeepgramTranscriber.endpoint(base: URL(string: "ws://localhost:8080/listen")!)
        #expect(url.host == "localhost")
        #expect(url.port == 8080)
        #expect(url.path == "/listen")
        #expect(query(url)["model"] == "nova-3")
    }

    // MARK: - The frames that come back

    @Test("A voice-activity frame becomes the barge-in signal")
    func speechStartedIsDetection() {
        let events = DeepgramTranscriber.events(
            in: #"{"type":"SpeechStarted","channel_index":[0,1],"timestamp":1.2}"#
        )
        #expect(events == [.speechDetected])
    }

    /// `SpeechStarted`'s counterpart, and the only signal that a noise came to nothing.
    /// It arrives whether or not any words were recognised, which is exactly the case
    /// `.hearing` had no way out of — and the session went mute for good in it.
    @Test("An utterance ending with no words is still reported")
    func utteranceEndIsTheOtherHalf() {
        #expect(DeepgramTranscriber.events(in: #"{"type":"UtteranceEnd","last_word_end":1.9}"#)
                == [.speechEnded])
    }

    /// The two flags are different facts and this parse used to collapse them into one.
    ///
    /// `is_final` says this *segment* will not be revised. `speech_final` says the
    /// **person stopped talking**. Reading only the second and calling it "the final
    /// transcript" discarded every settled segment that was not the last, and turned
    /// each endpointed fragment into a whole task — which is what made a sentence with
    /// two pauses in it start three runs that cancelled one another.
    @Test("A settled segment and the end of a turn are separate facts")
    func segmentFinalIsNotUtteranceFinal() {
        let segment = DeepgramTranscriber.events(in: frame("open my", isFinal: true, speechFinal: false))
        #expect(segment == [.transcript("open my", isFinal: true)],
                "a settled segment was forwarded as a revisable guess and then lost")

        let utterance = DeepgramTranscriber.events(
            in: frame("calendar", isFinal: true, speechFinal: true)
        )
        #expect(utterance == [.transcript("calendar", isFinal: true), .speechEnded],
                "the endpointer's turn boundary never reached the session")
    }

    /// The order within the frame is the contract `VoiceSession` is written against:
    /// the words are accumulated first and the boundary spends them, so a boundary
    /// delivered ahead of its own words would submit the turn without them.
    @Test("The words come before the boundary they end")
    func transcriptPrecedesItsBoundary() {
        let events = DeepgramTranscriber.events(
            in: frame("open my calendar", isFinal: true, speechFinal: true)
        )
        #expect(events.count == 2)
        #expect(events.first == .transcript("open my calendar", isFinal: true))
        #expect(events.last == .speechEnded)
    }

    @Test("An interim result is reported as interim")
    func interimIsInterim() {
        #expect(DeepgramTranscriber.events(in: frame("open", isFinal: false, speechFinal: false))
                == [.transcript("open", isFinal: false)])
    }

    /// Deepgram emits empty transcripts continuously through silence. `VoiceSession`
    /// refuses to act on one, but a stream of them would still churn its phase on every
    /// frame, so they stop here.
    /// The whitespace cases carry JSON escape sequences rather than real characters: a
    /// raw newline inside a JSON string is malformed, so building one through the
    /// helper would have been discarded by the decoder and this would have passed
    /// without ever reaching the empty-transcript branch it exists to check.
    @Test("Silence produces no events at all", arguments: ["", " ", "\\n", "\\t  ", "\\r\\n"])
    func emptyTranscriptsAreDropped(escaped: String) throws {
        let frame = """
            {"speech_final":false,"channel":{"alternatives":[{"transcript":"\(escaped)"}]}}
            """
        // The frame itself has to be valid, or this proves only that bad JSON is dropped.
        _ = try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
        #expect(DeepgramTranscriber.events(in: frame).isEmpty)
    }

    /// The empty transcript is dropped; the boundary riding on the same frame is not.
    ///
    /// Deepgram endpoints a turn whose last frame carries nothing — the words were in
    /// the segments before it — and an early return on the empty string swallowed the
    /// one event that says the person has stopped talking. The turn would then wait out
    /// the settle timer instead of starting, which is a second of silence with no cause
    /// the user can see.
    @Test("An endpoint with no words in it still reports the turn is over")
    func emptyFinalStillCarriesTheBoundary() {
        let frame = #"{"speech_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#
        #expect(DeepgramTranscriber.events(in: frame) == [.speechEnded])
    }

    /// A transcriber is a network peer, and this parse runs on whatever it sends. It
    /// has to survive anything without trapping — a dropped connection mid-frame is
    /// ordinary, not exceptional.
    @Test("Malformed frames are ignored rather than trusted", arguments: [
        "", "not json", "{}", "[]", "null", #"{"channel":{}}"#,
        #"{"channel":{"alternatives":[]}}"#, #"{"channel":{"alternatives":[{}]}}"#,
        #"{"type":"Metadata","duration":3.2}"#,
        #"{"channel":{"alternatives":[{"transcript":null}]}}"#,
        #"{"channel":{"alternatives":"not an array"}}"#,
    ])
    func malformedFramesAreIgnored(frame: String) {
        #expect(DeepgramTranscriber.events(in: frame).isEmpty)
    }

    /// The first alternative is the one Deepgram ranks highest; the rest are guesses it
    /// already rejected and must never reach the agent as an instruction.
    @Test("Only the top-ranked alternative is used")
    func lowerRankedAlternativesAreIgnored() {
        let events = DeepgramTranscriber.events(in: """
            {"is_final":true,"speech_final":true,"channel":{"alternatives":[
              {"transcript":"open my calendar","confidence":0.99},
              {"transcript":"open my calender","confidence":0.41}]}}
            """)
        #expect(events == [.transcript("open my calendar", isFinal: true), .speechEnded])
    }

    // MARK: - Credentials

    @Test("An empty key is refused before a socket is opened")
    func emptyKeyIsRefused() async {
        let transcriber = DeepgramTranscriber(apiKey: "   ")
        await #expect(throws: DeepgramTranscriber.Error.self) {
            try await transcriber.start { _ in }
        }
    }

    /// The message has to name a command that actually parses — the same rule
    /// `AnthropicClient.missingCredentials` was corrected under, after suggesting a
    /// flag that failed with "Unknown option".
    @Test("The missing-key message names the store and does not leak one")
    func missingCredentialsMessageIsUseful() {
        let text = DeepgramTranscriber.Error.missingCredentials.description
        #expect(text.contains(ConfigFile.defaultURL.path))
        #expect(text.contains("DEEPGRAM_API_KEY"))
    }

    @Test("No stored key means no transcriber, rather than one that cannot work")
    func absentKeyYieldsNothing() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        // Only meaningful when the environment is not supplying one.
        try #require(ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] == nil)
        #expect(try DeepgramTranscriber.stored(config: config) == nil)
    }

    private func frame(_ text: String, isFinal: Bool, speechFinal: Bool) -> String {
        """
        {"is_final":\(isFinal),"speech_final":\(speechFinal),
         "channel":{"alternatives":[{"transcript":"\(text)","confidence":0.98}]}}
        """
    }
}

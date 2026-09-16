import Foundation

/// Streaming speech-to-text over OpenAI's Realtime API, in transcription mode.
///
/// The second vendor behind `SpeechTranscriber`, and the seam's first real test. The
/// session above it is unchanged: it still sees `speechDetected`, interim transcripts
/// and a final one, so barge-in, echo gating and the approval grammar all keep working
/// without knowing who produced them. `AgentLoop` is untouched, which is the invariant
/// that matters — *voice is a peripheral, never the brain*.
///
/// Two things differ from Deepgram and both are load-bearing:
///
/// **Sample rate.** Deepgram is told 16 kHz and believes it. The Realtime API's `pcm16`
/// is defined as 24 kHz, and a vendor told the wrong rate does not fail — it transcribes
/// noise, confidently, which is the exact failure `AudioCapture` exists to prevent. So
/// the rate is a property of the transcriber and the capture converts to whatever the
/// chosen one asks for, rather than to a constant.
///
/// **Interim results.** Deepgram's interim transcript is a running guess at the whole
/// utterance. OpenAI sends *deltas* — each frame is the next few characters, not a
/// restatement — so a delta forwarded raw would show the user "open", then "my", then
/// "calendar" as three separate hearings of one sentence. They are accumulated here, and
/// the accumulator is threaded through the parse rather than hidden inside it, so the
/// whole translation stays checkable without a socket.
public actor OpenAIRealtimeTranscriber: SpeechTranscriber {

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case connectionFailed(String)
        /// The API answered, and refused. Carried through verbatim: the realtime
        /// surface moves, and a guess at what the server meant is worth less to
        /// someone debugging than the sentence the server actually sent.
        case refused(String)

        public var description: String {
            switch self {
            case let .connectionFailed(detail): return "Could not reach the OpenAI Realtime API: \(detail)"
            case let .refused(detail): return "OpenAI refused the transcription session: \(detail)"
            }
        }
    }

    /// 24 kHz, because that is what `pcm16` means to this API. See the note above.
    public nonisolated let sampleRate = 24_000

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var isRunning = false
    /// The utterance being assembled out of deltas. See `events(in:transcript:)`.
    private var partial = ""

    public init(
        apiKey: String,
        baseURL: URL? = nil,
        model: String = "gpt-4o-transcribe",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? URL(string: "wss://api.openai.com/v1/realtime")!
        self.model = model
        self.session = session
    }

    /// The socket's URL.
    ///
    /// `intent=transcription` is what asks for a transcription-only session rather than
    /// a conversational one. That distinction is the architectural decision this whole
    /// file rests on: a conversational realtime session would hold the conversation
    /// itself, which would replace `AgentLoop` and take the prompt cache, the tier
    /// ladder, the permission gate and the verbatim-replay transcript with it.
    static func endpoint(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "intent", value: "transcription")]
        return components.url!
    }

    /// The session configuration sent as the first frame.
    ///
    /// Built here and tested, because every field degrades silently when it is wrong:
    ///
    /// - `input_audio_format` names a rate rather than carrying one: `pcm16` *means*
    ///   24 kHz mono little-endian to this API, which is why the rate lives on the
    ///   transcriber and the capture converts to it. See the type's note.
    /// - `turn_detection` server VAD is what produces `speech_started`, which is what
    ///   barge-in acts on. Without it the earliest signal is a finished transcript, and
    ///   that is a whole sentence too late to feel like an interruption.
    /// - `silence_duration_ms` is the endpointing question Deepgram spells `endpointing`.
    ///   500 ms rather than Deepgram's 300, because this API charges a turn boundary
    ///   with a model round-trip rather than a websocket frame.
    static func sessionUpdate(model: String) -> String {
        let payload: [String: JSONValue] = [
            "type": .string("transcription_session.update"),
            "session": .object([
                "input_audio_format": .string("pcm16"),
                "input_audio_transcription": .object([
                    "model": .string(model),
                ]),
                "turn_detection": .object([
                    "type": .string("server_vad"),
                    "threshold": .number(0.5),
                    "prefix_padding_ms": .number(300),
                    "silence_duration_ms": .number(500),
                ]),
                // The agent speaks through the same machine it listens on. Echo
                // cancellation is asked of the device first — see `AudioCapture` — and
                // this is the second line of defence when the device refuses.
                "input_audio_noise_reduction": .object([
                    "type": .string("near_field"),
                ]),
            ]),
        ]
        return JSONValue.object(payload).encodedString
    }

    /// One buffer of PCM, as the frame this API accepts.
    ///
    /// Base64 over JSON rather than a binary websocket frame: the Realtime API takes
    /// audio as a field on a message, and a raw binary frame is silently ignored.
    static func audioFrame(_ audio: Data) -> String {
        JSONValue.object([
            "type": .string("input_audio_buffer.append"),
            "audio": .string(audio.base64EncodedString()),
        ]).encodedString
    }

    public func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        guard !isRunning else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissingVoiceCredentials(.openaiRealtime)
        }
        var request = URLRequest(url: Self.endpoint(base: baseURL))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // The Realtime API has carried this header since its beta and still accepts it.
        // Sent rather than omitted because an endpoint that ignores it costs nothing,
        // and one that requires it fails with an error about the session type that
        // reads as a bad model id.
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let socket = session.webSocketTask(with: request)
        self.socket = socket
        isRunning = true
        partial = ""
        socket.resume()

        // Sent before any audio. Audio appended to a session that has not been told its
        // format is interpreted as the default, which is the confidently-transcribed
        // noise this file's header warns about.
        do {
            try await socket.send(.string(Self.sessionUpdate(model: model)))
        } catch {
            isRunning = false
            self.socket = nil
            socket.cancel(with: .goingAway, reason: nil)
            throw Error.connectionFailed("\(error)")
        }

        Task { await self.receive(onEvent: onEvent) }
    }

    public func send(_ audio: Data) async {
        guard isRunning, let socket else { return }
        // Dropped rather than thrown, exactly as Deepgram's is: this runs dozens of
        // times a second, and a send that fails means the socket is already going down,
        // which `receive` reports once instead of continuously from here.
        try? await socket.send(.string(Self.audioFrame(audio)))
    }

    public func finish() async {
        // Not `guard isRunning else { return }`. `receive` clears that flag when the
        // socket faults, so the early return meant a *failed* session never cancelled
        // its `URLSessionWebSocketTask` — the one case where cleanup matters most.
        // Cancelling twice is harmless; leaking a task per fault is not.
        defer {
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
        }
        guard isRunning else { return }
        isRunning = false
        // Commits whatever is still buffered so the last utterance is not lost to
        // hanging up mid-sentence — the same courtesy Deepgram's `CloseStream` does.
        //
        // Harmless when `server_vad` has already committed on its own: the server
        // answers an empty commit with an error event, which `events(in:)` turns into
        // `.failed` — and by here the session is closing, so nothing acts on it.
        try? await socket?.send(.string(#"{"type":"input_audio_buffer.commit"}"#))
        await drain()
        partial = ""
    }

    /// Gives the flush frame a moment to be answered before the socket is cancelled.
    ///
    /// Without this the courtesy above was decorative: the close frame was sent and the
    /// task cancelled in the very next statement, so whatever the vendor flushed had
    /// nowhere to arrive and the last utterance was lost exactly as if nothing had been
    /// sent. `receive` is still awaiting when this runs — `isRunning` is already false,
    /// so the loop delivers whatever lands and then exits on its next check.
    ///
    /// A quarter of a second, and not a round-trip wait: this runs when a user has
    /// stopped a session, and a stop that visibly hangs is worse than a dropped word.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(250))
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async {
        while isRunning, let socket {
            do {
                let message = try await socket.receive()
                guard case let .string(text) = message else { continue }
                for event in Self.events(in: text, transcript: &partial) { onEvent(event) }
            } catch {
                if isRunning { onEvent(.failed("\(error)")) }
                isRunning = false
                return
            }
        }
    }

    /// Turns one Realtime frame into the events the session understands.
    ///
    /// - Parameter transcript: the utterance assembled so far, updated in place. This is
    ///   the whole difference from Deepgram's parse: a delta is a *continuation*, and
    ///   emitting one on its own would hand `VoiceSession` three words as three separate
    ///   hearings of the same sentence. Threaded as an `inout` rather than held in the
    ///   actor so the accumulation — the fiddliest part, behind a socket no test can
    ///   reach — is checkable directly.
    static func events(in frame: String, transcript: inout String) -> [TranscriptEvent] {
        guard let data = frame.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = root["type"]?.stringValue else { return [] }

        switch type {
        case "input_audio_buffer.speech_started":
            // The earliest possible signal, and the one barge-in acts on. The partial
            // is cleared here rather than on the first delta, so a new utterance never
            // shows the tail of the previous one while its first word is arriving.
            transcript = ""
            return [.speechDetected]

        case "conversation.item.input_audio_transcription.delta":
            guard let delta = root["delta"]?.stringValue, !delta.isEmpty else { return [] }
            transcript += delta
            // Interim, like Deepgram's: a running guess at the whole utterance, which
            // is what `VoiceSession.heard` shows and what it refuses to act on.
            return [.transcript(transcript, isFinal: false)]

        case "conversation.item.input_audio_transcription.completed":
            // The authoritative text for the turn, which is not always the deltas
            // concatenated — the model revises. Preferred over the accumulator for that
            // reason, and the accumulator is only the fallback for a completion that
            // arrives without one.
            let final = root["transcript"]?.stringValue ?? transcript
            transcript = ""
            guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.transcript(final, isFinal: true)]

        case "conversation.item.input_audio_transcription.failed":
            transcript = ""
            return [.failed(errorDetail(root) ?? "transcription failed")]

        case "error":
            // Not fatal to the session, matching how a dropped Deepgram socket is
            // treated: the app reports it and keeps listening. A realtime session that
            // tore itself down on the first rejected field would take the microphone
            // away over something the next utterance may not trip.
            return [.failed(errorDetail(root) ?? "unspecified error")]

        default:
            return []
        }
    }

    /// The server's own words for what went wrong.
    ///
    /// Passed through rather than summarised. The realtime surface changes, and the
    /// message naming the field it rejected is worth more to whoever is debugging this
    /// than any sentence written here ahead of time.
    private static func errorDetail(_ root: JSONValue) -> String? {
        guard let error = root["error"] else { return nil }
        let message = error["message"]?.stringValue
        let code = error["code"]?.stringValue
        switch (message, code) {
        case let (message?, code?): return "\(message) (\(code))"
        case let (message?, nil): return message
        case let (nil, code?): return code
        case (nil, nil): return nil
        }
    }
}

private extension JSONValue {
    /// The value as a JSON string, keys sorted.
    ///
    /// Sorted so the frames this file builds are comparable against a literal in a
    /// test. Every one of them is a contract with a vendor that accepts a misspelled
    /// field by ignoring it, which is the failure mode the tests exist to catch.
    var encodedString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

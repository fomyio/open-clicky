import Foundation

/// Streaming speech-to-text over Deepgram's websocket.
///
/// Chosen over a conversational voice API for one architectural reason: it transcribes
/// and nothing else. The agent's brain stays `AgentLoop` against Anthropic, which is
/// what keeps the prompt cache, the tier ladder, the permission gate and the
/// verbatim-replay transcript invariant intact — a voice API that also holds the
/// conversation would have replaced all four. This turns speech into a `String` and
/// hands it to the same `submit` the text field uses.
///
/// Raw `URLSessionWebSocketTask` for the same reason `AnthropicClient` is raw HTTP:
/// there is no Swift SDK worth the dependency, and the surface used here is three
/// messages wide.
public actor DeepgramTranscriber: SpeechTranscriber {

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingCredentials
        case connectionFailed(String)

        public var description: String {
            switch self {
            case .missingCredentials:
                // Deferred to `MissingVoiceCredentials` rather than written twice. The
                // text that used to live here named `openclicky auth --provider
                // deepgram`, which could not work — `--provider` takes a
                // `Provider.Kind` — so the only documented route to a key was a command
                // that errored. One sentence, one place, and a test holds it to naming
                // a command the parser accepts.
                return "\(MissingVoiceCredentials(.deepgram))"
            case let .connectionFailed(detail):
                return "Could not reach Deepgram: \(detail)"
            }
        }
    }

    /// The provider name this key is stored under, shared with `ConfigFile`.
    public static let credentialName = VoiceProvider.deepgram.credentialName

    /// 16 kHz, declared in the query string below and converted to at the tap.
    public nonisolated let sampleRate = AudioFormat.sampleRate

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var isRunning = false

    public init(apiKey: String, baseURL: URL? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? URL(string: "wss://api.deepgram.com/v1/listen")!
        self.session = session
    }

    /// Reads the key the same way every other credential in this project is read.
    ///
    /// Environment first, then the file — the order `Provider` resolves in, so a key
    /// exported for one shell overrides a stored one here as it does everywhere else.
    /// `keys()` refuses a file other accounts can read, and that refusal is left to
    /// propagate rather than being softened to "no key": a credential in a
    /// world-readable file is already exposed, and carrying on would only decide when
    /// someone finds out.
    public static func stored(config: ConfigFile) throws -> DeepgramTranscriber? {
        guard let key = try VoiceProvider.deepgram.storedKey(config: config) else { return nil }
        return DeepgramTranscriber(apiKey: key)
    }

    /// The query the socket is opened with.
    ///
    /// Built here and tested, because every one of these is load-bearing and a typo in
    /// any of them degrades silently into a session that half works:
    ///
    /// - `interim_results` is what makes the transcript appear while someone is still
    ///   talking rather than a sentence later.
    /// - `vad_events` is what makes barge-in immediate. Without it the earliest signal
    ///   is a word, and a word is most of a second too late.
    /// - `endpointing` is how long a pause has to be before Deepgram calls the turn
    ///   finished. 800ms rather than 300: at 300 a breath mid-sentence ends the turn,
    ///   and "can you check the system settings for updates" was endpointed three times
    ///   on the way through — three tasks, each cancelling the last. `VoiceSession`
    ///   joins segments now, so the only thing this number decides is how long someone
    ///   may pause while thinking before the agent takes the floor.
    /// - `utterance_end_ms` is what makes `UtteranceEnd` arrive at all, and without it
    ///   `SpeechStarted` had no counterpart: a cough or a door fires the VAD, never
    ///   produces a transcript, and left `VoiceSession` parked in `.hearing` — where it
    ///   refuses to speak — for the rest of the session. Deepgram requires
    ///   `interim_results` for it, which is already asked for above. 1000ms is the
    ///   vendor's own minimum, and longer than `endpointing` on purpose: this is the
    ///   fallback for silence that produced *no* words, not a second endpointer.
    /// - the encoding trio must match `AudioFormat` exactly; Deepgram trusts what it is
    ///   told and mis-declaring it produces confident transcription of noise.
    static func endpoint(base: URL, model: String = "nova-3") -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "model", value: model),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: String(AudioFormat.sampleRate)),
            .init(name: "channels", value: String(AudioFormat.channels)),
            .init(name: "interim_results", value: "true"),
            .init(name: "vad_events", value: "true"),
            .init(name: "endpointing", value: "800"),
            .init(name: "utterance_end_ms", value: "1000"),
            .init(name: "smart_format", value: "true"),
        ]
        return components.url!
    }

    public func start(onEvent: @escaping @Sendable (TranscriptEvent) -> Void) async throws {
        guard !isRunning else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingCredentials
        }
        var request = URLRequest(url: Self.endpoint(base: baseURL))
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = session.webSocketTask(with: request)
        self.socket = socket
        isRunning = true
        socket.resume()
        Task { await self.receive(onEvent: onEvent) }
    }

    public func send(_ audio: Data) async {
        guard isRunning, let socket else { return }
        // Failures are dropped rather than thrown. This is called for every buffer the
        // microphone produces — dozens a second — and a send that fails means the
        // socket is already going down, which `receive` reports once instead of tens of
        // times a second from here.
        try? await socket.send(.data(audio))
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
        // Deepgram flushes whatever it was still holding when it sees this, so the last
        // utterance is not lost to hanging up mid-sentence.
        try? await socket?.send(.string(#"{"type":"CloseStream"}"#))
        await drain()
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
                for event in Self.events(in: text) { onEvent(event) }
            } catch {
                // A closed socket during teardown is the expected path, not a failure
                // worth telling the session about.
                if isRunning { onEvent(.failed("\(error)")) }
                isRunning = false
                return
            }
        }
    }

    /// Turns one Deepgram frame into the events the session understands.
    ///
    /// A static function over a string so the whole parse is testable without a socket
    /// — the same argument `StreamAssembler` makes for the chat-completions dialect,
    /// and for the same reason: this is the fiddliest part and it sits behind a network
    /// call that a test cannot reach.
    ///
    static func events(in frame: String) -> [TranscriptEvent] {
        guard let data = frame.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }

        if root["type"]?.stringValue == "SpeechStarted" { return [.speechDetected] }
        // `SpeechStarted`'s counterpart, and the reason `utterance_end_ms` is in the
        // query. It arrives whether or not any words were recognised, which is exactly
        // the case `.hearing` had no way out of.
        if root["type"]?.stringValue == "UtteranceEnd" { return [.speechEnded] }

        guard let alternative = root["channel"]?["alternatives"]?.arrayValue?.first else {
            return []
        }
        let text = alternative["transcript"]?.stringValue ?? ""

        // The two flags are different facts and this used to collapse them into one.
        //
        // `is_final` says *this segment* will not be revised. `speech_final` says the
        // endpointer decided the **person stopped talking**. Reading only the second
        // and calling it "the final transcript" threw away every settled segment that
        // was not the last one, and made each endpointed fragment a whole task: a
        // sentence with two pauses in it started three runs, each superseding and
        // cancelling the one before, and the user got no answer to any of them.
        //
        // So each is forwarded as what it is. `isFinal` marks a segment worth keeping
        // and `speechEnded` marks the turn — and `VoiceSession` is what joins the one
        // into the other.
        var events: [TranscriptEvent] = []
        // Empty transcripts are dropped here rather than passed on: Deepgram emits them
        // continuously through silence, and a stream of empty interims would churn the
        // session's phase on every frame. The turn boundary below is still forwarded —
        // an endpoint with nothing in it is exactly how the session learns that the
        // noise it was told about came to nothing.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(.transcript(text, isFinal: root["is_final"]?.boolValue ?? false))
        }
        if root["speech_final"]?.boolValue == true { events.append(.speechEnded) }
        return events
    }
}

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
                return """
                    No Deepgram API key found.

                    Store one in \(ConfigFile.defaultURL.path):
                      openclicky auth --provider deepgram

                    Or set it for this shell only:
                      export DEEPGRAM_API_KEY=...
                    """
            case let .connectionFailed(detail):
                return "Could not reach Deepgram: \(detail)"
            }
        }
    }

    /// The provider name this key is stored under, shared with `ConfigFile`.
    public static let credentialName = "deepgram"

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
        if let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DeepgramTranscriber(apiKey: key)
        }
        guard let key = try config.keys()[credentialName] else { return nil }
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
    /// - `endpointing` is how long a pause has to be before an utterance is called
    ///   finished. 300ms is short enough to feel conversational and long enough to
    ///   survive someone thinking mid-sentence.
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
            .init(name: "endpointing", value: "300"),
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
        guard isRunning else { return }
        isRunning = false
        // Deepgram closes cleanly on this and flushes whatever it was still holding, so
        // the last utterance is not lost to hanging up mid-sentence.
        try? await socket?.send(.string(#"{"type":"CloseStream"}"#))
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
    /// Empty transcripts are dropped here rather than passed on. Deepgram emits them
    /// continuously through silence, and while `VoiceSession` refuses to act on one, a
    /// stream of empty interim results would still churn its phase on every frame.
    static func events(in frame: String) -> [TranscriptEvent] {
        guard let data = frame.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }

        if root["type"]?.stringValue == "SpeechStarted" { return [.speechDetected] }

        guard let alternative = root["channel"]?["alternatives"]?.arrayValue?.first,
              let text = alternative["transcript"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // `speech_final` means the endpointer decided the utterance is over.
        // `is_final` only means this *segment* will not be revised, and a long sentence
        // produces several — treating those as complete utterances would submit half a
        // sentence as a task and then the other half as a second one.
        let isFinal = root["speech_final"]?.boolValue ?? false
        return [.transcript(text, isFinal: isFinal)]
    }
}

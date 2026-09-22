import Foundation
import AVFoundation

/// A natural, expressive voice over the network, behind the same `SpeechSynthesizer`
/// seam `SystemSpeechSynthesizer`'s own header names as the reason it exists: "a Deepgram
/// Aura or OpenAI voice can be dropped in, at the cost of both properties above."
///
/// **The cost, paid deliberately.** Starting is a REST round trip — a few hundred
/// milliseconds the system voice never spends — and stopping cannot cut mid-buffer the
/// way `AVSpeechSynthesizer.stopSpeaking(at: .immediate)` does: `stop()` here silences
/// `AVAudioPlayer` and cancels whatever request is in flight, which is as immediate as a
/// network-backed voice gets, not as immediate as a device call. Both trades are the ones
/// `TTSProvider.openai.detail` tells the user about before they pick this over the
/// default, and neither is hidden from them after.
///
/// Queued the way the system voice queues, in front of it rather than behind
/// `AVAudioPlayer` — which has no queue of its own, only one clip at a time — so a turn
/// spoken as several `speak(_:)` calls plays in order here exactly as it would there.
public final class OpenAISpeechSynthesizer: NSObject, SpeechSynthesizer, @unchecked Sendable {

    /// One call to `/v1/audio/speech`. Kept apart from the network and the player below
    /// so its shape can be asserted — see `OpenAISpeechSynthesizerTests` — without a
    /// socket or a speaker, the same split `JevClient.Request` uses for the same reason.
    struct Request: Encodable {
        let model: String
        let input: String
        let voice: String
        let instructions: String?
        let response_format: String
    }

    public static let defaultModel = "gpt-4o-mini-tts"
    /// One of OpenAI's newer, more expressive voices rather than one of the original
    /// six — chosen for warmth over neutrality, which is the whole complaint this class
    /// exists to answer.
    public static let defaultVoice = "coral"

    /// The one style instruction every utterance carries.
    ///
    /// Deliberately general rather than per-line: `SpeechSynthesizer.speak(_:)` takes
    /// text alone, and threading a mood through every caller — the opener, a tool
    /// announcement, the model's own prose — would be a second parameter each of them
    /// has to decide a value for, for a difference `gpt-4o-mini-tts` itself already
    /// reads from punctuation and content most of the time. A voice that is warm and
    /// present by default costs nothing on a line that did not need it, and is what
    /// "robotic" asked to stop being.
    public static let defaultInstructions = """
        Speak warmly and naturally, like a capable assistant who is genuinely paying \
        attention: present tense, a little upbeat, never a flat monotone read-through. \
        Keep the pace brisk — this is spoken while an action is already under way, not \
        read to an empty room.
        """

    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String?
    private let endpoint: URL
    private let session: URLSession
    private let onFinished: @Sendable () -> Void

    private let lock = NSLock()
    /// Sentences waiting to be spoken, oldest first.
    private var queue: [String] = []
    private var isProcessing = false
    private var currentRequest: Task<Void, Never>?
    private var player: AVAudioPlayer?

    public init(
        apiKey: String,
        model: String = defaultModel,
        voice: String = defaultVoice,
        instructions: String? = defaultInstructions,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/speech")!,
        session: URLSession? = nil,
        onFinished: @escaping @Sendable () -> Void = {}
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Long enough for a full sentence of audio to render server-side and
            // arrive; short enough that a stalled request does not sit in the queue
            // forever ahead of everything said after it.
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: configuration)
        }
        self.onFinished = onFinished
    }

    public var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isProcessing
    }

    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        queue.append(trimmed)
        let alreadyRunning = isProcessing
        isProcessing = true
        lock.unlock()
        guard !alreadyRunning else { return }
        advance()
    }

    public func stop() {
        lock.lock()
        queue.removeAll()
        isProcessing = false
        let request = currentRequest
        currentRequest = nil
        let activePlayer = player
        player = nil
        lock.unlock()
        // Cancelled before stopped: a request that is about to deliver audio must not
        // hand it to `startPlaying` after `stop()` has already returned, or a sentence
        // starts after the caller was told the voice had gone quiet.
        request?.cancel()
        // `.stop()` does not invoke the delegate's finish callback — Apple's own
        // contract — so nothing here re-triggers `advance()` on its way out.
        activePlayer?.stop()
    }

    /// Pulls the next sentence off the queue and fetches its audio, or finishes.
    ///
    /// One function for both the ordinary advance and the recovery from a request that
    /// failed outright: a dropped sentence is recoverable exactly as a `JevClient`
    /// reading that never arrives is, and stalling everything said after it on one bad
    /// response would be a worse failure than losing that one line.
    private func advance() {
        lock.lock()
        guard !queue.isEmpty else {
            isProcessing = false
            lock.unlock()
            onFinished()
            return
        }
        let text = queue.removeFirst()
        lock.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            let data = await self.fetch(text)
            // `stop()` already reset every piece of state this would touch and this
            // request's cancellation is the only reason to be here — saying anything
            // more would be the `didCancel` mistake `SystemSpeechSynthesizer`'s own
            // comment names: reporting "finished" from a phase barge-in deliberately
            // left.
            guard !Task.isCancelled else { return }
            guard let data else {
                self.advance()
                return
            }
            self.startPlaying(data)
        }
        lock.lock()
        currentRequest = task
        lock.unlock()
    }

    private func fetch(_ text: String) async -> Data? {
        guard let body = try? JSONEncoder().encode(Request(
            model: model, input: text, voice: voice,
            instructions: instructions, response_format: "wav"
        )) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Every failure — a timeout, a 401, a 500 — lands in the same place and means
        // the same thing to the caller: this sentence is not going to be said. What it
        // must not do is throw and stop the turns after it from being said either.
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }

    private func startPlaying(_ data: Data) {
        guard let audioPlayer = try? AVAudioPlayer(data: data) else {
            advance()
            return
        }
        audioPlayer.delegate = self
        lock.lock()
        player = audioPlayer
        lock.unlock()
        guard audioPlayer.play() else {
            advance()
            return
        }
    }
}

extension OpenAISpeechSynthesizer: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        lock.lock()
        self.player = nil
        lock.unlock()
        advance()
    }
}

import Foundation

/// Reads a turn with TypeSafe's Jev, a model that returns typed decisions and no text.
///
/// Chosen over asking a Messages-class model the same questions for three reasons, and
/// only one of them is speed.
///
/// - **It cannot answer off-schema.** A transcript is untrusted input — it is whatever
///   the room said, transcribed by a vendor — and the reply to a free-text prompt is a
///   string this process then has to parse and believe. A `Choice` comes back as one of
///   the options declared in the request or not at all, so there is no field for a
///   sentence in the transcript to steer and nothing to parse defensively.
/// - **Its confidence is calibrated**, which is what makes `TurnReading`'s thresholds
///   mean anything. Thresholds over a number that is not calibrated are a guess wearing
///   a decimal point.
/// - **All questions on one state are answered in parallel**, so the four asked here
///   cost about what one costs. This is why there is no cascade: a second call to
///   refine the first would double the only budget that matters.
///
/// ~70–500 ms, which is why classification is *speculative* rather than blocking — see
/// `VoiceSession.classify`. The session never waits for this. A reading that arrives
/// after its turn was decided is discarded by `TurnReading.applies(to:)`.
public struct JevClient: TurnClassifier {

    /// The name this key is stored under in `~/.openclicky/config.json`.
    ///
    /// Its own entry, not borrowed from a model provider, for the reason
    /// `VoiceProvider.credentialName` gives: revoking a key used for one thing should
    /// not silently disable another, and "the microphone stopped understanding me" is a
    /// bad way to learn that a model key was rotated.
    public static let credentialName = "typesafe"
    public static let apiKeyVariable = "TYPESAFE_API_KEY"

    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession
    /// The session the deliberate check uses.
    ///
    /// Separate because the two have opposite deadlines and one of them is not
    /// negotiable. `session` is capped at `deadline` — a second, which is the length of
    /// a pause in a conversation, not a network budget — and a request cannot raise that
    /// on its own, because `URLSessionConfiguration.timeoutIntervalForRequest` applies
    /// whatever the request asks for. So a check made through it times out against a
    /// service that is merely thinking, and reports a working key as unreachable.
    private let probeSession: URLSession
    /// Said once, when the service refuses in a way a person has to fix.
    ///
    /// Everything else here fails silently on purpose — a timeout, a dropped
    /// connection, a 500 all mean "no reading", and the session carries on exactly as it
    /// did before this file existed. **A rejected key is different.** It never recovers,
    /// it produces no error anywhere, and what the user sees is a feature that was
    /// configured and simply does nothing: `doctor` says a key is stored, the session
    /// starts normally, and every turn quietly takes the slow path forever.
    ///
    /// That is the exact shape of defect this project keeps finding, so the narrow set
    /// of statuses that mean *your configuration is wrong* are said out loud, once.
    private let report: @Sendable (String) -> Void
    private let reported = Reported()

    /// How long a reading may take before it is worthless.
    ///
    /// Not a network budget — it is how long the answer stays worth having. That used to
    /// be `VoiceSession.settle`, because classification only ran once the speaker had
    /// paused, and a reading landing after the turn went out could not change anything.
    ///
    /// It is longer now, and the reason is that the question is asked earlier. A reading
    /// is requested every few words *while somebody is still talking*, so its useful
    /// life is the rest of the sentence rather than the gap at the end of one.
    ///
    /// Three seconds because of what the service actually does, measured rather than
    /// assumed: ~390ms steady state with the whole application catalogue in the request
    /// (16.7KB, 117 options — no slower than a bare one), and **~925ms for the first
    /// call of a session**, which is the TLS handshake. At one second that first
    /// classification of every session was discarded, which is the one nobody would have
    /// noticed missing and the one that decides whether the feature appears to work at
    /// all.
    public static let deadline: TimeInterval = 3.0

    /// How long a deliberate check may take.
    ///
    /// Somebody who typed `auth` or `doctor --classifier` is waiting for an answer and
    /// will give it a moment; a turn in flight will not. Reporting a good key as
    /// unreachable because the service took two seconds is the worst outcome this check
    /// has, since it sends the user off to replace something that was never wrong.
    public static let probeDeadline: TimeInterval = 15

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        session: URLSession? = nil,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.report = report
        if let session {
            // Injected: one session for both, so a test drives exactly what it built.
            self.session = session
            self.probeSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.deadline
            configuration.timeoutIntervalForResource = Self.deadline
            self.session = URLSession(configuration: configuration)

            let probe = URLSessionConfiguration.ephemeral
            probe.timeoutIntervalForRequest = Self.probeDeadline
            probe.timeoutIntervalForResource = Self.probeDeadline
            self.probeSession = URLSession(configuration: probe)
        }
    }

    /// The key, environment first then the file, in the order every other credential in
    /// this project is resolved.
    ///
    /// The refusal `keys()` raises on a world-readable file is left to propagate for the
    /// same reason it is everywhere else: a key other accounts can read is exposed, and
    /// carrying on would only decide when somebody finds out.
    public static func storedKey(config: ConfigFile = ConfigFile()) throws -> String? {
        if let key = ProcessInfo.processInfo.environment[apiKeyVariable],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key
        }
        return try config.keys()[credentialName]
    }

    public func read(_ context: TurnContext, options: FastPath.Options) async -> TurnReading? {
        guard let body = try? JSONEncoder().encode(
            Request(context: context, options: options)
        ) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Every failure lands in the same place and means the same thing: no reading,
        // and the session keeps the behaviour it had before this file existed. A 429, a
        // dropped connection and a malformed body are different problems for whoever
        // reads the logs and the identical problem for the turn in flight.
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        guard http.statusCode == 200 else {
            if let complaint = Self.configurationProblem(http.statusCode),
               reported.firstTime() {
                report(complaint)
            }
            return nil
        }
        guard let answers = Self.answers(in: data) else { return nil }

        // A partial answer is not a reading. Anything missing would have to be given a
        // default, and the only safe default for each of these is the value that changes
        // nothing — at which point the reading is the absence of one, said at length.
        guard let addressed = answers[Key.addressed]?.noul,
              let complete = answers[Key.complete]?.noul,
              let halt = answers[Key.halt]?.noul,
              let chosen = answers[Key.intent]?.choice,
              let intent = TurnReading.Intent(rawValue: chosen)
        else { return nil }

        // Resolved here, against the options that were actually sent. Everything the
        // fast path is allowed to refuse for — a name nobody offered, two builds of one
        // app, a narrow win, a list that was cut — is decided locally, so none of it
        // depends on the vendor behaving the way its documentation says.
        let picked = answers[Key.action]
        let action = FastPath.resolve(
            chosen: picked?.choice ?? FastPath.Action.model.name,
            confidence: picked?.confidence ?? 0,
            margin: picked?.margin,
            options: options
        )

        return TurnReading(
            utterance: context.utterance,
            addressed: addressed,
            complete: complete,
            halt: halt,
            intent: intent,
            intentConfidence: answers[Key.intent]?.confidence ?? 0,
            action: action
        )
    }

    /// Tries the key against the service with the smallest request that proves anything.
    ///
    /// "Stored in the config file" is not the same claim as "this key works", and
    /// telling somebody the first while they hear the second is how a mistyped key
    /// becomes a feature that silently does nothing — the exact failure the one-off
    /// complaint in `read` exists to catch after the fact. This catches it before.
    ///
    /// It has to be a *real* classification rather than a ping: the question worth
    /// answering is not "is the host up" but "does this build and this service agree
    /// about the request", and only a request of the shape `read` sends can answer it.
    /// One `Noul` over a dozen tokens is a fraction of a cent.
    ///
    /// Reuses `Credentials.Verification` deliberately. A second vocabulary for the same
    /// four outcomes would be a second thing to keep in step with the wording every
    /// other credential in this project is reported with.
    public func verify() async -> Credentials.Verification {
        let probe = TurnContext(
            utterance: "open the settings",
            agentLastSaid: "",
            isRunInFlight: false,
            isAwaitingApproval: false
        )
        guard let body = try? JSONEncoder().encode(Request(context: probe)) else {
            return .misconfigured("this build could not encode a request")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = Self.probeDeadline

        let data: Data
        let http: HTTPURLResponse
        do {
            let (received, response) = try await probeSession.data(for: request)
            guard let status = response as? HTTPURLResponse else {
                return .unreachable("the service answered with something that was not HTTP")
            }
            data = received
            http = status
        } catch {
            return .unreachable(error.localizedDescription)
        }

        switch http.statusCode {
        case 200:
            // Answered, but about what? A 200 carrying a body this build cannot read is
            // the `misconfigured` case exactly — the credential is fine and replacing it
            // would not help. `doctor --provider ollama` reporting "verified" against a
            // model that had never been pulled is the precedent for caring about this.
            guard let answers = Self.answers(in: data),
                  answers[Key.addressed]?.noul != nil
            else {
                return .misconfigured(
                    "it answered, but not with the questions this build asked"
                )
            }
            return .working
        case 401, 403:
            return .rejected("HTTP \(http.statusCode)")
        case 400, 404, 422:
            return .misconfigured("HTTP \(http.statusCode) — it refused the request itself")
        case 429:
            return .unreachable("rate limited (HTTP 429) — the key may be fine")
        default:
            return .unreachable("HTTP \(http.statusCode)")
        }
    }

    /// What to say about a status that will not fix itself, or nil to stay quiet.
    ///
    /// Deliberately a short list. A 429 is a rate limit and passes on its own; a 5xx is
    /// the service having a bad minute; a timeout is the network. None of those is
    /// something the user can act on, and a banner for each would train them to ignore
    /// the one that matters.
    static func configurationProblem(_ status: Int) -> String? {
        switch status {
        case 401, 403:
            return """
                Turn classification is being refused: the TypeSafe key was rejected \
                (HTTP \(status)). Voice still works and every turn is taking the ordinary \
                route. Fix it with `openclicky auth --classifier`.
                """
        case 400, 404, 422:
            return """
                Turn classification is being refused (HTTP \(status)) — this build and \
                the service disagree about the request. Voice still works and every turn \
                is taking the ordinary route.
                """
        default:
            return nil
        }
    }

    /// One complaint per session, whatever happens after it.
    ///
    /// A turn is classified several times as it is spoken, so an unfixable refusal
    /// arrives a few times a sentence — and a banner per window would bury the session
    /// it is trying to describe.
    final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var already = false
        func firstTime() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if already { return false }
            already = true
            return true
        }
    }

    // MARK: - The wire

    private enum Key {
        static let addressed = "addressed"
        static let complete = "complete"
        static let halt = "halt"
        static let intent = "intent"
        static let action = "action"
    }

    /// One request, every question. There is no second call by design.
    struct Request: Encodable {
        let model = "jev-latest"
        let state: String
        let questions: [String: Question]

        init(context: TurnContext, options: FastPath.Options = .empty) {
            state = Request.state(for: context)
            var questions: [String: Question] = [
                Key.addressed: .noul(
                    instructions: """
                        Was the utterance spoken to the assistant? Answer no if the \
                        speaker is talking to another person, on a call, reading \
                        something aloud, or thinking out loud to themselves.
                        """
                ),
                Key.complete: .noul(
                    instructions: """
                        Is the utterance a finished thought? Answer no only if the \
                        speaker was plainly cut off mid-sentence and more words were \
                        coming. A short question or a terse command is finished.
                        """
                ),
                Key.halt: .noul(
                    instructions: """
                        Is the utterance asking the assistant to stop what it is doing, \
                        and nothing else? Answer no if it is an instruction that merely \
                        contains a word like stop — "stop the music" asks the assistant \
                        to do something, it does not ask it to stop.
                        """
                ),
                Key.intent: .choice(
                    instructions: "What is the utterance for?",
                    criteria: TurnReading.Intent.criteria
                ),
            ]
            // One flat choice whose option *is* the action, asked in the same request
            // and therefore answered in parallel with the rest. The alternative — a
            // route question of automatic/none/llm plus one question per family — would
            // need a further question to say *which* family, and would let two fields
            // disagree about what was asked for.
            //
            // Omitted entirely when there is nothing to offer, rather than sent with an
            // empty option list: a choice between `none` and `llm` alone is a question
            // whose answer changes nothing, and it would still be paid for.
            if !options.isEmpty {
                questions[Key.action] = .choice(
                    instructions: """
                        Which of these is the speaker asking for? Pick an action only if \
                        the utterance plainly asks for exactly that and nothing else. If \
                        it asks for anything more, anything different, or anything you \
                        are unsure about, pick the option for handing it on.
                        """,
                    criteria: options.criteria
                )
            }
            self.questions = questions
        }

        /// What the model is told about the moment, in the order it matters.
        ///
        /// The framing is deliberately about *a room with a microphone in it* rather
        /// than about a command line. The question that has no lexical answer —
        /// "was this for me" — is only answerable if the model knows that the
        /// alternative is a real possibility.
        private static func state(for context: TurnContext) -> String {
            var lines = [
                """
                A hands-free assistant operates the user's Mac. Its microphone is open \
                continuously and hears the whole room, so not everything transcribed was \
                said to it.
                """
            ]
            if !context.agentLastSaid.isEmpty {
                lines.append("The assistant last said aloud: \"\(context.agentLastSaid)\"")
            }
            lines.append(
                context.isRunInFlight
                    ? "The assistant is running a task right now."
                    : "The assistant is idle."
            )
            if context.isAwaitingApproval {
                lines.append(
                    "The assistant has asked a yes/no question and is waiting for the answer."
                )
            }
            lines.append("The utterance to judge: \"\(context.utterance)\"")
            return lines.joined(separator: "\n\n")
        }
    }

    /// The two primitives this file uses. `Score` is deliberately absent: none of these
    /// judgements is a rubric, and an ordered scale invented for a yes/no question
    /// invites a threshold that means nothing.
    enum Question: Encodable {
        case noul(instructions: String)
        case choice(instructions: String, criteria: [String: String])

        private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .noul(instructions):
                try container.encode("noul", forKey: .type)
                try container.encode(instructions, forKey: .instructions)
            case let .choice(instructions, criteria):
                try container.encode("choice", forKey: .type)
                try container.encode(instructions, forKey: .instructions)
                try container.encode(criteria, forKey: .criteria)
            }
        }
    }

    /// The answers out of a response body, or nil if there are none to be had.
    ///
    /// **The envelope is not decoration, and getting it wrong was invisible.** The
    /// published example shows the answers at the top level; the service returns them
    /// under `answers`, beside `model` and `usage`. Decoded as a bare dictionary that
    /// parses — into an empty one — so every reading came back nil, every turn took the
    /// slow path, and nothing anywhere said a word. It was `verify` sending a real
    /// classification rather than a ping that turned that into a sentence on a terminal.
    static func answers(in data: Data) -> [String: Answer]? {
        try? JSONDecoder().decode(Envelope.self, from: data).answers
    }

    struct Envelope: Decodable {
        let answers: [String: Answer]
    }

    /// One answer. Every field optional, because which of them is populated depends on
    /// the primitive that was asked and a response naming a field this build does not
    /// know must still decode.
    struct Answer: Decodable {
        let noul: Double?
        let choice: String?
        let confidence: Double?
        /// The full distribution over a choice's options, where the service returns one.
        ///
        /// Optional because it must be: a confidence alone is materially weaker than a
        /// margin, and the code has to work either way rather than assume a field is
        /// there. `FastPath.resolve` treats nil as one fewer check, never as licence.
        let probabilities: [String: Double]?

        /// How far the winner is ahead of the runner-up, or nil when unknowable.
        var margin: Double? {
            guard let probabilities, probabilities.count > 1 else { return nil }
            let ranked = probabilities.values.sorted(by: >)
            return ranked[0] - ranked[1]
        }
    }
}

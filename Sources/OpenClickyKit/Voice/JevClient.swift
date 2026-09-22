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

    /// How long a reading may take before it is worthless.
    ///
    /// Shorter than any sensible network timeout, because this is not a network budget
    /// — it is the length of a pause in a conversation. `VoiceSession.settle` is 1.2
    /// seconds and a reading that lands after the turn has gone out cannot change
    /// anything; holding the connection open past that only spends money.
    public static let deadline: TimeInterval = 1.0

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.deadline
            configuration.timeoutIntervalForResource = Self.deadline
            self.session = URLSession(configuration: configuration)
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

    public func read(_ context: TurnContext) async -> TurnReading? {
        guard let body = try? JSONEncoder().encode(Request(context: context)) else {
            return nil
        }
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
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let answers = try? JSONDecoder().decode([String: Answer].self, from: data)
        else { return nil }

        // A partial answer is not a reading. Anything missing would have to be given a
        // default, and the only safe default for each of these is the value that changes
        // nothing — at which point the reading is the absence of one, said at length.
        guard let addressed = answers[Key.addressed]?.noul,
              let complete = answers[Key.complete]?.noul,
              let halt = answers[Key.halt]?.noul,
              let chosen = answers[Key.intent]?.choice,
              let intent = TurnReading.Intent(rawValue: chosen)
        else { return nil }

        return TurnReading(
            utterance: context.utterance,
            addressed: addressed,
            complete: complete,
            halt: halt,
            intent: intent,
            intentConfidence: answers[Key.intent]?.confidence ?? 0
        )
    }

    // MARK: - The wire

    private enum Key {
        static let addressed = "addressed"
        static let complete = "complete"
        static let halt = "halt"
        static let intent = "intent"
    }

    /// One request, four questions. There is no second call by design.
    struct Request: Encodable {
        let model = "jev-latest"
        let state: String
        let questions: [String: Question]

        init(context: TurnContext) {
            state = Request.state(for: context)
            questions = [
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

    /// One answer. Every field optional, because which of them is populated depends on
    /// the primitive that was asked and a response naming a field this build does not
    /// know must still decode.
    struct Answer: Decodable {
        let noul: Double?
        let choice: String?
        let confidence: Double?
    }
}

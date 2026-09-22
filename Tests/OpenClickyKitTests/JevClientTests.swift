import Testing
import Foundation
@testable import OpenClickyKit

/// The wire, which is the half of this feature no state-machine test can reach.
///
/// Everything here is about a failure that is silent by construction: a request whose
/// question names do not match the ones the response is read back under, an intent the
/// schema never described, a 429 read as an answer. Each of those produces a session
/// that looks like it is classifying and is not — which is the exact shape of bug this
/// project keeps finding in the audio stack.
/// Serialized because the stub below is reached through `URLProtocol`, which the
/// loading system instantiates itself — there is no per-session handle to hang state
/// off, so the request and the canned answer live in type storage. Run in parallel, the
/// cases overwrite each other's answers and fail on whichever loses the race, which is
/// a flake that looks exactly like a parsing bug.
@Suite("Jev client", .serialized)
struct JevClientTests {

    /// Answers whatever it is told to, and keeps the request it was given.
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var seen: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            // `httpBody` is stripped by the loading system, so it is read from the
            // stream the way a server would read it.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                stream.close()
                Stub.seen = data
            } else {
                Stub.seen = request.httpBody
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Stub.status,
                httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Collects what the client decided was worth interrupting the session for.
    private final class ReportSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var report: @Sendable (String) -> Void {
            { [self] text in lock.lock(); seen.append(text); lock.unlock() }
        }
        var complaints: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func client(
        status: Int = 200, body: String,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) -> JevClient {
        Stub.status = status
        Stub.body = Data(body.utf8)
        Stub.seen = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return JevClient(
            apiKey: "sk-test-123456789",
            session: URLSession(configuration: configuration),
            report: report
        )
    }

    private var context: TurnContext {
        TurnContext(
            utterance: "open the settings app",
            agentLastSaid: "Bringing Safari to the front.",
            isRunInFlight: true,
            isAwaitingApproval: false
        )
    }

    private let wellFormed = """
        {
          "addressed": {"noul": 0.94, "confidence": 0.9},
          "complete":  {"noul": 0.88, "confidence": 0.9},
          "halt":      {"noul": 0.02, "confidence": 0.95},
          "intent":    {"choice": "instruction", "confidence": 0.86}
        }
        """

    @Test("A well-formed answer becomes a reading of the turn that was asked about")
    func aGoodAnswerIsRead() async {
        let reading = await client(body: wellFormed).read(context, options: .empty)
        #expect(reading?.utterance == "open the settings app",
                "the reading was not keyed to the text it describes")
        #expect(reading?.addressed == 0.94)
        #expect(reading?.complete == 0.88)
        #expect(reading?.halt == 0.02)
        #expect(reading?.intent == .instruction)
        #expect(reading?.intentConfidence == 0.86)
    }

    /// The request is where a rename goes wrong silently: a question asked under one
    /// name and read back under another is not an error, it is a permanently absent
    /// answer.
    @Test("One request carries every question, under the names the answer is read by")
    func allQuestionsTravelInOneRequest() async throws {
        _ = await client(body: wellFormed).read(context, options: .empty)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(Set(questions.keys) == ["addressed", "complete", "halt", "intent"],
                "a question was asked under a name nothing reads back")
        // The whole reason there is no cascade: a second call would double the only
        // budget that matters, and these cost about what one costs.
        #expect(questions.count == 4)
    }

    @Test("The state carries the context that makes the questions answerable")
    func theStateCarriesTheContext() async throws {
        _ = await client(body: wellFormed).read(context, options: .empty)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let state = try #require(json["state"] as? String)
        #expect(state.contains("open the settings app"))
        #expect(state.contains("Bringing Safari to the front."),
                "an answer cannot be told from an instruction without the question")
        #expect(state.contains("running a task"),
                "an amendment cannot be told from a new task without knowing one is going")
    }

    /// Every option the model may pick has to be described, or it can only ever be
    /// picked for the wrong reason.
    @Test("Every intent the code can read is described in the request")
    func everyIntentIsDescribed() async throws {
        _ = await client(body: wellFormed).read(context, options: .empty)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let questions = try #require(json["questions"] as? [String: Any])
        let intent = try #require(questions["intent"] as? [String: Any])
        let criteria = try #require(intent["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == Set(TurnReading.Intent.allCases.map(\.rawValue)))
        #expect(criteria.values.allSatisfy { !$0.isEmpty })
    }

    @Test("The key is sent as a bearer token and never in the body")
    func theKeyTravelsInTheHeader() async throws {
        _ = await client(body: wellFormed).read(context, options: .empty)
        let body = try #require(Stub.seen)
        #expect(!String(decoding: body, as: UTF8.self).contains("sk-test-123456789"),
                "the credential was written into the request body")
    }

    // MARK: - Everything that must come back as no answer at all

    /// The session's whole safety argument rests on this: a failure is *nil*, and nil
    /// is the behaviour that shipped before any of this existed. A default invented
    /// here would be a judgement nobody made, applied to a real turn.
    @Test("A refused request is no reading", arguments: [401, 429, 500, 503])
    func aRefusalIsNoReading(status: Int) async {
        #expect(await client(status: status, body: wellFormed).read(context, options: .empty) == nil)
    }

    @Test("A partial answer is no reading")
    func aPartialAnswerIsNoReading() async {
        let missingHalt = """
            {
              "addressed": {"noul": 0.94},
              "complete":  {"noul": 0.88},
              "intent":    {"choice": "instruction"}
            }
            """
        #expect(await client(body: missingHalt).read(context, options: .empty) == nil,
                "a missing answer was filled in with a value nobody decided")
    }

    /// A newer service answering with an option this build has never heard of. Read as
    /// nothing rather than coerced into the nearest case — the nearest case to `halt`
    /// is the one that cancels work.
    @Test("An intent this build does not know is no reading")
    func anUnknownIntentIsNoReading() async {
        let unknown = """
            {
              "addressed": {"noul": 0.94},
              "complete":  {"noul": 0.88},
              "halt":      {"noul": 0.02},
              "intent":    {"choice": "dictation"}
            }
            """
        #expect(await client(body: unknown).read(context, options: .empty) == nil)
    }

    @Test("A malformed body is no reading", arguments: ["", "not json", "[]", "{}"])
    func aMalformedBodyIsNoReading(body: String) async {
        #expect(await client(body: body).read(context, options: .empty) == nil)
    }

    // MARK: - The action question

    private var appOptions: FastPath.Options {
        FastPath.Options(
            apps: [AppCatalogue.Entry(
                bundleIdentifier: "com.apple.Safari", name: "Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app"), isRunning: true
            )],
            truncated: false
        )
    }

    private func answered(_ action: String, confidence: Double = 0.99,
                          probabilities: String? = nil) -> String {
        let distribution = probabilities.map { ", \"probabilities\": \($0)" } ?? ""
        return """
            {
              "addressed": {"noul": 0.94},
              "complete":  {"noul": 0.88},
              "halt":      {"noul": 0.02},
              "intent":    {"choice": "instruction"},
              "action":    {"choice": "\(action)", "confidence": \(confidence)\(distribution)}
            }
            """
    }

    /// One request, one more question, no second call. The whole reason there is no
    /// cascade: parallel questions cost about what one costs.
    @Test("The action rides in the same request as everything else")
    func theActionQuestionTravelsWithTheRest() async throws {
        _ = await client(body: answered("none")).read(context, options: appOptions)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(questions["action"] != nil, "the action was asked in a second call")
        #expect(Set(questions.keys) == ["addressed", "complete", "halt", "intent", "action"])
    }

    /// Without them a Choice has no way to say "not one of these", and is forced to name
    /// an app for "what's the weather".
    @Test("Doing nothing and handing on are always among the options")
    func escapeHatchesAreOnTheWire() async throws {
        _ = await client(body: answered("none")).read(context, options: appOptions)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let questions = try #require(json["questions"] as? [String: Any])
        let action = try #require(questions["action"] as? [String: Any])
        let criteria = try #require(action["criteria"] as? [String: String])
        #expect(criteria["none"] != nil)
        #expect(criteria["llm"] != nil)
        #expect(criteria["activate:com.apple.Safari"] != nil)
    }

    /// A choice between "nothing" and "ask the model" changes nothing and is still
    /// billed for.
    @Test("With nothing to offer, the question is not asked at all")
    func noOptionsMeansNoQuestion() async throws {
        _ = await client(body: wellFormed).read(context, options: .empty)
        let body = try #require(Stub.seen)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(questions["action"] == nil, "an empty choice was sent and paid for")
    }

    @Test("A confident pick of an offered app becomes that action")
    func aPickBecomesAnAction() async {
        let reading = await client(body: answered("activate:com.apple.Safari"))
            .read(context, options: appOptions)
        #expect(reading?.action == .activate(bundleIdentifier: "com.apple.Safari"))
        #expect(reading?.canRunWithoutAModel == true)
    }

    /// The local validator, reached through the wire. A name nobody offered means a
    /// version skew, and the safe reading of an answer to a question we did not ask is
    /// that there is no answer.
    @Test("An app that was never offered comes back as work for the model")
    func anUnofferedPickIsRefused() async {
        let reading = await client(body: answered("activate:com.example.Nope"))
            .read(context, options: appOptions)
        #expect(reading?.action == .model)
        #expect(reading?.canRunWithoutAModel == false)
    }

    @Test("An unsure pick comes back as work for the model")
    func anUnsurePickIsRefused() async {
        let reading = await client(body: answered("activate:com.apple.Safari", confidence: 0.4))
            .read(context, options: appOptions)
        #expect(reading?.action == .model)
    }

    /// The distribution is what makes a margin computable at all. A calibrated 0.91
    /// spread over two near-identical options is a coin flip wearing a decimal point.
    @Test("A win by a narrow margin comes back as work for the model")
    func aNarrowWinIsRefused() async {
        let close = #"{"activate:com.apple.Safari": 0.46, "llm": 0.44, "none": 0.10}"#
        let reading = await client(
            body: answered("activate:com.apple.Safari", probabilities: close)
        ).read(context, options: appOptions)
        #expect(reading?.action == .model, "a near-tie was acted on")
    }

    @Test("A win by a wide margin is acted on")
    func aClearWinIsKept() async {
        let clear = #"{"activate:com.apple.Safari": 0.95, "llm": 0.03, "none": 0.02}"#
        let reading = await client(
            body: answered("activate:com.apple.Safari", probabilities: clear)
        ).read(context, options: appOptions)
        #expect(reading?.action == .activate(bundleIdentifier: "com.apple.Safari"))
    }

    /// An absent action is not an absent reading. The other four questions still
    /// answered, and the turn still goes to the model as it did before any of this.
    @Test("A reading with no action at all is still a reading")
    func aMissingActionLeavesTheRestIntact() async {
        let reading = await client(body: wellFormed).read(context, options: appOptions)
        #expect(reading?.action == .model)
        #expect(reading?.addressed == 0.94, "a missing action discarded the whole reading")
    }

    // MARK: - A refusal that will not fix itself

    /// The defect this guards against: `doctor` says a key is stored, the session starts
    /// normally, and every turn quietly takes the slow path forever with nothing said.
    @Test("A rejected key is said out loud", arguments: [401, 403])
    func aRejectedKeyIsReported(status: Int) async {
        let spy = ReportSpy()
        let client = client(status: status, body: wellFormed, report: spy.report)
        #expect(await client.read(context, options: .empty) == nil)
        #expect(spy.complaints.count == 1, "a rejected key failed silently")
        #expect(spy.complaints.first?.contains("auth --classifier") == true,
                "the complaint did not say how to fix it")
    }

    @Test("A disagreement about the request is said out loud", arguments: [400, 404, 422])
    func aSchemaMismatchIsReported(status: Int) async {
        let spy = ReportSpy()
        let client = client(status: status, body: wellFormed, report: spy.report)
        _ = await client.read(context, options: .empty)
        #expect(spy.complaints.count == 1)
    }

    /// A banner for each of these would train the user to ignore the one that matters.
    /// None is something they can act on.
    @Test("What passes on its own is not complained about", arguments: [429, 500, 502, 503])
    func transientFailuresStaySilent(status: Int) async {
        let spy = ReportSpy()
        let client = client(status: status, body: wellFormed, report: spy.report)
        _ = await client.read(context, options: .empty)
        #expect(spy.complaints.isEmpty, "a passing problem interrupted the session")
    }

    /// A turn is classified several times as it is spoken, so an unfixable refusal
    /// arrives a few times a sentence.
    @Test("An unfixable refusal is said once, not once per window")
    func theComplaintIsSaidOnce() async {
        let spy = ReportSpy()
        let client = client(status: 401, body: wellFormed, report: spy.report)
        for _ in 0..<5 { _ = await client.read(context, options: .empty) }
        #expect(spy.complaints.count == 1, "every window of every sentence raised a banner")
    }

    /// A reading is worth having only while the turn it describes is still open, and
    /// `VoiceSession.settle` is 1.2 seconds. Holding a connection past that spends
    /// money on an answer nothing can use.
    @Test("The deadline is shorter than the pause it has to fit inside")
    func theDeadlineFitsInsideATurn() {
        #expect(JevClient.deadline < VoiceSession.settle)
    }
}

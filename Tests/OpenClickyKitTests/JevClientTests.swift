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

    private func client(status: Int = 200, body: String) -> JevClient {
        Stub.status = status
        Stub.body = Data(body.utf8)
        Stub.seen = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return JevClient(
            apiKey: "sk-test-123456789",
            session: URLSession(configuration: configuration)
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
        let reading = await client(body: wellFormed).read(context)
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
        _ = await client(body: wellFormed).read(context)
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
        _ = await client(body: wellFormed).read(context)
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
        _ = await client(body: wellFormed).read(context)
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
        _ = await client(body: wellFormed).read(context)
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
        #expect(await client(status: status, body: wellFormed).read(context) == nil)
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
        #expect(await client(body: missingHalt).read(context) == nil,
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
        #expect(await client(body: unknown).read(context) == nil)
    }

    @Test("A malformed body is no reading", arguments: ["", "not json", "[]", "{}"])
    func aMalformedBodyIsNoReading(body: String) async {
        #expect(await client(body: body).read(context) == nil)
    }

    /// A reading is worth having only while the turn it describes is still open, and
    /// `VoiceSession.settle` is 1.2 seconds. Holding a connection past that spends
    /// money on an answer nothing can use.
    @Test("The deadline is shorter than the pause it has to fit inside")
    func theDeadlineFitsInsideATurn() {
        #expect(JevClient.deadline < VoiceSession.settle)
    }
}

import Testing
import Foundation
@testable import OpenClickyKit

/// Ollama's model list, which is the daemon's answer and not this build's guess.
///
/// The defect these defend: the catalogue offered `llama3.2-vision`, `qwen2.5vl`,
/// `llava` and `llama3.2`, and the daemon on the machine it was found on served
/// `deepseek-r1:7b`, `llama3:latest`, `glm-5.2:cloud` and five more. Not one of the
/// four was installed — every entry in the picker 404'd, and so did the default the
/// picker opened on. It was reported as "the ids are missing the `:cloud` suffix",
/// which is the same bug seen from the other end: an id is only meaningful next to the
/// endpoint that serves it, and the local daemon and `ollama.com` do not even agree
/// about the id of the same model.
///
/// So the list is asked for, and the strings are passed through untouched. Every test
/// here runs against a stubbed `URLProtocol`; none contacts a daemon.
@Suite("Ollama model listing", .serialized)
struct OllamaModelCatalogTests {

    /// Serves one scripted response and keeps the requests it saw.
    ///
    /// Static state because `URLProtocol` is instantiated by `URLSession`, which gives
    /// no hook for per-instance context. The suite is `.serialized` so it is safe.
    final class Stub: URLProtocol {
        struct Step {
            var status: Int = 200
            var body: String = "{}"
            /// When set, the request fails at the transport instead of answering —
            /// which is what a daemon that is not running looks like.
            var failure: Bool = false
        }

        nonisolated(unsafe) private static var step = Step()
        nonisolated(unsafe) private static var seen: [URLRequest] = []
        private static let lock = NSLock()

        static func script(_ step: Step) {
            lock.lock(); defer { lock.unlock() }
            Self.step = step
            seen = []
        }

        static var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        private static func next(_ request: URLRequest) -> Step {
            lock.lock(); defer { lock.unlock() }
            seen.append(request)
            return step
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let step = Self.next(request)
            guard !step.failure else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(step.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config)
    }

    /// What `curl http://localhost:11434/v1/models` actually answered on the machine
    /// the bug was found on, trimmed to two entries: one cloud relay, one local pull.
    private static let listing = """
    {"object":"list","data":[
      {"id":"glm-5.2:cloud","object":"model","created":1,"owned_by":"library"},
      {"id":"deepseek-r1:7b","object":"model","created":2,"owned_by":"library"}
    ]}
    """

    private func installed(
        kind: Provider.Kind = .ollama,
        base: String? = "http://localhost:11434/v1",
        key: String? = nil
    ) async -> [ModelChoice] {
        await ModelCatalog.installed(
            for: kind, baseURL: base.flatMap(URL.init(string:)),
            apiKey: key, session: session()
        )
    }

    // MARK: - The regression itself

    /// The whole bug in one assertion. A tag is part of the id, not decoration on it:
    /// `glm-5.2:cloud` is what the daemon calls the model it relays, and the same model
    /// is `glm-5.2` at `ollama.com` — so anything that "tidies" the suffix produces an
    /// id that 404s against the endpoint that reported it.
    @Test("An id reaches the picker exactly as the endpoint wrote it")
    func tagsSurviveTheListing() async {
        Stub.script(.init(body: Self.listing))
        let found = await installed()

        #expect(found.map(\.id) == ["deepseek-r1:7b", "glm-5.2:cloud"])
        #expect(found.contains { $0.id == "glm-5.2:cloud" }, ":cloud was stripped")
        #expect(found.contains { $0.id == "deepseek-r1:7b" }, ":7b was stripped")
        // And nothing invented a plain form beside it.
        #expect(!found.contains { $0.id == "glm-5.2" })
        #expect(!found.contains { $0.id == "deepseek-r1" })
    }

    /// The same id, one layer further on: what a picker offers has to be what the
    /// request carries. A listing that kept the tag and a client that dropped it on the
    /// way out would be the identical 404 with nowhere to see it happen.
    @Test("The id a listing offers is the id the next request sends")
    func theListedIdIsTheIdSent() async throws {
        Stub.script(.init(body: Self.listing))
        let chosen = await installed().first { $0.id.hasSuffix(":cloud") }
        let id = try #require(chosen?.id)

        Stub.script(.init(body: """
        {"id":"c1","choices":[{"message":{"role":"assistant","content":"ok"},
         "finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """))
        let client = OpenAICompatibleClient(
            provider: "Ollama", baseURL: URL(string: "http://localhost:11434/v1")!,
            apiKey: nil, session: session()
        )
        _ = try await client.send(
            Wire.Request(model: id, maxTokens: 16, system: [], messages: [.user("hi")], tools: [])
        )

        let sent = try #require(Stub.requests.last?.httpBodyStream.map(Self.drain))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: sent)
        guard case let .object(body) = decoded, case let .string(model)? = body["model"] else {
            Issue.record("no model in the request body"); return
        }
        #expect(model == "glm-5.2:cloud")
    }

    /// `httpBody` is stripped by `URLSession` before the protocol sees it; the stream
    /// is where the bytes are.
    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    // MARK: - Failing quietly

    /// A settings window is opened *because* something is broken. It must not be the
    /// thing that breaks — and it must not fill the gap with an id nobody serves.
    @Test("Every way of failing produces an empty list and no invention", arguments: [
        Stub.Step(failure: true),                                   // no daemon
        Stub.Step(status: 404, body: #"{"error":"not found"}"#),    // wrong path
        Stub.Step(status: 500, body: "boom"),                       // a broken daemon
        Stub.Step(status: 200, body: "<html>proxy</html>"),         // something else entirely
        Stub.Step(status: 200, body: #"{"data":[{"name":"x"}]}"#),  // a shape we do not know
        Stub.Step(status: 200, body: "{"),                          // malformed JSON
    ])
    func failuresAreEmptyAndSilent(step: Stub.Step) async {
        Stub.script(step)
        #expect(await installed().isEmpty)
    }

    /// An id that is blank cannot be picked, and saved it would mean "no model chosen".
    @Test("A blank id in the listing is dropped rather than shown")
    func blankIdsAreDropped() async {
        Stub.script(.init(body: #"{"data":[{"id":"  "},{"id":"llama3:latest"}]}"#))
        #expect(await installed().map(\.id) == ["llama3:latest"])
    }

    // MARK: - Which endpoint, signed how

    @Test("A keyless loopback daemon is asked without an Authorization header")
    func loopbackSendsNoHeader() async {
        Stub.script(.init(body: Self.listing))
        _ = await installed()
        let request = Stub.requests.first
        #expect(request?.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil,
                "an empty bearer makes some proxies 401 a request that would have worked")
    }

    /// Ollama's own cloud endpoint is a normal signed API, and it is reachable by
    /// pointing the base URL at it — the listing has to be signed like any other call.
    @Test("A remote endpoint over https is asked with the key")
    func remoteEndpointIsSigned() async {
        Stub.script(.init(body: Self.listing))
        _ = await installed(base: "https://ollama.com/v1", key: "test-key-123456789")
        #expect(Stub.requests.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer test-key-123456789")
    }

    /// The refusal `Provider.resolve` makes, made quietly. A bearer token over
    /// plaintext HTTP to anything but loopback is readable by every hop in between, and
    /// a listing must not become the one path that sends it anyway.
    @Test("A key is never sent in cleartext to another machine")
    func plaintextRemoteDropsTheKey() async {
        Stub.script(.init(body: Self.listing))
        _ = await installed(base: "http://gpu-box.lan:11434/v1", key: "test-key-123456789")
        let request = Stub.requests.first
        #expect(request?.url?.absoluteString == "http://gpu-box.lan:11434/v1/models")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("The models path is appended however the base URL is written", arguments: [
        "http://localhost:11434/v1", "http://localhost:11434/v1/",
        "http://localhost:4000", "https://api.openai.com/v1/chat/completions",
    ])
    func modelsPathIsBuiltConsistently(base: String) {
        let url = OpenAICompatibleClient.modelsEndpoint(for: URL(string: base)!)
        #expect(url.absoluteString.hasSuffix("/models"))
        #expect(!url.absoluteString.contains("chat/completions"))
        #expect(!url.absoluteString.contains("//models"))
    }

    @Test("With no base URL configured, the provider's own is asked")
    func defaultBaseURLIsUsed() async {
        Stub.script(.init(body: Self.listing))
        _ = await installed(base: nil)
        #expect(Stub.requests.first?.url?.absoluteString == "http://localhost:11434/v1/models")
    }

    // MARK: - Scope: Ollama and nothing else

    /// The exception is Ollama's alone. A hosted endpoint answers with everything an
    /// account can reach — including models that 400 on the first request — and answers
    /// nothing at all while the credential is still being typed, which is exactly when
    /// the panel is open. Their curated lists must not be replaced by that.
    @Test("No other provider is queried at all", arguments: [
        Provider.Kind.anthropic, .openai, .groq, .litellm,
    ])
    func onlyOllamaIsQueried(kind: Provider.Kind) async {
        Stub.script(.init(body: Self.listing))
        #expect(await installed(kind: kind).isEmpty)
        #expect(Stub.requests.isEmpty, "\(kind.label) was asked for a model list")
        #expect(!ModelCatalog.isLiveQueried(kind))
    }

    @Test("Ollama is the provider whose list is live")
    func ollamaIsLiveQueried() {
        #expect(ModelCatalog.isLiveQueried(.ollama))
    }

    /// Guards against a blanket edit: the curated lists are untouched, and only the one
    /// that could not be right is empty.
    @Test("The static catalogue is empty for Ollama and unchanged elsewhere")
    func staticCatalogueIsScoped() {
        #expect(ModelCatalog.models(for: .ollama).isEmpty)
        #expect(ModelCatalog.planners(for: .ollama).isEmpty)
        #expect(Provider.Kind.ollama.defaultModel == nil)

        #expect(ModelCatalog.models(for: .anthropic).contains { $0.id == DefaultModel.id })
        #expect(ModelCatalog.models(for: .openai).contains { $0.id == "gpt-4o" })
        #expect(ModelCatalog.models(for: .groq).contains { $0.id == "llama-3.3-70b-versatile" })
        #expect(ModelCatalog.models(for: .litellm).isEmpty)
        for kind in [Provider.Kind.anthropic, .openai, .groq] {
            #expect(ModelCatalog.models(for: kind).count >= 3, "\(kind.label) lost entries")
        }
    }

    // MARK: - What the picker does with the answer

    /// The list arrives milliseconds after the window opens, and the two things it must
    /// not disturb are the two `ModelPicker` exists to protect: what the user typed, and
    /// the fact that they chose to type it.
    @Test("A list arriving does not clobber a typed id")
    func arrivingListKeepsTypedValue() async {
        Stub.script(.init(body: Self.listing))
        var picker = ModelPicker(value: "", choices: [], allowsNone: false)
        picker.type("my-own:tag")

        picker.offer(await installed())
        #expect(picker.value == "my-own:tag")
        #expect(picker.isCustom, "the field vanishing mid-word is the defect this fixes")
        #expect(picker.choices.count == 2, "and the list is there to pick from")
    }

    /// The same, for an id that turns out to be in the list. Keeping the decision is
    /// what stops the field closing under someone's cursor.
    @Test("A typed id that the list happens to contain stays typed")
    func typingSurvivesAMatchingList() async {
        Stub.script(.init(body: Self.listing))
        var picker = ModelPicker(value: "", choices: [], allowsNone: false)
        picker.type("glm-5.2:cloud")

        picker.offer(await installed())
        #expect(picker.value == "glm-5.2:cloud")
        #expect(picker.isCustom)
    }

    @Test("Picking from an arrived list selects it without the text field")
    func pickingFromTheArrivedList() async {
        Stub.script(.init(body: Self.listing))
        var picker = ModelPicker(value: "", choices: [], allowsNone: false)
        picker.offer(await installed())

        let worthSaving = picker.pick("glm-5.2:cloud")
        #expect(worthSaving, "worth persisting")
        #expect(picker.value == "glm-5.2:cloud")
        #expect(!picker.isCustom)
    }

    // MARK: - Capabilities of a tagged id

    /// Pinned, not changed. `normalized` splits at the colon to look a family up, and
    /// two working configurations depend on it — `llava:13b` keeps its eyes, and
    /// `openai/gpt-4o` keeps its dialect. It is a lookup key and never a wire value.
    @Test("A tagged id keeps the capabilities of its family, and only the lookup strips")
    func taggedIdsResolveByFamily() {
        #expect(ModelCapabilities.normalized("glm-5.2:cloud") == "glm-5.2")
        let cloud = ModelCapabilities.forModel("glm-5.2:cloud")
        #expect(!cloud.vision, "an unknown family is text-only, which caps the run at tier 2")
        #expect(cloud.outputTokenField == "max_tokens")
        #expect(!cloud.strictTools)
        #expect(cloud.systemRole == "system")

        // The two the split exists for, unchanged.
        #expect(ModelCapabilities.forModel("llava:13b").vision)
        #expect(ModelCapabilities.forModel("openai/gpt-4o").vision)

        // And the id in a choice is never the normalised one.
        #expect(ModelChoice(id: "glm-5.2:cloud").id == "glm-5.2:cloud")
    }
}

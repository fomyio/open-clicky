import Testing
import Foundation
@testable import OpenClickyKit

/// The translation between Wire's Anthropic shapes and the OpenAI dialect.
///
/// Every one of these is a pure function over values, so the suite is hermetic and
/// finishes in milliseconds. The parts worth defending are the ones that fail
/// *quietly*: a dropped image, a tool result that loses its error flag, a
/// `finish_reason` flattened to `end_turn` so the loop stops mid-plan and reports
/// success. None of those raise anything anywhere.
@Suite("OpenAI-compatible translation")
struct OpenAITranslationTests {

    private func request(
        model: String = "gpt-4o",
        system: [Wire.SystemBlock] = [.init("stable", cacheControl: true), .init("session")],
        messages: [Wire.Message] = [.user("hi")],
        tools: [Wire.ToolDefinition] = [],
        maxTokens: Int = 1_000
    ) -> Wire.Request {
        Wire.Request(
            model: model, maxTokens: maxTokens, system: system,
            messages: messages, tools: tools
        )
    }

    private func body(_ request: Wire.Request) -> JSONValue {
        OpenAIWire.requestBody(request, capabilities: .forModel(request.model))
    }

    // MARK: - The system prompt

    /// Wire sends `system` as an array with a cache breakpoint on the stable half.
    /// This dialect has one system message and no `cache_control`, so the breakpoint
    /// is dropped — but the *order* is not, because a prefix cache only works if the
    /// invariant text stays first.
    @Test("System blocks become one message, in order, with the breakpoint dropped")
    func systemBlocksCollapse() {
        let payload = body(request())
        let first = payload["messages"]?.arrayValue?.first
        #expect(first?["role"]?.stringValue == "system")
        let text = try! #require(first?["content"]?.stringValue)
        #expect(text.hasPrefix("stable"), "the cacheable prefix must stay first")
        #expect(text.contains("session"))
        #expect(!text.contains("cache_control"))
        #expect(payload["cache_control"] == nil)
    }

    /// The reasoning families renamed the role, and the rename is a 400 rather than a
    /// degraded answer.
    @Test("The system role follows the model", arguments: [
        ("gpt-4o", "system"), ("gpt-5", "developer"), ("llama3.2", "system"),
    ])
    func systemRoleFollowsTheModel(scenario: (String, String)) {
        let payload = body(request(model: scenario.0))
        #expect(payload["messages"]?.arrayValue?.first?["role"]?.stringValue == scenario.1)
    }

    @Test("The output cap uses the key the family accepts", arguments: [
        ("gpt-4o", "max_tokens"), ("o3-mini", "max_completion_tokens"),
    ])
    func outputCapKeyFollowsTheModel(scenario: (String, String)) {
        let payload = body(request(model: scenario.0, maxTokens: 4_096))
        #expect(payload[scenario.1]?.intValue == 4_096)
        let other = scenario.1 == "max_tokens" ? "max_completion_tokens" : "max_tokens"
        #expect(payload[other] == nil, "sending both is a 400 on the reasoning families")
    }

    /// Anthropic-only fields have no analogue and are dropped rather than guessed at.
    @Test("Anthropic-only request fields do not survive the translation")
    func anthropicFieldsAreDropped() {
        var wire = request(model: "gpt-4o")
        wire.effort = "high"
        wire.thinkingDisplay = "compact"
        let payload = body(wire)
        #expect(payload["thinking"] == nil)
        #expect(payload["output_config"] == nil)
        #expect(payload["effort"] == nil)
    }

    // MARK: - Tool definitions

    private var shellTool: Wire.ToolDefinition {
        Wire.ToolDefinition(
            name: "shell", description: "run a command",
            inputSchema: .schema(["command": .string(describing: "the command")],
                                 required: ["command"])
        )
    }

    /// `screenshot`'s schema has optional properties, which strict mode forbids.
    private var screenshotTool: Wire.ToolDefinition {
        Wire.ToolDefinition(
            name: "screenshot", description: "capture the screen",
            inputSchema: .schema(["region": .string(describing: "an area")], required: [])
        )
    }

    @Test("A tool becomes a function with its schema as parameters")
    func toolsBecomeFunctions() {
        let payload = body(request(tools: [shellTool]))
        let tool = try! #require(payload["tools"]?.arrayValue?.first)
        #expect(tool["type"]?.stringValue == "function")
        #expect(tool["function"]?["name"]?.stringValue == "shell")
        #expect(tool["function"]?["description"]?.stringValue == "run a command")
        #expect(tool["function"]?["parameters"]?["properties"]?["command"] != nil)
    }

    /// Strict mode additionally requires every property to appear in `required`.
    /// Sending `strict: true` beside a partial `required` list is a 400 on the whole
    /// request — so every call would fail, not merely the one using that tool.
    @Test("Strict is set only where the schema qualifies")
    func strictOnlyWhereTheSchemaQualifies() {
        let payload = body(request(tools: [shellTool, screenshotTool]))
        let tools = try! #require(payload["tools"]?.arrayValue)
        #expect(tools[0]["function"]?["strict"]?.boolValue == true, "shell qualifies")
        #expect(tools[1]["function"]?["strict"] == nil, "screenshot has optional properties")
    }

    /// Ollama and llama.cpp reject the field itself. Absent is the shape that works
    /// everywhere, so a runtime that does not understand strict never sees it.
    @Test("A runtime that does not understand strict never receives it")
    func strictIsAbsentOnLocalRuntimes() {
        let payload = body(request(model: "llama3.2", tools: [shellTool]))
        #expect(payload["tools"]?.arrayValue?.first?["function"]?["strict"] == nil)
    }

    @Test("A request with no tools omits the key rather than sending an empty array")
    func noToolsMeansNoKey() {
        #expect(body(request())["tools"] == nil)
    }

    // MARK: - Tool calls, both directions

    @Test("An assistant tool_use becomes a tool_call with string arguments")
    func toolUseBecomesToolCall() {
        let assistant = Wire.Message(role: .assistant, content: [
            .text("clicking save"),
            .toolUse(id: "toolu_1", name: "ax_press",
                     input: .object(["id": .string("e12")])),
        ])
        let payload = body(request(messages: [.user("go"), assistant]))
        let messages = try! #require(payload["messages"]?.arrayValue)
        let turn = try! #require(messages.last)

        #expect(turn["role"]?.stringValue == "assistant")
        #expect(turn["content"]?.stringValue == "clicking save")
        let call = try! #require(turn["tool_calls"]?.arrayValue?.first)
        #expect(call["id"]?.stringValue == "toolu_1")
        #expect(call["type"]?.stringValue == "function")
        #expect(call["function"]?["name"]?.stringValue == "ax_press")
        // A *string*, not an object: OpenAI rejects the object form.
        let arguments = try! #require(call["function"]?["arguments"]?.stringValue)
        #expect(arguments.contains("\"e12\""))
    }

    /// A turn that is only tool calls carries `null` content — the documented shape,
    /// and what several runtimes require rather than an empty string.
    @Test("A tool-call-only turn sends null content")
    func toolCallOnlyTurnSendsNullContent() {
        let assistant = Wire.Message(role: .assistant, content: [
            .toolUse(id: "t1", name: "shell", input: .object([:])),
        ])
        let payload = body(request(messages: [assistant]))
        let turn = try! #require(payload["messages"]?.arrayValue?.last)
        #expect(turn["content"] == .null)
    }

    /// Thinking blocks are signed and bound to the model that produced them. Replaying
    /// one to a different provider is at best ignored and at worst a 400.
    @Test("Thinking and passthrough blocks are dropped")
    func thinkingIsDropped() {
        let assistant = Wire.Message(role: .assistant, content: [
            .thinking(text: "secret reasoning", signature: "sig"),
            .passthrough(.object(["type": .string("redacted_thinking")])),
            .text("done"),
        ])
        let payload = body(request(messages: [assistant]))
        let turn = try! #require(payload["messages"]?.arrayValue?.last)
        #expect(turn["content"]?.stringValue == "done")
        let encoded = String(data: try! Wire.encoder.encode(payload), encoding: .utf8) ?? ""
        #expect(!encoded.contains("secret reasoning"))
        #expect(!encoded.contains("redacted_thinking"))
    }

    /// An assistant turn holding only a thinking block translates to nothing at all;
    /// several runtimes reject an empty message outright.
    @Test("A turn that translates to nothing is omitted")
    func emptyTurnIsOmitted() {
        let assistant = Wire.Message(role: .assistant, content: [
            .thinking(text: "…", signature: nil),
        ])
        let payload = body(request(messages: [.user("hi"), assistant]))
        #expect(payload["messages"]?.arrayValue?.count == 2, "system + the user turn")
    }

    // MARK: - Tool results

    @Test("Each tool_result becomes its own tool-role message")
    func toolResultsBecomeToolMessages() {
        let results = Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "t1", content: [.text("ok")], isError: false),
            .toolResult(toolUseID: "t2", content: [.text("also ok")], isError: false),
        ])
        let payload = body(request(messages: [results]))
        let messages = try! #require(payload["messages"]?.arrayValue).dropFirst()

        #expect(messages.count == 2, "one message per tool_call_id")
        #expect(messages.allSatisfy { $0["role"]?.stringValue == "tool" })
        #expect(messages.map { $0["tool_call_id"]?.stringValue } == ["t1", "t2"])
    }

    /// `is_error` has no analogue on a tool message. Without a marker a failure reads
    /// exactly like a successful result, and the model's next move builds on something
    /// that did not happen.
    @Test("A failed tool result is still legible as a failure")
    func errorFlagSurvivesAsAMarker() {
        let results = Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "t1", content: [.text("permission denied")], isError: true),
        ])
        let payload = body(request(messages: [results]))
        let message = try! #require(payload["messages"]?.arrayValue?.last)
        let text = try! #require(message["content"]?.stringValue)
        #expect(text.contains("permission denied"))
        #expect(text.contains("error"), "nothing marks this as a failure")
    }

    /// The tool role takes a plain string, so an image has to ride in the user message
    /// that follows. Dropping it instead would leave the model answering a question
    /// about a screenshot it never received.
    @Test("An image in a tool result follows in a user message")
    func imagesRideInAFollowingUserMessage() {
        let results = Wire.Message(role: .user, content: [
            .toolResult(
                toolUseID: "t1",
                content: [.text("Screenshot: 1568×980"), .image(mediaType: "image/jpeg", base64: "AAAA")],
                isError: false
            ),
        ])
        let payload = body(request(messages: [results]))
        let messages = try! #require(payload["messages"]?.arrayValue)

        let toolMessage = try! #require(messages.dropFirst().first)
        #expect(toolMessage["role"]?.stringValue == "tool")

        let userMessage = try! #require(messages.last)
        #expect(userMessage["role"]?.stringValue == "user")
        let parts = try! #require(userMessage["content"]?.arrayValue)
        let image = try! #require(parts.first { $0["type"]?.stringValue == "image_url" })
        #expect(image["image_url"]?["url"]?.stringValue == "data:image/jpeg;base64,AAAA")
    }

    /// A model that cannot be sent images must be told one existed rather than have it
    /// silently vanish — an absent image and an image the model failed to mention look
    /// identical from the loop's side.
    @Test("A text-only model is told the image existed instead of receiving it")
    func textOnlyModelIsToldAboutTheImage() {
        let results = Wire.Message(role: .user, content: [
            .toolResult(
                toolUseID: "t1",
                content: [.image(mediaType: "image/jpeg", base64: "AAAA")],
                isError: false
            ),
        ])
        let payload = OpenAIWire.requestBody(
            request(model: "llama3.2", messages: [results]),
            capabilities: .forModel("llama3.2")
        )
        let encoded = String(data: try! Wire.encoder.encode(payload), encoding: .utf8) ?? ""
        #expect(!encoded.contains("base64,AAAA"), "the image must not be sent")
        #expect(encoded.contains("cannot be sent images"))
    }

    @Test("Plain user text stays a plain string")
    func plainUserTextStaysAString() {
        let payload = body(request(messages: [.user("what is on screen?")]))
        let turn = try! #require(payload["messages"]?.arrayValue?.last)
        #expect(turn["content"]?.stringValue == "what is on screen?")
    }

    /// The loop appends notices after the tool results in the same message. They have
    /// to arrive, or a model whose reply was truncated is never told.
    @Test("Text alongside tool results is not lost")
    func trailingNoticesSurvive() {
        let results = Wire.Message(role: .user, content: [
            .toolResult(toolUseID: "t1", content: [.text("ok")], isError: false),
            .text("You have 1 turn left."),
        ])
        let payload = body(request(messages: [results]))
        let last = try! #require(payload["messages"]?.arrayValue?.last)
        #expect(last["role"]?.stringValue == "user")
        #expect(last["content"]?.stringValue == "You have 1 turn left.")
    }
}

/// Turning a chat completion back into the response the loop reads.
@Suite("OpenAI-compatible responses")
struct OpenAIResponseTests {

    private func decode(_ json: String) throws -> Wire.Response {
        let completion = try JSONDecoder().decode(
            OpenAIWire.Completion.self, from: Data(json.utf8)
        )
        return try OpenAIWire.response(completion, model: "gpt-4o")
    }

    @Test("Text and usage come through")
    func textAndUsage() throws {
        let response = try decode("""
        {"id":"chatcmpl-1","model":"gpt-4o","choices":[
          {"message":{"role":"assistant","content":"all done"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":120,"completion_tokens":8,
                  "prompt_tokens_details":{"cached_tokens":64}}}
        """)
        #expect(response.text == "all done")
        #expect(response.stopReason == "end_turn")
        #expect(response.usage.inputTokens == 120)
        #expect(response.usage.outputTokens == 8)
        #expect(response.usage.cacheReadInputTokens == 64)
    }

    @Test("Tool calls come back as tool_use blocks")
    func toolCallsBecomeToolUse() throws {
        let response = try decode("""
        {"id":"chatcmpl-2","choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"call_abc","type":"function","function":
            {"name":"shell","arguments":"{\\"command\\":\\"ls -la\\"}"}}]},
          "finish_reason":"tool_calls"}]}
        """)
        #expect(response.stopReason == "tool_use")
        let call = try #require(response.toolCalls.first)
        #expect(call.id == "call_abc")
        #expect(call.name == "shell")
        #expect(call.input["command"]?.stringValue == "ls -la")
    }

    /// The loop keys every result by the call's id. Ollama and llama.cpp omit it, and
    /// an absent id has to be invented here — not discovered missing when the results
    /// message is assembled and the request 400s for an orphaned tool_call.
    @Test("A tool call with no id is given a stable one")
    func missingToolCallIDIsSynthesised() throws {
        let response = try decode("""
        {"choices":[{"message":{"role":"assistant","tool_calls":[
          {"function":{"name":"ax_capture","arguments":"{}"}},
          {"function":{"name":"shell","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        """)
        #expect(response.toolCalls.map(\.id) == ["call_0", "call_1"])
    }

    /// Some proxies send the arguments as an object rather than the spec's string.
    @Test("Arguments sent as an object are accepted")
    func objectArgumentsAreAccepted() throws {
        let response = try decode("""
        {"choices":[{"message":{"tool_calls":[{"id":"c1","function":
          {"name":"key","arguments":{"combo":"cmd+s"}}}]},"finish_reason":"tool_calls"}]}
        """)
        #expect(response.toolCalls.first?.input["combo"]?.stringValue == "cmd+s")
    }

    /// Invalid JSON is the model's mistake, not the transport's, and it has to stay
    /// recoverable. Throwing would end the run; a value no required field can be read
    /// from makes the tool report the problem back through the normal result path.
    @Test("Unparsable arguments reach the tool as something it must reject")
    func unparsableArgumentsStayRecoverable() throws {
        let response = try decode("""
        {"choices":[{"message":{"tool_calls":[{"id":"c1","function":
          {"name":"shell","arguments":"{\\"command\\": "}}]},"finish_reason":"tool_calls"}]}
        """)
        let call = try #require(response.toolCalls.first)
        #expect(call.input["command"] == nil, "no field may be readable from a broken payload")
        #expect(throws: JSONValue.MissingField.self) { _ = try call.input.string("command") }
    }

    // MARK: - finish_reason, which the loop branches on

    /// `max_tokens` is one of exactly two stop reasons the loop reads specially: it
    /// warns that the reply was cut off. Mapped to anything else, a truncated answer
    /// is handed to the user as a complete one.
    @Test("finish_reason maps onto what the loop branches on", arguments: [
        ("stop", "end_turn"), ("length", "max_tokens"),
        ("tool_calls", "tool_use"), ("function_call", "tool_use"),
        ("content_filter", "refusal"),
    ])
    func finishReasonMapping(scenario: (String, String)) {
        #expect(OpenAIWire.stopReason(
            finishReason: scenario.0, hasToolCalls: false, refusal: nil
        ) == scenario.1)
    }

    /// Several local runtimes omit `finish_reason` on a non-streamed completion. The
    /// loop concludes when a response carries no calls, so defaulting to `end_turn`
    /// would end every Ollama run on its first tool call.
    @Test("An absent finish_reason follows the content")
    func absentFinishReasonFollowsTheContent() {
        #expect(OpenAIWire.stopReason(finishReason: nil, hasToolCalls: true, refusal: nil) == "tool_use")
        #expect(OpenAIWire.stopReason(finishReason: nil, hasToolCalls: false, refusal: nil) == "end_turn")
        #expect(OpenAIWire.stopReason(finishReason: "", hasToolCalls: true, refusal: nil) == "tool_use")
    }

    /// A reason we have no name for is passed through rather than flattened, so the
    /// closing line says the provider's word for what happened.
    @Test("An unrecognised finish_reason is not flattened")
    func unknownFinishReasonIsPassedThrough() {
        #expect(OpenAIWire.stopReason(
            finishReason: "guardrail_intervened", hasToolCalls: false, refusal: nil
        ) == "guardrail_intervened")
    }

    /// OpenAI's structured decline is the closer analogue of Anthropic's refusal than
    /// a content filter is, and the loop ends the run on it with the explanation.
    @Test("A refusal carries its explanation to the loop")
    func refusalCarriesItsExplanation() throws {
        let response = try decode("""
        {"choices":[{"message":{"role":"assistant","refusal":"I can't help with that."},
          "finish_reason":"stop"}]}
        """)
        #expect(response.stopReason == "refusal")
        #expect(response.stopDetails?.explanation == "I can't help with that.")
    }

    @Test("A response with no choices is an error, not an empty turn")
    func noChoicesIsAnError() {
        #expect(throws: OpenAICompatibleClient.Error.self) {
            _ = try decode(#"{"id":"x","choices":[]}"#)
        }
    }

    @Test("A completion with no usage block reports zeros rather than failing")
    func missingUsageIsZero() throws {
        let response = try decode(#"{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}"#)
        #expect(response.usage.inputTokens == 0)
        #expect(response.usage.outputTokens == 0)
    }
}

/// The client itself, over a stubbed `URLProtocol`. No live endpoint is contacted.
@Suite("OpenAI-compatible client", .serialized)
struct OpenAIClientTests {

    /// Serves scripted responses and keeps the last request it saw.
    ///
    /// Static state because `URLProtocol` is instantiated by `URLSession`, which gives
    /// no hook for per-instance context. The suite is `.serialized` so it is safe.
    final class Stub: URLProtocol {
        struct Step {
            let status: Int
            let body: String
            var headers: [String: String] = [:]
        }

        nonisolated(unsafe) private static var steps: [Step] = []
        nonisolated(unsafe) private static var seenRequests: [URLRequest] = []
        nonisolated(unsafe) private static var seenBodies: [Data] = []
        private static let lock = NSLock()

        static func script(_ steps: [Step]) {
            lock.lock(); defer { lock.unlock() }
            Self.steps = steps
            seenRequests = []
            seenBodies = []
        }

        static var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return seenRequests
        }

        static var bodies: [JSONValue] {
            lock.lock(); defer { lock.unlock() }
            return seenBodies.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }

        private static func next(_ request: URLRequest) -> Step {
            lock.lock(); defer { lock.unlock() }
            seenRequests.append(request)
            // `httpBody` is stripped by URLSession before the protocol sees it; the
            // stream is where the bytes actually are.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(contentsOf: buffer[0..<read])
                }
                stream.close()
                seenBodies.append(data)
            } else if let body = request.httpBody {
                seenBodies.append(body)
            }
            return steps.isEmpty ? Step(status: 500, body: "{}") : steps.removeFirst()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let step = Self.next(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: step.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(step.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static let success = """
    {"id":"chatcmpl-1","model":"gpt-4o","choices":[
      {"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],
     "usage":{"prompt_tokens":5,"completion_tokens":2}}
    """

    private func client(
        base: String = "http://localhost:11434/v1",
        provider: String = "Ollama",
        apiKey: String? = nil,
        maxRetries: Int = 3
    ) -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return OpenAICompatibleClient(
            provider: provider, baseURL: URL(string: base)!, apiKey: apiKey,
            session: URLSession(configuration: config),
            maxRetries: maxRetries, retryBaseDelay: 0.001
        )
    }

    private var request: Wire.Request {
        Wire.Request(
            model: "gpt-4o", maxTokens: 100, system: [.init("s")],
            messages: [.user("hi")], tools: []
        )
    }

    /// People paste the base URL with and without a trailing slash in equal measure,
    /// and `URL(string:relativeTo:)` treats the two differently — the second resolves
    /// against the parent and drops `/v1`, producing a 404 that reads as "Ollama is
    /// not running".
    @Test("The completions path is appended however the base URL is written", arguments: [
        "http://localhost:11434/v1",
        "http://localhost:11434/v1/",
        "http://localhost:4000",
        "https://api.openai.com/v1/chat/completions",
    ])
    func endpointIsBuiltConsistently(base: String) {
        let url = OpenAICompatibleClient.completionsEndpoint(for: URL(string: base)!)
        #expect(url.absoluteString.hasSuffix("/chat/completions"))
        #expect(!url.absoluteString.contains("chat/completions/chat"))
        #expect(!url.absoluteString.contains("//chat"))
    }

    @Test("A round trip sends the translated body and returns a Wire response")
    func roundTrip() async throws {
        Stub.script([.init(status: 200, body: Self.success)])
        let response = try await client().send(request)

        #expect(response.text == "ok")
        #expect(response.stopReason == "end_turn")

        let sent = try #require(Stub.bodies.first)
        #expect(sent["model"]?.stringValue == "gpt-4o")
        #expect(sent["max_tokens"]?.intValue == 100)
        #expect(sent["messages"]?.arrayValue?.count == 2)
    }

    /// Ollama needs no key, and an empty `Authorization: Bearer ` header makes some
    /// proxies 401 a request that would have succeeded unauthenticated.
    @Test("A keyless provider sends no Authorization header")
    func keylessProviderSendsNoHeader() async throws {
        Stub.script([.init(status: 200, body: Self.success)])
        _ = try await client(apiKey: nil).send(request)
        let sent = try #require(Stub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A key is sent as a bearer token")
    func keyIsSentAsBearer() async throws {
        Stub.script([.init(status: 200, body: Self.success)])
        _ = try await client(apiKey: "sk-test-123456789").send(request)
        let sent = try #require(Stub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123456789")
    }

    /// The same shape-follows-the-model rule the Anthropic encoder enforces. A client
    /// that captured the shape at init would reintroduce that desync one layer down.
    @Test("The request shape follows the model it names, not the client")
    func shapeFollowsTheRequestModel() async throws {
        Stub.script([.init(status: 200, body: Self.success)])
        var reasoning = request
        reasoning.model = "o3-mini"
        _ = try await client().send(reasoning)

        let sent = try #require(Stub.bodies.first)
        #expect(sent["max_completion_tokens"]?.intValue == 100)
        #expect(sent["max_tokens"] == nil)
        #expect(sent["messages"]?.arrayValue?.first?["role"]?.stringValue == "developer")
    }

    @Test("A transient failure is retried and then succeeds", arguments: [429, 500, 503])
    func retriesTransientFailures(status: Int) async throws {
        Stub.script([
            .init(status: status, body: #"{"error":{"type":"overloaded","message":"busy"}}"#),
            .init(status: 200, body: Self.success),
        ])
        let response = try await client().send(request)
        #expect(response.text == "ok")
        #expect(Stub.requests.count == 2)
    }

    @Test("Client errors are not retried", arguments: [400, 401, 404])
    func clientErrorsAreNotRetried(status: Int) async {
        Stub.script([.init(status: status, body: #"{"error":{"type":"invalid","message":"nope"}}"#)])
        await #expect(throws: OpenAICompatibleClient.Error.self) {
            _ = try await client().send(request)
        }
        #expect(Stub.requests.count == 1)
    }

    /// "Could not connect" against a local Ollama means the daemon is not running;
    /// against OpenAI it means the network is down. Same error, opposite fix — so the
    /// message has to name which one it was.
    @Test("Errors name the provider that produced them")
    func errorsNameTheProvider() async {
        Stub.script([.init(status: 404, body: #"{"error":{"type":"not_found","message":"model 'llava' not found"}}"#)])
        do {
            _ = try await client(provider: "Ollama").send(request)
            Issue.record("expected a throw")
        } catch let error as OpenAICompatibleClient.Error {
            #expect(error.description.contains("Ollama"))
            #expect(error.description.contains("404"))
            #expect(error.description.contains("llava"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A malformed success body is reported, not retried")
    func malformedBodyIsNotRetried() async {
        Stub.script([.init(status: 200, body: "not json at all")])
        await #expect(throws: OpenAICompatibleClient.Error.self) {
            _ = try await client().send(request)
        }
        #expect(Stub.requests.count == 1)
    }

    /// Shared with the Anthropic client, so it is defended once for both.
    @Test("A server-sent Retry-After wins over the computed backoff")
    func backoffHonoursRetryAfter() {
        #expect(Backoff.delay(attempt: 0, retryAfter: 7, base: 0.5) == 7)
        #expect(Backoff.delay(attempt: 0, retryAfter: 8_000, base: 0.5) == 60)
        let first = Backoff.delay(attempt: 0, retryAfter: nil, base: 0.5)
        let later = Backoff.delay(attempt: 4, retryAfter: nil, base: 0.5)
        #expect(later > first)
        #expect(later <= 10)
    }

    /// The seam's whole promise: a conforming client is invisible above it. If this
    /// stops holding, a provider has become a second route into the agent rather than
    /// a translation beneath it.
    @Test("The client satisfies MessagesClient with nothing else changed")
    func conformsToTheSeam() async throws {
        Stub.script([.init(status: 200, body: Self.success)])
        let messages: any MessagesClient = client()
        let response = try await messages.send(request)
        #expect(response.role == .assistant)
    }

    // MARK: - A content filter is not a refusal

    // Both reach the loop as `stop_reason: "refusal"`, because that is the branch that
    // ends a run with an explanation. They are not the same event, and only one of
    // them fills `message.refusal` — OpenAI sets no refusal text for a content filter.

    @Test("A model refusal carries the model's own words")
    func modelRefusalKeepsItsExplanation() throws {
        let details = try #require(OpenAIWire.stopDetails(
            finishReason: "stop", refusal: "I can't help with that."
        ))
        #expect(details.type == "refusal")
        #expect(details.category == "model_refusal")
        #expect(details.explanation == "I can't help with that.")
    }

    @Test("A content filter says so, and says it was not the model")
    func contentFilterIsAttributedCorrectly() throws {
        // Before this the loop found no details and reported "the model declined this
        // request (no explanation given)" — the wrong actor, and nothing actionable.
        let details = try #require(OpenAIWire.stopDetails(
            finishReason: "content_filter", refusal: nil
        ))
        #expect(details.category == "content_filter")
        #expect(details.explanation?.contains("content filter") == true)
        #expect(details.explanation?.contains("not the model itself") == true)
    }

    @Test("An ordinary stop carries no details")
    func ordinaryStopHasNoDetails() {
        #expect(OpenAIWire.stopDetails(finishReason: "stop", refusal: nil) == nil)
        #expect(OpenAIWire.stopDetails(finishReason: "tool_calls", refusal: nil) == nil)
        #expect(OpenAIWire.stopDetails(finishReason: nil, refusal: nil) == nil)
        // An empty refusal string is not a refusal.
        #expect(OpenAIWire.stopDetails(finishReason: "stop", refusal: "") == nil)
    }

    @Test("A refusal outranks the finish reason")
    func refusalTextWinsOverContentFilter() throws {
        // If a provider sets both, the model's own words are the more specific fact.
        let details = try #require(OpenAIWire.stopDetails(
            finishReason: "content_filter", refusal: "I won't do that."
        ))
        #expect(details.category == "model_refusal")
        #expect(details.explanation == "I won't do that.")
    }

}

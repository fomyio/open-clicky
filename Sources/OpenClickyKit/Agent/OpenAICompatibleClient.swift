import Foundation

/// Translation between Wire's Anthropic-shaped types and the OpenAI chat-completions
/// dialect that Ollama, LiteLLM, Groq and OpenAI itself all speak.
///
/// A separate namespace of pure functions rather than methods on the client, because
/// the translation is the part worth testing and the HTTP round-trip is not. Every
/// function here takes a value and returns a value; nothing reaches the network.
///
/// The request is assembled as a `JSONValue` rather than a mirror of Encodable
/// structs. The dialect's optionality is the reason: `strict` must be absent rather
/// than false on runtimes that reject it, the output cap changes key by family, and
/// the system role is a string that differs between them. A struct would model those
/// as fields that are always present and then need custom encoding for each one,
/// which is how `Wire.Request` ended up hand-encoding its own body too.
enum OpenAIWire {

    // MARK: - Request

    static func requestBody(
        _ request: Wire.Request, capabilities: ModelCapabilities
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages(request, capabilities: capabilities)),
        ]
        // `max_tokens` is deprecated on OpenAI and rejected outright by the reasoning
        // families; `max_completion_tokens` is unknown to older Ollama builds. There
        // is no key that works everywhere, so the model chooses — see
        // `ModelCapabilities.outputTokenField`.
        body[capabilities.outputTokenField] = .number(Double(request.maxTokens))

        let definitions = tools(request.tools, capabilities: capabilities)
        if !definitions.isEmpty {
            body["tools"] = .array(definitions)
        }
        // `thinking`, `output_config.effort` and `cache_control` have no analogue in
        // this dialect and are dropped rather than approximated. Reasoning effort on
        // the OpenAI families is a differently-shaped field with a different meaning,
        // and inventing a mapping would silently change what the user asked for.
        return .object(body)
    }

    /// Wire messages, flattened into the role sequence the dialect expects.
    ///
    /// The shapes do not correspond one-to-one, and the two places they diverge are
    /// both places a naive translation loses data silently:
    ///
    /// - A Wire user message carrying several `tool_result` blocks becomes several
    ///   `tool`-role messages. Anthropic requires every result for a turn in one user
    ///   message; OpenAI requires one message per `tool_call_id`. Both are satisfied
    ///   by expanding here — the loop still hands us one message, and every call it
    ///   answers still gets an answer.
    /// - A `tool` message's content is a plain string, so an image in a tool result
    ///   has nowhere to go. It follows in a user message instead, which is the
    ///   documented workaround and keeps the image adjacent to the result it came from.
    static func messages(
        _ request: Wire.Request, capabilities: ModelCapabilities
    ) -> [JSONValue] {
        var out: [JSONValue] = []

        if !request.system.isEmpty {
            // The cache breakpoint is dropped: this dialect has no `cache_control`.
            // OpenAI caches long prefixes automatically and the local runtimes do not
            // cache at all, so the only thing preserved is the *order* — the stable
            // prefix stays first, which is what makes automatic prefix caching work
            // at all. Joining is safe because `SystemBlock` is plain text either way.
            out.append(.object([
                "role": .string(capabilities.systemRole),
                "content": .string(request.system.map(\.text).joined(separator: "\n\n")),
            ]))
        }

        for message in request.messages {
            switch message.role {
            case .assistant:
                if let translated = assistantMessage(message.content) { out.append(translated) }
            case .user:
                out.append(contentsOf: userMessages(message.content, capabilities: capabilities))
            }
        }
        return out
    }

    /// An assistant turn: prose plus the calls it wants run.
    ///
    /// Thinking blocks are dropped. They are signed, bound to the model that produced
    /// them, and meaningless to any other — replaying one is at best ignored and at
    /// worst a 400. Nothing else in the turn depends on them, so dropping is lossless
    /// for every provider this client talks to.
    static func assistantMessage(_ blocks: [Wire.ContentBlock]) -> JSONValue? {
        var text = ""
        var calls: [JSONValue] = []

        for block in blocks {
            switch block {
            case let .text(value):
                if !text.isEmpty { text += "\n" }
                text += value
            case let .toolUse(id, name, input):
                calls.append(.object([
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name),
                        // Arguments are a *string* here, not an object. Sending the
                        // object is accepted by some proxies and rejected by OpenAI.
                        "arguments": .string(encodeArguments(input)),
                    ]),
                ]))
            case .thinking, .passthrough, .toolResult:
                continue
            }
        }

        // An assistant turn with neither prose nor calls says nothing and is rejected
        // by several runtimes as an empty message. Omitting it is what a transcript
        // holding only a thinking block should translate to.
        guard !text.isEmpty || !calls.isEmpty else { return nil }

        var message: [String: JSONValue] = ["role": .string("assistant")]
        // `null`, not `""`: the documented shape for a turn that is only tool calls.
        message["content"] = text.isEmpty ? .null : .string(text)
        if !calls.isEmpty { message["tool_calls"] = .array(calls) }
        return .object(message)
    }

    /// A user turn, which in this loop is usually a batch of tool results.
    static func userMessages(
        _ blocks: [Wire.ContentBlock], capabilities: ModelCapabilities
    ) -> [JSONValue] {
        var out: [JSONValue] = []
        var trailing: [JSONValue] = []

        func appendText(_ text: String) {
            trailing.append(.object(["type": .string("text"), "text": .string(text)]))
        }

        for block in blocks {
            switch block {
            case let .text(value):
                appendText(value)

            case let .toolResult(toolUseID, content, isError):
                var text = content.compactMap { part -> String? in
                    if case let .text(value) = part { return value }
                    return nil
                }.joined(separator: "\n")

                // `is_error` has no analogue on a `tool` message, and without a marker
                // a failure reads exactly like a successful result — the model's next
                // move then builds on something that did not happen.
                if isError { text = "[error] " + (text.isEmpty ? "the call failed" : text) }

                let images = content.filter(\.isImage)
                if !images.isEmpty {
                    text += text.isEmpty ? "" : "\n"
                    text += capabilities.vision
                        ? "[image follows in the next message]"
                        : "[an image was produced, but this model cannot be sent images]"
                }

                out.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(toolUseID),
                    "content": .string(text.isEmpty ? "(no output)" : text),
                ]))

                // The `tool` role takes a string, so the image rides in the user
                // message that follows the results — adjacent to the call it answers.
                for case let .image(mediaType, base64) in images where capabilities.vision {
                    trailing.append(.object([
                        "type": .string("image_url"),
                        "image_url": .object([
                            "url": .string("data:\(mediaType);base64,\(base64)"),
                        ]),
                    ]))
                }

            case .toolUse, .thinking, .passthrough:
                continue
            }
        }

        if !trailing.isEmpty {
            // A single text part is sent as a plain string: the parts array is
            // correct everywhere but the string is what every runtime has been
            // tested against, and a text-only turn is the common case.
            let onlyText = trailing.count == 1 && trailing[0]["type"]?.stringValue == "text"
            out.append(.object([
                "role": .string("user"),
                "content": onlyText
                    ? .string(trailing[0]["text"]?.stringValue ?? "")
                    : .array(trailing),
            ]))
        }
        return out
    }

    /// Tool definitions in the `{type: "function", function: {…}}` envelope.
    ///
    /// `strict` is set only when the endpoint understands it *and* the schema
    /// qualifies. OpenAI's strict mode additionally requires every property to appear
    /// in `required`, which several of our schemas deliberately do not do —
    /// `screenshot` takes an optional region and an optional display. Sending `strict`
    /// with a partial `required` list is a 400 on the whole request, so the schema is
    /// checked rather than assumed.
    static func tools(
        _ definitions: [Wire.ToolDefinition], capabilities: ModelCapabilities
    ) -> [JSONValue] {
        definitions.map { definition in
            var function: [String: JSONValue] = [
                "name": .string(definition.name),
                "description": .string(definition.description),
                "parameters": definition.inputSchema,
            ]
            if definition.strict, capabilities.strictTools,
               schemaQualifiesForStrict(definition.inputSchema) {
                function["strict"] = .bool(true)
            }
            return .object(["type": .string("function"), "function": .object(function)])
        }
    }

    /// Whether a schema meets OpenAI's additional requirements for strict mode.
    ///
    /// Applied to nested objects too, not only the root. OpenAI requires every object
    /// in the schema to close `additionalProperties` and list every property in
    /// `required`, and no tool here has a nested object today — which is exactly what
    /// makes a root-only check a trap rather than a bug: the first tool to grow one
    /// would satisfy the root, be sent `strict: true`, and 400 every request against
    /// OpenAI while working fine on every local runtime. Recursing costs nothing and
    /// removes the trap.
    ///
    /// Errs toward *not* strict, which is the safe direction: omitting `strict` loses
    /// a schema guarantee the model would probably have honoured anyway, while
    /// claiming it wrongly fails the whole request.
    static func schemaQualifiesForStrict(_ schema: JSONValue) -> Bool {
        guard let properties = schema["properties"]?.objectValue else { return false }
        guard schema["additionalProperties"]?.boolValue == false else { return false }
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        guard required == Set(properties.keys) else { return false }

        return properties.values.allSatisfy { property in
            // Only objects carry the requirement. A string, number or array of
            // scalars has nothing to close.
            guard property["type"]?.stringValue == "object" else {
                // An array of objects carries it on its `items`.
                if property["type"]?.stringValue == "array", let items = property["items"],
                   items["type"]?.stringValue == "object" {
                    return schemaQualifiesForStrict(items)
                }
                return true
            }
            return schemaQualifiesForStrict(property)
        }
    }

    /// Tool arguments as the JSON *string* the dialect wants.
    ///
    /// Sorted keys for the same reason `Wire.encoder` sorts them: Swift seeds its
    /// hashing per process, so an unsorted object serialises differently run to run
    /// and defeats any prefix cache the provider keeps.
    static func encodeArguments(_ input: JSONValue) -> String {
        guard let data = try? Wire.encoder.encode(input),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Response

    struct Completion: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String
                /// A JSON *string* per the spec, but several proxies send the object.
                /// Decoded loosely so one non-conforming provider is not a hard error.
                let arguments: JSONValue?
            }
            let id: String?
            let function: Function
        }

        struct Message: Decodable {
            let content: String?
            /// OpenAI's structured decline. Distinct from a content filter, and the
            /// closer analogue of Anthropic's `stop_reason: "refusal"`.
            let refusal: String?
            let toolCalls: [ToolCall]?

            private enum CodingKeys: String, CodingKey {
                case content, refusal
                case toolCalls = "tool_calls"
            }
        }

        struct Choice: Decodable {
            let message: Message
            let finishReason: String?

            private enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Usage: Decodable {
            struct PromptDetails: Decodable {
                let cachedTokens: Int?
                private enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }
            let promptTokens: Int?
            let completionTokens: Int?
            let promptTokensDetails: PromptDetails?

            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case promptTokensDetails = "prompt_tokens_details"
            }
        }

        let id: String?
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    static func response(_ completion: Completion, model: String) throws -> Wire.Response {
        guard let choice = completion.choices.first else {
            throw OpenAICompatibleClient.Error.malformedResponse(
                provider: model, detail: "the response contained no choices"
            )
        }

        var blocks: [Wire.ContentBlock] = []
        if let text = choice.message.content, !text.isEmpty {
            blocks.append(.text(text))
        }
        if let refusal = choice.message.refusal, !refusal.isEmpty {
            blocks.append(.text(refusal))
        }

        let calls = choice.message.toolCalls ?? []
        for (index, call) in calls.enumerated() {
            // Ollama and llama.cpp omit the id on tool calls. The loop keys every
            // result by it, so an absent one has to be invented here rather than
            // discovered missing when the results message is assembled — and it has
            // to be derived from the position so the same call gets the same id if
            // this response is ever translated twice.
            blocks.append(.toolUse(
                id: call.id ?? "call_\(index)",
                name: call.function.name,
                input: decodeArguments(call.function.arguments)
            ))
        }

        let reason = stopReason(
            finishReason: choice.finishReason,
            hasToolCalls: !calls.isEmpty,
            refusal: choice.message.refusal
        )

        return Wire.Response(
            id: completion.id ?? "chatcmpl-unknown",
            role: .assistant,
            content: blocks,
            model: completion.model ?? model,
            stopReason: reason,
            stopDetails: stopDetails(
                finishReason: choice.finishReason, refusal: choice.message.refusal
            ),
            usage: Wire.Usage(
                inputTokens: completion.usage?.promptTokens ?? 0,
                outputTokens: completion.usage?.completionTokens ?? 0,
                cacheReadInputTokens: completion.usage?.promptTokensDetails?.cachedTokens,
                cacheCreationInputTokens: nil
            )
        )
    }

    /// Why the run stopped, in words the user can act on.
    ///
    /// Both `refusal` and `content_filter` reach the loop as `stop_reason: "refusal"`,
    /// because that is the branch that ends a run with an explanation. They are not
    /// the same event, and only one of them fills `message.refusal`: a content filter
    /// is the provider's moderation stopping the response, and OpenAI sets no refusal
    /// text for it. Without this the loop found no details and reported "the model
    /// declined this request (no explanation given)" — which names the wrong actor and
    /// gives the user nothing to do about it.
    static func stopDetails(finishReason: String?, refusal: String?) -> Wire.StopDetails? {
        if let refusal, !refusal.isEmpty {
            return Wire.StopDetails(type: "refusal", category: "model_refusal", explanation: refusal)
        }
        if finishReason == "content_filter" {
            return Wire.StopDetails(
                type: "refusal", category: "content_filter",
                explanation: "the provider's content filter stopped this response, "
                    + "not the model itself — the request never reached a decision"
            )
        }
        return nil
    }

    /// `finish_reason` in the vocabulary the loop branches on.
    ///
    /// The loop reads exactly two values specially — `"refusal"` ends the run with the
    /// model's explanation, and `"max_tokens"` warns that the turn was cut off — and
    /// everything else only reaches a closing line. So the two that matter are mapped
    /// exactly, and anything unrecognised is passed through verbatim rather than
    /// flattened to `end_turn`: a run that stopped for a reason we have no name for
    /// should say the provider's word for it, not a word we made up.
    ///
    /// The absent case is real and not defensive. Several local runtimes omit
    /// `finish_reason` on a non-streamed completion, and defaulting it to `end_turn`
    /// would end every Ollama run on its first tool call — the loop concludes when a
    /// response carries no calls, so the reason has to follow the content.
    static func stopReason(
        finishReason: String?, hasToolCalls: Bool, refusal: String?
    ) -> String {
        if refusal != nil { return "refusal" }
        switch finishReason {
        case "stop": return "end_turn"
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        case "content_filter": return "refusal"
        case nil, "": return hasToolCalls ? "tool_use" : "end_turn"
        case let other?: return other
        }
    }

    /// Tool arguments back into the shape the tools read.
    ///
    /// Invalid JSON is the model's mistake, not the transport's, and it has to stay
    /// recoverable: throwing here would end the run, while a value that cannot satisfy
    /// any required field makes the tool report the problem back through the normal
    /// `tool_result` path, where the model can see it and try again. A bare string is
    /// exactly that value — every keyed lookup against it returns nil.
    static func decodeArguments(_ raw: JSONValue?) -> JSONValue {
        guard let raw else { return .object([:]) }
        guard case let .string(text) = raw else { return raw }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              case .object = decoded else {
            return .string(text)
        }
        return decoded
    }
}

/// Called before each backoff, so a wait can be shown rather than merely endured.
///
/// At module scope because both clients report through it. A rate limit with
/// `Retry-After: 60` and three retries is three minutes during which the CLI prints
/// "· thinking…"; that is indistinguishable from a hang, and the reasonable response
/// to a hang is to kill the run — so a client without this was quietly training
/// people to abandon requests that were about to succeed.
public typealias RetryNotice = @Sendable (
    _ attempt: Int, _ of: Int, _ delay: Double, _ reason: String
) async -> Void

/// Backoff shared by every client.
///
/// One definition because there were about to be two, and two would have drifted:
/// the retry policy is the part that decides whether a transient 429 ends a run, and
/// a second copy is a second thing to get right.
enum Backoff {
    /// - Parameters:
    ///   - retryAfter: the server's own answer, which wins when it gives one — it
    ///     reflects when capacity actually returns, and retrying sooner just burns
    ///     another request against the limit.
    ///   - base: the first delay. Exponential from there, with jitter so a fleet of
    ///     clients does not resynchronise onto the same retry instant.
    /// `Retry-After` in seconds, from either form the header is allowed to take.
    ///
    /// RFC 7231 permits a delay in seconds *or* an HTTP-date, and `Double.init` reads
    /// only the first. A proxy that sends the date form — nginx and Cloudflare both
    /// do — parsed as nil and fell through to a 1–8 second exponential backoff, so a
    /// limit that asked for a minute got three rapid retries into the same wall and
    /// then failed the run. That is precisely the "quietly training people to abandon
    /// requests that were about to succeed" failure the retry notice exists to
    /// prevent, arriving through the header meant to prevent it.
    ///
    /// A date already in the past means the wait is over, which is 0 rather than nil:
    /// nil would discard the server's answer and back off anyway.
    static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> Double? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return nil
        }
        if let seconds = Double(header) { return seconds }
        guard let date = httpDateFormatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// IMF-fixdate, the only form a sender is required to produce. Fixed locale and
    /// zone: a device set to a non-Gregorian calendar or a 24-hour-off locale parses
    /// the same bytes differently, and a date the server sent in GMT must not be read
    /// as local time.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func delay(attempt: Int, retryAfter: Double?, base: Double) -> Double {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, 60) }
        let growth = min(pow(2.0, Double(attempt)) * base, 8.0)
        return growth + Double.random(in: 0...(growth * 0.25))
    }
}

/// One client for every endpoint that speaks OpenAI's chat-completions dialect:
/// Ollama on `localhost:11434/v1`, LiteLLM on `localhost:4000`, Groq, and OpenAI.
///
/// It conforms to `MessagesClient`, which is a one-method protocol, so nothing above
/// it changes: the agent loop, every tool, the permission gate and the whole safety
/// layer see a `send(Wire.Request) -> Wire.Response` and cannot tell which provider
/// answered. That is the point of the seam, and the reason a provider cannot become a
/// second route around the gate — there is no route here at all, only a translation.
///
/// No Python sidecar. LiteLLM as a proxy would work and is a supported target, but
/// requiring a Python process to use a native Mac app is a worse default than
/// speaking the dialect directly.
public actor OpenAICompatibleClient: MessagesClient {

    public enum Error: Swift.Error, CustomStringConvertible {
        case api(provider: String, status: Int, type: String, message: String, retryAfter: Double?)
        case transport(provider: String, underlying: Swift.Error)
        case malformedResponse(provider: String, detail: String)

        public var description: String {
            switch self {
            case let .api(provider, status, type, message, _):
                return "\(provider) API error \(status) (\(type)): \(message)"
            case let .transport(provider, underlying):
                // Naming the provider matters most here: "could not connect" against
                // a local Ollama means the daemon is not running, and against OpenAI
                // means the network is down. Same error, opposite fix.
                return "Could not reach \(provider): \(underlying.localizedDescription)"
            case let .malformedResponse(provider, detail):
                return "Malformed response from \(provider): \(detail)"
            }
        }

        var isRetryable: Bool {
            switch self {
            case .transport: return true
            case let .api(_, status, _, _, _):
                return status == 408 || status == 409 || status == 429 || status >= 500
            case .malformedResponse: return false
            }
        }
    }

    /// What the errors call this endpoint, e.g. "Ollama".
    private let provider: String
    private let endpoint: URL
    private let apiKey: String?
    private let session: URLSession
    private let maxRetries: Int
    private let retryBaseDelay: Double
    private let onRetry: RetryNotice?

    public init(
        provider: String,
        baseURL: URL,
        apiKey: String?,
        maxRetries: Int = 3,
        onRetry: RetryNotice? = nil
    ) {
        let config = URLSessionConfiguration.ephemeral
        // A local model on CPU can take minutes for one turn, so this matches the
        // Anthropic client's ten rather than the URLSession default's sixty seconds.
        config.timeoutIntervalForRequest = 600
        config.httpAdditionalHeaders = ["User-Agent": "OpenClicky/0.1 (macOS)"]
        self.init(
            provider: provider, baseURL: baseURL, apiKey: apiKey,
            session: URLSession(configuration: config),
            maxRetries: maxRetries, onRetry: onRetry
        )
    }

    /// Seam for tests: a stubbed `URLSession` and a near-zero backoff, so the wire
    /// shape and the retry policy are exercised without a network or a real wait.
    init(
        provider: String,
        baseURL: URL,
        apiKey: String?,
        session: URLSession,
        maxRetries: Int = 3,
        retryBaseDelay: Double = 0.5,
        onRetry: RetryNotice? = nil
    ) {
        self.provider = provider
        self.endpoint = Self.completionsEndpoint(for: baseURL)
        self.apiKey = apiKey
        self.session = session
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.onRetry = onRetry
    }

    /// `<base>/chat/completions`, whether or not the base carries a trailing slash.
    ///
    /// People paste `http://localhost:11434/v1` and `http://localhost:11434/v1/` with
    /// equal frequency, and `URL(string:relativeTo:)` treats the two differently —
    /// the second resolves against the parent and silently drops `/v1`, producing a
    /// 404 that reads as "Ollama is not running".
    static func completionsEndpoint(for baseURL: URL) -> URL {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        // Already a completions URL: LiteLLM's docs show the full path, and appending
        // to it produces `/chat/completions/chat/completions`.
        if text.hasSuffix("/chat/completions") { return URL(string: text) ?? baseURL }
        return URL(string: text + "/chat/completions") ?? baseURL
    }

    public func send(_ request: Wire.Request) async throws -> Wire.Response {
        var attempt = 0
        while true {
            do {
                return try await perform(request)
            } catch let error as Error where error.isRetryable && attempt < maxRetries {
                let delay = retryDelay(attempt: attempt, error: error)
                attempt += 1
                await onRetry?(attempt, maxRetries, delay, error.description)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func perform(_ body: Wire.Request) async throws -> Wire.Response {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Omitted entirely when absent rather than sent empty: Ollama needs no key,
        // and an `Authorization: Bearer ` header makes some proxies 401 a request
        // that would have been fine unauthenticated.
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // The shape is derived from the request's own model on every send, never
        // captured at init. `Wire.Request.capabilities` was a stored field once, and
        // reassigning `model` left the two disagreeing while the encoder trusted the
        // stale one — the failure that gate exists to prevent, reintroduced silently.
        // A client that cached the shape would be the same bug one layer down.
        let shape = ModelCapabilities.forModel(body.model)
        req.httpBody = try Wire.encoder.encode(
            OpenAIWire.requestBody(body, capabilities: shape)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Error.transport(provider: provider, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse(provider: provider, detail: "not an HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(Wire.APIError.self, from: data)
            throw Error.api(
                provider: provider,
                status: http.statusCode,
                type: decoded?.error.type ?? "unknown",
                message: decoded?.error.message ?? String(data: data, encoding: .utf8) ?? "<no body>",
                retryAfter: Backoff.retryAfterSeconds(http.value(forHTTPHeaderField: "retry-after"))
            )
        }

        let completion: OpenAIWire.Completion
        do {
            completion = try JSONDecoder().decode(OpenAIWire.Completion.self, from: data)
        } catch {
            throw Error.malformedResponse(provider: provider, detail: "\(error)")
        }
        return try OpenAIWire.response(completion, model: body.model)
    }

    func retryDelay(attempt: Int, error: Error) -> Double {
        var retryAfter: Double?
        if case let .api(_, _, _, _, value) = error { retryAfter = value }
        return Backoff.delay(attempt: attempt, retryAfter: retryAfter, base: retryBaseDelay)
    }
}

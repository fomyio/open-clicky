import Foundation

/// Wire types for the Anthropic Messages API (`POST /v1/messages`).
///
/// Hand-rolled rather than SDK-backed: Anthropic ships no Swift SDK, so these
/// mirror the documented JSON shapes directly. Keep them faithful to the wire
/// format — every field name here is the API's, not ours.
public enum Wire {

    // MARK: - Content blocks

    /// A single block inside a message's `content` array.
    ///
    /// The API returns a heterogeneous array discriminated by `type`, which does
    /// not map onto a Swift struct, so this is an enum with hand-written coding.
    public enum ContentBlock: Codable, Equatable, Sendable {
        case text(String)
        case thinking(text: String, signature: String?)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, content: [ToolResultContent], isError: Bool)
        /// A block type we do not model. Preserved verbatim so it can be echoed
        /// back to the API unchanged (required for thinking-block replay).
        case passthrough(JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type, text, thinking, signature, id, name, input
            case toolUseID = "tool_use_id"
            case content
            case isError = "is_error"
        }

        public init(from decoder: Decoder) throws {
            let raw = try JSONValue(from: decoder)
            guard case let .object(fields) = raw, case let .string(type)? = fields["type"] else {
                self = .passthrough(raw)
                return
            }
            switch type {
            case "text":
                self = .text(fields["text"]?.stringValue ?? "")
            case "thinking":
                self = .thinking(
                    text: fields["thinking"]?.stringValue ?? "",
                    signature: fields["signature"]?.stringValue
                )
            case "tool_use":
                guard let id = fields["id"]?.stringValue,
                      let name = fields["name"]?.stringValue else {
                    self = .passthrough(raw)
                    return
                }
                self = .toolUse(id: id, name: name, input: fields["input"] ?? .object([:]))
            case "tool_result":
                guard let id = fields["tool_use_id"]?.stringValue else {
                    self = .passthrough(raw)
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let content = (try? container.decode([ToolResultContent].self, forKey: .content)) ?? []
                self = .toolResult(
                    toolUseID: id,
                    content: content,
                    isError: fields["is_error"]?.boolValue ?? false
                )
            default:
                // Unknown block types (redacted_thinking, server tool results, …)
                // round-trip untouched rather than being dropped.
                self = .passthrough(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            // Passthrough must claim the encoder before any keyed container is
            // opened — the two are mutually exclusive, and opening the keyed one
            // first makes this silently encode an empty object.
            if case let .passthrough(value) = self {
                try value.encode(to: encoder)
                return
            }

            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case let .thinking(text, signature):
                try c.encode("thinking", forKey: .type)
                try c.encode(text, forKey: .thinking)
                try c.encodeIfPresent(signature, forKey: .signature)
            case let .toolUse(id, name, input):
                try c.encode("tool_use", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(input, forKey: .input)
            case let .toolResult(toolUseID, content, isError):
                try c.encode("tool_result", forKey: .type)
                try c.encode(toolUseID, forKey: .toolUseID)
                try c.encode(content, forKey: .content)
                if isError { try c.encode(true, forKey: .isError) }
            case .passthrough:
                preconditionFailure("handled above, before the keyed container was opened")
            }
        }
    }

    /// Content returned from a tool. Text for cheap channels, images for screenshots.
    public enum ToolResultContent: Codable, Equatable, Sendable {
        case text(String)
        case image(mediaType: String, base64: String)

        public var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        /// Approximate token cost, for budgeting and logging.
        ///
        /// Images dominate a computer-use transcript, so a rough figure is enough
        /// to make the difference visible; text is estimated at ~4 chars/token.
        public var estimatedTokens: Int {
            switch self {
            case let .text(text): return text.count / 4
            case .image: return 1_500
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, source }
        private enum SourceKeys: String, CodingKey { case type, media_type, data }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "image":
                let s = try c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                self = .image(
                    mediaType: try s.decode(String.self, forKey: .media_type),
                    base64: try s.decode(String.self, forKey: .data)
                )
            default:
                self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case let .image(mediaType, base64):
                try c.encode("image", forKey: .type)
                var s = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try s.encode("base64", forKey: .type)
                try s.encode(mediaType, forKey: .media_type)
                try s.encode(base64, forKey: .data)
            }
        }
    }

    // MARK: - Messages

    public struct Message: Codable, Equatable, Sendable {
        public let role: Role
        public let content: [ContentBlock]

        public init(role: Role, content: [ContentBlock]) {
            self.role = role
            self.content = content
        }

        public static func user(_ text: String) -> Message {
            Message(role: .user, content: [.text(text)])
        }
    }

    public enum Role: String, Codable, Sendable { case user, assistant }

    // MARK: - Tool definitions

    public struct ToolDefinition: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
        /// Guarantees `tool_use.input` validates against the schema exactly.
        /// Requires `additionalProperties: false` and a `required` array.
        public let strict: Bool
        /// Set on the last-listed tool to cache the whole tool block.
        public var cacheControl: Bool

        private enum CodingKeys: String, CodingKey {
            case name, description, strict
            case inputSchema = "input_schema"
            case cacheControl = "cache_control"
        }

        public init(name: String, description: String, inputSchema: JSONValue,
                    strict: Bool = true, cacheControl: Bool = false) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.strict = strict
            self.cacheControl = cacheControl
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            try c.encode(inputSchema, forKey: .inputSchema)
            if strict { try c.encode(true, forKey: .strict) }
            if cacheControl {
                try c.encode(JSONValue.object(["type": .string("ephemeral")]), forKey: .cacheControl)
            }
        }
    }

    /// The encoder every request goes through.
    ///
    /// `.sortedKeys` is not cosmetic. Schemas and tool inputs are held as
    /// `[String: JSONValue]`, and Swift seeds its hashing per process, so the same
    /// request serialised in two runs produced two different byte streams. The tool
    /// block carries the cache breakpoint and sits *first* in the cached prefix, so a
    /// reordered key there invalidated the tools and the system prompt with it — the
    /// entire prefix re-read at full price on every invocation. Sorting makes the
    /// bytes a function of the content alone.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: - Request

    public struct Request: Encodable, Sendable {
        public var model: String
        public var maxTokens: Int
        public var system: [SystemBlock]
        public var messages: [Message]
        public var tools: [ToolDefinition]
        public var effort: String?
        /// Opus 5 runs adaptive thinking by default; `budget_tokens` and the
        /// sampling parameters are rejected with a 400 on this model family.
        public var thinkingDisplay: String?

        private enum CodingKeys: String, CodingKey {
            case model, system, messages, tools, thinking
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }

        public init(model: String, maxTokens: Int, system: [SystemBlock],
                    messages: [Message], tools: [ToolDefinition],
                    effort: String? = nil, thinkingDisplay: String? = nil) {
            self.model = model
            self.maxTokens = maxTokens
            self.system = system
            self.messages = messages
            self.tools = tools
            self.effort = effort
            self.thinkingDisplay = thinkingDisplay
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(maxTokens, forKey: .maxTokens)
            try c.encode(system, forKey: .system)
            try c.encode(messages, forKey: .messages)
            if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
            if let effort {
                try c.encode(JSONValue.object(["effort": .string(effort)]), forKey: .outputConfig)
            }
            var thinking: [String: JSONValue] = ["type": .string("adaptive")]
            if let thinkingDisplay { thinking["display"] = .string(thinkingDisplay) }
            try c.encode(JSONValue.object(thinking), forKey: .thinking)
        }
    }

    /// A system prompt block. Split so the stable prefix can carry a cache breakpoint
    /// and volatile per-session text can follow it.
    public struct SystemBlock: Encodable, Sendable {
        public let text: String
        public let cacheControl: Bool

        public init(_ text: String, cacheControl: Bool = false) {
            self.text = text
            self.cacheControl = cacheControl
        }

        private enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            if cacheControl {
                try c.encode(JSONValue.object(["type": .string("ephemeral")]), forKey: .cacheControl)
            }
        }
    }

    // MARK: - Response

    public struct Response: Decodable, Sendable {
        public let id: String
        public let role: Role
        public let content: [ContentBlock]
        public let model: String
        public let stopReason: String?
        public let stopDetails: StopDetails?
        public let usage: Usage

        private enum CodingKeys: String, CodingKey {
            case id, role, content, model, usage
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }

        /// The tool calls the model wants executed this turn, in order.
        public var toolCalls: [(id: String, name: String, input: JSONValue)] {
            content.compactMap {
                if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
                return nil
            }
        }

        /// Visible prose from this turn, with thinking and tool blocks stripped.
        public var text: String {
            content.compactMap {
                if case let .text(t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
        }
    }

    /// Populated only when `stopReason == "refusal"`; `nil` for every other stop reason.
    public struct StopDetails: Decodable, Sendable {
        public let type: String
        public let category: String?
        public let explanation: String?
    }

    public struct Usage: Decodable, Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadInputTokens: Int?
        public let cacheCreationInputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    public struct APIError: Decodable, Sendable {
        public struct Detail: Decodable, Sendable {
            public let type: String
            public let message: String
        }
        public let error: Detail
    }
}

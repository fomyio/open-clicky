import Testing
import Foundation
@testable import OpenClickyKit

@Suite("Anthropic wire format")
struct WireTests {

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("Tool results encode in the shape the API expects")
    func encodesToolResult() throws {
        let block = Wire.ContentBlock.toolResult(
            toolUseID: "toolu_1", content: [.text("done")], isError: false
        )
        let json = try encode(block)
        #expect(json["type"]?.stringValue == "tool_result")
        #expect(json["tool_use_id"]?.stringValue == "toolu_1")
        #expect(json["content"]?.arrayValue?.first?["text"]?.stringValue == "done")
        #expect(json["is_error"] == nil, "is_error should be omitted when false")
    }

    @Test("Errored tool results carry is_error")
    func encodesErrorFlag() throws {
        let block = Wire.ContentBlock.toolResult(
            toolUseID: "toolu_2", content: [.text("boom")], isError: true
        )
        #expect(try encode(block)["is_error"]?.boolValue == true)
    }

    @Test("Image results nest a base64 source")
    func encodesImageResult() throws {
        let block = Wire.ContentBlock.toolResult(
            toolUseID: "t", content: [.image(mediaType: "image/jpeg", base64: "AAAA")], isError: false
        )
        let source = try encode(block)["content"]?.arrayValue?.first?["source"]
        #expect(source?["type"]?.stringValue == "base64")
        #expect(source?["media_type"]?.stringValue == "image/jpeg")
        #expect(source?["data"]?.stringValue == "AAAA")
    }

    @Test("Tool use blocks decode from a response")
    func decodesToolUse() throws {
        let json = """
        {"id":"msg_1","role":"assistant","model":"claude-opus-5","stop_reason":"tool_use",
         "content":[{"type":"text","text":"Looking."},
                    {"type":"tool_use","id":"toolu_9","name":"shell","input":{"command":"ls"}}],
         "usage":{"input_tokens":10,"output_tokens":5}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.text == "Looking.")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "shell")
        #expect(response.toolCalls[0].input["command"]?.stringValue == "ls")
    }

    /// Thinking blocks are bound to the model that produced them and must replay
    /// byte-identically. Anything we fail to model has to survive a round trip too.
    @Test("Unknown block types round-trip unchanged")
    func preservesUnknownBlocks() throws {
        let json = """
        {"type":"redacted_thinking","data":"encrypted-payload","extra":{"nested":true}}
        """
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case .passthrough = block else {
            Issue.record("expected passthrough, got \(block)")
            return
        }
        let reencoded = try encode(block)
        #expect(reencoded["type"]?.stringValue == "redacted_thinking")
        #expect(reencoded["data"]?.stringValue == "encrypted-payload")
        #expect(reencoded["extra"]?["nested"]?.boolValue == true)
    }

    @Test("Thinking blocks keep their signature")
    func preservesThinkingSignature() throws {
        let json = """
        {"type":"thinking","thinking":"considering","signature":"sig-abc"}
        """
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        let reencoded = try encode(block)
        #expect(reencoded["signature"]?.stringValue == "sig-abc")
        #expect(reencoded["thinking"]?.stringValue == "considering")
    }

    @Test("stop_details is absent for ordinary stop reasons")
    func stopDetailsOnlyOnRefusal() throws {
        let json = """
        {"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn",
         "content":[],"usage":{"input_tokens":1,"output_tokens":1}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.stopDetails == nil)
    }

    @Test("The request sends adaptive thinking and effort, and no sampling parameters")
    func requestShape() throws {
        let request = Wire.Request(
            model: "claude-opus-5", maxTokens: 16_000,
            system: [.init("stable", cacheControl: true), .init("session")],
            messages: [.user("hello")], tools: [], effort: "high"
        )
        let json = try encode(request)

        #expect(json["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(json["output_config"]?["effort"]?.stringValue == "high")
        #expect(json["max_tokens"]?.intValue == 16_000)
        // Rejected with a 400 on the Opus 5 family.
        #expect(json["temperature"] == nil)
        #expect(json["top_p"] == nil)
        #expect(json["thinking"]?["budget_tokens"] == nil)

        let system = json["system"]?.arrayValue
        #expect(system?.count == 2)
        #expect(system?[0]["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(system?[1]["cache_control"] == nil)
    }

    @Test("Tool definitions are strict and closed")
    func toolDefinitionShape() throws {
        let tool = ShellTool()
        let json = try encode(tool.definition)
        #expect(json["name"]?.stringValue == "shell")
        #expect(json["strict"]?.boolValue == true)
        #expect(json["input_schema"]?["additionalProperties"]?.boolValue == false)
        #expect(json["input_schema"]?["required"]?.arrayValue?.first?.stringValue == "command")
    }

    // MARK: - Malformed responses

    /// A block the decoder cannot make sense of must round-trip rather than throw:
    /// one unexpected field would otherwise fail the whole response and lose a turn's
    /// work, and dropping it would corrupt the history the model replays.
    @Test("A block with no type decodes as passthrough", arguments: [
        #"{"no_type_field": true}"#,
        #"{"type": 42}"#,
        #"{"type": "future_block_kind", "payload": {"a": [1, 2]}}"#,
    ])
    func malformedBlocksBecomePassthrough(json: String) throws {
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case .passthrough = block else {
            Issue.record("expected passthrough for \(json), got \(block)")
            return
        }
        // And it must survive re-encoding, since it goes back on the next request.
        let reencoded = try encode(block)
        #expect(reencoded == (try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
    }

    @Test("A tool_use missing its id or name degrades to passthrough", arguments: [
        #"{"type": "tool_use", "name": "shell", "input": {}}"#,
        #"{"type": "tool_use", "id": "toolu_1", "input": {}}"#,
    ])
    func incompleteToolUseIsPassthrough(json: String) throws {
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case .passthrough = block else {
            Issue.record("an unusable tool_use must not be presented as a call")
            return
        }
    }

    @Test("A tool_result missing its tool_use_id degrades to passthrough")
    func incompleteToolResultIsPassthrough() throws {
        let json = #"{"type": "tool_result", "content": [{"type": "text", "text": "x"}]}"#
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case .passthrough = block else {
            Issue.record("expected passthrough")
            return
        }
    }

    @Test("A tool_result decodes its text and image content")
    func decodesToolResultContent() throws {
        let json = """
        {"type":"tool_result","tool_use_id":"toolu_5","is_error":true,
         "content":[{"type":"text","text":"failed"},
                    {"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}
        """
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case let .toolResult(id, content, isError) = block else {
            Issue.record("expected a tool_result, got \(block)")
            return
        }
        #expect(id == "toolu_5")
        #expect(isError)
        #expect(content.count == 2)
        #expect(content[0] == .text("failed"))
        #expect(content[1] == .image(mediaType: "image/png", base64: "QUJD"))
        #expect(content[1].isImage)
        #expect(!content[0].isImage)
    }

    @Test("A tool_result with unreadable content decodes to an empty result")
    func toolResultWithBadContent() throws {
        // The id is what keeps the tool_use paired; content can be recovered from.
        let json = #"{"type":"tool_result","tool_use_id":"toolu_9","content":"not an array"}"#
        let block = try JSONDecoder().decode(Wire.ContentBlock.self, from: Data(json.utf8))
        guard case let .toolResult(id, content, _) = block else {
            Issue.record("expected a tool_result")
            return
        }
        #expect(id == "toolu_9")
        #expect(content.isEmpty)
    }

    @Test("An unknown tool-result content type falls back to text")
    func unknownContentTypeFallsBackToText() throws {
        let json = #"{"type":"video","text":"a description"}"#
        let content = try JSONDecoder().decode(Wire.ToolResultContent.self, from: Data(json.utf8))
        #expect(content == .text("a description"))
    }

    // MARK: - Responses

    @Test("A refusal carries its stop details")
    func decodesRefusal() throws {
        let json = """
        {"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"refusal",
         "stop_details":{"type":"refusal","category":"cyber","explanation":"declined"},
         "content":[],"usage":{"input_tokens":1,"output_tokens":0}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.stopReason == "refusal")
        #expect(response.stopDetails?.category == "cyber")
        #expect(response.stopDetails?.explanation == "declined")
        #expect(response.text.isEmpty)
        #expect(response.toolCalls.isEmpty)
    }

    @Test("Cache usage fields are optional")
    func usageFieldsAreOptional() throws {
        let json = """
        {"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn",
         "content":[],"usage":{"input_tokens":10,"output_tokens":2}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.usage.cacheReadInputTokens == nil)
        #expect(response.usage.inputTokens == 10)
    }

    @Test("Several text blocks join into one message")
    func joinsTextBlocks() throws {
        let json = """
        {"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"end_turn",
         "content":[{"type":"text","text":"first"},
                    {"type":"thinking","thinking":"hidden"},
                    {"type":"text","text":"second"}],
         "usage":{"input_tokens":1,"output_tokens":1}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.text == "first\nsecond", "thinking must not leak into the visible text")
    }

    @Test("Parallel tool calls are returned in order")
    func decodesParallelToolCalls() throws {
        let json = """
        {"id":"m","role":"assistant","model":"claude-opus-5","stop_reason":"tool_use",
         "content":[{"type":"tool_use","id":"t1","name":"alpha","input":{}},
                    {"type":"tool_use","id":"t2","name":"beta","input":{"k":"v"}}],
         "usage":{"input_tokens":1,"output_tokens":1}}
        """
        let response = try JSONDecoder().decode(Wire.Response.self, from: Data(json.utf8))
        #expect(response.toolCalls.map(\.name) == ["alpha", "beta"])
        #expect(response.toolCalls[1].input["k"]?.stringValue == "v")
    }

    @Test("An API error body decodes")
    func decodesAPIError() throws {
        let json = #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        let error = try JSONDecoder().decode(Wire.APIError.self, from: Data(json.utf8))
        #expect(error.error.type == "rate_limit_error")
        #expect(error.error.message == "slow down")
    }

    @Test("Only the last tool carries the cache breakpoint")
    func cacheBreakpointPlacement() throws {
        let registry = ToolRegistry([ShellTool(), AppleScriptTool(), AXCaptureTool()])
        let definitions = registry.definitions
        #expect(definitions.dropLast().allSatisfy { !$0.cacheControl })
        #expect(definitions.last?.cacheControl == true)
    }
}

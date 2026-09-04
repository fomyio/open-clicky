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

    @Test("Only the last tool carries the cache breakpoint")
    func cacheBreakpointPlacement() throws {
        let registry = ToolRegistry([ShellTool(), AppleScriptTool(), AXCaptureTool()])
        let definitions = registry.definitions
        #expect(definitions.dropLast().allSatisfy { !$0.cacheControl })
        #expect(definitions.last?.cacheControl == true)
    }
}

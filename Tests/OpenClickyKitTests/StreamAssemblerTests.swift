import Testing
import Foundation
@testable import OpenClickyKit

/// Rebuilding a completion from an event stream, without a network.
///
/// The awkward part of the dialect is that a tool call arrives in fragments — a name
/// in one chunk, then `arguments` as a run of string pieces that mean nothing until
/// concatenated, tied together only by an `index`. Every test here is a pure feed of
/// lines, so that whole surface is exercised with no HTTP at all.
@Suite("Stream assembler")
struct StreamAssemblerTests {

    private func feed(_ lines: [String]) -> (assembler: StreamAssembler, seen: String) {
        var assembler = StreamAssembler()
        var seen = ""
        for line in lines { seen += assembler.consume(line: line) ?? "" }
        return (assembler, seen)
    }

    @Test("Text arrives incrementally and assembles in order")
    func textAssembles() {
        let (assembler, seen) = feed([
            #"data: {"id":"c1","model":"m","choices":[{"delta":{"content":"Hel"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"lo, "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"world"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])
        // The point of streaming: each piece was available the moment it arrived.
        #expect(seen == "Hello, world")
        #expect(assembler.sawDone)

        let completion = assembler.completion()
        let choice = completion["choices"]?.arrayValue?.first
        #expect(choice?["message"]?["content"]?.stringValue == "Hello, world")
        #expect(choice?["finish_reason"]?.stringValue == "stop")
        #expect(completion["id"]?.stringValue == "c1")
        #expect(completion["model"]?.stringValue == "m")
    }

    @Test("Tool-call arguments are concatenated, never replaced")
    func toolArgumentsConcatenate() throws {
        // The fragment that makes this awkward: `{"comm`, `and":"ls`, `"}` is not JSON
        // at any point until the last piece lands.
        let (assembler, _) = feed([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"shell","arguments":"{\"comm"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"}"}}]}}]}"#,
            "data: [DONE]",
        ])
        let call = try #require(
            assembler.completion()["choices"]?.arrayValue?.first?["message"]?["tool_calls"]?
                .arrayValue?.first
        )
        #expect(call["id"]?.stringValue == "call_a")
        #expect(call["function"]?["name"]?.stringValue == "shell")
        #expect(call["function"]?["arguments"]?.stringValue == #"{"command":"ls"}"#)
        // And it survives the round trip the real client makes.
        let decoded = OpenAIWire.decodeArguments(call["function"]?["arguments"])
        #expect(decoded["command"]?.stringValue == "ls")
    }

    @Test("Several tool calls stay separate, ordered by index")
    func multipleCallsStaySeparate() throws {
        let (assembler, _) = feed([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"first","arguments":"{}"}}]}}]}"#,
            "data: [DONE]",
        ])
        let calls = try #require(
            assembler.completion()["choices"]?.arrayValue?.first?["message"]?["tool_calls"]?.arrayValue
        )
        #expect(calls.count == 2)
        // Sorted by index, not by arrival: nothing promises they come in order.
        #expect(calls[0]["function"]?["name"]?.stringValue == "first")
        #expect(calls[1]["function"]?["name"]?.stringValue == "second")
    }

    @Test("A runtime that omits index does not merge two calls into one")
    func absentIndexDoesNotMerge() throws {
        // Folding an absent index onto 0 would concatenate two unrelated argument
        // strings into one unparsable blob, and the model would be told its second
        // call failed for a reason it could not diagnose.
        let (assembler, _) = feed([
            #"data: {"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"first","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"id":"b","function":{"name":"second","arguments":"{}"}}]}}]}"#,
            "data: [DONE]",
        ])
        let calls = try #require(
            assembler.completion()["choices"]?.arrayValue?.first?["message"]?["tool_calls"]?.arrayValue
        )
        #expect(calls.count == 2)
        #expect(calls[0]["function"]?["arguments"]?.stringValue == "{}")
    }

    @Test("Keep-alive comments and blank lines are not payload")
    func heartbeatsAreIgnored() {
        // Some proxies send `:` comments to hold the connection open. Decoding one as
        // JSON would end the stream on a heartbeat.
        let (assembler, seen) = feed([
            ": keep-alive", "", "   ",
            #"data: {"choices":[{"delta":{"content":"hi"}}]}"#,
            ": another", "data: [DONE]",
        ])
        #expect(seen == "hi")
        #expect(assembler.sawDone)
    }

    @Test("Usage is taken as a total, not accumulated")
    func usageIsATotal() {
        let (assembler, _) = feed([
            #"data: {"choices":[{"delta":{"content":"x"}}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#,
            "data: [DONE]",
        ])
        let usage = assembler.completion()["usage"]
        #expect(usage?["prompt_tokens"]?.doubleValue == 10)
        #expect(usage?["completion_tokens"]?.doubleValue == 2)
    }

    @Test("An endpoint that sends no usage reports none rather than zero")
    func absentUsageIsAbsent() {
        // Zeros would be a measurement, and a wrong one — `bench` and `CostMeter`
        // both read these.
        let (assembler, _) = feed([
            #"data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])
        #expect(assembler.completion()["usage"] == nil)
    }

    @Test("A stream that ends without a finish_reason still answers the loop")
    func inferredFinishReason() {
        let plain = feed([#"data: {"choices":[{"delta":{"content":"x"}}]}"#, "data: [DONE]"]).assembler
        #expect(plain.completion()["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue == "stop")

        let calling = feed([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"shell","arguments":"{}"}}]}}]}"#,
            "data: [DONE]",
        ]).assembler
        #expect(calling.completion()["choices"]?.arrayValue?.first?["finish_reason"]?.stringValue == "tool_calls")
    }

    @Test("Malformed payload is skipped, not fatal")
    func malformedChunkIsSkipped() {
        // A proxy that injects a bad frame should cost that frame, not the run.
        let (assembler, seen) = feed([
            "data: {not json",
            #"data: {"choices":[{"delta":{"content":"ok"}}]}"#,
            "data: [DONE]",
        ])
        #expect(seen == "ok")
        #expect(assembler.sawDone)
    }

    @Test("A streamed completion decodes exactly like a buffered one")
    func streamedShapeMatchesBuffered() throws {
        // The property that matters most: nothing downstream may be able to tell which
        // path produced the response, or streaming becomes a second route through the
        // safety layer.
        let (assembler, _) = feed([
            #"data: {"id":"c9","model":"m","choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#,
            "data: [DONE]",
        ])
        let data = try Wire.encoder.encode(assembler.completion())
        let completion = try JSONDecoder().decode(OpenAIWire.Completion.self, from: data)
        let response = try OpenAIWire.response(completion, model: "m")
        #expect(response.text == "done")
        #expect(response.stopReason == "end_turn")
        #expect(response.usage.inputTokens == 5)
        #expect(response.usage.outputTokens == 1)
    }

    // MARK: - The renderer and the stream must not both draw

    // Found by running it: with streaming wired up and the renderer unchanged, every
    // reply appeared twice — once a fragment at a time, then again in full when the
    // turn closed.

    @Test("A streaming caller does not have its text reprinted")
    func streamingSuppressesTheEcho() {
        var report = RunReport(isInteractive: true, streamsText: true)
        let lines = report.lines(for: .assistantText("Hello, world"))
        // Only the blank line that closes what the stream was writing into.
        #expect(!lines.contains { $0.text.contains("Hello, world") })
        #expect(lines.count == 1)
    }

    @Test("A non-streaming caller still gets the text")
    func bufferedCallerStillSeesTheText() {
        // The other direction is worse: suppressing for a provider that never streams
        // loses the reply entirely.
        var report = RunReport(isInteractive: true, streamsText: false)
        let lines = report.lines(for: .assistantText("Hello, world"))
        #expect(lines.contains { $0.text == "Hello, world" })
    }

    @Test("Only providers that stream are asked to")
    func onlyStreamingProvidersClaimIt() throws {
        // The condition both halves read. Anthropic's client ignores `onText`, so
        // claiming it streams would suppress a render that never happens.
        for kind in Provider.Kind.allCases {
            let streams = (kind != .anthropic)
            #expect(
                Provider(kind: kind, model: "m", baseURL: nil, credentials: nil).streamsText
                    == streams,
                "\(kind.rawValue)"
            )
        }
    }

}

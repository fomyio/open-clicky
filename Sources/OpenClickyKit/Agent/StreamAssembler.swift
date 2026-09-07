import Foundation

/// Rebuilds one whole completion from a chat-completions event stream.
///
/// # Why stream at all
///
/// Not for throughput. A streamed turn and a buffered one finish at the same instant,
/// and the loop cannot act on a partial `tool_use` block anyway — the arguments are
/// not valid JSON until the last fragment arrives. What changes is what the user sees
/// while it happens.
///
/// Measured on this machine: turns of 15–35 seconds against a local model, and one
/// recorded 62-second turn against Anthropic, during every second of which the CLI
/// printed `· thinking…` and nothing else. This project already knows what that costs
/// — the retry notice exists because "three minutes of silence is indistinguishable
/// from a hang, and the reasonable response to a hang is to kill the run". A slow turn
/// is the same silence arriving a different way.
///
/// # Why an assembler rather than parsing inside the client
///
/// The awkward part of this dialect is that tool calls arrive in fragments: a name in
/// one chunk, then `arguments` as a run of string pieces that mean nothing until
/// concatenated, keyed by an `index` that is the only thing tying them together. Doing
/// that inline would put the fiddliest logic in the one place a test has to reach
/// through HTTP. Here it is a pure function over lines, and the whole failure surface
/// is exercised without a network.
public struct StreamAssembler {

    /// One tool call being built up across chunks.
    private struct PartialCall {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    private var text = ""
    private var refusal = ""
    private var finishReason: String?
    private var id: String?
    private var model: String?
    private var usage: JSONValue?
    /// Keyed by the stream's own `index`, which is the only handle it gives. A
    /// dictionary rather than an array because nothing guarantees the indices arrive
    /// in order, or start at zero.
    private var calls: [Int: PartialCall] = [:]

    public init() {}

    /// Whether the stream said it was finished.
    public private(set) var sawDone = false

    /// Feeds one line of the event stream.
    ///
    /// - Returns: newly arrived assistant text, if this line carried any, so a caller
    ///   can show it the moment it exists rather than at the end.
    @discardableResult
    public mutating func consume(line: String) -> String? {
        // SSE frames are `field: value`, and only `data:` carries payload. Comments
        // (`:` prefixed) are keep-alives some proxies send to hold the connection
        // open; treating one as JSON would end the stream on a heartbeat.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)

        // The terminator is a literal, not JSON. Decoding it fails silently and the
        // stream then looks truncated rather than finished.
        if payload == "[DONE]" { sawDone = true; return nil }
        guard !payload.isEmpty,
              let chunk = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        else { return nil }

        if let value = chunk["id"]?.stringValue { id = value }
        if let value = chunk["model"]?.stringValue { model = value }
        // Sent once, on a chunk of its own with no choices, when the request asked for
        // it. Overwrites rather than accumulates: it is a total, not a delta.
        if let value = chunk["usage"], value != .null { usage = value }

        guard let choice = chunk["choices"]?.arrayValue?.first else { return nil }
        if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }

        guard let delta = choice["delta"] else { return nil }
        if let value = delta["refusal"]?.stringValue { refusal += value }

        for call in delta["tool_calls"]?.arrayValue ?? [] {
            // Absent `index` means a runtime that sends one call per chunk whole;
            // folding those onto 0 would merge two distinct calls into one.
            let index = call["index"]?.doubleValue.map(Int.init) ?? calls.count
            var partial = calls[index] ?? PartialCall()
            if let value = call["id"]?.stringValue { partial.id = value }
            if let value = call["function"]?["name"]?.stringValue { partial.name = value }
            if let value = call["function"]?["arguments"]?.stringValue {
                // Appended, never replaced. This is the fragment that makes streaming
                // tool calls awkward: each piece is a slice of a JSON string and is
                // meaningless until the run is complete.
                partial.arguments += value
            }
            calls[index] = partial
        }

        guard let content = delta["content"]?.stringValue, !content.isEmpty else {
            return nil
        }
        text += content
        return content
    }

    /// The completion the stream described, in the shape the buffered path produces.
    ///
    /// Deliberately identical, so everything downstream — the response translation,
    /// the loop, the transcript — cannot tell which path produced it. A streamed run
    /// that differed from a buffered one in any way visible to the loop would be a
    /// second code path through the safety layer, which is the thing this client was
    /// built not to become.
    public func completion() -> JSONValue {
        var message: [String: JSONValue] = ["role": .string("assistant")]
        message["content"] = text.isEmpty ? .null : .string(text)
        if !refusal.isEmpty { message["refusal"] = .string(refusal) }
        if !calls.isEmpty {
            message["tool_calls"] = .array(calls.keys.sorted().map { index in
                let call = calls[index] ?? PartialCall()
                return .object([
                    "id": call.id.map(JSONValue.string) ?? .string("call_\(index)"),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name ?? ""),
                        "arguments": .string(call.arguments),
                    ]),
                ])
            })
        }
        var choice: [String: JSONValue] = ["index": .number(0), "message": .object(message)]
        // A stream that ended without saying why still has to answer the loop's
        // question. `tool_calls` when calls arrived, `stop` otherwise — the same
        // inference `stopReason` makes for a buffered response with no finish_reason.
        choice["finish_reason"] = .string(finishReason ?? (calls.isEmpty ? "stop" : "tool_calls"))

        var body: [String: JSONValue] = [
            "id": .string(id ?? "chatcmpl-stream"),
            "choices": .array([.object(choice)]),
        ]
        if let model { body["model"] = .string(model) }
        // Absent when the endpoint does not send it. Reporting zeros would be a
        // measurement, and a wrong one — `bench` and `CostMeter` both read these.
        if let usage { body["usage"] = usage }
        return .object(body)
    }
}

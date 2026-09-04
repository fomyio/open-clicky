import Testing
import Foundation
@testable import OpenClickyKit

/// Drives the loop against a scripted client so the batching, fail-fast and denial
/// semantics can be tested without an API round-trip. These are the behaviours that
/// decide whether the agent acts on a screen it has actually observed.
@Suite("Agent loop", .serialized)
struct AgentLoopTests {

    // MARK: - Test doubles

    /// Returns pre-scripted responses in order, recording the requests it received.
    private final class ScriptedClient: MessagesClient, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Wire.Response]
        private(set) var requests: [Wire.Request] = []

        init(_ responses: [Wire.Response]) { self.queue = responses }

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            guard !queue.isEmpty else {
                // The loop asked for more turns than the script provides; end cleanly
                // so a turn-limit test does not fail on an exhausted queue instead.
                return Self.response(stopReason: "end_turn", content: [.text("done")])
            }
            return queue.removeFirst()
        }

        static func response(
            stopReason: String, content: [Wire.ContentBlock], stopDetails: Wire.StopDetails? = nil
        ) -> Wire.Response {
            var fields: [String: JSONValue] = [
                "id": .string("msg_test"),
                "role": .string("assistant"),
                "model": .string("claude-opus-5"),
                "stop_reason": .string(stopReason),
                "usage": .object([
                    "input_tokens": .number(100), "output_tokens": .number(20),
                    "cache_read_input_tokens": .number(80),
                ]),
            ]
            let encoder = JSONEncoder()
            let blocks = try! JSONDecoder().decode(
                [JSONValue].self, from: try! encoder.encode(content)
            )
            fields["content"] = .array(blocks)
            if let stopDetails {
                fields["stop_details"] = .object([
                    "type": .string(stopDetails.type),
                    "category": stopDetails.category.map(JSONValue.string) ?? .null,
                    "explanation": stopDetails.explanation.map(JSONValue.string) ?? .null,
                ])
            }
            let data = try! encoder.encode(JSONValue.object(fields))
            return try! JSONDecoder().decode(Wire.Response.self, from: data)
        }

        static func toolCall(_ id: String, _ name: String, _ input: [String: JSONValue] = [:]) -> Wire.ContentBlock {
            .toolUse(id: id, name: name, input: .object(input))
        }
    }

    /// A tool whose behaviour and call count the test controls.
    private struct StubTool: Tool {
        let name: String
        let tier: Tier
        let description = "A stub tool used to drive the agent loop in tests."
        var inputSchema: JSONValue { .schema([:], required: []) }
        let riskValue: Risk
        let outcome: @Sendable () -> ToolOutput
        let recorder: CallRecorder

        func risk(for input: JSONValue) -> Risk { riskValue }

        func run(_ input: JSONValue) async throws -> ToolOutput {
            recorder.record(name)
            return outcome()
        }
    }

    /// Lets a stub tool trigger cancellation from inside its own execution, which is
    /// where a real ctrl-c would land.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?
        private var pending = false

        func onFire(_ action: @escaping () -> Void) {
            lock.lock()
            let shouldRunNow = pending
            self.action = action
            lock.unlock()
            if shouldRunNow { action() }
        }

        func fire() {
            lock.lock()
            let action = self.action
            pending = true
            lock.unlock()
            action?()
        }
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private func makeLoop(
        client: ScriptedClient,
        tools: [any Tool],
        mode: PermissionMode = .bypass,
        maxTurns: Int = 10,
        prompt: @escaping PermissionGate.Prompt = { _, _, _ in true },
        events: EventRecorder = EventRecorder()
    ) throws -> (AgentLoop, Transcript, EventRecorder) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-loop-\(UUID().uuidString)")
        let transcript = try Transcript(directory: directory)
        let loop = AgentLoop(
            client: client,
            registry: ToolRegistry(tools),
            gate: PermissionGate(mode: mode, prompt: prompt),
            transcript: transcript,
            mode: mode,
            config: .init(maxTurns: maxTurns),
            observer: { event in await events.record(event) }
        )
        return (loop, transcript, events)
    }

    private actor EventRecorder {
        private(set) var events: [AgentLoop.Event] = []
        func record(_ event: AgentLoop.Event) { events.append(event) }

        var skipped: [String] {
            events.compactMap { if case let .toolSkipped(name) = $0 { return name } else { return nil } }
        }
        var denied: [String] {
            events.compactMap { if case let .toolDenied(name, _) = $0 { return name } else { return nil } }
        }
        var finishReasons: [String] {
            events.compactMap { if case let .finished(reason) = $0 { return reason } else { return nil } }
        }
    }

    // MARK: - Happy path

    @Test("A tool call is executed and its result fed back")
    func executesToolCall() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [ScriptedClient.toolCall("t1", "probe")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("All done.")]),
        ])
        let tool = StubTool(
            name: "probe", tier: .shell, riskValue: .read,
            outcome: { .text("result-value") }, recorder: recorder
        )
        let (loop, transcript, _) = try makeLoop(client: client, tools: [tool])

        let answer = try await loop.run(task: "check something")
        #expect(answer == "All done.")
        #expect(recorder.calls == ["probe"])

        // The second request must carry the first turn's result back.
        let conversation = await transcript.conversation
        let resultTexts = conversation.flatMap { $0.content }.compactMap { block -> String? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined()
        }
        #expect(resultTexts.contains("result-value"))
    }

    /// Splitting results across messages teaches the model to stop batching, so the
    /// whole batch must come back in exactly one user message.
    @Test("All tool results for a turn go back in a single user message")
    func batchResultsShareOneMessage() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "alpha"),
                ScriptedClient.toolCall("t2", "beta"),
                ScriptedClient.toolCall("t3", "gamma"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tools: [any Tool] = ["alpha", "beta", "gamma"].map {
            StubTool(name: $0, tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder)
        }
        let (loop, transcript, _) = try makeLoop(client: client, tools: tools)
        _ = try await loop.run(task: "do three things")

        let userMessagesWithResults = await transcript.conversation.filter { message in
            message.role == .user && message.content.contains { block in
                if case .toolResult = block { return true }
                return false
            }
        }
        #expect(userMessagesWithResults.count == 1)
        #expect(userMessagesWithResults.first?.content.count == 3)
    }

    // MARK: - Fail-fast

    /// The model plans a batch against the state it last observed. Once a step fails
    /// that assumption is void, so the rest must not run against a screen it never saw.
    @Test("A failed call skips the rest of the batch")
    func failFastSkipsRemainder() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "first"),
                ScriptedClient.toolCall("t2", "second"),
                ScriptedClient.toolCall("t3", "third"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("recovered")]),
        ])
        let tools: [any Tool] = [
            StubTool(name: "first", tier: .shell, riskValue: .read,
                     outcome: { .failure("boom") }, recorder: recorder),
            StubTool(name: "second", tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder),
            StubTool(name: "third", tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder),
        ]
        let (loop, transcript, events) = try makeLoop(client: client, tools: tools)
        _ = try await loop.run(task: "chain")

        #expect(recorder.calls == ["first"], "nothing after the failure should execute")
        #expect(await events.skipped == ["second", "third"])

        // Skipped calls still need a tool_result, or their tool_use is orphaned.
        let results = await transcript.conversation.flatMap { $0.content }.compactMap { block -> (String, Bool)? in
            guard case let .toolResult(id, _, isError) = block else { return nil }
            return (id, isError)
        }
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.1 }, "the failure and both skips are all errors")
    }

    @Test("An unknown tool name fails the batch rather than being ignored")
    func unknownToolFailsBatch() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "nonexistent"),
                ScriptedClient.toolCall("t2", "real"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "real", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: recorder)
        let (loop, _, events) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "call something that does not exist")

        #expect(recorder.calls.isEmpty)
        #expect(await events.skipped == ["real"])
    }

    // MARK: - Permissions

    @Test("A denied call aborts the batch and reports the reason to the model")
    func denialAbortsBatch() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "mutate"),
                ScriptedClient.toolCall("t2", "after"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("understood")]),
        ])
        let tools: [any Tool] = [
            StubTool(name: "mutate", tier: .shell, riskValue: .write(summary: "change things"),
                     outcome: { .text("should not run") }, recorder: recorder),
            StubTool(name: "after", tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder),
        ]
        let (loop, transcript, events) = try makeLoop(
            client: client, tools: tools, mode: .ask, prompt: { _, _, _ in false }
        )
        _ = try await loop.run(task: "change something")

        #expect(recorder.calls.isEmpty, "a denied tool must never execute")
        #expect(await events.denied == ["mutate"])
        #expect(await events.skipped == ["after"])

        let text = await transcript.conversation.flatMap { $0.content }.compactMap { block -> String? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined()
        }.joined(separator: " ")
        #expect(text.contains("declined"), "the model needs to know it was the user's decision")
    }

    @Test("read-only mode refuses a mutating call without prompting")
    func readOnlyModeRefusesWithoutPrompt() async throws {
        let recorder = CallRecorder()
        let promptCalls = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [ScriptedClient.toolCall("t1", "mutate")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("ok")]),
        ])
        let tool = StubTool(name: "mutate", tier: .shell, riskValue: .write(summary: "write"),
                            outcome: { .text("ran") }, recorder: recorder)
        let (loop, _, _) = try makeLoop(
            client: client, tools: [tool], mode: .readOnly,
            prompt: { name, _, _ in promptCalls.record(name); return true }
        )
        _ = try await loop.run(task: "try to mutate")

        #expect(recorder.calls.isEmpty)
        #expect(promptCalls.calls.isEmpty, "read-only refuses outright, it does not ask")
    }

    // MARK: - Termination

    @Test("The turn limit bounds a loop that never finishes")
    func turnLimitIsEnforced() async throws {
        let recorder = CallRecorder()
        // Always asks for another tool call — without a cap this never terminates.
        let client = ScriptedClient(Array(repeating: ScriptedClient.response(
            stopReason: "tool_use", content: [ScriptedClient.toolCall("t", "spin")]
        ), count: 50))
        let tool = StubTool(name: "spin", tier: .shell, riskValue: .read,
                            outcome: { .text("again") }, recorder: recorder)
        let (loop, _, events) = try makeLoop(client: client, tools: [tool], maxTurns: 4)

        let answer = try await loop.run(task: "spin forever")
        #expect(recorder.calls.count == 4)
        #expect(answer.contains("Stopped after 4 turns"))
        #expect(await events.finishReasons.contains { $0.contains("turn limit") })
    }

    @Test("A refusal ends the loop and explains itself")
    func refusalTerminates() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(
                stopReason: "refusal", content: [],
                stopDetails: Wire.StopDetails(type: "refusal", category: "cyber", explanation: "declined")
            ),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])
        let answer = try await loop.run(task: "something refused")
        #expect(answer.contains("declined"))
        #expect(await events.finishReasons.contains { $0.contains("declined") })
    }

    @Test("A response with no tool calls ends the turn")
    func plainAnswerTerminates() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Nothing to do.")]),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [])
        #expect(try await loop.run(task: "hello") == "Nothing to do.")
    }

    // MARK: - Request shape

    @Test("Every request carries the cached system prefix and the tool block")
    func requestCarriesCacheBreakpoints() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "hello")

        let request = try #require(client.requests.first)
        #expect(request.system.count == 2)
        #expect(request.system[0].cacheControl, "the stable prefix must carry the breakpoint")
        #expect(!request.system[1].cacheControl)
        #expect(request.tools.last?.cacheControl == true)
        #expect(request.effort == "high")
    }

    /// Any session-specific text in the stable prefix would invalidate the cache on
    /// every turn, silently turning a cached prompt into a fully-billed one.
    @Test("The stable system prefix is byte-identical across turns")
    func stablePrefixDoesNotDrift() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [ScriptedClient.toolCall("t1", "probe")]),
            ScriptedClient.response(stopReason: "tool_use", content: [ScriptedClient.toolCall("t2", "probe")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "several turns")

        #expect(client.requests.count == 3)
        let prefixes = Set(client.requests.map(\.system[0].text))
        #expect(prefixes.count == 1, "the cached prefix drifted between turns")
    }

    @Test("The environment probe is attached to the task, not the system prompt")
    func probeRidesWithTheUserTurn() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [])
        _ = try await loop.run(task: "what am I looking at")

        let request = try #require(client.requests.first)
        let firstUserText = request.messages.first?.content.compactMap { block -> String? in
            if case let .text(t) = block { return t }
            return nil
        }.joined() ?? ""
        #expect(firstUserText.contains("<environment>"))
        #expect(firstUserText.contains("what am I looking at"))
        #expect(!request.system[0].text.contains("<environment>"))
    }

    @Test("Assistant turns are echoed back verbatim so thinking blocks survive")
    func assistantTurnsReplayUnchanged() async throws {
        let thinking = Wire.ContentBlock.thinking(text: "reasoning", signature: "sig-xyz")
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [thinking, ScriptedClient.toolCall("t1", "probe")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "think first")

        let replayed = client.requests[1].messages.flatMap(\.content).contains { block in
            if case let .thinking(_, signature) = block { return signature == "sig-xyz" }
            return false
        }
        #expect(replayed, "thinking blocks are bound to the model and must replay unchanged")
    }

    // MARK: - Interruption

    /// A batch can be a dozen clicks and keystrokes. Checking cancellation only once
    /// per turn would let the rest of them land after the user has asked to stop.
    @Test("Cancellation stops the batch at the next action boundary")
    func cancellationStopsMidBatch() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "first"),
                ScriptedClient.toolCall("t2", "second"),
                ScriptedClient.toolCall("t3", "third"),
            ]),
        ])

        // Cancelling the surrounding task is what ctrl-c does in the CLI.
        let cancelSignal = CancelBox()
        let tools: [any Tool] = [
            StubTool(name: "first", tier: .shell, riskValue: .read,
                     outcome: { cancelSignal.fire(); return .text("ok") }, recorder: recorder),
            StubTool(name: "second", tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder),
            StubTool(name: "third", tier: .shell, riskValue: .read,
                     outcome: { .text("ok") }, recorder: recorder),
        ]
        let (loop, transcript, events) = try makeLoop(client: client, tools: tools)

        let task = Task { try await loop.run(task: "several actions") }
        cancelSignal.onFire { task.cancel() }
        _ = try? await task.value

        #expect(recorder.calls == ["first"], "actions after the stop must not run")
        #expect(await events.events.contains { if case .interrupted = $0 { return true }; return false })

        // Interrupted calls still need a result, or their tool_use is orphaned.
        let results = await transcript.conversation.flatMap { $0.content }.filter { block in
            if case .toolResult = block { return true }
            return false
        }
        #expect(results.count == 3)
    }

    @Test("An interrupted run still reports what it did")
    func interruptedRunReportsCleanly() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                .text("Starting now."),
                ScriptedClient.toolCall("t1", "act"),
            ]),
        ])
        let cancelSignal = CancelBox()
        let tool = StubTool(name: "act", tier: .shell, riskValue: .read,
                            outcome: { cancelSignal.fire(); return .text("ok") },
                            recorder: CallRecorder())
        let (loop, _, events) = try makeLoop(client: client, tools: [tool])

        let task = Task { try await loop.run(task: "do it") }
        cancelSignal.onFire { task.cancel() }
        let answer = try? await task.value

        #expect(answer == "Starting now.", "the model's own words survive the interruption")
        #expect(await events.finishReasons.contains { $0.contains("interrupted") })
    }

    @Test("Usage is reported for every turn")
    func reportsUsage() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])
        _ = try await loop.run(task: "hello")

        let usage = await events.events.compactMap { event -> (Int, Int, Int)? in
            if case let .usage(input, output, cache) = event { return (input, output, cache) }
            return nil
        }
        #expect(usage.count == 1)
        #expect(usage.first?.0 == 100)
        #expect(usage.first?.2 == 80)
    }
}

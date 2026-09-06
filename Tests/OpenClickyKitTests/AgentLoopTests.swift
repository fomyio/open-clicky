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
    ///
    /// An actor rather than a lock: `send` is async, and holding a lock across a
    /// suspension point is exactly the hazard Swift 6 refuses to compile.
    private actor ScriptedClient: MessagesClient {
        private var queue: [Wire.Response]
        private(set) var requests: [Wire.Request] = []

        init(_ responses: [Wire.Response]) { self.queue = responses }

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            requests.append(request)
            guard !queue.isEmpty else {
                // The loop asked for more turns than the script provides; end cleanly
                // so a turn-limit test does not fail on an exhausted queue instead.
                return Self.response(stopReason: "end_turn", content: [.text("done")])
            }
            return queue.removeFirst()
        }

        nonisolated static func response(
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

        nonisolated static func toolCall(_ id: String, _ name: String, _ input: [String: JSONValue] = [:]) -> Wire.ContentBlock {
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
        prompt: @escaping PermissionGate.Prompt = { _, _, _ in .allow },
        events: EventRecorder = EventRecorder(),
        frontmost: @escaping @Sendable () -> String? = { "com.example.ordinary" },
        captureOwner: @escaping @Sendable () -> String? = { "com.example.ordinary" }
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
            observer: { event in await events.record(event) },
            frontmostBundleIdentifier: frontmost,
            targetBundleIdentifier: captureOwner
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
            client: client, tools: tools, mode: .ask, prompt: { _, _, _ in .deny }
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
            prompt: { name, _, _ in promptCalls.record(name); return .allow }
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

    /// A reply cut off at the token limit is not a finished answer. Reporting it as
    /// one hands the user half a reply with nothing to indicate the rest is missing.
    @Test("A truncated reply is reported as truncated, not as an answer")
    func truncationIsSurfaced() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(
                stopReason: "max_tokens",
                content: [.text("Here is the first part of the ans")]
            ),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])
        let answer = try await loop.run(task: "explain everything")

        #expect(answer.contains("Here is the first part"), "the partial reply is still shown")
        #expect(answer.contains("cut off"), "and it must be marked as incomplete")
        #expect(await events.finishReasons.contains { $0.contains("truncated") })
    }

    @Test("Truncation before any output still explains what happened")
    func truncationWithNoOutput() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "max_tokens", content: []),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [])
        let answer = try await loop.run(task: "explain everything")
        #expect(answer.contains("cut off"))
    }

    /// Truncation that still carried tool calls can proceed — but the model's
    /// reasoning was clipped and it should not assume its plan arrived intact.
    @Test("Tool calls that survive truncation still run")
    func truncationWithToolCallsContinues() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "max_tokens", content: [
                .text("Checking"), ScriptedClient.toolCall("t1", "probe"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: recorder)
        let (loop, _, events) = try makeLoop(client: client, tools: [tool])
        let answer = try await loop.run(task: "check")

        #expect(recorder.calls == ["probe"])
        #expect(answer == "done")
        let texts = await events.events.compactMap { event -> String? in
            if case let .assistantText(t) = event { return t }
            return nil
        }
        #expect(texts.contains { $0.contains("truncated") }, "the clipped reasoning must be flagged")
    }

    /// The observer draws to the user's terminal and nothing else. Flagging the
    /// truncation there told the human and left the model believing its plan had
    /// arrived intact — so it carried on from a turn whose second half was thrown
    /// away, with no reason to re-check anything.
    @Test("The model is told its reply was truncated, not just the user")
    func truncationNoticeReachesTheModel() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "max_tokens", content: [
                .text("Checking"), ScriptedClient.toolCall("t1", "probe"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "check")

        // The second request is the one carrying the results of the truncated turn.
        let requests = await client.requests
        let content = try #require(requests.last?.messages.last?.content)

        let notices = content.compactMap { block -> String? in
            if case let .text(text) = block { return text }
            return nil
        }
        #expect(notices.contains { $0.contains("cut off") },
                "the model was never told the turn was truncated")

        // The API rejects a message whose tool_results do not come first.
        let firstText = content.firstIndex { if case .text = $0 { return true }; return false }
        let lastResult = content.lastIndex { if case .toolResult = $0 { return true }; return false }
        if let firstText, let lastResult {
            #expect(lastResult < firstText, "a text block was placed before a tool_result")
        }
    }

    /// The run stops at a fixed turn count. Until the model was told, it was severed
    /// mid-plan and the user got "Stopped after 40 turns without finishing" — a run
    /// with no report of what had actually been done. A model that knows it has one
    /// turn left spends it summarising.
    @Test("The model is warned before the turn limit cuts it off")
    func turnLimitIsAnnounced() async throws {
        let toolUse = ScriptedClient.response(stopReason: "tool_use", content: [
            ScriptedClient.toolCall("t1", "probe"),
        ])
        let client = ScriptedClient(Array(repeating: toolUse, count: 4))
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool], maxTurns: 3)
        _ = try await loop.run(task: "work")

        let requests = await client.requests
        #expect(requests.count == 3)

        /// Notices ride in the message that answers a tool_use, never in the task.
        func notices(in request: Wire.Request) -> [String] {
            request.messages
                .filter { $0.content.contains { if case .toolResult = $0 { return true }; return false } }
                .flatMap(\.content)
                .compactMap { if case let .text(text) = $0 { return text }; return nil }
        }

        // A notice appended after turn N is read by the model in request N+1, so the
        // warning has to reach the final request — the one whose reply is the last
        // thing the user will see.
        #expect(notices(in: requests[2]).contains { $0.contains("1 turn left") },
                "the model was never warned it was about to be cut off")
        #expect(!notices(in: requests[1]).contains { $0.contains("turn left") },
                "warned while two turns still remained")
    }

    /// The general property behind the off-by-one: the loop appends notices to the
    /// results message, and on the final iteration it exits immediately afterwards.
    /// Anything written there is read by nobody, so a notice placed on the last turn
    /// is not a warning — it is a string composed into a transcript and abandoned.
    @Test("No notice is written on a turn nothing will read")
    func noNoticeOnTheFinalTurn() async throws {
        let toolUse = ScriptedClient.response(stopReason: "tool_use", content: [
            ScriptedClient.toolCall("t1", "probe"),
        ])
        let client = ScriptedClient(Array(repeating: toolUse, count: 4))
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, transcript, _) = try makeLoop(client: client, tools: [tool], maxTurns: 3)
        _ = try await loop.run(task: "work")

        // The record ends with the results of the final turn; nothing follows it.
        let conversation = await transcript.conversation(policy: .unpruned)
        let final = try #require(conversation.last)
        #expect(final.role == .user, "the run should end on the last results message")
        #expect(!final.content.contains { if case .text = $0 { return true }; return false },
                "a notice was written on a turn no request will ever carry")
    }

    /// A turn that was not truncated must not carry the warning.
    @Test("An intact turn sends no truncation notice")
    func intactTurnHasNoNotice() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "probe"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "check")

        let requests = await client.requests
        let content = requests.last?.messages.last?.content ?? []
        #expect(!content.contains { if case .text = $0 { return true }; return false },
                "an untruncated turn should send tool_results and nothing else")
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

        let requests = await client.requests
        let request = try #require(requests.first)
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

        #expect(await client.requests.count == 3)
        let prefixes = Set(await client.requests.map(\.system[0].text))
        #expect(prefixes.count == 1, "the cached prefix drifted between turns")
    }

    /// The tier costs steer every choice the model makes about which capability to
    /// reach for, so they have to be true. Two of them were not — tier 2 was described
    /// as "a few hundred tokens" when a capture of a busy window is about 1,100, and a
    /// screenshot as 1,500 vision tokens when a 1920px image is about 2,000. A model
    /// that notices the guidance is wrong has reason to discount all of it.
    @Test("The ladder's stated costs match what the tiers actually cost")
    func ladderCostsAreAccurate() {
        let registry = ToolRegistry([
            ShellTool(), AppleScriptTool(), AXCaptureTool(), ScreenshotTool(),
        ])
        let prompt = SystemPrompt.stable(registry: registry)

        #expect(prompt.contains("no vision tokens"), "tiers 0 and 1 are genuinely free of them")
        #expect(prompt.contains("~1,000 tokens"), "measured: ~1,143 for a 264-node window")
        #expect(prompt.contains("~2,000 vision tokens"), "measured: 2,055 for 1920x803")
        #expect(!prompt.contains("1,500"), "the old understated figure must be gone")
        #expect(!prompt.contains("few hundred"), "so must the old tier-2 claim")
    }

    /// Read the prompt the model actually receives, not the source that produces it.
    ///
    /// Swift keeps whatever indentation a continued line carries beyond the closing
    /// delimiter, so nineteen bullets reached the model as "and `ax_press`   report
    /// what changed". It compiled, every test passed, and only printing the string
    /// showed it — which is the point: some defects are only visible in the output.
    @Test("The prompt reaches the model without stray whitespace")
    func promptIsCleanlyFormatted() {
        let registry = ToolRegistry([ShellTool(), AppleScriptTool(), AXCaptureTool(), ScreenshotTool()])
        let prompt = SystemPrompt.stable(registry: registry)

        for line in prompt.split(separator: "\n") {
            #expect(line.range(of: #"\S\s{2,}\S"#, options: .regularExpression) == nil,
                    "stray whitespace: \(line.prefix(80))")
            #expect(!line.hasSuffix(" "), "trailing space: \(line.prefix(60))")
        }
        #expect(!prompt.contains("\\\n"), "a line continuation survived into the output")
    }

    /// A prompt that misdescribes the machine misleads every decision made from it.
    @Test("The prompt describes the containment that actually exists")
    func promptDescribesRealContainment() {
        let prompt = SystemPrompt.stable(registry: ToolRegistry([ShellTool()]))

        // Shell commands do run under sandbox-exec; saying otherwise was simply wrong.
        #expect(!prompt.contains("There is no sandbox"))
        #expect(prompt.contains("run confined"), "the shell's confinement should be stated")
        #expect(prompt.contains("undoable") || prompt.contains("no undo"),
                "and the absence of undo, which is the part that is true")
    }

    /// Rendering the request and reading it showed "Permission mode: ask — ask — you
    /// approve each action": the explanation began with the mode's own name, and the
    /// caller prefixed it too. Every session carried the duplication.
    @Test("The session prompt names each mode once", arguments: PermissionMode.allCases)
    func sessionPromptDoesNotRepeatTheModeName(mode: PermissionMode) {
        let session = SystemPrompt.session(
            mode: mode, permissions: PermissionStatus(screenRecording: true, accessibility: true)
        )
        let line = session.split(separator: "\n").first { $0.hasPrefix("Permission mode") }
        let rendered = String(try! #require(line))

        #expect(rendered.hasPrefix("Permission mode: \(mode.rawValue) — "))
        // Not a naive substring count: "auto" occurs inside "automatically", and the
        // defect was specifically the name repeated immediately after itself.
        let explanation = rendered.replacingOccurrences(
            of: "Permission mode: \(mode.rawValue) — ", with: ""
        )
        #expect(!explanation.hasPrefix(mode.rawValue), "duplicated: \(rendered)")
        #expect(!explanation.isEmpty, "the mode was named but not explained")
    }

    /// The cached block is billed in full on the first turn of every session.
    @Test("The cached prefix stays within a sensible budget")
    func cachedBlockIsNotBloated() throws {
        let registry = ToolRegistry([
            ShellTool(), ReadFileTool(), WriteFileTool(), AppleScriptTool(), ShortcutsTool(),
            AXCaptureTool(), AXPressTool(), AXSetValueTool(), ScreenshotTool(), ZoomTool(),
            ClickTool(), DragTool(), TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
        ])
        let prompt = SystemPrompt.stable(registry: registry)
        let schemas = try JSONEncoder().encode(registry.definitions)

        // ~4,100 tokens today: ~900 of prompt and ~3,200 of tool schemas.
        #expect((prompt.count + schemas.count) / 4 < 6_000,
                "cached block is \((prompt.count + schemas.count) / 4) tokens")
    }

    /// Every pruning test exercised `Transcript.conversation(policy:)` directly, so
    /// nothing noticed whether the loop actually called it — a mutation sending the
    /// unpruned conversation passed the entire suite. The transcript's behaviour and
    /// the loop's use of it are separate facts and both need asserting.
    @Test("The loop sends the pruned conversation, not the whole transcript")
    func loopSendsPrunedContext() async throws {
        let image = String(repeating: "A", count: 20_000)

        // Five screenshot turns, then a plain answer.
        var turns: [[Wire.ContentBlock]] = []
        for index in 1...5 {
            turns.append([ScriptedClient.toolCall("shot\(index)", "screenshot")])
        }

        let client = ScriptedClient(turns.map {
            ScriptedClient.response(stopReason: "tool_use", content: $0)
        })
        let recorder = CallRecorder()
        let tool = StubTool(
            name: "screenshot", tier: .pixels, riskValue: .read,
            outcome: { .image(mediaType: "image/jpeg", base64: image) },
            recorder: recorder
        )
        let (loop, _, _) = try makeLoop(client: client, tools: [tool], maxTurns: 7)
        _ = try await loop.run(task: "look repeatedly")

        // The final request carries five turns of history but only the recent images.
        let requests = await client.requests
        let last = try #require(requests.last)
        let imagesSent = last.messages.flatMap(\.content).reduce(into: 0) { total, block in
            guard case let .toolResult(_, content, _) = block else { return }
            total += content.filter(\.isImage).count
        }
        #expect(imagesSent <= 2, "the loop sent \(imagesSent) images; pruning was skipped")

        // And the elision note is present, proving the older ones were replaced
        // rather than simply absent.
        let text = last.messages.flatMap(\.content).compactMap { block -> String? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }
                .joined()
        }.joined(separator: " ")
        #expect(text.contains("take a new screenshot"), "older images should leave guidance")

        // Every tool_use still has its result, so pruning did not break the request.
        let uses = Set(last.messages.flatMap(\.content).compactMap { block -> String? in
            if case let .toolUse(id, _, _) = block { return id }
            return nil
        })
        let results = Set(last.messages.flatMap(\.content).compactMap { block -> String? in
            if case let .toolResult(id, _, _) = block { return id }
            return nil
        })
        #expect(uses == results)
    }

    @Test("The environment probe is attached to the task, not the system prompt")
    func probeRidesWithTheUserTurn() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [])
        _ = try await loop.run(task: "what am I looking at")

        let requests = await client.requests
        let request = try #require(requests.first)
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

        let replayed = await client.requests[1].messages.flatMap(\.content).contains { block in
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

    /// The cost line is the only feedback a user gets on what a task is costing, and
    /// the only signal that prompt caching is working. Found by mutation: the meter
    /// could stop recording entirely and nothing objected.
    @Test("Cost reflects the tokens actually reported")
    func costTracksReportedUsage() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [ScriptedClient.toolCall("t1", "probe")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "probe", tier: .shell, riskValue: .read,
                            outcome: { .text("ok") }, recorder: CallRecorder())
        let (loop, _, events) = try makeLoop(client: client, tools: [tool])
        _ = try await loop.run(task: "measure me")

        let meters = await events.events.compactMap { event -> CostMeter? in
            if case let .cost(meter) = event { return meter }
            return nil
        }
        let final = try #require(meters.last)

        // The scripted client reports 100 in / 20 out / 80 cached per turn, twice.
        #expect(final.turns == 2)
        #expect(final.inputTokens == 200)
        #expect(final.outputTokens == 40)
        #expect(final.cacheReadTokens == 160)
        #expect(final.totalCost > 0, "a run that used tokens must cost something")

        // And it accumulates rather than reporting only the last turn.
        #expect(meters.count == 2)
        #expect(meters[0].inputTokens < final.inputTokens)
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

    // MARK: - The cache breakpoint

    /// `stable` carries the prompt cache breakpoint, so anything session-specific in
    /// it re-bills the whole prefix every turn. CLAUDE.md names this as an invariant
    /// that fails silently, and the mutation sweep found nothing defending it: a
    /// `\(Date())` spliced into the first line went entirely unnoticed. It is the same
    /// class as the tool-schema ordering bug — nothing breaks, the bill just grows.
    @Test("The cached prompt does not vary between calls")
    func stablePromptDoesNotDrift() async throws {
        let registry = Invocation().registry
        let first = SystemPrompt.stable(registry: registry)
        try await Task.sleep(for: .milliseconds(1100))
        let second = SystemPrompt.stable(registry: registry)
        #expect(first == second, "the cached prefix changed between two calls")
    }

    /// The same property stated a second way, because equality alone only catches
    /// drift fast enough to show up between two calls — a value that changes hourly,
    /// or per machine, or per user, would slip through it entirely.
    @Test("The cached prompt carries nothing specific to this machine or moment")
    func stablePromptHasNoSessionState() {
        let prompt = SystemPrompt.stable(registry: Invocation().registry)
        let environment = ProcessInfo.processInfo.environment

        let forbidden: [(String, String)] = [
            ("the user's home directory", FileManager.default.homeDirectoryForCurrentUser.path),
            ("the user name", NSUserName()),
            ("the host name", ProcessInfo.processInfo.hostName),
            ("the process id", String(ProcessInfo.processInfo.processIdentifier)),
            ("the current year", String(Calendar.current.component(.year, from: Date()))),
            ("a shell path", environment["SHELL"] ?? "\u{0}absent"),
        ]
        for (what, value) in forbidden where !value.isEmpty {
            #expect(!prompt.contains(value),
                    "\(what) is in the cached prefix, which re-bills it every turn")
        }
    }

    /// Session state belongs in the block after the breakpoint, and has to actually be
    /// there — an invariant with two halves, and testing only the first would let the
    /// mode quietly stop reaching the model at all.
    @Test("Permission mode reaches the model, but not through the cached block")
    func sessionStateLivesAfterTheBreakpoint() {
        let registry = Invocation().registry
        for mode in PermissionMode.allCases {
            let session = SystemPrompt.session(
                mode: mode, permissions: PermissionStatus(screenRecording: true, accessibility: true)
            )
            #expect(session.contains(mode.rawValue), "\(mode.rawValue) never reaches the model")
            #expect(!SystemPrompt.stable(registry: registry).contains(mode.explanation),
                    "the mode's explanation is inside the cached block")
        }
    }

    /// The wiring, not the part. `Policy.escalate` was covered by four tests and the
    /// loop's call to it by none, so the sweep could delete the call and nothing
    /// objected — the agent free to press "Allow" on its own consent dialog in auto
    /// mode. Testing that a capability works is not testing that it is reached.
    @Test("The loop refuses to act on a consent dialog without asking")
    func consentDialogsEscalateThroughTheLoop() async throws {
        let asked = Prompts()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "press"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "press", tier: .accessibility,
                            riskValue: .write(summary: "AXPress on Button \"Allow\""),
                            outcome: { .text("pressed") }, recorder: CallRecorder())

        // auto mode runs writes silently and stops for destructive actions, which is
        // the whole distinction this escalation turns on.
        let (loop, _, _) = try makeLoop(
            client: client, tools: [tool], mode: .auto,
            prompt: { _, _, _ in await asked.record(); return .deny },
            frontmost: { "com.apple.UserNotificationCenter" }
        )
        _ = try await loop.run(task: "allow it")

        #expect(await asked.count == 1, "the agent answered a consent dialog unprompted")
    }

    @Test("An ordinary window still runs writes silently in auto mode")
    func ordinaryWindowsAreUnaffectedThroughTheLoop() async throws {
        let asked = Prompts()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "press"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "press", tier: .accessibility,
                            riskValue: .write(summary: "AXPress on Button \"Save\""),
                            outcome: { .text("pressed") }, recorder: CallRecorder())
        let (loop, _, _) = try makeLoop(
            client: client, tools: [tool], mode: .auto,
            prompt: { _, _, _ in await asked.record(); return .allow },
            frontmost: { "com.apple.TextEdit" }
        )
        _ = try await loop.run(task: "save")

        #expect(await asked.count == 0, "auto mode stopped for an ordinary write")
    }

    private actor Prompts {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// The audit's worst finding, and the third time this session that a helper was
    /// tested while the wiring to it was not. `ax_capture` takes a bundle_identifier
    /// and reads that app instead of the frontmost one; an accessibility action drives
    /// an element without activating its app. So the agent can read a consent dialog
    /// while Finder is frontmost, press "Allow", and a frontmost-only check sees
    /// nothing — using a documented parameter, not a trick.
    @Test("Pressing an element owned by a consent dialog asks, whatever is frontmost")
    func capturedSecuritySurfaceEscalatesThroughTheLoop() async throws {
        let asked = Prompts()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "press"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let tool = StubTool(name: "press", tier: .accessibility,
                            riskValue: .write(summary: "AXPress on Button \"Allow\""),
                            outcome: { .text("pressed") }, recorder: CallRecorder())

        let (loop, _, _) = try makeLoop(
            client: client, tools: [tool], mode: .auto,
            prompt: { _, _, _ in await asked.record(); return .deny },
            frontmost: { "com.apple.finder" },
            captureOwner: { "com.apple.UserNotificationCenter" }
        )
        _ = try await loop.run(task: "allow it")

        #expect(await asked.count == 1,
                "the agent pressed a consent dialog it had captured by bundle id")
    }

    // MARK: - The prompt must match the toolset

    /// `--max-tier` is documented as a hard ceiling: a capped tool is absent from the
    /// registry, not merely discouraged. The advice after the ladder was a fixed
    /// block, so under `--max-tier 0` a model with three tools was told it had "four
    /// tiers", that clicking Save is `ax_capture` then `ax_press`, and to consider
    /// whether a screenshot was warranted. It cannot do any of those, so the prompt
    /// was sending it after tools that answer "no tool named".
    @Test("The prompt never names a tier the run does not have", arguments: [
        (Tier.shell, ["ax_capture", "ax_press", "screenshot", "app_script"]),
        (.script, ["ax_capture", "ax_press", "screenshot"]),
        (.accessibility, ["screenshot", "zoom"]),
    ])
    func promptOmitsUnavailableTiers(pair: (Tier, [String])) {
        var invocation = Invocation()
        invocation.maxTier = pair.0
        let prompt = SystemPrompt.stable(registry: invocation.registry)

        for absent in pair.1 {
            #expect(!prompt.contains("`\(absent)`"),
                    "tier \(pair.0.rawValue) prompt recommends \(absent), which is not in the registry")
        }
    }

    /// The full toolset must still get the full advice — trimming by tier is only
    /// correct if nothing is lost when nothing is capped.
    @Test("At full capability the prompt keeps every example")
    func fullPromptKeepsEverything() {
        let prompt = SystemPrompt.stable(registry: Invocation().registry)
        for expected in ["`shell`", "`app_script`", "`ax_capture`", "`ax_press`", "`screenshot`"] {
            #expect(prompt.contains(expected), "the uncapped prompt lost \(expected)")
        }
        #expect(prompt.contains("Before taking a screenshot"))
        #expect(prompt.contains("four tiers"))
    }

    /// A capped run should be told it is capped. A task needing a missing tier is
    /// then a limit to report rather than a puzzle to work around.
    @Test("A capped run is told the ceiling exists", arguments: [Tier.shell, .script, .accessibility])
    func cappedRunsAreToldTheCeiling(tier: Tier) {
        var invocation = Invocation()
        invocation.maxTier = tier
        let prompt = SystemPrompt.stable(registry: invocation.registry)
        #expect(prompt.contains("capped at tier \(tier.rawValue)"))
    }

    /// "Your tools sit on one tiers, cheapest first" — the plural, and an ordering
    /// claim about a single item.
    @Test("The tier count is grammatical at every cap", arguments: [
        (Tier.shell, "one tier —"), (.script, "two tiers"),
        (.accessibility, "three tiers"), (.pixels, "four tiers"),
    ])
    func tierCountIsGrammatical(pair: (Tier, String)) {
        var invocation = Invocation()
        invocation.maxTier = pair.0
        let prompt = SystemPrompt.stable(registry: invocation.registry)
        #expect(prompt.contains(pair.1), "expected \(pair.1)")
        #expect(!prompt.contains("one tiers"))
    }

    /// The mode was named and its consequences left to be inferred. A read-only run
    /// still holds `write_file`, `click`, `type` and six more that can never succeed,
    /// and the only way to learn that was to spend turns being refused.
    @Test("read-only says that acting is impossible, not merely gated")
    func readOnlySpellsOutTheConsequence() {
        let block = SystemPrompt.session(
            mode: .readOnly,
            permissions: PermissionStatus(screenRecording: true, accessibility: true)
        )
        #expect(block.contains("Only observation is possible"))
        #expect(block.contains("say what it is and stop"))
    }

    /// bypass removes the backstop entirely, including the guard against the agent
    /// approving its own permission dialogs. The model is the only remaining judgement
    /// in the loop, and it should know that.
    @Test("bypass says there will be no prompt to stop anything")
    func bypassSaysThereIsNoBackstop() {
        let block = SystemPrompt.session(
            mode: .bypass,
            permissions: PermissionStatus(screenRecording: true, accessibility: true)
        )
        #expect(block.contains("Nothing will stop you"))
        #expect(block.contains("irreversible"))
    }

    /// The two modes with a working prompt need no extra paragraph — the user is still
    /// in the loop, and a warning on every run is a warning nobody reads.
    @Test("ask and auto stay terse", arguments: [PermissionMode.ask, .auto])
    func workingModesStayTerse(mode: PermissionMode) {
        let block = SystemPrompt.session(
            mode: mode,
            permissions: PermissionStatus(screenRecording: true, accessibility: true)
        )
        #expect(block.count < 120, "the \(mode.rawValue) block grew a paragraph")
        #expect(block.contains(mode.rawValue))
    }

    /// Phrased without naming tools on purpose: naming them is how the capability
    /// ladder came to describe tools a capped run does not have.
    @Test("The mode advice names no tool", arguments: PermissionMode.allCases)
    func modeAdviceNamesNoTool(mode: PermissionMode) {
        let block = SystemPrompt.session(
            mode: mode,
            permissions: PermissionStatus(screenRecording: true, accessibility: true)
        )
        for tool in ["`click`", "`write_file`", "`screenshot`", "`ax_press`", "`type`"] {
            #expect(!block.contains(tool),
                    "\(mode.rawValue) names \(tool), which a capped run may not have")
        }
    }
}

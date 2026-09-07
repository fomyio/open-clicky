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

    /// Fails the first request and answers the rest, so a planner can be unreachable
    /// while the executor is not.
    private actor FailingFirstClient: MessagesClient {
        private var sent = 0
        private let later: Wire.Response
        private(set) var requests: [Wire.Request] = []

        init(then later: Wire.Response) { self.later = later }

        struct Unreachable: Swift.Error {}

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            requests.append(request)
            sent += 1
            if sent == 1 { throw Unreachable() }
            return later
        }
    }

    /// Refuses every request, so a run can die the way an unreachable or
    /// incompatible endpoint makes it die.
    private actor AlwaysFailingClient: MessagesClient {
        struct Refused: Swift.Error, CustomStringConvertible {
            let detail: String
            var description: String { "Refused: \(detail)" }
        }
        private let detail: String
        init(detail: String = "does not support tools") { self.detail = detail }
        func send(_ request: Wire.Request) async throws -> Wire.Response {
            throw Refused(detail: detail)
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
        client: any MessagesClient,
        tools: [any Tool],
        mode: PermissionMode = .bypass,
        maxTurns: Int = 10,
        prompt: @escaping PermissionGate.Prompt = { _, _, _ in .allow },
        events: EventRecorder = EventRecorder(),
        frontmost: @escaping @Sendable () -> String? = { "com.example.ordinary" },
        captureOwner: @escaping @Sendable () -> String? = { "com.example.ordinary" },
        planner: Planner? = nil
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
            config: .init(maxTurns: maxTurns, planner: planner),
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
        var costs: [CostMeter] {
            events.compactMap { if case let .cost(meter) = $0 { return meter } else { return nil } }
        }
        var planningFailures: [(model: String, reason: String)] {
            events.compactMap {
                if case let .planningFailed(model, reason) = $0 { return (model, reason) }
                return nil
            }
        }
        var plans: [String] {
            events.compactMap { if case let .planned(_, plan) = $0 { return plan } else { return nil } }
        }
        var outcomes: [RunOutcome] {
            events.compactMap { if case let .outcome(outcome) = $0 { return outcome } else { return nil } }
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

    /// The ladder only ever pushed downward, and one run read that as final: an
    /// AppleScript keystroke came back denied and the model reported that it could not
    /// send keyboard input at all, while `ax_press` and `key` — a different permission
    /// entirely — sat unused in its own registry.
    @Test("The prompt says to escalate after a failure, not only to start low")
    func promptTeachesEscalationAfterFailure() {
        let registry = ToolRegistry([
            ShellTool(), AppleScriptTool(), AXCaptureTool(), ScreenshotTool(), KeyTool(),
        ])
        let prompt = SystemPrompt.stable(registry: registry)

        #expect(prompt.contains("tells you about that route, not about the task"))
        #expect(prompt.contains("try it before concluding"))
        #expect(prompt.contains("every tier available to you has actually been tried"))
        // And the rule it must not have replaced.
        #expect(prompt.contains("Always use the lowest tier"))
    }

    /// Nothing to escalate to when there is one tier, and advice to climb a ladder
    /// that is not there is the same defect as describing absent tools.
    @Test("A shell-only run is not told to escalate")
    func promptOmitsEscalationWithoutHigherTiers() {
        let prompt = SystemPrompt.stable(registry: ToolRegistry([ShellTool(), ReadFileTool()]))

        #expect(!prompt.contains("tells you about that route"))
        #expect(!prompt.contains("the tier above it"))
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

    // MARK: - The prompt for a model that cannot see

    /// A small local model handed the ladder alone reasons about a screen it cannot
    /// see and asks for a screenshot it will never receive. Told that the
    /// accessibility tree *is* its perception, it goes straight to `ax_capture`.
    @Test("A grounded run is told the tree is its perception")
    func groundedPromptLeansOnElementIDs() {
        var invocation = Invocation()
        invocation.model = "llama3.3"
        let prompt = SystemPrompt.stable(
            registry: invocation.registry, grounding: .forModel(invocation.model)
        )

        #expect(prompt.contains("cannot see the screen"))
        #expect(prompt.contains("`ax_capture`"))
        #expect(prompt.contains("`ax_press`"))
        #expect(prompt.contains("`ax_set_value`"))
        // And never sends it after a tool that is not loaded.
        for absent in ["`screenshot`", "`zoom`", "`click`", "`type`", "`key`"] {
            #expect(!prompt.contains(absent), "the grounded prompt recommends \(absent)")
        }
    }

    /// The visual prompt must be byte-identical to the one before the variant existed:
    /// a prefix that changed shape for every run to serve a minority of them would
    /// re-bill the cache for everyone.
    @Test("A visual run's prompt is untouched by the variant")
    func visualPromptIsUnchanged() {
        let registry = Invocation().registry
        #expect(SystemPrompt.stable(registry: registry)
                == SystemPrompt.stable(registry: registry, grounding: .visual))
        #expect(!SystemPrompt.stable(registry: registry).contains("cannot see the screen"))
    }

    /// Derived from the model, never chosen, so the prompt cannot claim a perception
    /// the registry does not back.
    @Test("Grounding follows the model", arguments: [
        ("claude-opus-5", false), ("gpt-4o", false),
        ("llama3.3", true), ("gpt-3.5-turbo", true),
    ])
    func groundingFollowsTheModel(scenario: (String, Bool)) {
        var invocation = Invocation()
        invocation.model = scenario.0
        let prompt = SystemPrompt.stable(
            registry: invocation.registry, grounding: .forModel(scenario.0)
        )
        #expect(prompt.contains("cannot see the screen") == scenario.1)
    }

    /// The section is gated on the registry too, so `--max-tier 1` against a blind
    /// model does not describe a three-step workflow whose tools are all absent.
    @Test("A grounded run with no accessibility tier says nothing about the tree")
    func groundedSectionRespectsTheTierCap() {
        var invocation = Invocation()
        invocation.model = "llama3.3"
        invocation.maxTier = .script
        let prompt = SystemPrompt.stable(
            registry: invocation.registry, grounding: .elementsOnly
        )
        #expect(!prompt.contains("cannot see the screen"))
    }

    /// The cache invariant, restated for the variant: it is a property of the model,
    /// fixed before the first request, so it must not drift between turns either.
    @Test("The grounded prompt does not drift or carry session state")
    func groundedPromptIsStable() async throws {
        var invocation = Invocation()
        invocation.model = "llama3.3"
        let registry = invocation.registry
        let first = SystemPrompt.stable(registry: registry, grounding: .elementsOnly)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(first == SystemPrompt.stable(registry: registry, grounding: .elementsOnly))
        #expect(!first.contains(NSUserName()))
        #expect(!first.contains(String(Calendar.current.component(.year, from: Date()))))
    }

    /// The wiring, not the part. `Grounding.forModel` existing and the loop calling it
    /// are separate facts, and the sweep would call an unreached one NOT CAUGHT.
    @Test("The loop sends the grounded prompt for a model that cannot see")
    func loopSendsTheGroundedPrompt() async throws {
        var invocation = Invocation()
        invocation.model = "llama3.3"
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let loop = AgentLoop(
            client: client,
            registry: invocation.registry,
            gate: PermissionGate(mode: .readOnly) { _, _, _ in .allow },
            transcript: try Transcript(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("openclicky-grounded-\(UUID().uuidString)")
            ),
            mode: .readOnly,
            config: invocation.loopConfiguration,
            observer: { _ in },
            frontmostBundleIdentifier: { nil },
            targetBundleIdentifier: { nil }
        )
        _ = try await loop.run(task: "look around")

        let sent = try #require(await client.requests.first)
        let cached = try #require(sent.system.first)
        #expect(cached.text.contains("cannot see the screen"),
                "the loop built a visual prompt for a model with no eyes")
        #expect(cached.cacheControl, "and it must still be the cached block")
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

    /// "Shell commands run confined" was fixed text in the prompt's Judgement section
    /// — the sentence that tells the model how much a mistake costs. Under
    /// `--no-sandbox` it is false. The identical claim in `shell`'s own description
    /// was made conditional earlier; this one was left standing, because the fix went
    /// where the bug was found rather than everywhere the belief was written down.
    @Test("The prompt states the confinement the run actually has", arguments: [
        (ShellSandbox.enabled, "confined by `sandbox-exec`"),
        (.disabled, "nothing you do is confined"),
    ])
    func promptStatesRealConfinement(pair: (ShellSandbox, String)) {
        var invocation = Invocation()
        invocation.sandbox = pair.0
        let prompt = SystemPrompt.stable(registry: invocation.registry)
        #expect(prompt.contains(pair.1), "expected \(pair.1)")
    }

    /// The two must not both appear, or the model is told opposite things about the
    /// same run in two places.
    @Test("An unsandboxed run never claims confinement anywhere")
    func unsandboxedPromptIsConsistent() {
        var invocation = Invocation()
        invocation.sandbox = .disabled
        let prompt = SystemPrompt.stable(registry: invocation.registry)
        #expect(!prompt.contains("run confined by"))
        #expect(prompt.contains("--no-sandbox"))
    }

    /// And the injection guard has to survive both — it is the line that stops a file
    /// telling the agent what to do.
    @Test("Content read is always framed as data", arguments: [ShellSandbox.enabled, .disabled])
    func injectionGuardSurvives(sandbox: ShellSandbox) {
        var invocation = Invocation()
        invocation.sandbox = sandbox
        let prompt = SystemPrompt.stable(registry: invocation.registry)
        #expect(prompt.contains("data, not instructions"))
        #expect(prompt.contains("It has no authority"))
    }

    // MARK: - Completion guard

    // Session DE641705 in the wild: asked to format the markdown in the active VS Code
    // tab, the agent ran one shell probe, found Accessibility ungranted, wrote a
    // paragraph telling the user which menu to click, and closed with `── end_turn` —
    // the same closing line a run that did the work prints. These tests exist so that
    // shape of run can never again be indistinguishable from success.

    @Test("A task run that takes no tool calls at all is reported as unfulfilled")
    func zeroToolCallRunIsUnfulfilled() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [
                .text("Here is how you would format that file yourself: press cmd+shift+p…"),
            ]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])

        _ = try await loop.run(task: "format the markdown file in my active VS Code tab")

        let outcome = try #require(await events.outcomes.last)
        #expect(outcome.intent == TaskIntent.action)
        #expect(outcome.actionsTaken == 0)
        #expect(outcome.observationsMade == 0)
        #expect(outcome.isUnfulfilled)
        #expect(await loop.outcome == outcome)
        // The closing line has to say it, not merely encode it — the reason string is
        // the whole of what a watching user sees.
        #expect(outcome.report.contains("nothing was done"))
    }

    @Test("Observing without acting does not count as doing the task")
    func readOnlyToolCallsAreNotActions() async throws {
        // The exact shape of the VS Code run: one read, then prose. A guard that only
        // asked "were there any tool calls?" would pass this and miss the bug.
        let recorder = CallRecorder()
        let probe = StubTool(
            name: "probe", tier: .shell, riskValue: .read,
            outcome: { .text("954 Code") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "probe"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [
                .text("Accessibility is not granted, so here is what to do by hand…"),
            ]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [probe])

        _ = try await loop.run(task: "format the markdown file in my active VS Code tab")

        let outcome = try #require(await events.outcomes.last)
        #expect(recorder.calls == ["probe"])
        #expect(outcome.observationsMade == 1)
        #expect(outcome.actionsTaken == 0)
        #expect(outcome.isUnfulfilled)
    }

    @Test("A run that changes state is reported as fulfilled")
    func stateChangingRunIsFulfilled() async throws {
        let recorder = CallRecorder()
        let writer = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "formats the file"),
            outcome: { .text("formatted") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "writer"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Formatted.")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [writer])

        _ = try await loop.run(task: "format the markdown file in my active VS Code tab")

        let outcome = try #require(await events.outcomes.last)
        #expect(outcome.actionsTaken == 1)
        #expect(!outcome.isUnfulfilled)
        #expect(outcome.report == "end_turn")
    }

    @Test("A failed action is not counted as an action taken")
    func failedActionDoesNotCount() async throws {
        // "It threw" and "it worked" are the same number of tool calls and opposite
        // outcomes. Counting attempts rather than effects would let a run that tried
        // once, failed, and gave up report itself as having done the job.
        let recorder = CallRecorder()
        let writer = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "formats the file"),
            outcome: { .failure("no such file") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "writer"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("I could not.")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [writer])

        _ = try await loop.run(task: "format the markdown file in my active VS Code tab")

        let outcome = try #require(await events.outcomes.last)
        #expect(outcome.actionsTaken == 0)
        #expect(outcome.isUnfulfilled)
    }

    @Test("Answering a question without acting is not unfulfilled")
    func questionAnsweredWithoutActingIsFine() async throws {
        // The guard has to stay quiet here or it becomes noise on the commonest path:
        // most Tier 0 questions are one read and no actions, by design.
        let recorder = CallRecorder()
        let probe = StubTool(
            name: "probe", tier: .shell, riskValue: .read,
            outcome: { .text("48 GB free") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "probe"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("48 GB free.")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [probe])

        _ = try await loop.run(task: "how much disk space is left?")

        let outcome = try #require(await events.outcomes.last)
        #expect(outcome.intent == TaskIntent.question)
        #expect(!outcome.isUnfulfilled)
    }

    @Test("Every exit from the loop records an outcome")
    func everyExitRecordsAnOutcome() async throws {
        // `conclude` funnels all five exits; this is the test that notices if a sixth
        // is ever added that emits `.finished` on its own. A `.finished` without a
        // preceding `.outcome` renders as an ordinary successful close.
        let cases: [(String, [Wire.Response])] = [
            ("refusal", [ScriptedClient.response(
                stopReason: "refusal", content: [],
                stopDetails: .init(type: "refusal", category: nil, explanation: "no")
            )]),
            ("max_tokens", [ScriptedClient.response(
                stopReason: "max_tokens", content: [.text("half a sen")]
            )]),
            ("end_turn", [ScriptedClient.response(
                stopReason: "end_turn", content: [.text("done")]
            )]),
        ]
        for (label, responses) in cases {
            let (loop, _, events) = try makeLoop(client: ScriptedClient(responses), tools: [])
            _ = try await loop.run(task: "do the thing")
            let finished = await events.finishReasons
            let outcomes = await events.outcomes
            #expect(outcomes.count == finished.count, "\(label): outcome/finished mismatch")
            #expect(await loop.outcome != nil, "\(label): no outcome recorded")
        }
    }


    // MARK: - Gate timing

    @Test("A wait on the user is recorded, so it can be taken out of the tool time")
    func recordsGateWait() async throws {
        // Measured: `sandbox-exec` adds ~5ms and `pgrep -l Code` runs in ~25ms, against
        // the 3.43s the recorded session showed in that window. The difference was a
        // human reading a prompt. Without this note the two are indistinguishable
        // afterwards, and every latency figure credits the machine with the user's
        // reaction time.
        let recorder = CallRecorder()
        let writer = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "changes a file"),
            outcome: { .text("done") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "writer"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, transcript, _) = try makeLoop(
            client: client, tools: [writer], mode: .ask,
            // Deliberately over the 50ms floor, and by enough that a slow machine
            // cannot push a genuinely instant approval over it.
            prompt: { _, _, _ in
                try? await Task.sleep(nanoseconds: 150_000_000)
                return .allow
            }
        )

        _ = try await loop.run(task: "change the file")

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let gates = entries.filter { $0.kind == "gate" }
        #expect(gates.count == 1)
        #expect(gates.first?.payload["tool"]?.stringValue == "writer")
        let waited = try #require(gates.first?.payload["seconds"]?.doubleValue)
        #expect(waited >= 0.15)
        // A sanity ceiling: a duration read off the wrong clock, or in the wrong
        // units, lands orders of magnitude away rather than slightly off.
        #expect(waited < 10)
    }

    @Test("An approval that never asked is not recorded as a wait")
    func doesNotRecordInstantApprovals() async throws {
        // In bypass every call is allowed in microseconds. Noting those would put an
        // entry in the record for each one and measure nothing but the actor hop.
        let recorder = CallRecorder()
        let writer = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "changes a file"),
            outcome: { .text("done") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "writer"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, transcript, _) = try makeLoop(client: client, tools: [writer], mode: .bypass)

        _ = try await loop.run(task: "change the file")

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        #expect(!entries.contains { $0.kind == "gate" })
    }


    @Test("The outcome is written to the record, not only emitted")
    func recordsTheOutcome() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [
                .text("Here is how you would do that yourself…"),
            ]),
        ])
        let (loop, transcript, _) = try makeLoop(client: client, tools: [])

        _ = try await loop.run(task: "format the markdown file in my active VS Code tab")

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let outcomes = entries.filter { $0.kind == "outcome" }
        #expect(outcomes.count == 1)
        let payload = try #require(outcomes.first?.payload)
        #expect(payload["unfulfilled"]?.boolValue == true)
        #expect(payload["intent"]?.stringValue == "action")
        #expect(payload["actions_taken"]?.doubleValue == 0)
    }

    @Test("A second run never answers with the first run's verdict")
    func doesNotLeakTheVerdictBetweenRuns() async throws {
        // `run` can throw and leave `conclude` uncalled. Without clearing the field at
        // the start, the next run would report the previous one's outcome — and a
        // stale "it acted" is exactly the reading this guard exists to prevent.
        let recorder = CallRecorder()
        let writer = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "changes a file"),
            outcome: { .text("done") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "writer"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
            // The second run narrates and acts on nothing.
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Here is how…")]),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [writer])

        _ = try await loop.run(task: "change the file")
        let first = try #require(await loop.outcome)
        #expect(first.actionsTaken == 1)
        #expect(!first.isUnfulfilled)

        _ = try await loop.run(task: "change the other file")
        let second = try #require(await loop.outcome)
        #expect(second.actionsTaken == 0)
        #expect(second.isUnfulfilled)
    }


    // MARK: - Planning

    // The capability ladder applied to model choice. A plan runs as its own
    // conversation rather than as turn 0 of the executor's, because the transcript
    // replays assistant turns verbatim and thinking blocks are bound to the model
    // that made them — a mid-conversation model switch replays one model's thinking
    // to another.

    @Test("A plan is requested before the first executor turn and briefed to it")
    func plansBeforeExecuting() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [
                .text("1. Tier 0 shell: run prettier over the file."),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        // A non-empty registry on purpose: with no tools loaded, "the planner was
        // given no tools" is true however the code behaves, and the assertion below
        // proves nothing. The mutation sweep caught exactly that.
        let idle = StubTool(
            name: "writer", tier: .script, riskValue: .write(summary: "writes"),
            outcome: { .text("ok") }, recorder: CallRecorder()
        )
        let (loop, _, _) = try makeLoop(
            client: client, tools: [idle], planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "format the markdown file")

        let requests = await client.requests
        #expect(requests.count == 2)
        // The planner's request, first, on the planner's model and holding no tools.
        #expect(requests[0].model == "claude-opus-5")
        #expect(requests[0].tools.isEmpty)
        // The executor holds them, so an empty planner list is a decision rather than
        // an accident of an empty registry.
        #expect(!requests[1].tools.isEmpty)
        // The executor's, on the configured model, carrying the plan in its opening
        // message rather than as an assistant turn.
        #expect(requests[1].model == DefaultModel.id)
        let opening = requests[1].messages.first
        #expect(opening?.role == .user)
        let text = opening?.content.compactMap { block -> String? in
            if case let .text(t) = block { return t }
            return nil
        }.joined() ?? ""
        #expect(text.contains("prettier"))
        #expect(text.contains("advice, not instruction"))
    }

    @Test("The executor's transcript never holds the planner's assistant turn")
    func plannerTurnStaysOutOfTheTranscript() async throws {
        // The invariant this design exists to protect. A foreign assistant block in an
        // append-only transcript replays on every subsequent turn.
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("1. Do the thing.")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, transcript, _) = try makeLoop(
            client: client, tools: [], planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "do the thing")

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let assistants = entries.filter { $0.kind == "assistant" }
        // One assistant entry: the executor's. The planner's reply is recorded as a
        // `plan` note, which is not part of the conversation.
        #expect(assistants.count == 1)
        #expect(entries.contains { $0.kind == "plan" })
        let plan = try #require(entries.first { $0.kind == "plan" })
        #expect(plan.payload["model"]?.stringValue == "claude-opus-5")
    }

    @Test("A planner that fails does not stop the run")
    func plannerFailureIsNotFatal() async throws {
        // Planning is an optimisation. A run that refuses to start because the advice
        // was unavailable is strictly worse than one that proceeds without it.
        let client = FailingFirstClient(
            then: ScriptedClient.response(stopReason: "end_turn", content: [.text("Done anyway.")])
        )
        let (loop, _, events) = try makeLoop(
            client: client, tools: [], planner: Planner(model: "claude-opus-5")
        )

        let result = try await loop.run(task: "do the thing")
        #expect(result == "Done anyway.")
        #expect(await events.plans.isEmpty)
        // …and says so. Silence here is indistinguishable from a bad plan.
        #expect(await events.planningFailures.count == 1)
    }

    @Test("A planner the provider cannot serve is reported, not absorbed")
    func unreachablePlannerIsReported() async throws {
        // The commonest real case: `--provider ollama --planner claude-opus-5` sends
        // "claude-opus-5" to Ollama, which has never heard of it. Before this, the run
        // proceeded unplanned in silence and the user judged the planner by a run it
        // took no part in.
        let client = FailingFirstClient(
            then: ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")])
        )
        let (loop, transcript, events) = try makeLoop(
            client: client, tools: [], planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "do the thing")

        let failures = await events.planningFailures
        #expect(failures.count == 1)
        #expect(failures.first?.model == "claude-opus-5")
        #expect(!(failures.first?.reason.isEmpty ?? true))

        // And in the record, so the absence is explicable after the fact too.
        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let note = try #require(entries.first { $0.kind == "plan_failed" })
        #expect(note.payload["model"]?.stringValue == "claude-opus-5")
        #expect(!entries.contains { $0.kind == "plan" })
    }

    @Test("A planner that returns nothing is a failure, not an empty plan")
    func emptyPlanIsAFailure() async throws {
        // "There is no plan" has two meanings that must not be confused: nobody asked
        // for one, and one was asked for and did not arrive.
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("   ")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _, events) = try makeLoop(
            client: client, tools: [], planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "do the thing")
        #expect(await events.planningFailures.count == 1)
        #expect(await events.plans.isEmpty)
    }

    @Test("An unplanned run reports no planning failure either")
    func noPlannerMeansNoFailureReport() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])
        _ = try await loop.run(task: "do the thing")
        #expect(await events.planningFailures.isEmpty)
    }

    @Test("Without a planner the opening message is unchanged")
    func unplannedRunsAreUntouched() async throws {
        // The default path has to stay byte-identical, or every existing run pays for
        // a feature it did not ask for.
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _, _) = try makeLoop(client: client, tools: [])

        _ = try await loop.run(task: "do the thing")

        let requests = await client.requests
        #expect(requests.count == 1)
        let text = requests[0].messages.first?.content.compactMap { block -> String? in
            if case let .text(t) = block { return t }
            return nil
        }.joined() ?? ""
        #expect(!text.contains("<plan>"))
        #expect(text.hasSuffix("do the thing"))
    }

    @Test("The planner is told only about tiers this run has")
    func plannerPromptRespectsTheTierCap() {
        // A plan opening with "take a screenshot" under --max-tier 1 is worse than no
        // plan: the executor spends a turn discovering the tool is absent.
        let capped = ToolRegistry.standard(maxTier: .shell)
        let prompt = Planner.prompt(registry: capped)
        #expect(!prompt.contains("screenshot"))
        #expect(!prompt.contains("ax_press"))
        #expect(prompt.contains("shell"))
    }


    @Test("The planner's tokens reach the cost meter")
    func planningCostIsReported() async throws {
        // The whole point: a run that plans with an expensive model and executes with
        // a cheap one must not report the cheap half as the whole bill.
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("1. Do it.")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, transcript, events) = try makeLoop(
            client: client, tools: [], planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "do the thing")

        let meter = try #require(await events.costs.last)
        #expect(meter.planningCost > 0)
        #expect(meter.totalCost > meter.executionCost)

        // And in the record, so a later `bench` or listing can see it too.
        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let plan = try #require(entries.first { $0.kind == "plan" })
        #expect((plan.payload["planning_cost_usd"]?.doubleValue ?? 0) > 0)
    }

    @Test("An unplanned run reports no planning cost at all")
    func unplannedRunHasNoPlanningCost() async throws {
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _, events) = try makeLoop(client: client, tools: [])

        _ = try await loop.run(task: "do the thing")

        let meter = try #require(await events.costs.last)
        #expect(meter.planningCost == 0)
        #expect(meter.totalCost == meter.executionCost)
    }


    // MARK: - Recording a failure

    // Two sessions in the wild hold one user message and nothing else, from a local
    // model that turned out not to support tools. Neither says so: the error went to
    // stderr and left with the scrollback, and `transcripts` shows a zero-turn session
    // with no cause. Same defect as claiming success unearned, one layer out.

    @Test("A run that throws records why before the error leaves")
    func recordsTheFailure() async throws {
        let client = AlwaysFailingClient()
        let (loop, transcript, _) = try makeLoop(client: client, tools: [])

        await #expect(throws: AlwaysFailingClient.Refused.self) {
            _ = try await loop.run(task: "do the thing")
        }

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let failures = entries.filter { $0.kind == "failed" }
        #expect(failures.count == 1)
        let reason = try #require(failures.first?.payload["reason"]?.stringValue)
        #expect(reason.contains("Refused"))
    }

    @Test("A very long error is truncated rather than stored whole")
    func truncatesTheFailureReason() async throws {
        // A client error can carry a whole response body. A transcript is a record,
        // not a log sink.
        let client = AlwaysFailingClient(detail: String(repeating: "x", count: 5_000))
        let (loop, transcript, _) = try makeLoop(client: client, tools: [])

        _ = try? await loop.run(task: "do the thing")

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        let reason = try #require(entries.first { $0.kind == "failed" }?.payload["reason"]?.stringValue)
        #expect(reason.count <= 500)
    }

    @Test("An interruption is not recorded as a failure")
    func cancellationIsNotAFailure() async throws {
        // The user asked for it, and the in-loop path already records an interrupted
        // outcome. Two contradictory verdicts in one record is worse than one.
        let box = CancelBox()
        let recorder = CallRecorder()
        let stopper = StubTool(
            name: "stopper", tier: .shell, riskValue: .read,
            outcome: { box.fire(); return .text("ok") }, recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "tool_use", content: [
                ScriptedClient.toolCall("t1", "stopper"),
            ]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("done")]),
        ])
        let (loop, transcript, _) = try makeLoop(client: client, tools: [stopper])

        let task = Task { try await loop.run(task: "do the thing") }
        box.onFire { task.cancel() }
        _ = try? await task.value

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        #expect(!entries.contains { $0.kind == "failed" })
    }

}

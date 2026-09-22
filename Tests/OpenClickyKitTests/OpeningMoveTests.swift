import Testing
import Foundation
@testable import OpenClickyKit

/// A call decided before the model was asked, and the guarantees that make that safe.
///
/// The first of these is the one the whole design rests on: the pre-decided call goes
/// through the *same* `execute` a model's call goes through. If that ever stops being
/// true, the fast path is a second route to execution and every check this project has
/// is one branch away from being optional.
@Suite("Opening move", .serialized)
struct OpeningMoveTests {

    // MARK: - Doubles

    private actor ScriptedClient: MessagesClient {
        private var queue: [Wire.Response]
        private(set) var requests: [Wire.Request] = []

        init(_ responses: [Wire.Response] = []) { self.queue = responses }

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            requests.append(request)
            guard !queue.isEmpty else {
                return Self.response(stopReason: "end_turn", content: [.text("done")])
            }
            return queue.removeFirst()
        }

        nonisolated static func response(
            stopReason: String, content: [Wire.ContentBlock]
        ) -> Wire.Response {
            let encoder = JSONEncoder()
            let blocks = try! JSONDecoder().decode(
                [JSONValue].self, from: try! encoder.encode(content)
            )
            let fields: [String: JSONValue] = [
                "id": .string("msg_test"), "role": .string("assistant"),
                "model": .string("claude-opus-5"),
                "stop_reason": .string(stopReason),
                "usage": .object([
                    "input_tokens": .number(100), "output_tokens": .number(20),
                ]),
                "content": .array(blocks),
            ]
            let data = try! encoder.encode(JSONValue.object(fields))
            return try! JSONDecoder().decode(Wire.Response.self, from: data)
        }
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

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

    private let safari = AppCatalogue.Entry(
        bundleIdentifier: "com.apple.Safari",
        name: "Safari",
        url: URL(fileURLWithPath: "/Applications/Safari.app"),
        isRunning: false
    )

    private func activateTool(
        _ recorder: CallRecorder, verdict: ChangeVerdict = .changed
    ) -> StubTool {
        StubTool(
            name: "activate_app",
            tier: .shell,
            riskValue: .focus(.activate(safari)),
            outcome: { ToolOutput(content: [.text("Safari is now frontmost.")], changeVerdict: verdict) },
            recorder: recorder
        )
    }

    private func move(concludes: Bool = true) -> OpeningMove {
        OpeningMove(
            tool: "activate_app",
            input: .object(["bundle_identifier": .string("com.apple.Safari")]),
            narration: "Bringing Safari to the front.",
            spokenResult: "Safari.",
            concludesTask: concludes
        )
    }

    private func makeLoop(
        client: any MessagesClient,
        tools: [any Tool],
        mode: PermissionMode = .auto,
        planner: Planner? = nil
    ) throws -> (AgentLoop, Transcript) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-opening-\(UUID().uuidString)")
        let transcript = try Transcript(directory: directory)
        let loop = AgentLoop(
            client: client,
            registry: ToolRegistry(tools),
            gate: PermissionGate(mode: mode, prompt: { _, _, _ in .allow }),
            transcript: transcript,
            mode: mode,
            config: .init(maxTurns: 5, planner: planner),
            observer: { _ in },
            frontmostBundleIdentifier: { "com.example.ordinary" },
            targetBundleIdentifier: { "com.example.ordinary" },
            summonedFrom: { nil },
            environment: { "<screens>\nscreen 0: 1920×1080 pt at (0,0) (main)\n</screens>" }
        )
        return (loop, transcript)
    }

    // MARK: - The point of the whole thing

    /// The saving is the model call, and this is the test that says so. Not "fewer
    /// tokens" or "a shorter prompt" — *zero requests*.
    @Test("A request the fast path settles never reaches the model")
    func settledRunSendsNothing() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient()
        let (loop, _) = try makeLoop(client: client, tools: [activateTool(recorder)])

        let said = try await loop.run(task: "open Safari", opening: [move()])

        #expect(await client.requests.isEmpty, "a settled request still called the model")
        #expect(recorder.calls == ["activate_app"])
        #expect(said == "Safari.")

        let outcome = try #require(await loop.outcome)
        #expect(outcome.actionsTaken == 1)
        #expect(outcome.stopReason.disposition == .concluded)
        #expect(!outcome.isUnfulfilled, "a run that opened the app reported doing nothing")
        #expect(!outcome.isIncomplete)
    }

    /// `.concluded` means the model ended its own turn, and on this path it was never
    /// asked. The sentence has to say which exit this was.
    @Test("The run says it was settled, not that a model concluded it")
    func settledSaysSo() async throws {
        let recorder = CallRecorder()
        let (loop, _) = try makeLoop(
            client: ScriptedClient(), tools: [activateTool(recorder)]
        )
        _ = try await loop.run(task: "open Safari", opening: [move()])
        let outcome = try #require(await loop.outcome)
        #expect(outcome.stopReason.sentence.contains("before the model was asked"))
    }

    // MARK: - It goes through the gate, not around it

    /// The invariant the design stands on. Read-only refuses a focus change, and the
    /// refusal has to happen to a pre-decided call exactly as it happens to the model's.
    @Test("A pre-decided call is refused by the gate like any other")
    func readOnlyDeniesTheOpeningMove() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("I cannot in read-only mode.")]),
        ])
        let (loop, _) = try makeLoop(
            client: client, tools: [activateTool(recorder)], mode: .readOnly
        )

        _ = try await loop.run(task: "open Safari", opening: [move()])

        #expect(recorder.calls.isEmpty, "read-only ran a pre-decided call it would have refused")
        // And the run did not end there: the denial reaches the model, which is the
        // whole recovery path. A prose note would have had to invent it.
        #expect(!(await client.requests.isEmpty),
                "a denied opening move ended the run instead of reaching the model")
        let outcome = try #require(await loop.outcome)
        #expect(outcome.actionsTaken == 0)
    }

    /// The four-part guard. An action that ran but verified as `.unchanged` books as an
    /// *observation*, so `actionsTaken` stays short — and concluding there would produce
    /// a run that reports "nothing was done" while claiming to be finished.
    @Test("An action that did not land falls through to the model")
    func unverifiedActionDoesNotSettle() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("It did not come forward.")]),
        ])
        let (loop, _) = try makeLoop(
            client: client, tools: [activateTool(recorder, verdict: .unchanged)]
        )

        _ = try await loop.run(task: "open Safari", opening: [move()])

        #expect(recorder.calls == ["activate_app"], "the call never ran")
        #expect(!(await client.requests.isEmpty),
                "a run claimed to be finished on an action that never landed")
    }

    @Test("A failed action falls through to the model")
    func failedActionDoesNotSettle() async throws {
        let recorder = CallRecorder()
        let failing = StubTool(
            name: "activate_app", tier: .shell,
            riskValue: .focus(.activate(safari)),
            outcome: { .failure("No such application.") },
            recorder: recorder
        )
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Could not.")]),
        ])
        let (loop, _) = try makeLoop(client: client, tools: [failing])

        _ = try await loop.run(task: "open Safari", opening: [move()])
        #expect(!(await client.requests.isEmpty), "a failed action settled the run")
    }

    // MARK: - What the transcript says

    /// The pairing has to be real. Every `tool_result` keys to a `tool_use`, and the
    /// model has to read the action as its own prior work or it will simply do it again.
    @Test("The transcript holds a real tool_use and its matching tool_result")
    func transcriptPairingIsReal() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Now on GitHub.")]),
        ])
        let (loop, transcript) = try makeLoop(client: client, tools: [activateTool(recorder)])

        _ = try await loop.run(
            task: "open Safari and go to GitHub", opening: [move(concludes: false)]
        )

        let messages = await transcript.conversation(policy: .init())
        let assistant = messages.first { $0.role == .assistant }
        let uses: [String] = assistant?.content.compactMap {
            if case let .toolUse(id, _, _) = $0 { return id } else { return nil }
        } ?? []
        #expect(uses == ["opening_0"], "the fabricated call is missing or mis-keyed")

        let results: [String] = messages.flatMap { message in
            message.content.compactMap {
                if case let .toolResult(id, _, _) = $0 { return id } else { return nil }
            }
        }
        #expect(results == ["opening_0"], "a tool_use was left without its tool_result")
    }

    /// The other half of "acts, then continues": the model is handed a conversation in
    /// which the work is already done, so it picks up from there.
    @Test("A request with more to it runs the move and then asks the model")
    func compoundRequestContinues() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _) = try makeLoop(client: client, tools: [activateTool(recorder)])

        _ = try await loop.run(
            task: "open Safari and go to GitHub", opening: [move(concludes: false)]
        )

        #expect(recorder.calls == ["activate_app"])
        #expect(await client.requests.count == 1)
        let outcome = try #require(await loop.outcome)
        #expect(outcome.actionsTaken == 1, "the pre-decided action was not counted")
    }

    /// A planner exists to tell an executor how to approach the work. There is no
    /// executor turn here to tell, and the round trip is the exact cost this path was
    /// built to remove — so planning a settled request is pure latency, paid for nothing.
    @Test("A request that settles is never planned")
    func settledRunIsNotPlanned() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient()
        let (loop, _) = try makeLoop(
            client: client, tools: [activateTool(recorder)],
            planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(task: "open Safari", opening: [move()])

        #expect(await client.requests.isEmpty,
                "a request that never reaches the model was planned anyway")
        #expect(recorder.calls == ["activate_app"])
    }

    /// And the mirror: a request with more to it still gets its plan, because there is
    /// an executor turn for the plan to be about.
    @Test("A request that continues is still planned")
    func continuingRunIsStillPlanned() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("a plan")]),
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Done.")]),
        ])
        let (loop, _) = try makeLoop(
            client: client, tools: [activateTool(recorder)],
            planner: Planner(model: "claude-opus-5")
        )

        _ = try await loop.run(
            task: "open Safari and go to GitHub", opening: [move(concludes: false)]
        )
        #expect(await client.requests.count == 2, "the planner was skipped for a run that needed one")
    }

    // MARK: - Nothing pre-decided

    /// The default has to be invisible. Every existing caller passes no opening move and
    /// must behave exactly as it did.
    @Test("A run with nothing pre-decided is unchanged")
    func noOpeningMoveIsUnchanged() async throws {
        let recorder = CallRecorder()
        let client = ScriptedClient([
            ScriptedClient.response(stopReason: "end_turn", content: [.text("Hello.")]),
        ])
        let (loop, transcript) = try makeLoop(client: client, tools: [activateTool(recorder)])

        _ = try await loop.run(task: "say hello")

        #expect(recorder.calls.isEmpty)
        #expect(await client.requests.count == 1)
        let messages = await transcript.conversation(policy: .init())
        #expect(!messages.contains { message in
            message.content.contains { if case .toolUse = $0 { return true } else { return false } }
        }, "a run with nothing pre-decided fabricated a turn anyway")
    }
}

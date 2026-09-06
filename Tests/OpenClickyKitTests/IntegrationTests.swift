import Testing
import Foundation
@testable import OpenClickyKit

/// Drives the real tool registry through the real agent loop, permission gate and
/// transcript, with only the HTTP call scripted.
///
/// Everything else is unit-tested in isolation: the loop against stub tools, the
/// tools against the real OS. Nothing covered the wiring between them — a tool whose
/// name the loop cannot dispatch, a schema the model's arguments do not satisfy, or a
/// result that never reaches the transcript would pass every existing test.
@Suite("End to end", .serialized)
struct IntegrationTests {

    private final class Script: MessagesClient, @unchecked Sendable {
        private let queue: [[Wire.ContentBlock]]
        private let counter = Counter()

        init(_ turns: [[Wire.ContentBlock]]) { self.queue = turns }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
        }

        func send(_ request: Wire.Request) async throws -> Wire.Response {
            let index = counter.next()
            let content = index < queue.count ? queue[index] : [.text("Done.")]
            let stop = index < queue.count ? "tool_use" : "end_turn"
            return Self.make(content: content, stopReason: stop)
        }

        static func make(content: [Wire.ContentBlock], stopReason: String) -> Wire.Response {
            let encoder = JSONEncoder()
            let blocks = try! JSONDecoder().decode(
                [JSONValue].self, from: try! encoder.encode(content)
            )
            let payload = JSONValue.object([
                "id": .string("msg_integration"),
                "role": .string("assistant"),
                "model": .string("claude-opus-5"),
                "stop_reason": .string(stopReason),
                "content": .array(blocks),
                "usage": .object(["input_tokens": .number(50), "output_tokens": .number(10)]),
            ])
            return try! JSONDecoder().decode(
                Wire.Response.self, from: try! encoder.encode(payload)
            )
        }
    }

    /// Every tool the CLI ships, so the test fails if one is added without wiring.
    private var fullRegistry: ToolRegistry {
        ToolRegistry([
            ShellTool(), ReadFileTool(), WriteFileTool(),
            AppleScriptTool(), ShortcutsTool(),
            AXCaptureTool(), AXPressTool(), AXSetValueTool(),
            ScreenshotTool(), ZoomTool(), ClickTool(), DragTool(),
            TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
        ])
    }

    private func run(
        turns: [[Wire.ContentBlock]], mode: PermissionMode = .bypass,
        registry: ToolRegistry? = nil
    ) async throws -> (answer: String, transcript: Transcript, events: [AgentLoop.Event]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-e2e-\(UUID().uuidString)")
        let transcript = try Transcript(directory: directory)
        let recorder = EventLog()

        let loop = AgentLoop(
            client: Script(turns),
            registry: registry ?? fullRegistry,
            gate: PermissionGate(mode: mode) { _, _, _ in .allow },
            transcript: transcript,
            mode: mode,
            config: .init(maxTurns: 6),
            observer: { await recorder.append($0) }
        )
        let answer = try await loop.run(task: "integration")
        return (answer, transcript, await recorder.events)
    }

    private actor EventLog {
        private(set) var events: [AgentLoop.Event] = []
        func append(_ event: AgentLoop.Event) { events.append(event) }
    }

    private func toolCall(_ id: String, _ name: String, _ input: [String: JSONValue]) -> Wire.ContentBlock {
        .toolUse(id: id, name: name, input: .object(input))
    }

    private func resultText(_ transcript: Transcript) async -> String {
        await transcript.conversation.flatMap(\.content).compactMap { block -> String? in
            guard case let .toolResult(_, content, _) = block else { return nil }
            return content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }
                .joined(separator: "\n")
        }.joined(separator: "\n---\n")
    }

    // MARK: - Tiers 0 and 1 through the whole stack

    @Test("A shell command runs and its output reaches the transcript")
    func shellRunsEndToEnd() async throws {
        let (answer, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["command": .string("echo integration-marker")])],
        ])
        #expect(answer == "Done.")
        #expect(await resultText(transcript).contains("integration-marker"))
    }

    @Test("An AppleScript runs and its result reaches the transcript")
    func appleScriptRunsEndToEnd() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "app_script", ["script": .string("return 6 * 7")])],
        ])
        #expect(await resultText(transcript).contains("42"))
    }

    @Test("A file written in one turn is read back in the next")
    func filesRoundTripAcrossTurns() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-e2e-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "write_file", ["path": .string(path), "content": .string("carried-across")])],
            [toolCall("t2", "read_file", ["path": .string(path)])],
        ])
        #expect(await resultText(transcript).contains("carried-across"))
    }

    // MARK: - Batching through the real registry

    @Test("A batch of real tools runs in order and all results return together")
    func realBatchExecutesInOrder() async throws {
        let (_, transcript, _) = try await run(turns: [[
            toolCall("t1", "shell", ["command": .string("echo first")]),
            toolCall("t2", "shell", ["command": .string("echo second")]),
            toolCall("t3", "app_script", ["script": .string("return \"third\"")]),
        ]])

        let text = await resultText(transcript)
        #expect(text.contains("first") && text.contains("second") && text.contains("third"))

        let batches = await transcript.conversation.filter { message in
            message.role == .user && message.content.filter {
                if case .toolResult = $0 { return true }
                return false
            }.count == 3
        }
        #expect(batches.count == 1, "all three results must arrive in one user message")
    }

    /// The model plans a batch against state it has observed; once a step fails that
    /// assumption is void. Verified here against real tools rather than stubs.
    @Test("A failing real tool stops the rest of its batch")
    func realBatchFailsFast() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-should-not-exist-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let (_, _, events) = try await run(turns: [[
            toolCall("t1", "shell", ["command": .string("ls /definitely-not-a-real-path")]),
            toolCall("t2", "write_file", ["path": .string(marker), "content": .string("x")]),
        ]])

        let skipped = events.compactMap { event -> String? in
            if case let .toolSkipped(name) = event { return name }
            return nil
        }
        #expect(skipped == ["write_file"])
        #expect(!FileManager.default.fileExists(atPath: marker),
                "the skipped tool must not have run")
    }

    // MARK: - Safety through the whole stack

    @Test("read-only mode refuses a mutating call made through the real registry")
    func readOnlyModeBlocksRealMutation() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-readonly-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let (_, _, events) = try await run(turns: [
            [toolCall("t1", "write_file", ["path": .string(marker), "content": .string("x")])],
        ], mode: .readOnly)

        #expect(events.contains { if case .toolDenied = $0 { return true }; return false })
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// The deny-list has to hold when reached through the loop, not just when the
    /// policy is called directly.
    @Test("A deny-listed command is refused even in bypass mode")
    func denyListHoldsThroughTheLoop() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["command": .string("cat ~/.ssh/id_rsa")])],
        ], mode: .bypass)
        #expect(await resultText(transcript).contains("Refused"))
    }

    // MARK: - Wiring

    /// A tool the loop cannot dispatch by name fails the batch at runtime and would
    /// pass every isolated test, so check the whole set can be reached.
    @Test("Every registered tool is dispatchable by its own name")
    func everyToolIsDispatchable() async throws {
        let registry = fullRegistry
        for tool in registry.ordered {
            #expect(registry[tool.name] != nil, "\(tool.name) is not reachable by name")
        }

        // And the loop reports an unknown name rather than silently ignoring it.
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "no_such_tool", [:])],
        ])
        #expect(await resultText(transcript).contains("No tool named"))
    }

    @Test("Malformed arguments are reported to the model, not thrown away")
    func malformedArgumentsAreReported() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["wrong_key": .string("ls")])],
        ])
        let text = await resultText(transcript)
        #expect(text.contains("Invalid arguments") || text.contains("command"))
    }

    /// The whole conversation is resent each turn, so the transcript's shape is what
    /// the API sees. A malformed one is a 400 on the next request.
    @Test("The transcript stays a valid conversation across several turns")
    func transcriptRemainsValid() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["command": .string("echo one")])],
            [toolCall("t2", "shell", ["command": .string("echo two")])],
            [toolCall("t3", "app_script", ["script": .string("return 3")])],
        ])

        let conversation = await transcript.conversation
        let uses = Set(conversation.flatMap(\.content).compactMap { block -> String? in
            if case let .toolUse(id, _, _) = block { return id }
            return nil
        })
        let results = Set(conversation.flatMap(\.content).compactMap { block -> String? in
            if case let .toolResult(id, _, _) = block { return id }
            return nil
        })
        #expect(uses == results, "every tool_use needs its result and vice versa")
        #expect(uses.count == 3)

        // Roles must alternate correctly: a tool_result belongs to a user message.
        for message in conversation where message.role == .assistant {
            #expect(!message.content.contains { if case .toolResult = $0 { return true }; return false },
                    "a tool_result must never appear in an assistant turn")
        }
    }

    // MARK: - The record a run leaves, read back

    /// The reader was built and tested against transcripts written by hand. Nothing
    /// checked it against one the loop actually produced — a writer and a reader that
    /// have never met, which is the shape of most of the defects found in this
    /// project. This runs real tools and replays the file they left behind.
    @Test("A real run's transcript replays as what happened")
    func transcriptReplaysWhatHappened() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["command": .string("echo hello from the run")])],
            [toolCall("t2", "app_script", ["script": .string("return 21 * 2")])],
        ])

        let entries = try TranscriptReport.entries(at: URL(fileURLWithPath: await transcript.path))
        #expect(entries.count > 4, "a two-turn run should leave more than a handful of entries")
        #expect(entries.map(\.sequence) == Array(0..<entries.count),
                "the record must be gapless and in order")

        let rendered = TranscriptReport.lines(for: entries).map(\.text).joined(separator: "\n")
        #expect(rendered.contains("echo hello from the run"), "the command is not in the replay")
        #expect(rendered.contains("hello from the run"), "its output is not in the replay")
        #expect(rendered.contains("→ app_script"))
        #expect(rendered.contains("42"), "the script's result is not in the replay")
    }

    /// And the listing must describe that same run without opening most of it — the
    /// fast path reads only the ends of the file, so it is worth proving it agrees
    /// with a record the loop wrote rather than only with fixtures.
    @Test("A real run appears correctly in the listing")
    func realRunAppearsInListing() async throws {
        let (_, transcript, _) = try await run(turns: [
            [toolCall("t1", "shell", ["command": .string("echo listed")])],
        ])
        let url = URL(fileURLWithPath: await transcript.path)

        let listing = try #require(
            TranscriptReport.listings(in: url.deletingLastPathComponent())
                .first { $0.url.lastPathComponent == url.lastPathComponent }
        )
        #expect(listing.task == "integration",
                "the listed task is not what was asked: \(listing.task)")
        #expect(!listing.task.contains("environment"), "the environment probe leaked into the listing")
        #expect(listing.turns >= 1, "no turns counted for a run that made one")
    }
}

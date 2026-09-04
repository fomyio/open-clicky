import Foundation

/// Drives the observe → reason → act cycle.
///
/// The loop itself is small and deliberately so: request, execute the tool calls
/// it returns, append results, repeat. The interesting behaviour lives in the tool
/// tiers, the permission gate, and the system prompt.
public actor AgentLoop {

    /// Progress reported as the loop runs, for the CLI or an overlay to render.
    public enum Event: Sendable {
        case thinking
        case assistantText(String)
        case toolStarted(name: String, tier: Tier, summary: String)
        case toolFinished(name: String, ok: Bool, detail: String)
        case toolDenied(name: String, reason: String)
        case toolSkipped(name: String)
        case interrupted
        case usage(input: Int, output: Int, cacheRead: Int)
        /// Running session cost, emitted after each turn.
        case cost(CostMeter)
        case finished(reason: String)
    }

    public typealias Observer = @Sendable (Event) async -> Void

    public struct Configuration: Sendable {
        public var model: String
        public var maxTokens: Int
        public var effort: String
        /// Hard cap on request round-trips, so a confused loop cannot run forever.
        public var maxTurns: Int
        /// How much observation history is resent each turn.
        /// See `Transcript.ContextPolicy`.
        public var context: Transcript.ContextPolicy

        public init(
            model: String = "claude-opus-5",
            maxTokens: Int = 16_000,
            // Computer-use accuracy is materially better at high effort with adaptive
            // thinking; this is not the place to economise.
            effort: String = "high",
            maxTurns: Int = 40,
            context: Transcript.ContextPolicy = .default
        ) {
            self.model = model
            self.maxTokens = maxTokens
            self.effort = effort
            self.maxTurns = maxTurns
            self.context = context
        }
    }

    private let client: any MessagesClient
    private let registry: ToolRegistry
    private let gate: PermissionGate
    private let transcript: Transcript
    private let config: Configuration
    private let mode: PermissionMode
    private let observer: Observer

    public init(
        client: any MessagesClient,
        registry: ToolRegistry,
        gate: PermissionGate,
        transcript: Transcript,
        mode: PermissionMode,
        config: Configuration = Configuration(),
        observer: @escaping Observer
    ) {
        self.client = client
        self.registry = registry
        self.gate = gate
        self.transcript = transcript
        self.mode = mode
        self.config = config
        self.observer = observer
    }

    /// Runs one user task to completion.
    ///
    /// - Returns: the model's closing message.
    @discardableResult
    public func run(task: String) async throws -> String {
        let probe = ContextProbe.capture()
        await transcript.append(.user("\(probe.rendered)\n\n\(task)"))

        var finalText = ""
        var meter = CostMeter(model: config.model)

        for turn in 0..<config.maxTurns {
            try Task.checkCancellation()
            await observer(.thinking)

            let request = Wire.Request(
                model: config.model,
                maxTokens: config.maxTokens,
                system: [
                    // Cache breakpoint on the stable half: identical bytes every turn,
                    // so from turn two onwards it is read from cache, not re-billed.
                    .init(SystemPrompt.stable(registry: registry), cacheControl: true),
                    .init(SystemPrompt.session(mode: mode, permissions: PermissionStatus.current())),
                ],
                messages: await transcript.conversation(policy: config.context),
                tools: registry.definitions,
                effort: config.effort
            )

            let response = try await client.send(request)
            meter.record(response.usage)
            await observer(.cost(meter))
            await observer(.usage(
                input: response.usage.inputTokens,
                output: response.usage.outputTokens,
                cacheRead: response.usage.cacheReadInputTokens ?? 0
            ))
            await transcript.note(kind: "usage", [
                "turn": .number(Double(turn)),
                "input_tokens": .number(Double(response.usage.inputTokens)),
                "output_tokens": .number(Double(response.usage.outputTokens)),
                "cache_read_tokens": .number(Double(response.usage.cacheReadInputTokens ?? 0)),
                "session_cost_usd": .number(meter.totalCost),
            ])

            // Echo the assistant turn back verbatim, thinking blocks included —
            // they are bound to this model and must replay unchanged.
            await transcript.append(Wire.Message(role: .assistant, content: response.content))

            let text = response.text
            if !text.isEmpty {
                finalText = text
                await observer(.assistantText(text))
            }

            if response.stopReason == "refusal" {
                let detail = response.stopDetails?.explanation ?? "no explanation given"
                await observer(.finished(reason: "The model declined this request (\(detail))."))
                return finalText.isEmpty ? "Request declined: \(detail)" : finalText
            }

            let calls = response.toolCalls

            // A response cut off at max_tokens is not a finished answer. Treating it
            // as one hands the user a half-written reply with no indication that the
            // rest is missing — and mid-plan, drops the actions it was about to take.
            if response.stopReason == "max_tokens" {
                if calls.isEmpty {
                    await observer(.finished(reason: "response truncated at the \(config.maxTokens)-token limit"))
                    await transcript.note(kind: "truncated", [
                        "turn": .number(Double(turn)),
                        "max_tokens": .number(Double(config.maxTokens)),
                    ])
                    let warning = """

                    [This reply was cut off at the \(config.maxTokens)-token limit and is \
                    incomplete. Re-run with a larger --max-turns budget, or ask for a \
                    narrower task.]
                    """
                    return finalText.isEmpty
                        ? "The reply was cut off at the \(config.maxTokens)-token limit before any output was produced."
                        : finalText + warning
                }
                // Tool calls survived the truncation, so the turn can still proceed —
                // but the model's reasoning was clipped, and it needs to know that
                // rather than assume its plan arrived intact.
                await observer(.assistantText("[reply truncated at the token limit; continuing with the actions that arrived]"))
            }

            guard !calls.isEmpty else {
                await observer(.finished(reason: response.stopReason ?? "end_turn"))
                return finalText
            }

            let results = await execute(calls)
            // Every tool_result for a turn goes back in one user message. Splitting
            // them across messages teaches the model to stop batching.
            await transcript.append(Wire.Message(role: .user, content: results))

            if Task.isCancelled {
                await transcript.note(kind: "interrupted", [
                    "turn": .number(Double(turn)),
                    "session_cost_usd": .number(meter.totalCost),
                ])
                await observer(.finished(reason: "interrupted by the user"))
                return finalText.isEmpty
                    ? "Interrupted. Nothing further was done."
                    : finalText
            }
        }

        await observer(.finished(reason: "turn limit (\(config.maxTurns)) reached"))
        return finalText.isEmpty
            ? "Stopped after \(config.maxTurns) turns without finishing."
            : finalText
    }

    /// Runs a batch of tool calls in order, skipping the remainder after a failure.
    ///
    /// Fail-fast matters because the model plans a batch against the state it last
    /// observed. Once a step fails that assumption is void, and running the rest
    /// would act on a screen that is not the one it planned against.
    private func execute(
        _ calls: [(id: String, name: String, input: JSONValue)]
    ) async -> [Wire.ContentBlock] {
        var results: [Wire.ContentBlock] = []
        var batchFailed = false

        for call in calls {
            // Checked before every action, not just once a turn: a batch can be a
            // dozen clicks and keystrokes, and a stop request has to take effect
            // before the next one lands rather than after the whole batch.
            if Task.isCancelled {
                await observer(.interrupted)
                results.append(.toolResult(
                    toolUseID: call.id,
                    content: [.text("Not executed: the user interrupted the run.")],
                    isError: true
                ))
                batchFailed = true
                continue
            }

            if batchFailed {
                await observer(.toolSkipped(name: call.name))
                results.append(.toolResult(
                    toolUseID: call.id,
                    content: [.text("Not executed: an earlier action in this turn failed. Re-observe before retrying.")],
                    isError: true
                ))
                continue
            }

            guard let tool = registry[call.name] else {
                batchFailed = true
                results.append(.toolResult(
                    toolUseID: call.id,
                    content: [.text("No tool named '\(call.name)' is available.")],
                    isError: true
                ))
                continue
            }

            let risk = tool.risk(for: call.input)
            await observer(.toolStarted(name: tool.name, tier: tool.tier, summary: risk.summary))

            let decision = await gate.decide(tool: tool.name, risk: risk)
            if case let .deny(reason) = decision {
                batchFailed = true
                await observer(.toolDenied(name: tool.name, reason: reason))
                await transcript.note(kind: "denied", [
                    "tool": .string(tool.name), "reason": .string(reason),
                ])
                results.append(.toolResult(
                    toolUseID: call.id, content: [.text(reason)], isError: true
                ))
                continue
            }

            let output: ToolOutput
            do {
                output = try await tool.run(call.input)
            } catch let error as Policy.Violation {
                output = .failure(error.description)
            } catch let error as JSONValue.MissingField {
                output = .failure("Invalid arguments for '\(tool.name)': \(error.description)")
            } catch {
                output = .failure("'\(tool.name)' threw: \(error)")
            }

            if output.isError { batchFailed = true }
            await observer(.toolFinished(
                name: tool.name,
                ok: !output.isError,
                detail: output.content.compactMap {
                    if case let .text(t) = $0 { return t }
                    return "[image]"
                }.joined(separator: " ").truncated(160)
            ))

            results.append(.toolResult(
                toolUseID: call.id, content: output.content, isError: output.isError
            ))
        }
        return results
    }
}

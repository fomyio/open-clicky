import Foundation
import AppKit

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
        /// Backing off before another attempt at the same request.
        case retrying(attempt: Int, of: Int, delay: Double, reason: String)
        case usage(input: Int, output: Int, cacheRead: Int)
        /// Running session cost, emitted after each turn.
        case cost(CostMeter)
        case finished(reason: String)

        /// The reason a run reports when the user stopped it.
        ///
        /// A constant rather than prose both sides match on. The overlay decided
        /// between "stopped" and "finished" with `reason.contains("interrupted")`,
        /// which is a control-flow decision resting on wording owned by another
        /// module: rephrasing it to "Interrupted by the user" would have silently
        /// turned every stopped run into a completed one, with nothing to fail.
        public static let interruptedReason = "interrupted by the user"
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
            model: String = DefaultModel.id,
            maxTokens: Int = 16_000,
            // Computer-use accuracy is materially better at high effort with adaptive
            // thinking, so this stays high rather than economising. It is dropped from
            // the request on families that predate the field — see `ModelCapabilities`.
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

    /// The cached system prefix and tool block, built once.
    ///
    /// Both carry a prompt-cache breakpoint, which requires them to be byte-identical
    /// on every turn — any drift re-bills the whole prompt. Computing them once makes
    /// that a property of the structure rather than a convention someone has to
    /// remember, and there is no reason to rebuild them 40 times either way.
    private let stablePrompt: String
    private let toolDefinitions: [Wire.ToolDefinition]
    /// Injectable so a test can put the agent in front of a consent dialog. Without
    /// the seam, the tests proved `Policy.escalate` works and nothing proved the loop
    /// calls it — the sweep found the wiring undefended.
    private let frontmostBundleIdentifier: @Sendable () -> String?
    /// Which app owns the elements the last capture produced. Injected alongside the
    /// frontmost lookup so the two cannot be stubbed inconsistently.
    private let targetBundleIdentifier: @Sendable () -> String?

    public init(
        client: any MessagesClient,
        registry: ToolRegistry,
        gate: PermissionGate,
        transcript: Transcript,
        mode: PermissionMode,
        config: Configuration = Configuration(),
        observer: @escaping Observer,
        frontmostBundleIdentifier: @escaping @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        targetBundleIdentifier: @escaping @Sendable () -> String? = {
            AXCapture.labels.ownerBundleIdentifier
        }
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.targetBundleIdentifier = targetBundleIdentifier
        self.client = client
        self.registry = registry
        self.gate = gate
        self.transcript = transcript
        self.mode = mode
        self.config = config
        self.observer = observer
        self.stablePrompt = SystemPrompt.stable(registry: registry)
        self.toolDefinitions = registry.definitions
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
                    .init(stablePrompt, cacheControl: true),
                    .init(SystemPrompt.session(mode: mode, permissions: PermissionStatus.current())),
                ],
                messages: await transcript.conversation(policy: config.context),
                tools: toolDefinitions,
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
            /// Things the loop knows and the model does not, carried down to the
            /// results message. The observer draws to the user's terminal only, so
            /// anything the model has to act on has to travel back this way.
            var notices: [String] = []

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
                // rather than assume its plan arrived intact. The observer only draws
                // to the user's terminal, so the notice also has to travel back in the
                // results message or the model never learns anything was lost.
                await observer(.assistantText("[reply truncated at the token limit; continuing with the actions that arrived]"))
                notices.append("""
                Your previous reply was cut off at the \(config.maxTokens)-token limit. \
                The tool calls below ran, but anything you had not finished writing was \
                lost — including any further calls you intended to make in that turn. \
                Re-check the state before continuing, and keep replies shorter.
                """)
            }

            guard !calls.isEmpty else {
                await observer(.finished(reason: response.stopReason ?? "end_turn"))
                return finalText
            }

            var results = await execute(calls)
            // Text is appended after the tool_results, never before: the API requires
            // every tool_result to come first in the message that answers a tool_use.
            // The run ends at a fixed turn count, and until now it simply stopped —
            // severing the model mid-plan and handing the user "Stopped after 40 turns
            // without finishing." A model that knows it has one turn left spends it
            // summarising what it did and what remains, which is the difference
            // between an abandoned run and a report.
            //
            // Exactly one turn ahead, never zero: on the final iteration the loop
            // exits immediately after appending, so a notice written there is read by
            // nobody. A warning that arrives after the last request is not a warning.
            let requestsRemaining = config.maxTurns - turn - 1
            if requestsRemaining == 1 {
                notices.append("""
                You have 1 turn left before this run stops at its \(config.maxTurns)-turn \
                limit. If the task is not finished, use it to summarise what you did, \
                what you verified, and what remains — no further tool calls will run \
                after it.
                """)
            }
            for notice in notices { results.append(.text(notice)) }
            // Every tool_result for a turn goes back in one user message. Splitting
            // them across messages teaches the model to stop batching.
            await transcript.append(Wire.Message(role: .user, content: results))

            if Task.isCancelled {
                await transcript.note(kind: "interrupted", [
                    "turn": .number(Double(turn)),
                    "session_cost_usd": .number(meter.totalCost),
                ])
                await observer(.finished(reason: Event.interruptedReason))
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

            // Escalated centrally: a tool cannot be trusted to notice that the window
            // it is about to act on is the one granting this agent its privileges.
            // Both the app in front of the user and the app that owns the element
            // being acted on. `ax_capture` takes a bundle_identifier and reads that
            // app instead of the frontmost one, and an accessibility action drives an
            // element without activating its app — so capturing a consent dialog while
            // Finder is frontmost and pressing "Allow" defeated a frontmost-only check
            // using a documented parameter.
            let risk = Policy.escalate(
                tool.risk(for: call.input),
                frontmostBundleIdentifier: frontmostBundleIdentifier(),
                targetBundleIdentifier: targetBundleIdentifier()
            )
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
                // Flattened as well as truncated: a result with a newline in it broke
                // the run display, leaving the second line unindented and unmarked
                // among the agent's own words.
                detail: output.content.compactMap {
                    if case let .text(t) = $0 { return t }
                    return "[image]"
                }.joined(separator: " ")
                    .split(whereSeparator: \.isNewline)
                    .joined(separator: " ⏎ ")
                    .truncated(160)
            ))

            results.append(.toolResult(
                toolUseID: call.id, content: output.content, isError: output.isError
            ))
        }
        return results
    }
}

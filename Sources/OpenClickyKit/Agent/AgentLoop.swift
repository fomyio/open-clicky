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
        /// A plan came back from the planning model, and what it said.
        case planned(model: String, plan: String)
        /// What the run actually changed, emitted immediately before `.finished`.
        ///
        /// A separate event rather than a field on `.finished` because the two answer
        /// different questions — `.finished` says why the loop stopped, `.outcome`
        /// says whether that stop means anything was accomplished — and a renderer
        /// that only knows about the former still compiles and still works.
        case outcome(RunOutcome)
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
        /// A stronger model asked how to approach the task first. Nil runs unplanned,
        /// which is what every run did before this existed and remains the default.
        public var planner: Planner?

        public init(
            model: String = DefaultModel.id,
            maxTokens: Int = 16_000,
            // Computer-use accuracy is materially better at high effort with adaptive
            // thinking, so this stays high rather than economising. It is dropped from
            // the request on families that predate the field — see `ModelCapabilities`.
            effort: String = "high",
            maxTurns: Int = 40,
            context: Transcript.ContextPolicy = .default,
            planner: Planner? = nil
        ) {
            self.planner = planner
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
        // Derived from the model, once, at construction. It is fixed for the whole
        // session, so it belongs in the cached prefix rather than the per-turn block
        // — and computing it here rather than per turn makes that structural.
        self.stablePrompt = SystemPrompt.stable(
            registry: registry, grounding: .forModel(config.model)
        )
        self.toolDefinitions = registry.definitions
    }

    /// What the last completed run changed. `nil` until `run(task:)` returns.
    ///
    /// Readable after the fact as well as observable during, because the CLI's exit
    /// code depends on it and an observer closure is the wrong place to smuggle a
    /// value back out of an actor.
    public private(set) var outcome: RunOutcome?

    /// Invocations that ran and changed state, and those that only observed.
    ///
    /// Instance state rather than locals because `execute` does the classifying and
    /// returns content blocks; threading a counter back out through its return type
    /// would put bookkeeping in the signature of the function that runs tools.
    private var actionsTaken = 0
    private var observationsMade = 0

    /// Records the outcome, emits it, then emits `.finished`.
    ///
    /// Every exit from `run(task:)` goes through here. While each exit emitted its own
    /// `.finished` directly, adding a new one meant remembering to record an outcome
    /// too — and a missing outcome reads exactly like a successful one, which is the
    /// failure this whole type exists to catch. Funnelling them makes it structural.
    @discardableResult
    private func conclude(reason: String, intent: TaskIntent) async -> RunOutcome {
        let result = RunOutcome(
            actionsTaken: actionsTaken,
            observationsMade: observationsMade,
            intent: intent,
            stopReason: reason
        )
        outcome = result
        // Written to the record as well as emitted. The event reaches a terminal that
        // scrolls away; the transcript is what remains, and a listing that cannot tell
        // a run which did the work from one which explained why it could not is the
        // same failure this guard was built for, one layer further out.
        await transcript.note(kind: "outcome", [
            "actions_taken": .number(Double(result.actionsTaken)),
            "observations_made": .number(Double(result.observationsMade)),
            "intent": .string(result.intent.rawValue),
            "stop_reason": .string(result.stopReason),
            "unfulfilled": .bool(result.isUnfulfilled),
        ])
        await observer(.outcome(result))
        await observer(.finished(reason: reason))
        return result
    }

    /// Runs one user task to completion.
    ///
    /// - Returns: the model's closing message.
    @discardableResult
    public func run(task: String) async throws -> String {
        let probe = ContextProbe.capture()

        // What produced this run, written before anything else happens.
        //
        // A recorded session said what it did and never what it was. Comparing a
        // planned run against an unplanned one, or Haiku against Opus, meant knowing
        // from memory which session was which — so "measure before and after" rested
        // on the measurer remembering what they had changed. A record that cannot
        // identify its own configuration cannot be used for a comparison, which is
        // most of what a record of timings is for.
        //
        // Model ids and modes only. Nothing here is a secret, and nothing here is the
        // user's data — the endpoint and the key stay out deliberately.
        await transcript.note(kind: "run", [
            "model": .string(config.model),
            "planner": config.planner.map { .string($0.model) } ?? .null,
            "mode": .string(mode.rawValue),
            "max_tier": .number(Double(registry.maxTier.rawValue)),
            "max_turns": .number(Double(config.maxTurns)),
        ])

        // Planned before the transcript is opened, so the plan is part of the first
        // user message rather than a turn of its own. A separate turn would put a
        // second model's assistant block in a transcript that replays verbatim —
        // see `Planner` for why that is not merely untidy.
        var opening = "\(probe.rendered)\n\n\(task)"
        var meter = CostMeter(model: config.model)
        if let planner = config.planner {
            await observer(.thinking)
            if let planned = await planner.plan(
                task: task, environment: probe.rendered, registry: registry, client: client
            ) {
                opening = "\(probe.rendered)\n\n\(task)\n\n\(Planner.brief(planned.text))"
                // Billed at the planning model's own rate, before any executor turn,
                // so a run that plans and then fails still reports what it spent.
                meter.recordPlanning(planned.usage, model: planner.model)
                await observer(.planned(model: planner.model, plan: planned.text))
                await observer(.cost(meter))
                await transcript.note(kind: "plan", [
                    "model": .string(planner.model),
                    "plan": .string(planned.text),
                    "input_tokens": .number(Double(planned.usage.inputTokens)),
                    "output_tokens": .number(Double(planned.usage.outputTokens)),
                    "planning_cost_usd": .number(meter.planningCost),
                ])
            }
        }
        await transcript.append(.user(opening))

        // Classified from the raw task, before the probe is prepended — see
        // `TaskIntent.classify`.
        let intent = TaskIntent.classify(task)
        actionsTaken = 0
        observationsMade = 0
        // Cleared, not merely overwritten at the end. `run` can throw — a cancelled
        // task, a client error — and leave `conclude` uncalled, at which point a
        // second run on the same loop would answer `outcome` with the verdict from
        // the first. A stale "it acted" is exactly the reading this type exists to
        // prevent, so the window where one can be read has to be closed at the start.
        outcome = nil

        var finalText = ""

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
                await conclude(reason: "the model declined this request (\(detail))", intent: intent)
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
                    await conclude(reason: "response truncated at the \(config.maxTokens)-token limit", intent: intent)
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
                await conclude(reason: response.stopReason ?? "end_turn", intent: intent)
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
                await conclude(reason: Event.interruptedReason, intent: intent)
                return finalText.isEmpty
                    ? "Interrupted. Nothing further was done."
                    : finalText
            }
        }

        await conclude(reason: "turn limit (\(config.maxTurns)) reached", intent: intent)
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

            // Timed, because the window between a response and the next request was
            // being read as "tool execution" and is mostly not. Both recorded
            // sessions show 3.4s and 7.1s there for `pgrep -l Code` and
            // `open -a Spotify`; the commands themselves run in ~25ms under
            // `sandbox-exec`, measured. The rest is a human reading a prompt and
            // pressing a key. Left unseparated, every latency figure this project
            // produces credits the machine with the user's reaction time — and worse,
            // makes the permission gate look like a performance problem when it is
            // the one part of the run that is supposed to take as long as it takes.
            //
            // `ContinuousClock`, not `Date`: this is a duration, and a wall-clock
            // adjustment mid-prompt would otherwise record a negative one.
            let askedAt = ContinuousClock.now
            let decision = await gate.decide(tool: tool.name, risk: risk)
            let waited = ContinuousClock.now - askedAt
            let waitedSeconds = Double(waited.components.seconds)
                + Double(waited.components.attoseconds) / 1e18
            // An allow that never asked returns in microseconds. Noting those would
            // put an entry in the record for every call in a `bypass` run and measure
            // nothing but the actor hop.
            if waitedSeconds > 0.05 {
                await transcript.note(kind: "gate", [
                    "tool": .string(tool.name),
                    "seconds": .number(waitedSeconds),
                ])
            }
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

            // Counted here, not at the call site: only invocations that survived the
            // gate and actually ran count, and a failed one is not an action either —
            // `write_file` that threw changed nothing. `.read` is the whole point of
            // the distinction, so it is matched explicitly rather than by default.
            if !output.isError {
                if case .read = risk { observationsMade += 1 } else { actionsTaken += 1 }
            }
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

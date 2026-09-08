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
        /// A plan was asked for and did not arrive. The run continues without one.
        case planningFailed(model: String, reason: String)
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
        ///
        /// The wording now lives on `StopReason.interrupted`, which carries the
        /// disposition beside it; this stays as the name the renderers match, so the
        /// two can never disagree about what "interrupted" reads as.
        public static let interruptedReason = StopReason.interrupted.sentence
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
        /// Overrides pricing when the endpoint is not billed. Nil prices by model.
        public var pricing: Pricing?

        public init(
            model: String = DefaultModel.id,
            maxTokens: Int = 16_000,
            // Computer-use accuracy is materially better at high effort with adaptive
            // thinking, so this stays high rather than economising. It is dropped from
            // the request on families that predate the field — see `ModelCapabilities`.
            effort: String = "high",
            maxTurns: Int = 40,
            context: Transcript.ContextPolicy = .default,
            planner: Planner? = nil,
            pricing: Pricing? = nil
        ) {
            self.planner = planner
            self.pricing = pricing
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
        self.meter = CostMeter(model: config.model, pricing: config.pricing)
    }

    /// What the last completed run changed. `nil` until `run(task:)` returns.
    ///
    /// Readable after the fact as well as observable during, because the CLI's exit
    /// code depends on it and an observer closure is the wrong place to smuggle a
    /// value back out of an actor.
    ///
    /// Per *task*, not per session. A loop that stays open takes one instruction after
    /// another and each gets its own verdict; reporting the second task's success for
    /// the first, or the first's for the second, is the same lie as reporting success
    /// a single run did not earn. `run(task:)` clears this before it does anything.
    public private(set) var outcome: RunOutcome?

    /// What this loop has spent, across every task it has been given.
    ///
    /// Session-scoped rather than per-task, and that is the whole of the change: a
    /// `var meter = CostMeter(…)` inside the run was right while a process ran exactly
    /// one task and became a lie the moment it could run five, because the closing line
    /// would then report a five-task session as costing what its last task cost. Tokens
    /// are billed to an account, not to an instruction, so the running total has to
    /// live where the conversation does.
    ///
    /// A single `openclicky "<task>"` run is unaffected — one task, one meter, starting
    /// at zero and accumulating exactly as before, so its reported figure is unchanged
    /// byte for byte. `--planner` folds in the same way: `recordPlanning` is called once
    /// per task and adds to the session's planning total, so `(incl. $X planning)` means
    /// what every other figure on that line means.
    private var meter: CostMeter

    /// How many tasks this loop has been given, counting the one in flight.
    ///
    /// Written into each `run` record so a reader of the file can tell a session's
    /// third task from its first. The transcript is append-only and a persistent
    /// session writes several `run` entries into one file; without an index, the only
    /// way to count them is to decode every line, which is what the listing's whole
    /// backwards-scan design exists to avoid.
    private var tasksStarted = 0

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
    ///
    /// `reason` is a `StopReason` and not a `String` for the second half of that same
    /// guarantee. Five exits reach here and only one of them — the model ending its
    /// own turn — means the run got to the end of its work; the other four all read
    /// as sentences and were therefore indistinguishable to everything downstream.
    /// `StopReason` has no memberwise initialiser, so a sixth exit cannot be added
    /// without saying which of the three dispositions it is.
    @discardableResult
    private func conclude(reason: StopReason, intent: TaskIntent) async -> RunOutcome {
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
            "stop_reason": .string(result.stopReason.sentence),
            // The disposition as well as the sentence, so a listing can tell a run
            // that finished from one that ran out of road without parsing English —
            // `act=5 obs=7 unfulfilled=False stop=turn limit (12) reached` is a line
            // this record already printed, and every fact in it was true.
            "disposition": .string(result.stopReason.disposition.rawValue),
            "unfulfilled": .bool(result.isUnfulfilled),
            "incomplete": .bool(result.isIncomplete),
        ])
        await observer(.outcome(result))
        await observer(.finished(reason: reason.sentence))
        return result
    }

    /// Runs one user task to completion.
    ///
    /// - Returns: the model's closing message.
    @discardableResult
    public func run(task: String) async throws -> String {
        // Cleared here, at the entrance, rather than partway down `runToCompletion`.
        //
        // It used to be cleared after the environment probe, the `run` record and the
        // whole planning round-trip — every one of which can throw or be cancelled, and
        // any of which leaving early handed the *previous* task's verdict to a caller
        // asking about this one. That window did not exist while a process ran one task
        // and closes an entirely realistic failure now that it can run twenty: a stale
        // "it acted" read against an instruction that never got as far as its first
        // request is precisely the reading `RunOutcome` was built to prevent.
        outcome = nil

        // Every throw out of a run is recorded before it leaves.
        //
        // A run that dies on its first request left a transcript holding one user
        // message and nothing else — no turns, no outcome, no reason. The error went
        // to stderr and was gone with the scrollback, so `transcripts` showed a
        // mysterious zero-turn session and there was no way to learn afterwards what
        // had happened. Two such sessions are sitting in the wild right now from a
        // local model that turned out not to support tools, and neither says so.
        //
        // This is the same defect as a run reporting success it did not earn, one
        // layer further out: the record has to say what became of the run, and
        // "nothing was written" is not an answer a reader can act on.
        do {
            return try await runToCompletion(task: task)
        } catch is CancellationError {
            // Not a failure. The user asked for it, and the in-loop path already
            // records an interrupted outcome — noting this as an error would put two
            // contradictory verdicts in one record.
            throw CancellationError()
        } catch {
            await transcript.note(kind: "failed", [
                // Truncated: a client error can carry a whole response body, and a
                // transcript is a record, not a log sink. The first 500 characters
                // carry the status and the message every time.
                "reason": .string(String(describing: error).truncated(500)),
                "actions_taken": .number(Double(actionsTaken)),
            ])
            throw error
        }
    }

    private func runToCompletion(task: String) async throws -> String {
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
        tasksStarted += 1
        await transcript.note(kind: "run", [
            "model": .string(config.model),
            "planner": config.planner.map { .string($0.model) } ?? .null,
            "mode": .string(mode.rawValue),
            "max_tier": .number(Double(registry.maxTier.rawValue)),
            "max_turns": .number(Double(config.maxTurns)),
            // Which instruction of the session this is, 1-based. A persistent session
            // writes one of these per task into a single append-only file, and a reader
            // that assumes one `run` per session reports the last task's verdict beside
            // the first task's text. The index is what lets a listing say so — and it is
            // findable by the same backwards scan the listing already does, so counting
            // the session's tasks costs no extra reading.
            "task": .number(Double(tasksStarted)),
        ])

        // Planned before the transcript is opened, so the plan is part of the first
        // user message rather than a turn of its own. A separate turn would put a
        // second model's assistant block in a transcript that replays verbatim —
        // see `Planner` for why that is not merely untidy.
        var opening = "\(probe.rendered)\n\n\(task)"
        if let planner = config.planner {
            await observer(.thinking)
            switch await planner.plan(
                task: task, environment: probe.rendered, registry: registry, client: client
            ) {
            case let .unavailable(reason):
                // Reported, not absorbed. Planning is an optimisation and its absence
                // must not stop the run — but the user asked for a planner, and a run
                // that silently declines to plan looks exactly like one that planned
                // badly. The commonest cause is a planner the configured provider
                // cannot serve, which is a typo the user can fix in seconds if told.
                await observer(.planningFailed(model: planner.model, reason: reason))
                await transcript.note(kind: "plan_failed", [
                    "model": .string(planner.model),
                    "reason": .string(reason),
                ])

            case let .planned(planned):
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
        // Per task, like the verdict they add up to, and unlike the meter beside them:
        // what the second instruction changed is not what the first one did.
        actionsTaken = 0
        observationsMade = 0

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
                // `turn` restarts at zero for every task, so on a session that ran
                // three of them the last usage line says "turn 1" and a listing which
                // reads it as the session's length reports two turns for a session that
                // took twenty. The meter counts the whole session, so it already knows
                // the answer; writing it down is what lets the listing stay cheap.
                "session_turns": .number(Double(meter.turns)),
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
                await conclude(reason: .cutShort("the model declined this request (\(detail))"), intent: intent)
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
                    await conclude(reason: .cutShort("response truncated at the \(config.maxTokens)-token limit"), intent: intent)
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
                await conclude(reason: .concluded(response.stopReason ?? "end_turn"), intent: intent)
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
                await conclude(reason: .interrupted, intent: intent)
                return finalText.isEmpty
                    ? "Interrupted. Nothing further was done."
                    : finalText
            }
        }

        await conclude(reason: .cutShort("turn limit (\(config.maxTurns)) reached"), intent: intent)
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
            //
            // And a call the UI said did nothing is not an action either — a keystroke
            // the frontmost app ignored changed nothing just as surely as a
            // `write_file` that threw, it simply had the courtesy to return. `Risk`
            // cannot see this: it classifies what a call is *permitted* to change,
            // before it runs. `ChangeVerdict` is what the action's own check saw
            // afterwards, and it is the only structural signal that the permitted
            // change did not happen. Session
            // `39BAB4C3-478C-4D37-9933-9E2C5E2DDC45` — "press cmd+shift+p to open the
            // command palette" — recorded `act=1 obs=1 unfulfilled=False` and exited 0
            // on the strength of a `key` result that said, in words, "No observable
            // change", which the model then correctly summarised as "The command
            // palette didn't open."
            //
            // Counted as an *observation* rather than as nothing at all, deliberately.
            // The call did happen and it did return a fact about the machine: that
            // this strategy does not work here. Dropping it from both counters would
            // make `RunOutcome.report` tell the user "nothing was done — end_turn
            // after 0 observations and no actions" for a run that pressed five
            // different shortcuts, which reads exactly like the run that emitted no
            // tool calls at all and hides the difference the record exists to show.
            // Every successful invocation therefore still lands in exactly one bucket.
            if !output.isError {
                let verifiedNoOp = output.changeVerdict == .unchanged
                if case .read = risk {
                    observationsMade += 1
                } else if verifiedNoOp {
                    observationsMade += 1
                } else {
                    actionsTaken += 1
                }
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

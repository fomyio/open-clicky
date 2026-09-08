import Foundation

/// What the user asked for on the command line.
///
/// Lives in the library rather than the executable so it can be tested: `--mode` and
/// `--max-tier` decide whether the agent asks before acting and whether it can see
/// the screen at all, and both were unreachable by any test while they sat in `main`.
public struct Invocation: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case run(task: String)
        /// Runs an optional opening task and then keeps taking instructions.
        ///
        /// A separate case rather than a `Bool` beside `.run`, because the difference
        /// between the two is precisely that this one's task is optional: `openclicky
        /// -i` with nothing after it opens straight to the prompt, while `openclicky`
        /// with nothing after it is a request for the help text. An `Optional` on
        /// `.run` would have made "no task" representable in the one mode where it is
        /// meaningless, and the entry point would have had to check for it anyway.
        ///
        /// `.run` keeps its exact contract — one task, then exit 2 if it did not
        /// finish. Scripts chain off that (`openclicky "…" && next-thing`), so staying
        /// open cannot be the default: it would hang every CI job that ever called it.
        case interactive(task: String?)
        case auth
        case doctor
        /// Replays a stored session. `nil` means the most recent one.
        case transcript(session: String?)
        /// Lists stored sessions, newest first. `nil` shows a default page.
        case transcripts(limit: Int?)
        /// Deletes sessions older than a number of days, after confirmation.
        case forget(days: Int)
        /// Reports where recorded runs spent their wall-clock time.
        case bench
        /// Deletes one provider's stored key.
        case forgetKey
        case help
        /// Prints the build's identity and exits.
        case version
    }

    public var command: Command = .help
    public var mode: PermissionMode = .ask
    public var maxTier: Tier = .pixels
    public var model = DefaultModel.id
    public var effort = "high"
    /// Whether `--effort` was actually passed, as opposed to left at its default.
    ///
    /// The distinction is the whole point of the warning below: a default silently
    /// dropped on a model that cannot use it is correct and uninteresting, while a
    /// value the user typed and paid attention to disappearing is a lie.
    public var effortIsExplicit = false
    /// Whether `--model` was actually passed.
    ///
    /// The same distinction as `effortIsExplicit`, and load-bearing for a different
    /// reason: the built-in default only ever meant "the default for Anthropic", so
    /// carrying it into `--provider ollama` is a 404 that reads as a broken install.
    /// A model nobody typed is the provider's to choose.
    public var modelIsExplicit = false
    public var maxTurns = 40
    public var sandbox: ShellSandbox = .enabled
    /// From `--provider`. `nil` leaves the choice to the environment, then Anthropic.
    public var providerKind: Provider.Kind?
    /// From `--base-url`. `nil` leaves it to the environment, then the provider's own.
    public var baseURL: String?
    /// The agent's own surfaces — for a CLI, the terminal it is printing into.
    ///
    /// Set by the executable, like `pricing`: identifying the host terminal reads the
    /// environment, and this struct is parsed from arguments. Empty is the honest
    /// default — an unrecognised terminal must change nothing. It reaches the action
    /// tools through `registry`, so a value change in the agent's own scrollback stops
    /// being counted as proof that a keystroke landed in some other app.
    public var selfBundleIDs: [String] = []

    public init() {}

    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// Parses arguments, excluding the executable name.
    ///
    /// Every failure is an error rather than a fallback: silently ignoring an
    /// unrecognised `--mode` would run at the default while the user believed they
    /// had restricted it, which is the one mistake this parser must never make.
    public static func parse(_ arguments: [String]) -> Result<Invocation, ParseError> {
        var invocation = Invocation()
        var positional: [String] = []
        var index = 0
        var wantsInteractive = false

        func nextValue(for flag: String) -> String? {
            guard index < arguments.count, !arguments[index].hasPrefix("--") else { return nil }
            defer { index += 1 }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            switch argument {
            case "auth": invocation.command = .auth
            case "doctor": invocation.command = .doctor
            case "transcript": invocation.command = .transcript(session: nil)
            case "transcripts": invocation.command = .transcripts(limit: nil)
            case "forget": invocation.command = .forget(days: -1)
            case "bench": invocation.command = .bench
            case "forget-key": invocation.command = .forgetKey
            case "-h", "--help", "help": invocation.command = .help
            case "-v", "--version", "version": invocation.command = .version

            case "--mode":
                guard let raw = nextValue(for: argument),
                      let mode = PermissionMode(rawValue: raw) else {
                    return .failure(ParseError(message:
                        "--mode needs one of: \(PermissionMode.allCases.map(\.rawValue).joined(separator: ", "))"))
                }
                invocation.mode = mode

            case "--max-tier":
                guard let raw = nextValue(for: argument),
                      let value = Int(raw), let tier = Tier(rawValue: value) else {
                    return .failure(ParseError(message:
                        "--max-tier needs 0 (shell), 1 (script), 2 (accessibility) or 3 (pixels)"))
                }
                invocation.maxTier = tier

            // An empty value is rejected rather than treated as "unset". It is
            // explicit — so it wins over the environment, the stored choice and the
            // provider's default — and an empty model id reaches the endpoint as a
            // request for a model called nothing, whose error names no cause. The same
            // rule the resolver applies to an exported-but-empty variable.
            case "--model":
                guard let model = nextValue(for: argument), !model.isEmpty else {
                    return .failure(ParseError(message: "--model needs a model id"))
                }
                invocation.model = model
                invocation.modelIsExplicit = true

            case "--planner":
                guard let model = nextValue(for: argument), !model.isEmpty else {
                    return .failure(ParseError(message: "--planner needs a model id"))
                }
                invocation.plannerModel = model

            case "--provider":
                guard let raw = nextValue(for: argument),
                      let kind = Provider.Kind(rawValue: raw) else {
                    return .failure(ParseError(message:
                        "--provider needs one of: \(Provider.Kind.allCases.map(\.rawValue).joined(separator: ", "))"))
                }
                invocation.providerKind = kind

            case "--base-url":
                guard let raw = nextValue(for: argument) else {
                    return .failure(ParseError(message:
                        "--base-url needs a URL, e.g. http://localhost:11434/v1"))
                }
                invocation.baseURL = raw

            case "--effort":
                guard let effort = nextValue(for: argument), efforts.contains(effort) else {
                    return .failure(ParseError(message:
                        "--effort needs one of: \(efforts.joined(separator: ", "))"))
                }
                invocation.effort = effort
                invocation.effortIsExplicit = true

            case "--max-turns":
                guard let raw = nextValue(for: argument),
                      let turns = Int(raw), turns > 0 else {
                    return .failure(ParseError(message: "--max-turns needs a positive integer"))
                }
                invocation.maxTurns = turns

            case "--no-sandbox":
                invocation.sandbox = .disabled

            case "-i", "--interactive":
                wantsInteractive = true

            default:
                if argument.hasPrefix("-") {
                    return .failure(ParseError(message: "Unknown option '\(argument)'"))
                }
                positional.append(argument)
            }
        }

        if case .transcript = invocation.command, let name = positional.first {
            invocation.command = .transcript(session: name)
        }
        // `transcripts 50` reads as naturally as `transcript <id>`, and avoids a flag
        // for the one thing anyone wants to vary about a listing.
        if case .forget = invocation.command {
            guard let raw = positional.first, let days = Int(raw), days >= 0 else {
                return .failure(ParseError(message:
                    "forget needs a number of days, e.g. `forget 30` for sessions older than a month"))
            }
            invocation.command = .forget(days: days)
        }
        if case .transcripts = invocation.command, let count = positional.first {
            guard let limit = Int(count), limit > 0 else {
                return .failure(ParseError(message: "transcripts needs a positive count, e.g. `transcripts 50`"))
            }
            invocation.command = .transcripts(limit: limit)
        }
        // Before the bare-task rule below, and only when no subcommand claimed the
        // command: `--interactive` is about how a task is run, so `openclicky doctor
        // -i` is not a thing it can mean. Refused rather than ignored, which is the
        // rule every other value in this parser follows — a flag accepted and then
        // silently dropped is the one mistake it must never make.
        if wantsInteractive {
            guard invocation.command == .help else {
                return .failure(ParseError(message:
                    "--interactive runs tasks; it does not apply to a subcommand"))
            }
            invocation.command = .interactive(
                task: positional.isEmpty ? nil : positional.joined(separator: " ")
            )
        }
        if !positional.isEmpty, invocation.command == .help {
            invocation.command = .run(task: positional.joined(separator: " "))
        }
        return .success(invocation)
    }

    /// What the chosen model accepts and can be trusted to drive.
    public var capabilities: ModelCapabilities { .forModel(model) }

    /// The ceiling actually in force: the lower of what the user asked for and what
    /// the model can do.
    ///
    /// `--max-tier 2` and a text-only model arrive at the same registry by different
    /// routes, and the model's limit is not a preference to be overridden — offering
    /// `click` to something that cannot see the screenshot does not produce a refusal,
    /// it produces a confident coordinate for an image the model never received.
    public var effectiveMaxTier: Tier { min(maxTier, capabilities.maxTier) }

    /// The tools this invocation permits.
    ///
    /// `--max-tier` is a hard ceiling: a capped tool is not merely discouraged, it is
    /// absent from the registry, so the model cannot reach it however it is asked.
    public var registry: ToolRegistry { registry(asker: nil) }

    /// The same registry, with a way for `ask_user` to reach the person at the machine.
    ///
    /// A parameter on a method rather than a field on this struct, because an
    /// `Invocation` is `Equatable` and `Sendable` and describes what was *typed* — a
    /// closure is neither comparable nor something anybody typed. The executable owns
    /// the surface, so the executable passes it in, exactly as it passes the terminal
    /// it identified into `selfBundleIDs`. Omitting it leaves `ask_user` present and
    /// answering "nobody to ask", which is the truth for a registry with no surface.
    public func registry(asker: AskUserTool.Asker?) -> ToolRegistry {
        .standard(
            maxTier: effectiveMaxTier,
            sandbox: sandbox,
            selfBundleIDs: selfBundleIDs,
            imageSpace: capabilities.imageSpace,
            asker: asker
        )
    }

    public var loopConfiguration: AgentLoop.Configuration {
        .init(
            model: model, effort: effort, maxTurns: maxTurns,
            planner: plannerModel.map { Planner(model: $0) },
            pricing: pricing
        )
    }

    /// A model asked to plan before the executor starts, or nil to run unplanned.
    ///
    /// Not defaulted to anything. Planning costs a round-trip and a strong model's
    /// prices, and a default that silently does both would be the project deciding
    /// how the user should spend their money.
    public var plannerModel: String?

    /// The invocation as it will actually run, once the provider is known.
    ///
    /// Resolution is I/O — the environment and the config file — so it happens in the
    /// executable; folding its result back in happens here, where a test can reach it.
    /// Everything downstream (`capabilities`, `registry`, `effectiveMaxTier`,
    /// `loopConfiguration`) reads `model`, so substituting it once is the whole job.
    ///
    /// `--planner` still wins: a flag the user typed for this one run must not be
    /// overwritten by a stored preference, which is the same rule every other field
    /// here follows.
    public func resolved(with provider: Provider) -> Invocation {
        var copy = self
        copy.model = provider.model
        copy.pricing = provider.pricing
        copy.plannerModel = plannerModel ?? provider.plannerModel
        return copy
    }

    /// The rate this run is priced at, or nil to price by model.
    ///
    /// Set only by `resolved(with:)`, because whether a run is billed is a fact about
    /// the endpoint and nothing else in an invocation knows it.
    public var pricing: Pricing?

    /// A tier the user asked for and the model cannot reach, or nil.
    ///
    /// The same rule as `ignoredFlagWarning`, applied to the ceiling: `--max-tier 3`
    /// against a text-only model is accepted and then quietly reduced, and a run that
    /// never takes a screenshot looks like a run that chose not to. Said once, at the
    /// start, it is the explanation for everything that follows.
    public var cappedTierWarning: String? {
        guard effectiveMaxTier < maxTier else { return nil }
        return """
        \(model) cannot be sent images, so this run is capped at tier \
        \(effectiveMaxTier.rawValue) — the pixel tools are not loaded at all.
          It will work through the accessibility tree (`ax_capture`, `ax_press`) \
        instead, which is more reliable anyway. Use a vision model for tier 3.
        """
    }

    /// A flag that was accepted and then discarded, or nil when nothing was dropped.
    ///
    /// `output_config.effort` is a Claude 4.6+ field, so `--effort max` against Haiku
    /// is stripped from the request before it is sent — the run proceeds, costs the
    /// same, and behaves exactly as if the flag had never been typed. Accepting an
    /// argument and then ignoring it without a word is the failure this codebase
    /// treats as worse than rejecting it outright.
    ///
    /// It lives here rather than in `main.swift` because a check no test can reach is
    /// decoration; `PermissionStatus.isReady` was moved out of `main.swift` for
    /// exactly this reason after three guards turned out to be defended by nothing.
    public var ignoredFlagWarning: String? {
        guard effortIsExplicit, !ModelCapabilities.forModel(model).effort else { return nil }
        // Phrased for whichever model is actually in play. "Predates the field" was
        // written when every model here was a Claude one; against gpt-4o it is simply
        // false — `output_config.effort` is Anthropic's, and no OpenAI-compatible
        // endpoint has ever had it. A warning that misdescribes the reason sends the
        // reader looking for a newer version of the wrong thing.
        let reason = ModelCapabilities.normalized(model).hasPrefix("claude")
            ? "\(model) predates the field and rejects it"
            : "`output_config.effort` is an Anthropic field, and \(model) is not served by it"
        return """
        --effort \(effort) is ignored: \(reason), so it is left out of the request.
          Use a Claude 4.6+ model, such as --model claude-opus-5, for effort to apply.
        """
    }
}

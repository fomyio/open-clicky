import Foundation

/// What the user asked for on the command line.
///
/// Lives in the library rather than the executable so it can be tested: `--mode` and
/// `--max-tier` decide whether the agent asks before acting and whether it can see
/// the screen at all, and both were unreachable by any test while they sat in `main`.
public struct Invocation: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case run(task: String)
        case auth
        case doctor
        /// Replays a stored session. `nil` means the most recent one.
        case transcript(session: String?)
        /// Lists stored sessions, newest first. `nil` shows a default page.
        case transcripts(limit: Int?)
        /// Deletes sessions older than a number of days, after confirmation.
        case forget(days: Int)
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
    public var maxTurns = 40
    public var sandbox: ShellSandbox = .enabled

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

            case "--model":
                guard let model = nextValue(for: argument) else {
                    return .failure(ParseError(message: "--model needs a model id"))
                }
                invocation.model = model

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
        if !positional.isEmpty, invocation.command == .help {
            invocation.command = .run(task: positional.joined(separator: " "))
        }
        return .success(invocation)
    }

    /// The tools this invocation permits.
    ///
    /// `--max-tier` is a hard ceiling: a capped tool is not merely discouraged, it is
    /// absent from the registry, so the model cannot reach it however it is asked.
    public var registry: ToolRegistry {
        .standard(maxTier: maxTier, sandbox: sandbox)
    }

    public var loopConfiguration: AgentLoop.Configuration {
        .init(model: model, effort: effort, maxTurns: maxTurns)
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
        return """
        --effort \(effort) is ignored: \(model) predates the field and rejects it, \
        so it is left out of the request.
          Use a Claude 4.6+ model, such as --model claude-opus-5, for effort to apply.
        """
    }
}

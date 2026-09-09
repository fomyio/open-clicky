import Foundation

/// Where a tool sits on the capability ladder.
///
/// The ladder is the core cost/reliability idea in OpenClicky: prefer the cheapest
/// channel that can do the job, and escalate to pixels only when nothing else can.
/// Tiers are ordered, and the ordering is meaningful — it is surfaced to the model
/// in the system prompt and used to sort the tool list.
public enum Tier: Int, Comparable, Sendable, CaseIterable {
    /// Shell and filesystem. No vision tokens, fully deterministic.
    case shell = 0
    /// AppleScript / JXA / Shortcuts. Deterministic control of scriptable apps.
    case script = 1
    /// Accessibility tree. Cheap structured text; deterministic element activation.
    case accessibility = 2
    /// Screenshots and synthetic input. Expensive and approximate — the fallback.
    case pixels = 3

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The tier a tool name belongs to, without building a registry.
    ///
    /// A reader of a recorded session has a tool *name* and no instance — the
    /// transcript stores what was called, not the object that served it. Kept beside
    /// the tiers themselves rather than in the reader, so a tool added at a new tier
    /// is one edit rather than two that can disagree.
    ///
    /// Returns nil for a name this build does not know, which is what a session
    /// recorded by an older or newer binary looks like. Guessing a tier for it would
    /// put a made-up number in a report about tier discipline.
    public static func forToolNamed(_ name: String) -> Tier? {
        switch name {
        case "shell", "read_file", "write_file", "ask_user": return .shell
        case "app_script", "run_shortcut": return .script
        case "ax_capture", "ax_press", "ax_set_value": return .accessibility
        case "screenshot", "zoom", "click", "drag", "type", "key", "scroll", "wait":
            return .pixels
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .shell: return "Tier 0 (shell/files)"
        case .script: return "Tier 1 (AppleScript/Shortcuts)"
        case .accessibility: return "Tier 2 (accessibility tree)"
        case .pixels: return "Tier 3 (screenshot/pixels)"
        }
    }
}

/// How risky an invocation is, which decides whether the permission gate stops to ask.
public enum Risk: Sendable, Equatable {
    /// Observation with no side effects. Never prompts.
    case read
    /// Changes something recoverable. Prompts in `.ask` mode.
    case write(summary: String)
    /// Destructive, outward-facing, or irreversible. Prompts in every mode but `.bypass`.
    case dangerous(summary: String)

    /// The text shown to the user when this action is put to them for approval.
    ///
    /// Sanitised here rather than by each tool, because the tools kept forgetting.
    /// Shell summaries were hardened against terminal escapes and the accessibility
    /// and AppleScript ones were not, and every tool added later would have been one
    /// more place to remember. A summary carries values that came from content the
    /// agent just read — a form field, a line of a script — so an escape sequence in
    /// one can overwrite the badge printed above it and change what the user believes
    /// they are approving.
    ///
    /// Doing it on the way out means it cannot be skipped: there is no path to the
    /// prompt that does not come through here.
    public var summary: String {
        switch self {
        case .read: return "read-only"
        case let .write(text), let .dangerous(text): return Policy.summarize(text)
        }
    }

    /// The summary exactly as the tool wrote it. For tests and logs, never for display.
    var rawSummary: String {
        switch self {
        case .read: return "read-only"
        case let .write(text), let .dangerous(text): return text
        }
    }
}

/// Whether an invocation was checked against the UI afterwards, and what the check saw.
///
/// Three states, kept three states on purpose. `Risk` says what a call was *permitted*
/// to change; this says what it was *observed* to change, and the two answer different
/// questions for different tools. Most tools are never checked at all — `shell`,
/// `read_file`, `write_file`, `ax_capture`, `screenshot`, `wait` — and "not checked"
/// is emphatically not "checked and found nothing".
///
/// Collapsing this to a `Bool` is the mistake the type exists to refuse. An unverified
/// call defaulting to `false` would make `write_file` and `shell` stop counting as
/// actions, and the completion guard would then report every successful file edit as
/// "nothing was done" — the invariant in `RunOutcome` broken in the opposite
/// direction, and louder. The default is therefore `.unverified`, and only the seven
/// tools that actually run `Verified.act` ever say anything else.
public enum ChangeVerdict: Sendable, Equatable {
    /// Nobody looked. The tool has no post-action check, so nothing is claimed here.
    case unverified
    /// Checked, and the UI moved: real evidence the action landed.
    case changed
    /// Checked, and nothing observable moved — including the case where the only
    /// movement was the agent's own window, which `Verified` does not count as
    /// evidence. The action may have missed.
    case unchanged
    /// Checked, and the app could not be seen: it publishes no focused element, so
    /// there was never anything for the check to read. Distinct from `.unchanged`,
    /// which is a finding, and from `.unverified`, which means no check ran.
    ///
    /// VS Code, Chrome, Slack and Discord are all in this class. Measured: with VS
    /// Code frontmost and confirmed, `key cmd+shift+p` reported "No observable
    /// change" while `ax_capture` in the same run returned `Code — 5 elements`; the
    /// same tool in Finder reported the Go To Folder dialog opening. The keystroke
    /// worked and the check was blind.
    ///
    /// Booked like `.unchanged` at the counting site, deliberately. It may well have
    /// worked, but "may well have" is not earned success, and `RunOutcome` exists to
    /// refuse exactly that. Erring here costs a run that says it did nothing when it
    /// did something; erring the other way puts back the defect four commits removed.
    case unobservable
}

/// The result of running a tool, as it will be returned to the model.
public struct ToolOutput: Sendable {
    public var content: [Wire.ToolResultContent]
    public var isError: Bool

    /// What this invocation's own verification concluded, if it ran one.
    ///
    /// Carried structurally rather than left in the prose of `content`, because the
    /// loop has to count it and the loop must not read English to do so. See
    /// `Verified.Outcome` for the session that was reported as a success on the
    /// strength of a tool result that said, in words, that nothing had happened.
    public var changeVerdict: ChangeVerdict

    public init(
        content: [Wire.ToolResultContent],
        isError: Bool = false,
        changeVerdict: ChangeVerdict = .unverified
    ) {
        self.content = content
        self.isError = isError
        self.changeVerdict = changeVerdict
    }

    public static func text(_ text: String) -> ToolOutput {
        ToolOutput(content: [.text(text.isEmpty ? "(no output)" : text)])
    }

    /// The result of an action that verified itself, verdict and all.
    ///
    /// The one way a `Verified.Outcome` becomes a `ToolOutput`, so a call site cannot
    /// keep the sentence and drop the finding — which is precisely what seven call
    /// sites did for as long as `act` returned a `String`.
    public static func verified(_ outcome: Verified.Outcome) -> ToolOutput {
        ToolOutput(
            content: [.text(outcome.report.isEmpty ? "(no output)" : outcome.report)],
            changeVerdict: outcome.observedChange
                ? .changed
                : (outcome.couldObserve ? .unchanged : .unobservable)
        )
    }

    public static func failure(_ message: String) -> ToolOutput {
        ToolOutput(content: [.text(message)], isError: true)
    }

    public static func image(mediaType: String, base64: String, note: String? = nil) -> ToolOutput {
        var blocks: [Wire.ToolResultContent] = []
        if let note { blocks.append(.text(note)) }
        blocks.append(.image(mediaType: mediaType, base64: base64))
        return ToolOutput(content: blocks)
    }
}

/// A capability the agent can invoke.
///
/// Conformers own their JSON schema and their risk classification; the registry
/// and the permission gate stay generic over them.
public protocol Tool: Sendable {
    var name: String { get }
    var tier: Tier { get }
    var description: String { get }
    var inputSchema: JSONValue { get }

    /// Classifies an invocation before it runs, so the gate can decide whether to ask.
    ///
    /// Called with the same arguments that will be passed to `run`, and deliberately
    /// has no default implementation: `.read` skips the gate entirely, so a tool that
    /// forgot to answer this would be exempt from every permission mode. Answer it
    /// conservatively — mutating unless the call provably only observes.
    func risk(for input: JSONValue) -> Risk

    /// Executes the call. Throwing is equivalent to returning `.failure`, but the
    /// message is prefixed so the model can tell an exception from a tool-level error.
    func run(_ input: JSONValue) async throws -> ToolOutput
}

public extension Tool {
    // `risk(for:)` deliberately has no default.
    //
    // It used to default to `.read`, which is the most dangerous possible default in
    // this codebase: a read classification skips the permission gate in every mode,
    // `read-only` included. A tool added later that simply forgot to classify itself
    // would have been silently exempt from every safety control — and the omission
    // would look like nothing at all in review.
    //
    // Every tool that exists already overrides it, so removing the default costs
    // nothing today and makes the compiler ask the question of every tool written
    // from now on. Requirements are cheaper than conventions.

    var definition: Wire.ToolDefinition {
        Wire.ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            // Strict mode guarantees arguments validate against the schema, which
            // removes a whole class of "model sent a string where we wanted an int".
            strict: true
        )
    }
}

/// Holds the enabled tools and dispatches calls by name.
public struct ToolRegistry: Sendable {
    private let tools: [String: any Tool]
    public let ordered: [any Tool]

    public init(_ tools: [any Tool]) {
        // Sorted by tier so the cheapest capabilities are described first — the
        // ordering is itself a hint to the model about what to reach for.
        let sorted = tools.sorted {
            $0.tier == $1.tier ? $0.name < $1.name : $0.tier < $1.tier
        }
        self.ordered = sorted
        self.tools = Dictionary(uniqueKeysWithValues: sorted.map { ($0.name, $0) })
    }

    /// Every tool the agent ships with.
    ///
    /// One definition, because there were two: the CLI built its list in `Invocation`
    /// and the menu bar app built its own in `AppDelegate`. They agreed, but nothing
    /// made them — a tool added to one and forgotten in the other would simply be
    /// absent from that surface, with no error anywhere. The parameters are exactly
    /// what actually differs between the two callers.
    ///
    /// - Parameters:
    ///   - maxTier: hard ceiling. A capped tool is absent, not merely discouraged.
    ///   - sandbox: whether `shell` is confined. Also changes what `shell` tells the
    ///     model about its own containment.
    ///   - excludedBundleIDs: windows to keep out of screenshots — the app passes its
    ///     own overlay so the agent does not photograph itself.
    ///   - selfBundleIDs: the agent's own surfaces — the app's overlay, and for the
    ///     CLI the terminal it is printing into. Same shape of problem as
    ///     `excludedBundleIDs` and therefore the same route: an action must not count
    ///     the agent's own window redrawing as proof that it landed. Every action tool
    ///     takes it, rather than a process-global that any of them could read: there
    ///     is no ambient "who am I" in this codebase, and a hidden global is exactly
    ///     how a second surface would end up unaccounted for. See
    ///     `UIFingerprint.isSelfNoise(since:selfBundleIDs:)`.
    ///   - imageSpace: the pixel space this run's provider hands the model. Both
    ///     pixel-tier capture tools take it, because a screenshot sized for one
    ///     provider and a zoom sized for another would put two mappings in one
    ///     conversation — and `ScreenContext` only holds the most recent per screen.
    ///   - asker: how this surface puts a question to the user, for `ask_user`. Nil is
    ///     the honest default and not a disabled feature: a registry built with no
    ///     surface attached — a test, a plan, a report — genuinely has nobody to ask,
    ///     and `AskUserTool.noOneToAsk` says exactly that and returns at once. The tool
    ///     is present either way, because a model told "no tool named ask_user" learns
    ///     nothing, while one told "no answer is available here" carries on correctly.
    public static func standard(
        maxTier: Tier = .pixels,
        sandbox: ShellSandbox = .enabled,
        excludedBundleIDs: [String] = [],
        selfBundleIDs: [String] = [],
        imageSpace: ImageSpace = ScreenCapture.defaultSpace,
        asker: AskUserTool.Asker? = nil
    ) -> ToolRegistry {
        let all: [any Tool] = [
            ShellTool(sandbox: sandbox), ReadFileTool(), WriteFileTool(),
            AskUserTool(ask: asker ?? AskUserTool.noOneToAsk),
            AppleScriptTool(sandbox: sandbox, maxTier: maxTier), ShortcutsTool(),
            AXCaptureTool(),
            AXPressTool(selfBundleIDs: selfBundleIDs),
            AXSetValueTool(selfBundleIDs: selfBundleIDs),
            ScreenshotTool(excludedBundleIDs: excludedBundleIDs, space: imageSpace),
            ZoomTool(space: imageSpace),
            ClickTool(selfBundleIDs: selfBundleIDs),
            DragTool(selfBundleIDs: selfBundleIDs),
            TypeTool(selfBundleIDs: selfBundleIDs),
            KeyTool(selfBundleIDs: selfBundleIDs),
            ScrollTool(selfBundleIDs: selfBundleIDs),
            WaitTool(),
        ]
        return ToolRegistry(all.filter { $0.tier <= maxTier })
    }

    public subscript(name: String) -> (any Tool)? { tools[name] }

    public var maxTier: Tier { ordered.map(\.tier).max() ?? .shell }

    /// Tool definitions for the API request. The final entry carries the cache
    /// breakpoint so the whole tool block is cached across turns.
    public var definitions: [Wire.ToolDefinition] {
        var defs = ordered.map(\.definition)
        if !defs.isEmpty { defs[defs.count - 1].cacheControl = true }
        return defs
    }
}

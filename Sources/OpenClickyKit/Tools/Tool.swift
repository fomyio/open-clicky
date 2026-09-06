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

/// The result of running a tool, as it will be returned to the model.
public struct ToolOutput: Sendable {
    public var content: [Wire.ToolResultContent]
    public var isError: Bool

    public init(content: [Wire.ToolResultContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolOutput {
        ToolOutput(content: [.text(text.isEmpty ? "(no output)" : text)])
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
    public static func standard(
        maxTier: Tier = .pixels,
        sandbox: ShellSandbox = .enabled,
        excludedBundleIDs: [String] = []
    ) -> ToolRegistry {
        let all: [any Tool] = [
            ShellTool(sandbox: sandbox), ReadFileTool(), WriteFileTool(),
            AppleScriptTool(), ShortcutsTool(),
            AXCaptureTool(), AXPressTool(), AXSetValueTool(),
            ScreenshotTool(excludedBundleIDs: excludedBundleIDs), ZoomTool(),
            ClickTool(), DragTool(), TypeTool(), KeyTool(), ScrollTool(), WaitTool(),
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

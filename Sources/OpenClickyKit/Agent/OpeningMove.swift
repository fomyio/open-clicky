import Foundation

/// A tool call decided before the model was asked.
///
/// Some requests are not reasoning. "Open Safari" is a lookup in a finite set that is
/// sitting on the disk, and the only reason it ever cost a round trip to a language
/// model is that nothing here could enumerate the set. When something else — a
/// classifier over a closed option list — has already worked out the call, this is how
/// it reaches the loop.
///
/// **It is not a second route to execution, and that is the whole design.** An opening
/// move is not performed by whoever decided it. It is handed to `AgentLoop`, which runs
/// it through the identical path a model-emitted call takes: `Policy.escalate`, then
/// `PermissionGate.decide`, then `tool.run`, then the counting, then the transcript.
/// Nothing is skipped and nothing is special-cased — the only thing skipped is *the
/// model*, which is the part that was never deciding anything here.
///
/// The consequence worth stating: a gate that denies an opening move denies it exactly
/// as it would deny the model's. In read-only mode the focus change is refused, the
/// refusal reaches the model as an error `tool_result`, and the run carries on and
/// explains itself. That path exists for free precisely because this went through
/// `execute` rather than around it.
public struct OpeningMove: Sendable, Equatable {

    public let tool: String
    public let input: JSONValue

    /// What the fabricated assistant turn says before the call.
    ///
    /// The transcript holds an assistant message carrying this text and the `tool_use`,
    /// so the model reads the action as its own prior work rather than as something that
    /// happened to it — which is what stops it doing the same thing again. It also keeps
    /// the `tool_use`/`tool_result` pairing real, so the compaction and cache-marking
    /// paths need no special case for a turn nobody generated.
    public let narration: String

    /// What the run reports if this is all the request needed.
    public let spokenResult: String

    /// Whether the request is finished once this has run.
    ///
    /// The difference between "open Safari" and "open Safari and go to GitHub". True
    /// lets the run end without ever sending a request; false runs the move, leaves it
    /// in the transcript, and hands the loop to the model knowing it is done.
    ///
    /// Only ever a *permission* to conclude. The loop still refuses to unless the call
    /// actually ran, was allowed, returned no error, and verified as a change — see
    /// `AgentLoop`'s opening-move block.
    public let concludesTask: Bool

    public init(
        tool: String, input: JSONValue,
        narration: String, spokenResult: String, concludesTask: Bool
    ) {
        self.tool = tool
        self.input = input
        self.narration = narration
        self.spokenResult = spokenResult
        self.concludesTask = concludesTask
    }

    /// The id the fabricated `tool_use` carries.
    ///
    /// Stable and prefixed so a transcript reader can tell a pre-decided call from a
    /// model's own, which are ids the provider generated. Every `tool_result` must key
    /// to a real `tool_use`, so this is not decoration — it is the pairing.
    public func toolUseID(_ index: Int) -> String { "opening_\(index)" }
}

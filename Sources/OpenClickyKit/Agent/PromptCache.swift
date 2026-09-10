import Foundation

/// Where a request's cache breakpoints go.
///
/// The Messages API caches a *prefix*: a `cache_control` marker says "everything up to
/// here is one cache entry", and a later request reads back the longest prefix whose
/// bytes match exactly. Two things follow, and both are the reason this is a type
/// rather than four lines at the call site.
///
/// **Order is the whole design.** The request is assembled stable-to-volatile — tools,
/// then the system prompt, then the machine's screens, then the session's grants, then
/// the conversation, and last of all whatever just happened. Anything volatile placed
/// earlier than something stable invalidates the stable thing behind it, at full price,
/// on every turn. That failure is invisible from the outside: the request is still
/// correct and the answer is still right, only the bill changes — which is why
/// `CostMeter.cacheHitRate` exists and why a rate near zero is treated as a defect
/// report rather than a statistic.
///
/// **There are only four.** The API accepts four `cache_control` blocks per request, so
/// they are a budget to be spent, not a flag to be set everywhere. Two are fixed —
/// the tool block and the end of the system prefix — and the remaining two roll forward
/// through the conversation, which is the arrangement that keeps a growing history
/// cached without a breakpoint per turn.
public enum PromptCache {

    /// Breakpoints one request may carry. The API rejects a fifth.
    public static let budget = 4

    /// The two the prefix claims: the tool block, and the last cached system block.
    public static let reservedForPrefix = 2

    /// The two left for the conversation.
    public static var forHistory: Int { budget - reservedForPrefix }

    /// `messages` with the history breakpoints set, and every other breakpoint cleared.
    ///
    /// Two markers, and they do different jobs:
    ///
    /// - one at the end of the **settled** region — the part of the history the context
    ///   policy has finished rewriting. This is the marker that reliably *reads*: it is
    ///   the only place in the conversation whose prefix is guaranteed to be
    ///   byte-identical to what the last request sent, and it grows every turn.
    /// - one on the **last** message, which reads back on any turn where nothing aged
    ///   out behind it. Early in a session that is every turn, and it caches the
    ///   conversation whole; later it degrades to a write the next turn will not use.
    ///   Kept because the surcharge is 0.25× on the unsettled tail alone, while the
    ///   turns it does hit save 0.9× on everything.
    ///
    /// Splitting them like this is the whole reconciliation between two things that
    /// look incompatible. Pruning is *retroactive* — a screenshot intact on turn two is
    /// elided on turn four — and caching matches on a *prefix*, so a breakpoint with
    /// live pruning behind it never hits and the history is re-billed in full every
    /// turn. Placing one marker behind the pruning frontier is what makes a growing
    /// conversation cacheable without giving up the pruning that keeps it small.
    /// See `Transcript.settledThrough(_:policy:)` for where that frontier is.
    ///
    /// A turn boundary is the end of a user message, never the middle of an assistant
    /// one. An assistant turn is `thinking` + `tool_use` blocks bound to each other,
    /// and the API pairs each `tool_use` with the `tool_result` answering it — so the
    /// only quiescent point is after the results come back. The settled marker is
    /// snapped backwards onto one rather than dropped where the frontier happens to
    /// land.
    ///
    /// Cheap to get wrong in only one direction: a misplaced breakpoint shortens the
    /// prefix that matches, and can never make the request incorrect.
    public static func markingHistory(
        _ messages: [Wire.Message], settledThrough: Int = 0
    ) -> [Wire.Message] {
        var marked = messages.map { $0.caching(false) }
        guard let last = marked.indices.last else { return marked }
        marked[last] = marked[last].caching(true)

        // Strictly before `last`, so the two markers cannot land on the same message:
        // a session's first request has nothing settled and nothing cached yet, and one
        // marker is the honest answer there.
        let frontier = min(settledThrough, last)
        if let settled = marked[..<max(0, frontier)].indices.last(where: {
            marked[$0].role == .user
        }) {
            marked[settled] = marked[settled].caching(true)
        }
        return marked
    }

    /// The system blocks, stable first, with the breakpoint on the last cached one.
    ///
    /// - Parameters:
    ///   - stable: the prompt and ladder. Fixed for the whole session.
    ///   - environment: the machine's screens, or empty. Also fixed for the session,
    ///     but captured separately and therefore its own block.
    ///   - session: grants and permission mode, re-read every turn.
    ///
    /// `session` is left outside the cached region deliberately. It is about a hundred
    /// tokens, so caching it saves nothing worth measuring, and it is the one block
    /// here that can change mid-session — a user granting Accessibility while the agent
    /// is waiting flips it. Inside the breakpoint that grant would invalidate the
    /// prompt and the tools with it; outside, it costs the hundred tokens it is worth.
    ///
    /// An empty `environment` is dropped rather than sent blank, so a machine with no
    /// screens attached does not spend a breakpoint on nothing.
    public static func systemBlocks(
        stable: String, environment: String, session: String
    ) -> [Wire.SystemBlock] {
        var blocks: [Wire.SystemBlock] = []
        if environment.isEmpty {
            blocks.append(.init(stable, cacheControl: true))
        } else {
            blocks.append(.init(stable))
            blocks.append(.init(environment, cacheControl: true))
        }
        blocks.append(.init(session))
        return blocks
    }
}

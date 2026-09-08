import Foundation

/// One answer a suspended run is waiting for, and the race that losing it wedges.
///
/// A graphical surface cannot answer a prompt the way a terminal does. `readLine()`
/// blocks the thread that asked; a panel has to hand the question to the window server,
/// return, and be resumed later by a button. That "later" is a `CheckedContinuation`,
/// and a continuation nobody resumes is not a slow run, it is a dead one — the agent
/// loop is parked inside a tool call, and with one loop serving a whole conversation the
/// next instruction waits for this one to unwind, so a single lost resume takes every
/// task after it as well.
///
/// **The window this exists to close.** The continuation is created wherever the tool
/// happens to be running — the session controller's executor, not the main actor — and
/// has to hop to the main actor to register itself somewhere a button can reach it.
/// Between the moment the prompt becomes real (the overlay is showing it) and the moment
/// the continuation lands here, there is a stretch in which an answer *is* owed and
/// there is nothing to resume. Escape, Stop, or the next instruction arriving in that
/// stretch resumed nothing at all, and the run hung forever. The fix is two flags rather
/// than one pointer: `isExpected`, set synchronously on the main actor *before* the
/// prompt goes up, says an answer is owed; `wasCancelled` remembers a resolution that
/// arrived too early so that registration can answer it on the spot instead of parking.
///
/// **Why this is one type and not two copies.** The overlay now blocks on two different
/// things — may this tool run (`Bool`), and what is your answer
/// (`AskUserTool.Answer`) — and they are subject to the identical race for the identical
/// reason. Two copies of a concurrency fix is one copy that can be corrected alone: the
/// day someone notices a flaw here, they fix the one they were looking at, and the other
/// keeps hanging. So the mechanism is generic over what is being waited for, and the
/// only thing each caller supplies is the value that means "nobody is going to answer
/// this".
///
/// **Why it lives in the library.** Its two flags are the whole of a fix that no
/// integration test can reach through AppKit, and a guard no test can reach is one the
/// mutation sweep calls NOT CAUGHT. The same argument that moved `SummonedApp.Memory`
/// out of the app: the rule is decidable, so it belongs where tests can drive it.
///
/// Main-actor-isolated on purpose, and not an actor of its own. The point of the fix is
/// that "an answer is owed" is decided on the same executor that decides "this run is
/// being cancelled", with no suspension between the two — an actor would put a hop
/// there, which is precisely the gap being closed, and would make cancellation `async`
/// at call sites that must resolve before they return.
@MainActor
public final class PendingReply<Answer: Sendable> {

    /// Resolves the wait, once it has registered itself here.
    private var continuation: CheckedContinuation<Answer, Never>?

    /// Whether a wait is in flight and therefore owed an answer.
    ///
    /// True from before the prompt is shown until after it is answered, which is wider
    /// than `continuation != nil` by exactly the width of the race.
    private var isExpected = false

    /// Set when a resolution arrived before the continuation had registered, so the
    /// registration can answer it immediately instead of hanging. Only ever set while
    /// `isExpected`, or it would poison the *next* prompt — which the user would
    /// experience as the agent refusing something nobody was asked about.
    private var wasCancelled = false

    /// What an unanswerable wait resolves to. `false` for an approval; for a question,
    /// the `unavailable` case that tells the model nobody was there rather than
    /// inventing a reply on the user's behalf.
    private let whenCancelled: Answer

    public init(whenCancelled: Answer) {
        self.whenCancelled = whenCancelled
    }

    /// Whether an answer is owed right now.
    public var isPending: Bool { isExpected }

    /// Whether something is registered and resumable this instant. Narrower than
    /// `isPending` by the width of the race — which is the only reason both exist.
    public var isResumable: Bool { continuation != nil }

    /// Marks an answer as owed for the whole of `body`, and clears the bookkeeping
    /// after it however it ends.
    ///
    /// Must be entered on the main actor before anything puts the prompt on screen, and
    /// it is: this is a main-actor method called from main-actor code, so the flag is
    /// set with no suspension between the decision and the prompt becoming real. The
    /// `defer` is why this is a wrapper rather than a pair of `begin`/`end` calls — a
    /// path that returned early without clearing `wasCancelled` would deny the next
    /// prompt without asking.
    public func expecting<Result>(_ body: () async -> Result) async -> Result {
        isExpected = true
        defer {
            isExpected = false
            wasCancelled = false
        }
        return await body()
    }

    /// Suspends until someone resolves, or answers immediately if the wait was already
    /// cancelled on its way here.
    ///
    /// `nonisolated` because the caller is the tool, running on whatever executor the
    /// agent loop handed it; the hop to the main actor is the thing being guarded, so it
    /// is done here in one place rather than at each call site.
    ///
    /// - Parameter onRegistered: run on the main actor once this is resumable, which is
    ///   the only safe moment to show the prompt. Presenting before registering would
    ///   put a control on screen that resolves nothing.
    public nonisolated func wait(
        onRegistered: @escaping @MainActor @Sendable () -> Void = {}
    ) async -> Answer {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.register(continuation, onRegistered: onRegistered)
            }
        }
    }

    /// Answers the outstanding wait, from wherever the answer came from.
    ///
    /// One funnel for every caller — the buttons, Escape, Stop, the start of the next
    /// run — because the hazard is the same in all of them and the fix is not the
    /// obvious one.
    public func resolve(_ value: Answer) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
            return
        }
        // Only while one is actually owed. Latching speculatively would answer a prompt
        // that has not been asked yet.
        if isExpected { wasCancelled = true }
    }

    /// Nobody is going to answer this: resolve it with the value that says so.
    public func cancel() {
        resolve(whenCancelled)
    }

    private func register(
        _ continuation: CheckedContinuation<Answer, Never>,
        onRegistered: @MainActor () -> Void
    ) {
        guard !wasCancelled else {
            wasCancelled = false
            continuation.resume(returning: whenCancelled)
            return
        }
        self.continuation = continuation
        onRegistered()
    }
}

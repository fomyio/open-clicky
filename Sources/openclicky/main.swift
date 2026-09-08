import Foundation
import OpenClickyKit

// MARK: - Terminal rendering

enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    /// Whether the next instruction will come from a person at a keyboard.
    ///
    /// A different question from `isTTY`, which asks about *output*, and an interactive
    /// session needs both answers: `openclicky -i "…" > run.log` still has a human at
    /// the prompt, while `printf 'a\nb\n' | openclicky -i` has none and must not draw
    /// a prompt glyph into whatever is reading its output. Neither may sit waiting for
    /// input that will never arrive — a closed or exhausted stdin ends the session.
    static let stdinIsTTY = isatty(STDIN_FILENO) == 1

    static func style(_ text: String, _ code: String) -> String {
        isTTY ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func dim(_ t: String) -> String { style(t, "2") }
    static func bold(_ t: String) -> String { style(t, "1") }
    static func green(_ t: String) -> String { style(t, "32") }
    static func yellow(_ t: String) -> String { style(t, "33") }
    static func red(_ t: String) -> String { style(t, "31") }
    static func blue(_ t: String) -> String { style(t, "34") }

    static func out(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Writes without a trailing newline, for text arriving a fragment at a time.
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func err(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Reads a line from the terminal, bypassing stdin so it works while piped.
    static func ask(_ prompt: String) -> String? {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        return readLine(strippingNewline: true)
    }
}

/// Carries the report across the observer closure, which is `@Sendable`.
final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private let make: @Sendable () -> RunReport
    private var report: RunReport

    /// Takes a factory rather than a value, so `startTask` has something to build from.
    init(_ make: @escaping @Sendable () -> RunReport) {
        self.make = make
        self.report = make()
    }

    func lines(for event: AgentLoop.Event) -> [RunReport.Line] {
        lock.lock(); defer { lock.unlock() }
        return report.lines(for: event)
    }

    /// Starts the next instruction with a renderer that remembers nothing of the last.
    ///
    /// `RunReport` holds the outcome it was handed until `.finished` arrives, which is
    /// correct within a task and a trap across two: a task that throws before the loop
    /// concludes never emits `.finished`, so the held verdict would sit there waiting
    /// to be printed under the *next* task's closing line. Nothing in a one-task
    /// process could ever read it; a session that stays open would. Replacing the
    /// renderer per task makes that structural rather than a fact about which events
    /// happen to fire.
    func startTask() {
        lock.lock(); defer { lock.unlock() }
        report = make()
    }
}

// MARK: - Argument parsing
//
// The model itself lives in OpenClickyKit as `Invocation`, so `--mode` and
// `--max-tier` — which decide whether the agent asks before acting and whether it can
// see the screen — are reachable by tests. They were not while they lived here.

/// The usage text, in the library-visible layer so its claims can be checked.
///
/// Every flag named here must parse and every example must run, or the help is
/// documentation of a program that does not exist.
let usage = Usage.text(bold: Term.bold)

// MARK: - Commands

/// - Returns: whether everything it checked is in order.
///
/// The exit code is the verdict, so `openclicky doctor && openclicky "…"` guards a
/// run the way `brew doctor` does. It reported missing permissions and absent
/// credentials and then exited 0, which tells a script the machine is ready.
@discardableResult
func runDoctor(_ invocation: Invocation = Invocation()) async -> Bool {
    Term.out(Term.bold("OpenClicky doctor"))
    Term.out("")

    let permissions = PermissionStatus.current()
    let mark = { (ok: Bool) in ok ? Term.green("✓") : Term.red("✗") }
    Term.out("  \(mark(permissions.accessibility)) Accessibility        \(permissions.accessibility ? "granted" : "not granted")")
    Term.out("  \(mark(permissions.screenRecording)) Screen Recording     \(permissions.screenRecording ? "granted" : "not granted")")

    // Which endpoint this machine is actually configured to call, before anything is
    // said about the credential for it. "A key is rejected" and "the provider is
    // Ollama and nothing is listening" are different problems with the same symptom,
    // and a diagnostic that reports only the second half sends people to the wrong one.
    var verification: Credentials.Verification?
    // The highest tier this configuration can actually reach, which is what the
    // verdict below is measured against. Assume the full ladder until the provider
    // says otherwise, so an unresolvable provider is not also reported as ready.
    var ceiling = invocation.maxTier
    let provider = try? Provider.resolve(config: ConfigFile(),
        kind: invocation.providerKind,
        baseURL: invocation.baseURL,
        model: invocation.modelIsExplicit ? invocation.model : nil,
        planner: invocation.plannerModel
    )

    if let provider {
        Term.out("  \(mark(true)) Provider             \(provider.summary)")
        // Checked against the endpoint, not merely found. A diagnostic exists to
        // answer "why is this not working", and "a key is present" is not an answer
        // to that — a key that is present and rejected looks identical here to one
        // that works, and so does a model the provider has never heard of.
        let result = await provider.verify()
        verification = result
        switch result {
        case .working:
            Term.out("  \(mark(true)) Credentials          verified against \(provider.kind.label)")
        case let .rejected(detail):
            Term.out("  \(mark(false)) Credentials          rejected by \(provider.kind.label) — \(detail)")
            Term.out(Term.dim("      Run `openclicky auth --provider \(provider.kind.rawValue)` with a valid key."))
        case let .misconfigured(detail):
            Term.out("  \(mark(false)) Endpoint             will not serve this request — \(detail)")
            Term.out(Term.dim("      The credential is fine. Check the model id, or pull it:"))
            Term.out(Term.dim("      `openclicky --provider \(provider.kind.rawValue) --model <id> …`"))
        case let .unreachable(detail):
            // Not a verdict on the key, so not a verdict on the machine.
            Term.out("  \(mark(true)) Credentials          found, not checked — \(detail)")
        }

        // What the model can actually do, which decides the whole shape of a run.
        let capabilities = provider.capabilities
        ceiling = min(invocation.maxTier, capabilities.maxTier)
        // The image space is only reported where images exist. Printing
        // "images in the unconstrained space" for a model that cannot be sent one
        // reads as a setting rather than as the absence of a question.
        let space = capabilities.vision ? " · images in the \(capabilities.imageSpace.name) space" : ""
        Term.out("  \(mark(true)) Model capability     tier 0–\(ceiling.rawValue)\(capabilities.vision ? "" : " (no vision)")\(space)")
        if !capabilities.vision {
            Term.out(Term.dim("      Screenshots and clicks are not loaded for this model; it works"))
            Term.out(Term.dim("      through the accessibility tree instead, and Screen Recording"))
            Term.out(Term.dim("      is not needed."))
        }
        // Which store answered. "Configured" is two situations with two different
        // fixes, and someone chasing a stale key needs to know which one to edit.
        if let source = provider.source {
            Term.out(Term.dim("      key from: \(source.rawValue)"))
        }
        // A planner is the one part of a run that costs money before anything visible
        // happens, so a choice that buys nothing is worth naming here rather than in
        // a bill.
        if let planner = provider.plannerModel,
           let caution = ModelCatalog.plannerCaution(planner: planner, executor: provider.model) {
            Term.out(Term.yellow("      \(caution.replacingOccurrences(of: "\n", with: " "))"))
        }
    } else {
        // The resolution error says which provider and what to do about it.
        do {
            _ = try Provider.resolve(config: ConfigFile(),
                kind: invocation.providerKind,
                baseURL: invocation.baseURL,
                model: invocation.modelIsExplicit ? invocation.model : nil,
                planner: invocation.plannerModel
            )
        } catch {
            Term.out("  \(mark(false)) Provider             not configured")
            Term.out(Term.dim(String(describing: error).split(separator: "\n")
                .map { "      " + $0 }.joined(separator: "\n")))
        }
    }
    Term.out("")

    if let advice = permissions.advice {
        Term.out(Term.yellow(advice))
        Term.out("")
        Term.out(Term.dim("A CLI inherits its terminal's grants, so grant them to Terminal/iTerm, not to openclicky."))
        Term.out("")
        let answer = Term.ask("Ask macOS for the missing permissions now? [y/N]: ")?
            .lowercased().trimmingCharacters(in: .whitespaces) ?? "n"
        if answer == "y" || answer == "yes" {
            if !permissions.accessibility { AXCapture.shared.requestTrust() }
            if !permissions.screenRecording { ScreenCapture.shared.requestPermission() }
            Term.out(Term.dim("Requested. Screen Recording needs a relaunch of your terminal to take effect."))
        }
    } else if ceiling == .pixels {
        Term.out(Term.green("All four tiers are available."))
    } else {
        // Naming the real number, because "all four tiers are available" beside a
        // model that cannot see would be the diagnostic contradicting itself.
        Term.out(Term.green("Tiers 0–\(ceiling.rawValue) are available — everything this configuration can reach."))
    }

    let settings = (try? ConfigFile().settings()) ?? ConfigFile.Settings()
    if !settings.isEmpty {
        Term.out(Term.dim("Provider and model come from \(ConfigFile.defaultURL.path) — the app's Settings window writes it."))
        Term.out(Term.dim("  A flag or an environment variable overrides it for one run."))
        Term.out("")
    }

    let storage = Transcript.storage()
    if storage.sessions > 0 {
        Term.out("")
        Term.out("Session records: \(storage.summary)")
        Term.out(Term.dim("  \(storage.directory.path) — kept in full, including screenshots, and never pruned."))
        Term.out(Term.dim("  Read the most recent with `openclicky transcript`, or clear old ones with `openclicky forget <days>`."))
    }

    // Labelled, because unlabelled this reads as internals leaking into a diagnostic
    // rather than as the answer to "what does the agent know before I say anything".
    let probe = ContextProbe.capture()
    Term.out("")
    Term.out("Context every run starts with:")
    Term.out(Term.dim(probe.rendered))
    return permissions.isReady(credentials: verification, upTo: ceiling)
}

/// Deletes session records older than `days`, after showing what will go.
///
/// `doctor` has been reporting that these accumulate and are never pruned while
/// offering no way to act on it. Deleting someone's screenshots is their decision, so
/// this shows exactly what it would remove and asks — the tool's job is to make the
/// decision possible, not to make it.
///
/// - Returns: whether it completed. Nothing to delete is a success.
@discardableResult
func runForget(days: Int) -> Bool {
    let storage = Transcript.storage()
    let doomed = TranscriptReport.listings(in: storage.directory, olderThan: days)
    guard !doomed.isEmpty else {
        Term.out("No sessions older than \(days) day\(days == 1 ? "" : "s").")
        return true
    }

    let bytes = doomed.compactMap {
        (try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? Int) ?? nil
    }.reduce(0, +)
    let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)

    Term.out("\(doomed.count) session\(doomed.count == 1 ? "" : "s") older than \(days) day\(days == 1 ? "" : "s"), \(size):")
    Term.out("")
    for listing in doomed.prefix(10) { Term.out(listing.line) }
    if doomed.count > 10 { Term.out(Term.dim("  … and \(doomed.count - 10) more")) }
    Term.out("")

    // Typed confirmation, not a keypress. This is irreversible, and the same reasoning
    // that stopped a stray Return approving a destructive tool call applies here.
    let answer = Term.ask("Delete these permanently? Type 'delete' to confirm: ")?
        .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard answer == "delete" else {
        Term.out("Nothing was deleted.")
        return true
    }

    var removed = 0
    for listing in doomed {
        do {
            try FileManager.default.removeItem(at: listing.url)
            removed += 1
        } catch {
            Term.err(Term.red("Could not delete \(listing.url.lastPathComponent): \(error)"))
        }
    }
    Term.out(Term.green("Deleted \(removed) of \(doomed.count)."))
    return removed == doomed.count
}

/// Lists stored sessions, newest first.
/// - Parameter limit: how many to show. `nil` shows a page, because a listing that
///   fills the scrollback is one you cannot read the top of.
func runTranscripts(limit: Int?) {
    let storage = Transcript.storage()
    let listings = TranscriptReport.listings(in: storage.directory)
    guard !listings.isEmpty else {
        Term.out("No sessions recorded yet in \(storage.directory.path).")
        return
    }
    let shown = limit ?? 20
    Term.out(Term.dim("\(storage.summary) in \(storage.directory.path)"))
    Term.out("")
    for listing in listings.prefix(shown) { Term.out(listing.line) }
    Term.out("")
    if listings.count > shown {
        Term.out(Term.dim("Showing \(shown) of \(listings.count) — `openclicky transcripts \(listings.count)` for all."))
    }
    Term.out(Term.dim("Replay one with `openclicky transcript <id>`."))
}

/// Replays a stored session.
///
/// The record was written on every run and read by nothing — megabytes a session,
/// reported by `doctor`, never pruned, and openable only with `jq` and patience.
/// - Returns: whether a session was found and replayed.
@discardableResult
func runTranscript(_ session: String?) -> Bool {
    let storage = Transcript.storage()
    let files = ((try? FileManager.default.contentsOfDirectory(
        at: storage.directory, includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []).filter { $0.pathExtension == "jsonl" }

    let chosen: URL?
    if let session {
        chosen = session.contains("/")
            ? URL(fileURLWithPath: (session as NSString).expandingTildeInPath)
            : files.first { $0.lastPathComponent.hasPrefix(session) }
    } else {
        chosen = files.max {
            let date = { (url: URL) in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            return date($0) < date($1)
        }
    }

    guard let url = chosen else {
        // Non-zero, because a script asking for a session that does not exist has not
        // succeeded — it printed a sentence and returned success.
        Term.out(session.map { "No session matching \"\($0)\" in \(storage.directory.path)." }
            ?? "No sessions recorded yet in \(storage.directory.path).")
        return false
    }

    do {
        let entries = try TranscriptReport.entries(at: url)
        Term.out(Term.dim("\(url.lastPathComponent) — \(entries.count) entries"))
        Term.out("")
        for line in TranscriptReport.lines(for: entries) {
            switch line.emphasis {
            case .detail: Term.out(Term.dim(line.text))
            case .speech: Term.out(line.text)
            case .success: Term.out(Term.green(line.text))
            case .failure, .warning: Term.out(Term.red(line.text))
            }
        }
        return true
    } catch {
        Term.out(Term.red("Could not read \(url.path): \(error)"))
        return false
    }
}

func runAuth(_ invocation: Invocation = Invocation()) async {
    // Which provider's key this is. A key stored for one provider can never be picked
    // up as another's — resolution reads a single entry per provider, and a shared one
    // would make `--provider openai` quietly sign with an Anthropic key and 401.
    let kind = invocation.providerKind
        ?? ProcessInfo.processInfo.environment["OPENCLICKY_PROVIDER"]
            .flatMap(Provider.Kind.init(rawValue:))
        ?? .anthropic

    let config = ConfigFile()
    if (try? config.keys()[kind.rawValue]) != nil {
        Term.out(Term.dim("\(kind.article) \(kind.label) key is already stored. Entering one now replaces it."))
    }
    if kind == .ollama {
        Term.out(Term.dim("Ollama needs no key by default — this is only for a proxied or remote one."))
    }
    Term.out("Paste your \(kind.label) API key (input is not echoed).")

    // Trimmed before anything looks at it. A key pasted from a password manager or a
    // web page routinely carries a space, and untrimmed it failed in both directions:
    // a leading one made a valid key be rejected as "not an Anthropic API key", and a
    // trailing one stored a key that 401s on every request afterwards.
    let entered = readPassword(prompt: "API key: ")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let key = entered, !key.isEmpty else {
        Term.err(Term.red("No key entered."))
        exit(1)
    }
    // Only Anthropic has a checkable shape. Every other provider's keys vary by
    // deployment — a LiteLLM proxy issues whatever its operator configured — so
    // guessing at a prefix would reject valid keys, which is worse than accepting an
    // invalid one that the verification below is about to catch anyway.
    if kind == .anthropic, !key.hasPrefix("sk-ant-") {
        Term.err(Term.red("That does not look like an Anthropic API key (expected an sk-ant- prefix)."))
        exit(1)
    }
    // The config file is the only store. The Keychain used to be an option and is
    // gone: its read is gated by an ACL granted per binary, `swift build` produces a
    // new one every time, and a tool that asks for a password on each run teaches its
    // user to click through prompts — which costs them more than a `0600` file does.
    do {
        try config.setKey(key, provider: kind.rawValue)
        Term.out(Term.green("✓ Stored in \(config.url.path) (mode 600, readable only by you)."))
        Term.out(Term.dim("  Plain text, so anything that can read your home directory can read it."))
        Term.out(Term.dim("  Delete it with `openclicky forget-key --provider \(kind.rawValue)`."))
    } catch {
        Term.err(Term.red("Could not write \(config.url.path): \(error)"))
        exit(1)
    }

    // "Stored" is not the same claim as "works", and someone told the first while
    // hearing the second discovers the difference three commands later, attributing
    // it to something else. One token in and one out settles it now.
    Term.out(Term.dim("Checking it against the API…"))
    // Resolved rather than constructed, so this exercises the exact path a run takes
    // — including the file that was just written. A check that bypasses the lookup it
    // is meant to validate proves only that the key works somewhere.
    let verification: Credentials.Verification
    do {
        verification = await (try Provider.resolve(config: ConfigFile(),
            kind: kind,
            baseURL: invocation.baseURL,
            model: invocation.modelIsExplicit ? invocation.model : nil
        )).verify()
    } catch {
        Term.err(Term.red("\(error)"))
        exit(1)
    }
    switch verification {
    case .working:
        Term.out(Term.green("✓ \(verification.summary)"))
    case .rejected:
        Term.err(Term.red(verification.summary))
        exit(1)
    case .misconfigured:
        // The key was stored and the endpoint accepted it — the model id is the
        // problem, and `auth` did its job. Failing here would report a successful
        // store as an error, which is the mirror of the mistake this verification
        // exists to prevent.
        Term.out(Term.yellow(verification.summary))
    case .unreachable:
        Term.out(Term.dim(verification.summary))
    }
}

/// Reads a secret without echoing it to the terminal.
func readPassword(prompt: String) -> String? {
    FileHandle.standardOutput.write(Data(prompt.utf8))
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    let original = term
    term.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
    defer {
        var restore = original
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    return readLine(strippingNewline: true)
}

/// Deletes one provider's stored key.
///
/// Promised by `auth`'s own output before it existed, which meant the command it told
/// people to run was read as a *task* and sent to a model — a nonsense run, billed.
/// The help names it too, so the test that holds the help to the parser covers it.
func runForgetKey(_ invocation: Invocation) -> Bool {
    let kind = invocation.providerKind
        ?? ProcessInfo.processInfo.environment["OPENCLICKY_PROVIDER"]
            .flatMap(Provider.Kind.init(rawValue:))
        ?? .anthropic
    let config = ConfigFile()

    do {
        guard (try config.keys()[kind.rawValue]) != nil else {
            Term.out("No \(kind.label) key was stored.")
            return true
        }
        try config.removeKey(provider: kind.rawValue)
    } catch {
        Term.err(Term.red("Could not update \(config.url.path): \(error)"))
        return false
    }

    Term.out(Term.green("✓ Removed the \(kind.label) key from \(config.url.path)."))
    // Only the file is this command's to clear. A key exported in a shell outlives it,
    // and reporting a removal while `ANTHROPIC_API_KEY` is still set would be the
    // clearest possible version of the lie this codebase keeps hunting.
    if ProcessInfo.processInfo.environment[kind.apiKeyVariable] != nil
        || ProcessInfo.processInfo.environment["OPENCLICKY_API_KEY"] != nil {
        Term.out(Term.yellow("  A key is still set in your environment, and it wins over the file."))
    }
    return true
}

/// Prints where recorded runs spent their wall-clock time.
///
/// Reads the sessions already on disk rather than running anything: every recorded
/// run is a latency measurement, and this is the only thing that reads them as one.
/// That matters for a before-and-after — a baseline derived from runs that predate
/// the change cannot have been shaped by it.
func runBench() {
    let benchmark = LatencyBenchmark.load(from: Transcript.defaultDirectory)
    for line in benchmark.rendered() { Term.out(line) }
}

/// How the last instruction of a session ended, which is all the exit code reports.
///
/// One task or twenty, the caller in a shell wants the same thing: whether the last
/// thing it asked for worked. A session-wide verdict would have to invent a rule for
/// "three succeeded and one did not", and every rule for that is a guess about what
/// the script is chaining on.
enum TaskEnding {
    /// No instruction ever ran — `openclicky -i`, left at the prompt.
    case none
    case completed
    /// The run changed nothing, or was cut off before it finished. See
    /// `RunOutcome.isIncomplete`, which is the same rule a one-task run exits on.
    case incomplete
    case cancelled
    case failed

    /// Exit codes, deliberately identical to the ones a single `openclicky "<task>"`
    /// has always produced: 2 for a run that did not complete, 1 for one that threw,
    /// 130 for a ctrl-C. An interactive session that never ran anything exits 0 —
    /// nothing was asked, so nothing fell short.
    var exitCode: Int32 {
        switch self {
        case .none, .completed: return 0
        case .failed: return 1
        case .incomplete: return 2
        case .cancelled: return 130
        }
    }
}

/// What ctrl-C means right now, which depends on whether a task is running.
///
/// One signal source for the whole process, consulting this, rather than installing and
/// tearing one down per task: a SIGINT that lands during the swap reaches the default
/// disposition and kills the process outright — potentially between a mouse-down and
/// its mouse-up, which is the exact thing the handler exists to prevent.
///
/// The rules, in the order a user meets them:
///
///   - a task is running, first press → stop it at the next action boundary;
///   - the same task, second press → the user wants out now, so exit;
///   - no task running → leave the session.
///
/// The third case only arises where there is a session to leave. A one-shot run keeps
/// the in-flight state after its task ends (`returnsToAPrompt` is false), so a stray
/// signal there behaves exactly as it did before any of this existed: a cancel of a
/// finished task, which does nothing, then a forced exit on the second press.
final class Interrupts: @unchecked Sendable {
    enum Response {
        case stopTheTask(@Sendable () -> Void)
        case forceExit
        case leaveTheSession
    }

    private let lock = NSLock()
    private let returnsToAPrompt: Bool
    private var cancelInFlight: (@Sendable () -> Void)?
    private var alreadyAsked = false

    init(returnsToAPrompt: Bool) { self.returnsToAPrompt = returnsToAPrompt }

    func taskStarted(cancel: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        cancelInFlight = cancel
        // Per task, so the second press that forces an exit means the second press
        // *of this task*. Carried across, one ctrl-C in task 1 would make the very
        // first ctrl-C in task 9 kill the process instead of stopping the task.
        alreadyAsked = false
    }

    func taskEnded() {
        lock.lock(); defer { lock.unlock() }
        guard returnsToAPrompt else { return }
        cancelInFlight = nil
    }

    func signalArrived() -> Response {
        lock.lock(); defer { lock.unlock() }
        guard let cancelInFlight else { return .leaveTheSession }
        if alreadyAsked { return .forceExit }
        alreadyAsked = true
        return .stopTheTask(cancelInFlight)
    }
}

/// The next instruction, or nil when there will not be another one.
///
/// Reads stdin, which is the whole point, and is careful about two things. It draws a
/// prompt only for a terminal — piping a short script in (`printf 'a\nb\n' | openclicky
/// -i`) is a reasonable thing to do and must not scatter `›` through whatever is reading
/// the output. And it never waits on input that cannot come: `readLine` answers nil at
/// end of input, so a closed, empty or exhausted stdin ends the session immediately
/// rather than parking the process at a prompt nobody is looking at.
func nextInstruction() -> String? {
    if Term.stdinIsTTY { Term.write("\n" + Term.bold("› ")) }
    return readLine(strippingNewline: true)
}

/// Words that end the session, as well as ctrl-D.
///
/// Deliberately few and deliberately exact — matched against the whole line, never a
/// prefix. "quit the app I just opened" is an instruction, and a session that read it
/// as a goodbye would be worse than one with no quit word at all.
let farewells: Set<String> = ["quit", "exit", ":q", "bye"]

func runTask(_ parsed: Invocation, task: String?, interactive: Bool) async {
    let provider: Provider
    do {
        provider = try Provider.resolve(config: ConfigFile(),
            kind: parsed.providerKind,
            baseURL: parsed.baseURL,
            // A model nobody typed belongs to the provider: the built-in default
            // only ever meant "the default for Anthropic".
            model: parsed.modelIsExplicit ? parsed.model : nil,
            planner: parsed.plannerModel
        )
    } catch {
        Term.err(Term.red("\(error)"))
        exit(1)
    }
    // Everything downstream reads `model`, so folding the provider's choice in here
    // is what makes the registry, the capabilities and the loop agree about it.
    var invocation = parsed.resolved(with: provider)
    // The terminal this CLI is printing into is the frontmost app for most of a run,
    // and its scrollback — the agent's own output — changes on its own. Left
    // unnamed, every action "verified" against it. Reading `TERM_PROGRAM` is I/O, so
    // it happens here and is folded in, the same way the provider's model is.
    invocation.selfBundleIDs = HostTerminal.current()

    let permissions = PermissionStatus.current()
    if let advice = permissions.advice(upTo: invocation.effectiveMaxTier) {
        Term.err(Term.yellow(advice))
        Term.err("")
    }

    // Said once, before the run, rather than left for the user to infer from a
    // result that looks the same either way.
    for warning in [invocation.ignoredFlagWarning, invocation.cappedTierWarning].compactMap({ $0 }) {
        Term.err(Term.yellow(warning))
        Term.err("")
    }

    // How `ask_user` reaches the person at the keyboard, and when it declines to try.
    //
    // Only for a terminal, and stricter than the approval prompt beside it on purpose.
    // Both read the same stdin, and in a piped session that stdin is a script: the gate
    // can survive that because every answer it does not recognise is a denial, so the
    // worst a stray line does is refuse an action. A question has no safe default
    // answer — whatever line it consumed would be handed to the model as the user's
    // considered reply, and in `-i` that line is the next instruction, eaten. So with
    // no terminal there is nobody to ask, and saying so immediately is the whole
    // contract: `openclicky "…"` in CI must not park on a question forever.
    let asker: AskUserTool.Asker = { question in
        guard Term.stdinIsTTY else {
            return .unavailable(reason:
                "stdin is not a terminal, so there is nobody at a keyboard to answer")
        }
        // Framed by `Question`, not here. The surface chooses colour and nothing else:
        // the header, the caveat, the single prefixed line and the answer prompt are
        // all constants of the tool, so no wording of a question can reach them.
        Term.out("")
        Term.out(Term.blue(Term.bold(question.header)) + Term.dim(" — \(question.caveat)"))
        Term.out(Term.blue(question.line))
        guard let answer = Term.ask(question.answerPrompt) else {
            return .unavailable(reason: "stdin ended before an answer could be given")
        }
        return .answered(answer)
    }
    let registry = invocation.registry(asker: asker)

    let gate = PermissionGate(mode: invocation.mode) { tool, summary, risk in
        let isDestructive: Bool
        if case .dangerous = risk { isDestructive = true } else { isDestructive = false }

        Term.out("")
        Term.out("\(Term.bold("Approve?"))"
                 + (isDestructive ? Term.red(" DESTRUCTIVE ") : Term.yellow(" changes state "))
                 + Term.dim(tool))
        Term.out("  \(summary)")

        // Both the offer and its reading come from the gate, so a prompt cannot list
        // one set of choices while the parser accepts another — which it did: the
        // destructive prompt offered [y]es/[n]o and "a" approved anyway.
        let answer = Term.ask(PermissionGate.choices(
            isDestructive: isDestructive, tool: tool
        ))
        return PermissionGate.parse(answer, isDestructive: isDestructive)
    }

    let transcript: Transcript
    do {
        transcript = try Transcript()
    } catch {
        Term.err(Term.red("Could not open a transcript: \(error)"))
        exit(1)
    }

    // Rendering lives in RunReport, in the library, so a whole run's output can be
    // produced and read without an API key.
    // One condition, computed once and used for both halves: the renderer must
    // suppress exactly when the stream is drawing, or the reply is doubled or lost.
    let streaming = Term.isTTY && provider.streamsText
    let report = ReportBox { RunReport(isInteractive: Term.isTTY, streamsText: streaming) }
    // Redraws the waiting line with the seconds elapsed, until anything else happens.
    //
    // The problem streaming solved for OpenAI-compatible providers, solved a second
    // way for the one that cannot stream. Anthropic's event stream would have to
    // reconstruct thinking blocks *with their signatures* to keep transcript replay
    // valid, and that is not something to write against shapes I cannot exercise — a
    // wrong signature is a 400 on every subsequent turn. Counting seconds needs no
    // protocol at all and works for every provider.
    //
    // Only on a TTY: it depends on `\r` overwriting the line, and in a pipe or a log
    // it would emit one line per second forever.
    // Enabled while streaming too, and stopped by the first fragment rather than by
    // the next event.
    //
    // Disabling it for streamed providers traded one silence for another: a streamed
    // turn shows nothing until the first token, and on a local model that gap is the
    // weights loading — the longest wait in the run, and the one most likely to be
    // read as a hang. The ticker covers exactly that gap and then gets out of the way.
    let waiting = WaitingLine(enabled: Term.isTTY) { @Sendable text in
        Term.write(text)
    }
    // Timed whether or not anyone is watching: `WaitingLine` has the right lifecycle
    // and the wrong job, being disabled off a TTY, and a measurement that only happens
    // when someone is looking is not a measurement.
    let clock = TurnClock()
    let observer: AgentLoop.Observer = { event in
        if case .thinking = event {
            await waiting.start()
            await clock.start()
        } else {
            await waiting.stop()
        }
        for line in report.lines(for: event) {
            switch line.emphasis {
            case .detail: Term.out(Term.dim(line.text))
            case .speech: Term.out(line.text)
            case .success: Term.out(Term.green(line.text))
            case .failure: Term.out(Term.red(line.text))
            case .warning: Term.err(Term.yellow(line.text))
            }
        }
    }

    let loop = AgentLoop(
        // The only place a provider becomes a client. Everything below this line —
        // the loop, every tool, the permission gate — sees a `MessagesClient` and
        // cannot tell which endpoint answered, which is the point of the seam.
        client: provider.makeClient(
            onRetry: { attempt, total, delay, reason in
                await transcript.noteRetry(attempt: attempt, of: total, delay: delay, reason: reason)
                await observer(.retrying(attempt: attempt, of: total, delay: delay, reason: reason))
            },
            // Written straight out rather than through `RunReport`, which renders whole
            // lines: this arrives a few characters at a time and its whole value is
            // being visible before the line exists. The finished text still comes
            // through the observer afterwards, so the transcript and the report are
            // unchanged — this is a second view of the same bytes, not a replacement.
            onText: streaming ? { @Sendable fragment in
                // The first fragment ends the wait. `stop` is idempotent, so every
                // fragment after it costs one actor hop and draws nothing, and
                // `firstToken` answers once a turn for the same reason.
                await waiting.stop()
                if let seconds = await clock.firstToken() {
                    await transcript.noteFirstToken(seconds: seconds)
                }
                Term.write(fragment)
            } : nil
        ),
        registry: registry,
        gate: gate,
        transcript: transcript,
        mode: invocation.mode,
        config: invocation.loopConfiguration,
        observer: observer
    )

    Term.out(Term.dim("mode: \(invocation.mode.rawValue) · tiers 0–\(invocation.effectiveMaxTier.rawValue) · \(provider.summary)"))
    Term.out(Term.dim("transcript: \(await transcript.path)"))
    if invocation.effectiveMaxTier >= .accessibility {
        Term.out(Term.dim("press ctrl-c to stop — the agent can move your mouse and type"))
    }
    // Said before anything runs, because by the time it bites the user is watching an
    // approval prompt eat the instruction they typed two lines ago. The permission
    // gate reads the same stdin this session reads its instructions from, so with both
    // coming out of a pipe there is no way to tell one from the other.
    if interactive, !Term.stdinIsTTY, invocation.mode == .ask {
        Term.err(Term.yellow(
            "Instructions and approval prompts are both read from stdin, and stdin is "
            + "not a terminal.\n  A piped session should pass --mode auto or read-only, "
            + "or its approvals will consume the next instruction."))
        Term.err("")
    }

    let interrupts = Interrupts(returnsToAPrompt: interactive)
    let signals = installInterruptHandler {
        switch interrupts.signalArrived() {
        case let .stopTheTask(cancel):
            Term.err(Term.yellow("\nStopping after the current action…"))
            cancel()
        case .forceExit:
            // A second ctrl-c means the user wants out now, not at the next
            // boundary — honour that rather than appearing to hang.
            Term.err(Term.red("\nForced exit."))
            exit(130)
        case .leaveTheSession:
            // At an idle prompt there is no action to finish, so there is nothing to
            // wait for. Leaving is the only thing ctrl-c can sensibly mean here.
            Term.err(Term.yellow("\nLeaving."))
            exit(TaskEnding.cancelled.exitCode)
        }
    }
    defer { signals.cancel() }

    /// Runs one instruction on the loop and the transcript this session already has.
    ///
    /// The same call in both modes. Everything a persistent session needs beyond a
    /// one-shot run is already true of `AgentLoop.run(task:)`: it appends to the
    /// injected transcript, so the whole prior conversation goes back with the next
    /// request; it captures a fresh `ContextProbe`, so the environment block describes
    /// the desktop as it is now rather than as it was three tasks ago; and it clears
    /// its verdict on entry, so this task's outcome can never be the last one's.
    @Sendable func perform(_ instruction: String) async -> TaskEnding {
        report.startTask()
        // A cancellable task so ctrl-c can stop it between actions rather than
        // killing the process mid-click and leaving the transcript truncated.
        let run = Task { try await loop.run(task: instruction) }
        interrupts.taskStarted { run.cancel() }
        defer { interrupts.taskEnded() }

        do {
            _ = try await run.value
        } catch is CancellationError {
            Term.err("")
            Term.err(Term.yellow("Stopped."))
            return .cancelled
        } catch {
            // Printed and survived, not fatal. A session exists to carry context
            // forward, and a rate limit or a fumbled model id is exactly the moment
            // the user least wants to lose the conversation they have built up — so
            // this reports and hands the prompt back. A one-shot run has no prompt to
            // hand back to and exits on the code below, exactly as it always has.
            Term.err("")
            Term.err(Term.red("\(error)"))
            return .failed
        }

        // A run that was asked to do something and changed nothing is not a success,
        // and neither is one that was cut off before it finished, and the exit code is
        // the only part of this a script can read. `RunReport` has already said so on
        // the terminal; this says it to `openclicky "…" && next-thing`, which would
        // otherwise chain off a run whose entire output was an explanation of why it
        // could not proceed. Distinct from 1 so a caller can still tell "the agent ran
        // and did not complete the task" from "the agent failed to start".
        //
        // One code for both failures, not two. `act=5 obs=7 unfulfilled=False stop=turn
        // limit (12) reached` and `act=0 … stop=end_turn` differ in what the run managed
        // before it stopped, and not at all in what the caller should do next; a third
        // code would only make the contract harder to branch on.
        //
        // Read per task, after that task's own run. `loop.outcome` is overwritten by
        // every instruction and cleared at the start of each, so what is read here is
        // this instruction's verdict or nothing — never the previous one's.
        return await loop.outcome?.isIncomplete == true ? .incomplete : .completed
    }

    var ending = TaskEnding.none
    if let task { ending = await perform(task) }

    if interactive {
        if Term.stdinIsTTY {
            Term.out("")
            Term.out(Term.dim(
                "still here — the conversation carries forward. "
                + "ctrl-D or `quit` to leave."))
        }
        while let line = nextInstruction() {
            let instruction = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if instruction.isEmpty { continue }
            if farewells.contains(instruction.lowercased()) { break }
            ending = await perform(instruction)
        }
        if Term.stdinIsTTY { Term.out("") }
    }

    // The last instruction's verdict, and nothing else. See `TaskEnding`.
    let code = ending.exitCode
    if code != 0 { exit(code) }
}

/// Routes SIGINT to `handler` instead of killing the process outright.
///
/// A default ctrl-c would terminate mid-action — potentially between a mouse-down
/// and its mouse-up, leaving a button held. Cancelling the task instead lets the
/// loop stop at the next action boundary and finish writing its transcript.
///
/// What a press *means* is `Interrupts`' job, not this function's, and the split is
/// deliberate: a session that returns to a prompt needs a second and a third press to
/// mean different things, and a signal source that decided for itself could only ever
/// mean one. This is the plumbing; the policy is stateful and lives next to the state.
func installInterruptHandler(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    // A global queue, not .main: the main thread can be blocked in readLine() — at an
    // approval prompt, or waiting for the next instruction — and a handler scheduled
    // there would not run until the user answered, exactly when they most want out.
    let source = DispatchSource.makeSignalSource(
        signal: SIGINT, queue: DispatchQueue.global(qos: .userInitiated)
    )
    source.setEventHandler(handler: handler)
    source.resume()
    return source
}

// MARK: - Entry point

switch Invocation.parse(Array(CommandLine.arguments.dropFirst())) {
case let .failure(error):
    Term.err(Term.red(error.message))
    exit(1)
case let .success(invocation):
    switch invocation.command {
    case .help:
        Term.out(usage)
    case .version:
        Term.out(OpenClicky.versionLine)
    case .auth:
        await runAuth(invocation)
    case .doctor:
        if await runDoctor(invocation) == false { exit(1) }
    case let .transcript(session):
        if runTranscript(session) == false { exit(1) }
    case let .transcripts(limit):
        runTranscripts(limit: limit)
    case let .forget(days):
        if runForget(days: days) == false { exit(1) }
    case .bench:
        runBench()
    case .forgetKey:
        if runForgetKey(invocation) == false { exit(1) }
    case let .run(task):
        await runTask(invocation, task: task, interactive: false)
    case let .interactive(task):
        await runTask(invocation, task: task, interactive: true)
    }
}

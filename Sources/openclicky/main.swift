import Foundation
import OpenClickyKit

// MARK: - Terminal rendering

enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

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
    private var report: RunReport
    init(_ report: RunReport) { self.report = report }
    func lines(for event: AgentLoop.Event) -> [RunReport.Line] {
        lock.lock(); defer { lock.unlock() }
        return report.lines(for: event)
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
let usage = """
\(Term.bold("openclicky")) — an agent that operates your Mac

\(Term.bold("USAGE"))
  openclicky "<task>"            Run a task (exit 2 if it changed nothing)
  openclicky --version           Print the build
  openclicky auth                Store an API key, and check that it works
                                 (--provider chooses whose)
  openclicky doctor              Check permissions and configuration (exit 1 if not ready)
  openclicky transcripts [n]     List recorded sessions, newest first (default 20)
  openclicky transcript [id]     Replay one (default: the latest)
  openclicky forget <days>       Delete sessions older than <days>, after confirming
  openclicky bench               Report where recorded runs spent their time

\(Term.bold("OPTIONS"))
  --mode <mode>      read-only | ask | auto | bypass          (default: ask)
  --max-tier <0-3>   Highest capability tier the agent may use (default: 3)
                       0 shell/files · 1 AppleScript · 2 accessibility · 3 screenshots
  --provider <name>  anthropic | openai | ollama | litellm | groq
                       (default: anthropic, or $OPENCLICKY_PROVIDER)
  --base-url <url>   Endpoint for an OpenAI-compatible provider
                       (default: the provider's own, or $OPENCLICKY_BASE_URL)
  --model <id>       Model id
                       (default: the provider's own; \(DefaultModel.id) for anthropic)
                       A model that cannot be sent images caps the run at tier 2.
  --effort <level>   low | medium | high | xhigh | max         (default: high)
                       Ignored on models older than Claude 4.6, which reject it.
  --planner <id>     Ask a stronger model how to approach the task first
                       Costs one extra round-trip; off unless given.
  --max-turns <n>    Cap on agent turns                        (default: 40)
  --no-sandbox       Run shell commands without sandbox-exec

\(Term.bold("EXAMPLES"))
  openclicky "what's taking up space in my Downloads folder?"
  openclicky --max-tier 1 "how many unread emails do I have?"
  openclicky --mode auto "open the OpenClicky repo in Finder"
  openclicky --provider ollama --model llama3.2 "which windows are open?"

\(Term.bold("STOPPING IT"))
  Ctrl-C stops the agent at the next action boundary — it will not be killed
  between a mouse-down and its mouse-up. Press it twice to force an exit.

\(Term.bold("THE APP"))
  ./Scripts/bundle.sh builds OpenClicky.app: a menu-bar agent summoned with
  ⌥space, which shows what it is doing and asks before it changes anything.
"""

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
    let provider = try? Provider.resolve(
        kind: invocation.providerKind,
        baseURL: invocation.baseURL,
        model: invocation.modelIsExplicit ? invocation.model : nil
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
    } else {
        // The resolution error says which provider and what to do about it.
        do {
            _ = try Provider.resolve(
                kind: invocation.providerKind,
                baseURL: invocation.baseURL,
                model: invocation.modelIsExplicit ? invocation.model : nil
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
    // Which provider's key this is. The account name follows from it, so a key stored
    // for one provider can never be picked up as another's — the resolution order
    // reads a single account per provider, and a shared one would make
    // `--provider openai` quietly sign with an Anthropic key and 401.
    let kind = invocation.providerKind
        ?? ProcessInfo.processInfo.environment["OPENCLICKY_PROVIDER"]
            .flatMap(Provider.Kind.init(rawValue:))
        ?? .anthropic
    let account = kind.keychainAccount

    if (try? Keychain.standard.read(account: account)) ?? nil != nil {
        Term.out(Term.dim("A \(kind.label) key is already stored. Entering one now replaces it."))
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
    do {
        try Keychain.standard.write(key, account: account)
        Term.out(Term.green("✓ Stored in the macOS Keychain (service \(Keychain.serviceName), account \(account))."))
    } catch {
        Term.err(Term.red("Could not write to the Keychain: \(error)"))
        exit(1)
    }

    // "Stored" is not the same claim as "works", and someone told the first while
    // hearing the second discovers the difference three commands later, attributing
    // it to something else. One token in and one out settles it now.
    Term.out(Term.dim("Checking it against the API…"))
    // Resolved rather than constructed, so this exercises the exact path a run takes
    // — including the Keychain read that just happened. A check that bypasses the
    // lookup it is meant to validate proves only that the key works somewhere.
    let verification: Credentials.Verification
    do {
        verification = await (try Provider.resolve(
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

func runTask(_ parsed: Invocation, task: String) async {
    let provider: Provider
    do {
        provider = try Provider.resolve(
            kind: parsed.providerKind,
            baseURL: parsed.baseURL,
            // A model nobody typed belongs to the provider: the built-in default
            // only ever meant "the default for Anthropic".
            model: parsed.modelIsExplicit ? parsed.model : nil
        )
    } catch {
        Term.err(Term.red("\(error)"))
        exit(1)
    }
    // Everything downstream reads `model`, so folding the provider's choice in here
    // is what makes the registry, the capabilities and the loop agree about it.
    let invocation = parsed.resolved(with: provider)

    let permissions = PermissionStatus.current()
    if invocation.effectiveMaxTier >= .accessibility, let advice = permissions.advice {
        Term.err(Term.yellow(advice))
        Term.err("")
    }

    // Said once, before the run, rather than left for the user to infer from a
    // result that looks the same either way.
    for warning in [invocation.ignoredFlagWarning, invocation.cappedTierWarning].compactMap({ $0 }) {
        Term.err(Term.yellow(warning))
        Term.err("")
    }

    let registry = invocation.registry

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
    let report = ReportBox(RunReport(isInteractive: Term.isTTY))
    let observer: AgentLoop.Observer = { event in
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
        client: provider.makeClient { attempt, total, delay, reason in
            await observer(.retrying(attempt: attempt, of: total, delay: delay, reason: reason))
        },
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

    // The run is a cancellable task so ctrl-c can stop it between actions rather
    // than killing the process mid-click and leaving the transcript truncated.
    let run = Task { try await loop.run(task: task) }
    let interrupt = installInterruptHandler { run.cancel() }
    defer { interrupt.cancel() }

    do {
        _ = try await run.value
    } catch is CancellationError {
        Term.err("")
        Term.err(Term.yellow("Stopped."))
        exit(130)
    } catch {
        Term.err("")
        Term.err(Term.red("\(error)"))
        exit(1)
    }

    // A run that was asked to do something and changed nothing is not a success, and
    // the exit code is the only part of this a script can read. `RunReport` has
    // already said so on the terminal; this says it to `openclicky "…" && next-thing`,
    // which would otherwise chain off a run whose entire output was an explanation of
    // why it could not proceed. Distinct from 1 so a caller can still tell "the agent
    // ran and accomplished nothing" from "the agent failed to start".
    if await loop.outcome?.isUnfulfilled == true { exit(2) }
}

/// Routes SIGINT to `handler` instead of killing the process outright.
///
/// A default ctrl-c would terminate mid-action — potentially between a mouse-down
/// and its mouse-up, leaving a button held. Cancelling the task instead lets the
/// loop stop at the next action boundary and finish writing its transcript.
func installInterruptHandler(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    // A global queue, not .main: the main thread can be blocked in readLine() at an
    // approval prompt, and a handler scheduled there would not run until the user
    // answered — exactly when they are most likely to want out.
    let source = DispatchSource.makeSignalSource(
        signal: SIGINT, queue: DispatchQueue.global(qos: .userInitiated)
    )
    let fired = ManagedAtomicFlag()
    source.setEventHandler {
        if fired.testAndSet() {
            // A second ctrl-c means the user wants out now, not at the next
            // boundary — honour that rather than appearing to hang.
            Term.err(Term.red("\nForced exit."))
            exit(130)
        }
        Term.err(Term.yellow("\nStopping after the current action…"))
        handler()
    }
    source.resume()
    return source
}

/// Minimal one-shot flag; the loop only needs to know if this is the second signal.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Sets the flag, returning whether it was already set.
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { value = true }
        return value
    }
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
    case let .run(task):
        await runTask(invocation, task: task)
    }
}

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
  openclicky "<task>"            Run a task
  openclicky --version           Print the build
  openclicky auth                Store your API key, and check that it works
  openclicky doctor              Check permissions and configuration (exit 1 if not ready)
  openclicky transcripts [n]     List recorded sessions, newest first (default 20)
  openclicky transcript [id]     Replay one (default: the latest)
  openclicky forget <days>       Delete sessions older than <days>, after confirming

\(Term.bold("OPTIONS"))
  --mode <mode>      read-only | ask | auto | bypass          (default: ask)
  --max-tier <0-3>   Highest capability tier the agent may use (default: 3)
                       0 shell/files · 1 AppleScript · 2 accessibility · 3 screenshots
  --model <id>       Model id                                  (default: claude-opus-5)
  --effort <level>   low | medium | high | xhigh | max         (default: high)
  --max-turns <n>    Cap on agent turns                        (default: 40)
  --no-sandbox       Run shell commands without sandbox-exec

\(Term.bold("EXAMPLES"))
  openclicky "what's taking up space in my Downloads folder?"
  openclicky --max-tier 1 "how many unread emails do I have?"
  openclicky --mode auto "open the OpenClicky repo in Finder"

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
func runDoctor() async -> Bool {
    Term.out(Term.bold("OpenClicky doctor"))
    Term.out("")

    let permissions = PermissionStatus.current()
    let mark = { (ok: Bool) in ok ? Term.green("✓") : Term.red("✗") }
    Term.out("  \(mark(permissions.accessibility)) Accessibility        \(permissions.accessibility ? "granted" : "not granted")")
    Term.out("  \(mark(permissions.screenRecording)) Screen Recording     \(permissions.screenRecording ? "granted" : "not granted")")

    // Checked against the API, not merely found. A diagnostic exists to answer "why
    // is this not working", and "a key is present" is not an answer to that — a key
    // that is present and rejected looks identical here to one that works.
    var verification: Credentials.Verification?
    let credentials = try? Credentials.resolve()
    if let credentials {
        let result = await credentials.verify()
        verification = result
        switch result {
        case .working:
            Term.out("  \(mark(true)) Anthropic credentials verified")
        case let .rejected(detail):
            Term.out("  \(mark(false)) Anthropic credentials rejected — \(detail)")
            Term.out(Term.dim("      Run `openclicky auth` with a valid key."))
        case let .unreachable(detail):
            // Not a verdict on the key, so not a verdict on the machine.
            Term.out("  \(mark(true)) Anthropic credentials found, not checked — \(detail)")
        }
    } else {
        Term.out("  \(mark(false)) Anthropic credentials missing — run `openclicky auth`")
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
    } else {
        Term.out(Term.green("All four tiers are available."))
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
    return permissions.isReady(credentials: verification)
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

func runAuth() async {
    if (try? Keychain.standard.read(account: Keychain.apiKeyAccount)) ?? nil != nil {
        Term.out(Term.dim("A key is already stored. Entering one now replaces it."))
    }
    Term.out("Paste your Anthropic API key (input is not echoed).")

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
    guard key.hasPrefix("sk-ant-") else {
        Term.err(Term.red("That does not look like an Anthropic API key (expected an sk-ant- prefix)."))
        exit(1)
    }
    do {
        try Keychain.standard.write(key, account: Keychain.apiKeyAccount)
        Term.out(Term.green("✓ Stored in the macOS Keychain (service com.openclicky.credentials)."))
    } catch {
        Term.err(Term.red("Could not write to the Keychain: \(error)"))
        exit(1)
    }

    // "Stored" is not the same claim as "works", and someone told the first while
    // hearing the second discovers the difference three commands later, attributing
    // it to something else. One token in and one out settles it now.
    Term.out(Term.dim("Checking it against the API…"))
    let verification = await Credentials.apiKey(key).verify()
    switch verification {
    case .working:
        Term.out(Term.green("✓ \(verification.summary)"))
    case .rejected:
        Term.err(Term.red(verification.summary))
        exit(1)
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

func runTask(_ invocation: Invocation, task: String) async {
    let credentials: Credentials
    do {
        credentials = try Credentials.resolve()
    } catch {
        Term.err(Term.red("\(error)"))
        exit(1)
    }

    let permissions = PermissionStatus.current()
    if invocation.maxTier >= .accessibility, let advice = permissions.advice {
        Term.err(Term.yellow(advice))
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
        client: AnthropicClient(credentials: credentials) { attempt, total, delay, reason in
            await observer(.retrying(attempt: attempt, of: total, delay: delay, reason: reason))
        },
        registry: registry,
        gate: gate,
        transcript: transcript,
        mode: invocation.mode,
        config: invocation.loopConfiguration,
        observer: observer
    )

    Term.out(Term.dim("mode: \(invocation.mode.rawValue) · tiers 0–\(invocation.maxTier.rawValue) · \(invocation.model)"))
    Term.out(Term.dim("transcript: \(await transcript.path)"))
    if invocation.maxTier >= .accessibility {
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
        await runAuth()
    case .doctor:
        if await runDoctor() == false { exit(1) }
    case let .transcript(session):
        if runTranscript(session) == false { exit(1) }
    case let .transcripts(limit):
        runTranscripts(limit: limit)
    case let .forget(days):
        if runForget(days: days) == false { exit(1) }
    case let .run(task):
        await runTask(invocation, task: task)
    }
}

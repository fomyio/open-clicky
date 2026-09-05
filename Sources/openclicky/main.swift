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

/// Carries the latest cost snapshot out of the observer closure.
final class MeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var meter: CostMeter?
    func store(_ value: CostMeter) { lock.lock(); meter = value; lock.unlock() }
    var value: CostMeter? { lock.lock(); defer { lock.unlock() }; return meter }
}

// MARK: - Argument parsing
//
// The model itself lives in OpenClickyKit as `Invocation`, so `--mode` and
// `--max-tier` — which decide whether the agent asks before acting and whether it can
// see the screen — are reachable by tests. They were not while they lived here.

let usage = """
\(Term.bold("openclicky")) — an agent that operates your Mac

\(Term.bold("USAGE"))
  openclicky "<task>"            Run a task
  openclicky auth                Store your Anthropic API key in the Keychain
  openclicky doctor              Check permissions and configuration

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
"""

// MARK: - Commands

func runDoctor() async {
    Term.out(Term.bold("OpenClicky doctor"))
    Term.out("")

    let permissions = PermissionStatus.current()
    let mark = { (ok: Bool) in ok ? Term.green("✓") : Term.red("✗") }
    Term.out("  \(mark(permissions.accessibility)) Accessibility        \(permissions.accessibility ? "granted" : "not granted")")
    Term.out("  \(mark(permissions.screenRecording)) Screen Recording     \(permissions.screenRecording ? "granted" : "not granted")")

    let credentials = (try? Credentials.resolve()) != nil
    Term.out("  \(mark(credentials)) Anthropic credentials \(credentials ? "found" : "missing — run `openclicky auth`")")
    Term.out("")

    if let advice = permissions.advice {
        Term.out(Term.yellow(advice))
        Term.out("")
        Term.out(Term.dim("A CLI inherits its terminal's grants, so grant them to Terminal/iTerm, not to openclicky."))
        Term.out("")
        let answer = Term.ask("Ask macOS for the missing permissions now? [y/N]: ")?
            .lowercased().trimmingCharacters(in: .whitespaces) ?? "n"
        if answer == "y" || answer == "yes" {
            if !permissions.accessibility { await AXCapture.shared.requestTrust() }
            if !permissions.screenRecording { await ScreenCapture.shared.requestPermission() }
            Term.out(Term.dim("Requested. Screen Recording needs a relaunch of your terminal to take effect."))
        }
    } else {
        Term.out(Term.green("All four tiers are available."))
    }

    let probe = ContextProbe.capture()
    Term.out("")
    Term.out(Term.dim(probe.rendered))
}

func runAuth() {
    Term.out("Paste your Anthropic API key (input is not echoed).")
    guard let key = readPassword(prompt: "API key: "), !key.isEmpty else {
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

        // "Always" is not offered for destructive calls, because it cannot be
        // honoured: those ask every time by design, and offering a choice that
        // silently does nothing is worse than not offering it.
        let choices = isDestructive
            ? "  [y]es / [n]o: "
            : "  [y]es / [n]o / [a]lways allow \(tool): "
        let answer = Term.ask(choices)?
            .lowercased().trimmingCharacters(in: .whitespaces) ?? "n"

        switch answer {
        case "y", "yes": return .allow
        case "a", "always": return isDestructive ? .allow : .allowAlways
        default: return .deny
        }
    }

    let transcript: Transcript
    do {
        transcript = try Transcript()
    } catch {
        Term.err(Term.red("Could not open a transcript: \(error)"))
        exit(1)
    }

    // Captured so the final line can print the session total after the loop ends.
    let lastMeter = MeterBox()
    let observer: AgentLoop.Observer = { event in
        switch event {
        case .thinking:
            if Term.isTTY { Term.out(Term.dim("· thinking…")) }
        case let .assistantText(text):
            Term.out("")
            Term.out(text)
        case let .toolStarted(name, tier, summary):
            Term.out(Term.dim("  → [T\(tier.rawValue)] \(name): \(summary)"))
        case let .toolFinished(_, ok, detail):
            let marker = ok ? Term.green("    ✓") : Term.red("    ✗")
            Term.out("\(marker) \(Term.dim(detail))")
        case let .toolDenied(name, reason):
            Term.out(Term.red("    ✗ \(name) denied — \(reason)"))
        case let .toolSkipped(name):
            Term.out(Term.dim("    · \(name) skipped (earlier action failed)"))
        case .interrupted:
            Term.out(Term.yellow("    ■ stopped — no further actions will run"))
        case .usage:
            // Superseded by the running cost line below, which carries the same
            // numbers with the price attached.
            break
        case let .cost(meter):
            if Term.isTTY { Term.out(Term.dim("  \(meter.summary)")) }
            lastMeter.store(meter)
        case let .finished(reason):
            Term.out("")
            Term.out(Term.dim("── \(reason)"))
            if let meter = lastMeter.value {
                Term.out(Term.dim("   \(meter.summary)"))
                if meter.turns > 1, meter.cacheHitRate < 0.1 {
                    Term.err(Term.yellow("   note: cache hit rate is \(Int(meter.cacheHitRate * 100))% — the cached prefix may be being invalidated each turn."))
                }
            }
        }
    }

    let loop = AgentLoop(
        client: AnthropicClient(credentials: credentials),
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
    case .auth:
        runAuth()
    case .doctor:
        await runDoctor()
    case let .run(task):
        await runTask(invocation, task: task)
    }
}

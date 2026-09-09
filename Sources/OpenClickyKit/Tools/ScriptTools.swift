import Foundation

/// Tier 1 — drive scriptable macOS apps through AppleScript or JXA.
///
/// The most under-used capability on macOS and the reason OpenClicky can answer a
/// large share of "control my Mac" requests without taking a single screenshot.
/// Scriptable apps expose a typed object model, so this is deterministic where
/// pixel-clicking is probabilistic.
/// How `app_script` reaches `osascript`. The seam that lets a test assert a script
/// was refused without that script ever running.
public protocol ScriptRunning: Sendable {
    func run(arguments: [String], script: String, timeout: Int) async throws -> Subprocess.Result
}

public struct OsascriptRunner: ScriptRunning {
    public init() {}

    public func run(
        arguments: [String], script: String, timeout: Int
    ) async throws -> Subprocess.Result {
        try await Subprocess.run(
            executable: "/usr/bin/osascript",
            arguments: arguments, stdin: script, timeout: timeout
        )
    }
}

public struct AppleScriptTool: Tool {
    public let name = "app_script"
    public let tier = Tier.script
    public var description: String { """
    Run AppleScript or JavaScript-for-Automation (JXA) against scriptable macOS apps. \
    Strongly prefer this over screenshots and clicking: it is deterministic, costs no \
    vision tokens, and works whether or not the app is visible.

    Widely scriptable: Finder, Mail, Calendar, Notes, Reminders, Messages, Contacts, \
    Safari, Music, Photos, Terminal, System Events, Keynote/Pages/Numbers.

    **Guard anything that names an app.** `tell application "Mail" to …` *launches* \
    Mail if it is not already running, which is slow and a side effect the user did \
    not ask for. Check first:

        if application "Mail" is running then
            tell application "Mail" to return unread count of inbox
        end if
        return "Mail is not running"

    `System Events` and `Finder` are always running, so they need no guard.

    Verified patterns:
      • Frontmost app:   tell application "System Events" to name of first process whose frontmost is true
      • Running apps:    tell application "System Events" to get name of every process whose background only is false
      • Volume:          output volume of (get volume settings)
      • New note:        tell application "Notes" to make new note with properties {name:"x", body:"y"}
      • Safari page URL: tell application "Safari" to return URL of current tab of front window
      • UI scripting:    tell application "System Events" to tell process "X" to click button "OK" of window 1

    `System Events` UI scripting reaches menus and controls that have no direct \
    AppleScript API — still Tier 1, and still better than clicking by coordinate.

    **The first script targeting a given app blocks on a macOS consent dialog.** It \
    will sit there until the user answers, so a timeout on a first call to an app \
    usually means the dialog is waiting on screen, not that the script is wrong — say \
    so and try again rather than rewriting it. Once denied, the app returns \
    "Not authorized to send Apple events" immediately; that one is permanent until \
    the user changes it in System Settings ▸ Privacy & Security ▸ Automation.

    \(Self.confinementNote(sandbox: sandbox))
    """ }

    public var inputSchema: JSONValue {
        .schema([
            "script": .string(describing: "The script source to execute."),
            "language": .string(
                describing: "Script language. Defaults to applescript.",
                enum: ["applescript", "javascript"]
            ),
            "timeout_seconds": .integer(describing: "Kill the script after this many seconds. Default 30, maximum 300."),
        ], required: ["script"])
    }

    /// Whether `shell` is confined in this run. Only used to describe it accurately.
    let sandbox: ShellSandbox

    /// This run's tier ceiling. Only used to name alternatives that actually exist.
    ///
    /// A failure message that names `key` in a run capped at tier 1 sends the model
    /// after a tool the registry does not hold, which is the same defect the system
    /// prompt's guidance was fixed for. The ceiling is the one fact needed to say
    /// "try this instead" truthfully.
    let maxTier: Tier

    /// Why a script's shell escape is worse than the `shell` tool — which depends on
    /// whether `shell` is actually confined.
    ///
    /// The unconditional version told the model to prefer `shell` "because it is
    /// confined", which `--no-sandbox` makes untrue. Third place this same belief was
    /// written down: the shell tool's own description, the system prompt's Judgement
    /// section, and here. Each was fixed where it was found rather than everywhere it
    /// was stated.
    static func confinementNote(sandbox: ShellSandbox) -> String {
        switch sandbox {
        case .enabled:
            return """
                `do shell script` and the JXA ObjC bridge run outside the sandbox that \
                confines the `shell` tool, so they always require explicit approval. \
                Use the `shell` tool instead when you want a shell command — it is \
                confined and its output is cleaner.
                """
        case .disabled:
            return """
                `do shell script` and the JXA ObjC bridge are arbitrary code execution, \
                so they always require explicit approval. This run has no sandbox at \
                all, so `shell` is not confined either — prefer it for a shell command \
                because its output is cleaner and it is classified more precisely, not \
                because it is contained.
                """
        }
    }

    let runner: any ScriptRunning

    /// - Parameter runner: how a validated script is actually run.
    ///
    ///   Injectable for one reason: the tests that prove the deny-list holds have to
    ///   feed this tool the exact payloads the deny-list names — `rm -rf /` among
    ///   them. Those are safe only while the deny-list works, and the mutation
    ///   sweep's job is to break the deny-list deliberately, so a sweep run against
    ///   the real `osascript` would execute `rm -rf /` on the machine and read the
    ///   user's actual SSH private key into the test log. A gate is properly tested
    ///   by showing execution is never reached, which needs execution to be something
    ///   a test can hold.
    /// How this surface releases the keyboard before a script runs. See
    /// `Verified.FocusYield`.
    ///
    /// `app_script` is a second route to synthetic input, not merely a scripting tool:
    /// `tell application "System Events" to keystroke "p" using {command down}` posts
    /// keys exactly as `key` does. The yield was wired into the five CGEvent tools and
    /// not into this one, and a run promptly took this route instead — three
    /// `app_script` keystrokes, no `key` call, and every one of them landing in our own
    /// panel with nothing in the log because no yield ever ran. Every route to
    /// execution needs the same checks.
    let yieldFocus: Verified.FocusYield?

    public init(
        runner: any ScriptRunning = OsascriptRunner(),
        sandbox: ShellSandbox = .enabled,
        maxTier: Tier = .pixels,
        yieldFocus: Verified.FocusYield? = nil
    ) {
        self.runner = runner
        self.sandbox = sandbox
        self.maxTier = maxTier
        self.yieldFocus = yieldFocus
    }

    /// Scripting bridges that reach a shell or spawn a process.
    ///
    /// These make a script arbitrary code execution outside the sandbox, so they are
    /// never classified below destructive, and `run` refuses them unless the embedded
    /// command also passes the shell deny-list.
    static let shellEscapes = [
        "do shell script",       // AppleScript
        "doshellscript",         // JXA
        "objc.", "$.nstask", "nstask", "objectivec",  // JXA ObjC bridge
        "current application", // JXA's route to the ObjC bridge
        "system attribute",
        // Dynamic evaluation. A script assembled at runtime cannot be inspected
        // statically at all — splitting the phrase across a concatenation
        // (`set p to "do shell " & "script ..."` then `run script p`) defeats every
        // substring check above. Treating the evaluators themselves as escapes
        // closes that door without pretending to analyse the string they build.
        "run script", "load script",
    ]

    /// Verbs that only read. Everything else is assumed to mutate.
    ///
    /// Conservative by design: this classifier gates access to the permission
    /// prompt, so an unrecognised script must be treated as mutating. The previous
    /// inverse rule — read unless a mutation keyword appears — meant any script
    /// phrased outside the keyword list bypassed the gate in every mode, and JXA
    /// (`x.name = "y"`, no `set `) evaded it almost entirely.
    static let readOnlyVerbs = [
        "return", "get", "count of", "name of", "properties of", "value of",
        "exists", "id of", "title of", "url of", "path of", "bounds of",
    ]

    /// Phrases that mutate regardless of any reading verb elsewhere in the script.
    ///
    /// Creation is never a read, and a note whose body happens to contain the word
    /// "budget" must not be classified as one.
    static let mutationPhrases = [
        "make new", "duplicate", "delete", "move ", "add ", "remove", "set ",
        "click", "keystroke", "key code", "open ", "close ", "save", "activate",
        "launch", "quit", "print", "attach",
    ]

    /// Whether `phrase` occurs in `text` at word boundaries.
    ///
    /// Substring matching was unsound for short verbs: `"get "` occurs inside
    /// "budget ", "target " and "forget ", so an ordinary note-creating script whose
    /// text merely contained one of those words was classified read-only and skipped
    /// the permission gate. This can fire by accident, not only by crafted input.
    static func containsWord(_ phrase: String, in text: String) -> Bool {
        guard let range = text.range(of: phrase) else { return false }
        var searchStart = text.startIndex
        while let found = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let beforeOK = found.lowerBound == text.startIndex
                || !text[text.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == text.endIndex
                || !text[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchStart = text.index(after: found.lowerBound)
        }
        _ = range
        return false
    }

    public func risk(for input: JSONValue) -> Risk {
        guard let script = input["script"]?.stringValue else {
            return .write(summary: "script with missing arguments")
        }
        let lowered = script.lowercased()

        // A shell escape makes the script equivalent to arbitrary shell, and it runs
        // outside the sandbox that would confine the `shell` tool.
        if let escape = Self.shellEscapes.first(where: { lowered.contains($0) }) {
            return .dangerous(summary: "\(firstLine(of: script)) — uses '\(escape)' to run code outside the sandbox")
        }

        // Sending or deleting leaves the machine, or destroys data, irrecoverably.
        let outward = ["send", "delete", "empty trash", "erase", "quit application",
                       "shut down", "restart", "log out", "eject"]
        if outward.contains(where: { lowered.contains($0) }) {
            return .dangerous(summary: firstLine(of: script))
        }

        // A script naming a security surface is destructive whatever it appears to
        // do. `tell application "System Events" to tell process "System Settings"`
        // drives that window without activating it, so the frontmost check in the
        // loop never sees it — and a script that only reveals a Privacy pane is a
        // step in granting a permission, not an idle query.
        if Policy.namesSecuritySurface(script) {
            return .dangerous(summary: firstLine(of: script))
        }

        // Read-only only when a reading verb appears at a word boundary and nothing
        // in the script mutates. Fails closed: an unrecognised script is a write.
        let mutates = script.contains("=")
            || Self.mutationPhrases.contains { Self.containsWord($0.trimmingCharacters(in: .whitespaces), in: lowered) }
        if !mutates, Self.readOnlyVerbs.contains(where: { Self.containsWord($0, in: lowered) }) {
            return .read
        }
        return .write(summary: firstLine(of: script))
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let script = try input.string("script")
        let language = input.string("language", default: "applescript")

        // osascript cannot be confined by sandbox-exec the way `shell` is — it talks
        // to already-running apps over Apple events, and `do shell script` spawns
        // outside any wrapper we could apply. The deny-list is therefore the only
        // backstop here, and it has to be applied to the script text itself.
        try Policy.validateShell(script)
        let timeout = min(max(input.int("timeout_seconds", default: 30), 1), 300)

        // Unconditional rather than only for scripts that look like they send keys.
        // Deciding that from the text is the same losing game as the deny-list: a
        // keystroke can be assembled at runtime from fragments, and a script that
        // merely activates an app is the one whose keystrokes arrive next turn.
        // Releasing costs nothing when we do not hold the keyboard.
        await yieldFocus?()

        var arguments: [String] = []
        if language == "javascript" { arguments += ["-l", "JavaScript"] }
        // Source arrives on stdin rather than as an argument: scripts routinely
        // contain quotes and newlines that would need escaping otherwise.
        arguments.append("-")

        do {
            let result = try await runner.run(arguments: arguments, script: script, timeout: timeout)
            // The same check as `shell`: `do shell script "security … -w"` reaches the
            // identical credential by another route, and every route needs the check.
            if result.succeeded {
                if Policy.printsSecret(script) { return .text(Policy.withheldSecretNote) }
                return .text(result.stdout.trimmingCharacters(in: .newlines))
            }

            // osascript's own errors are the useful diagnostic; surface them intact
            // so the model can correct its script rather than guess. An automation
            // denial is the one case where intact is not enough — see
            // `escalation(stderr:maxTier:)`.
            let stderr = result.stderr.trimmingCharacters(in: .newlines)
            var message = "Script failed:\n\(stderr)"
            if let advice = Self.escalation(stderr: stderr, maxTier: maxTier) {
                message += "\n\n\(advice)"
            }
            if let panes = Self.settingsPaneAdvice(stderr: stderr, script: script) {
                message += "\n\n\(panes)"
            }
            return ToolOutput(content: [.text(message)], isError: true)
        } catch let error as Subprocess.Error {
            return .failure(Self.explain(error, script: script))
        }
    }

    /// Where System Settings keeps its panes, since Ventura.
    ///
    /// Each pane is an ExtensionKit extension whose `CFBundleIdentifier` is the id
    /// `reveal pane id` and the `x-apple.systempreferences:` URL both want.
    static let settingsExtensionsDirectory = "/System/Library/ExtensionKit/Extensions"

    /// Words that appear in nearly every pane id or in the scaffolding of every
    /// script, and so carry no information about which pane was meant.
    static let paneStopWords: Set<String> = [
        "apple", "settings", "setting", "extension", "extensions", "system",
        "preferences", "preference", "pane", "panes", "tell", "application",
        "reveal", "script", "using", "with", "then", "return", "running",
    ]

    /// What to try when a script names a System Settings pane that does not exist.
    ///
    /// Four runs in a row asked for the Siri pane and invented four different
    /// identifiers — `com.apple.settings.siri`, `com.apple.preferences.siri`, a menu
    /// item, and finally an unpressable element in whichever pane happened to be open.
    /// Every one came back `-1728`, which says only that the thing is not there. The
    /// pane ids changed shape in Ventura and nothing on the machine tells the model the
    /// new ones, so it guessed from memory and had no way to stop guessing.
    ///
    /// The real ids are on disk and take one directory listing to read, so a dead end
    /// hands back the way out — the same shape as `escalation` above and as
    /// `ScreenCapture.unknownScreen`, which lists the displays that *are* attached.
    static func settingsPaneAdvice(stderr: String, script: String) -> String? {
        // -1728 is "can't get <thing>", which osascript returns for any missing
        // reference. Narrowed to scripts that were actually reaching for a settings
        // pane, or this would fire on every typo'd property in every script.
        let lowered = script.lowercased()
        guard stderr.contains("-1728") else { return nil }
        guard lowered.contains("pane") || lowered.contains("system settings")
            || lowered.contains("system preferences") else { return nil }

        let all = availablePanes()
        guard !all.isEmpty else { return nil }

        // Ranked by the words the script itself used, so "siri" surfaces the Siri pane
        // rather than making the model read two hundred identifiers.
        //
        // The stoplist is what makes that work. Without it "apple" and "settings"
        // matched every pane on the machine, the list was sorted alphabetically and cut
        // at eight, and the Siri pane — the one word in the script that actually meant
        // something — never appeared. A filter that matches everything selects nothing.
        let words = Set(
            lowered.split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count > 3 && !Self.paneStopWords.contains($0) }
        )
        let matches = all
            .map { pane -> (id: String, score: Int) in
                let name = pane.lowercased()
                return (pane, words.filter { name.contains($0) }.count)
            }
            .filter { $0.score > 0 }
            // Most words matched first, then shortest id: `com.apple.Siri-Settings`
            // before a Siri-adjacent extension with a longer name.
            .sorted { ($0.score, $1.id.count) > ($1.score, $0.id.count) }
            .map(\.id)

        var lines = ["System Settings pane ids changed in Ventura; the ones on this Mac are read from \(settingsExtensionsDirectory)."]
        if !matches.isEmpty {
            lines.append("")
            lines.append("Matching what you asked for:")
            lines.append(contentsOf: matches.prefix(8).map { "  • \($0)" })
        }
        lines.append("")
        lines.append("Open one with `shell`, which is more reliable than `reveal pane id`:")
        lines.append("  open \"x-apple.systempreferences:\(matches.first ?? "com.apple.Appearance-Settings.extension")\"")
        if matches.isEmpty {
            lines.append("")
            lines.append("List them all:")
            lines.append("  ls \(settingsExtensionsDirectory) | sed 's/.appex$//'")
        }
        return lines.joined(separator: "\n")
    }

    /// Every settings pane identifier this Mac actually has.
    ///
    /// Read from disk rather than hard-coded: the list is different on every macOS
    /// version, and a list baked in here would be a fresh source of the exact wrong
    /// answer this exists to replace.
    static func availablePanes(
        in directory: String? = nil, fileManager: FileManager = .default
    ) -> [String] {
        let root = directory ?? settingsExtensionsDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".appex") else { return nil }
            let plist = "\(root)/\(name)/Contents/Info.plist"
            guard let data = fileManager.contents(atPath: plist),
                  let parsed = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any],
                  let identifier = parsed["CFBundleIdentifier"] as? String
            else { return nil }
            // Only the settings panes. The directory holds every ExtensionKit
            // extension on the system, most of which are not panes at all.
            return identifier.contains("Settings") || identifier.contains("settings")
                ? identifier : nil
        }.sorted()
    }

    /// The macOS privacy denials that stop AppleScript and nothing else.
    ///
    /// Each is a refusal by the osascript/System Events Apple-events principal, which
    /// is a *different* TCC principal from the one `AXIsProcessTrusted()` answers for
    /// — the one `key`, `click` and `ax_press` go through.
    static let automationDenials = [
        "not allowed to send keystrokes", "(1002)",          // UI scripting / keystroke
        "not authorized to send apple events", "(-1743)",    // per-app Automation
        "not allowed assistive access", "(-25211)",          // assistive access
    ]

    /// What to try when the AppleScript route — and only that route — is denied.
    ///
    /// A run that had `key` and `ax_press` in its registry, with Accessibility
    /// granted, gave up on "open the command palette" because
    /// `keystroke "p" using {command down, shift down}` came back "osascript is not
    /// allowed to send keystrokes. (1002)". Passed through raw, that reads as
    /// "this machine will not let me send keys", and the model told the user to press
    /// the chord themselves — a tier-escalation dead-end, not a permissions problem.
    /// Nothing in the message said the denial was tier-local, so nothing prompted the
    /// one step that would have worked: go up a tier.
    ///
    /// The advice has to be true of *this* run, so it names only tools the ceiling
    /// actually leaves in the registry; below tier 2 there is no other route, and
    /// saying so is what keeps the hint worth reading when it does appear.
    ///
    /// - Returns: guidance to append, or nil for an ordinary script failure — a
    ///   syntax error is the model's own bug and escalating past it would only move
    ///   the same mistake to a more expensive tier.
    static func escalation(stderr: String, maxTier: Tier) -> String? {
        let lowered = stderr.lowercased()
        guard automationDenials.contains(where: { lowered.contains($0) }) else { return nil }

        let preamble = """
            This denial is specific to the AppleScript/System Events route. macOS gates \
            it under a different privacy permission from the one synthetic input and the \
            accessibility API use, so it does not mean this run cannot drive the UI.
            """

        switch maxTier {
        case .pixels:
            return """
                \(preamble) The same chord is available from `key` (Tier 3), which posts \
                a CGEvent through the Accessibility permission this run may well already \
                hold — try it before reporting failure. When the target is a named \
                control rather than a chord, `ax_capture` then `ax_press` (Tier 2) is the \
                better route, because it activates the element you meant instead of a \
                shortcut you hope is bound.
                """
        case .accessibility:
            return """
                \(preamble) `ax_capture` then `ax_press` (Tier 2) reaches menu items, \
                buttons and other named controls by a different mechanism — try that \
                before reporting failure.
                """
        case .shell, .script:
            return """
                \(preamble) The routes that get around it are above this run's tier \
                ceiling, so they are not available to you at all: this one genuinely is \
                a limit to report rather than something to retry.
                """
        }
    }

    /// Adds the likely cause when a script times out.
    ///
    /// A first script against an app blocks on the macOS Automation consent dialog,
    /// which waits indefinitely for the user. Without this the model sees only a
    /// timeout, assumes its script is wrong, and rewrites something that was correct.
    static func explain(_ error: Subprocess.Error, script: String) -> String {
        guard case .timedOut = error else { return error.description }

        let named = script.range(of: #"(?i)tell application\s+"([^"]+)""#, options: .regularExpression)
            .map { String(script[$0]) }
        let target = named.flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }

        return """
            \(error.description)

            A script that names an app for the first time waits on the macOS Automation \
            consent dialog, which blocks until the user answers\(target.map { " — look for a prompt about \($0)" } ?? ""). \
            If that is what happened, the script is fine: ask the user to allow it and \
            run the same script again. Rewriting it will not help.
            """
    }

    /// The script's opening line. `Risk.summary` sanitises it before display.
    private func firstLine(of script: String) -> String {
        script.split(separator: "\n").first.map(String.init) ?? script
    }
}

/// Tier 1 — run a user-authored macOS Shortcut.
///
/// Shortcuts are the user's own pre-approved automations, so invoking one is
/// usually safer and more capable than reconstructing the same work from scratch.
public struct ShortcutsTool: Tool {
    public let name = "run_shortcut"
    public let tier = Tier.script
    public let description = """
    Run a macOS Shortcut by name, optionally passing input, and return its output. \
    Call with no `name` to list every shortcut the user has. Shortcuts are automations \
    the user already built and trusts — check the list before building something \
    equivalent out of other tools.

    A shortcut can take a while and may open windows or ask the user something, so a \
    slow one is not necessarily stuck.
    """

    public var inputSchema: JSONValue {
        .schema([
            "name": .string(describing: "Shortcut name to run. Omit to list all available shortcuts."),
            "input": .string(describing: "Text passed to the shortcut as its input."),
        ], required: [])
    }

    let runner: any ScriptRunning

    /// - Parameter runner: how a validated script is actually run.
    ///
    ///   Injectable for one reason: the tests that prove the deny-list holds have to
    ///   feed this tool the exact payloads the deny-list names — `rm -rf /` among
    ///   them. Those are safe only while the deny-list works, and the mutation
    ///   sweep's job is to break the deny-list deliberately, so a sweep run against
    ///   the real `osascript` would execute `rm -rf /` on the machine and read the
    ///   user's actual SSH private key into the test log. A gate is properly tested
    ///   by showing execution is never reached, which needs execution to be something
    ///   a test can hold.
    public init(runner: any ScriptRunning = OsascriptRunner()) {
        self.runner = runner
    }

    public func risk(for input: JSONValue) -> Risk {
        // Listing shortcuts only reads.
        guard let name = input["name"]?.stringValue, !name.isEmpty else { return .read }

        // A shortcut's body is opaque to us — it can shell out, delete files or send
        // data anywhere. Classifying it destructive keeps it out of the session
        // allowlist, so approving one shortcut never silently approves the next.
        return .dangerous(summary: "run the shortcut '\(name)', whose contents we cannot inspect")
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        guard let name = input["name"]?.stringValue, !name.isEmpty else {
            let result = try await Subprocess.run(
                executable: "/usr/bin/shortcuts", arguments: ["list"], timeout: 20
            )
            return result.succeeded
                ? .text("Available shortcuts:\n\(result.stdout)")
                : .failure(result.combined)
        }

        // `shortcuts run` writes results to --output-path; it prints nothing useful to
        // stdout. Without this the tool discarded whatever the shortcut produced while
        // its own description promised to return it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output")
        var arguments = ["run", name, "--output-path", outputURL.path]

        var stdin: String?
        if let text = input["input"]?.stringValue {
            // The input is a *path*, not stdin, whatever `-` might suggest.
            let inputURL = directory.appendingPathComponent("input")
            try? Data(text.utf8).write(to: inputURL)
            arguments += ["--input-path", inputURL.path]
            stdin = nil
        }

        let result = try await Subprocess.run(
            executable: "/usr/bin/shortcuts", arguments: arguments, stdin: stdin, timeout: 120
        )
        guard result.succeeded else { return .failure(result.combined) }

        if let data = try? Data(contentsOf: outputURL), !data.isEmpty {
            return .text(String(decoding: data, as: UTF8.self))
        }
        return .text("Shortcut '\(name)' completed with no output.")
    }
}

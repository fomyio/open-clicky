import Foundation

/// Tier 1 — drive scriptable macOS apps through AppleScript or JXA.
///
/// The most under-used capability on macOS and the reason OpenClicky can answer a
/// large share of "control my Mac" requests without taking a single screenshot.
/// Scriptable apps expose a typed object model, so this is deterministic where
/// pixel-clicking is probabilistic.
public struct AppleScriptTool: Tool {
    public let name = "app_script"
    public let tier = Tier.script
    public let description = """
    Run AppleScript or JavaScript-for-Automation (JXA) against scriptable macOS apps. \
    Strongly prefer this over screenshots and clicking: it is deterministic, costs no \
    vision tokens, and works whether or not the app is visible.

    Widely scriptable: Finder, Mail, Calendar, Notes, Reminders, Messages, Contacts, \
    Safari, Music, Photos, Terminal, System Events, Keynote/Pages/Numbers.

    Useful patterns:
      • Frontmost app:      tell application "System Events" to name of first process whose frontmost is true
      • Unread mail count:  tell application "Mail" to unread count of inbox
      • Today's events:     tell application "Calendar" to ...
      • New note:           tell application "Notes" to make new note with properties {name:"x", body:"y"}
      • Safari's page URL:  tell application "Safari" to URL of current tab of front window
      • Open a file:        tell application "Finder" to open POSIX file "/path"
      • Set volume:         set volume output volume 40
      • UI scripting:       tell application "System Events" to tell process "X" to click button "OK" of window 1

    `System Events` UI scripting reaches menus and controls that have no direct \
    AppleScript API — it is still Tier 1 and still beats clicking by coordinate.

    First use of a given app triggers a one-time macOS automation consent dialog.

    `do shell script` and the JXA ObjC bridge run outside the sandbox that confines \
    the `shell` tool, so they always require explicit approval. Use the `shell` tool \
    instead when you want a shell command — it is confined and its output is cleaner.
    """

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

    public init() {}

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

        var arguments: [String] = []
        if language == "javascript" { arguments += ["-l", "JavaScript"] }
        // Source arrives on stdin rather than as an argument: scripts routinely
        // contain quotes and newlines that would need escaping otherwise.
        arguments.append("-")

        do {
            let result = try await Subprocess.run(
                executable: "/usr/bin/osascript",
                arguments: arguments,
                stdin: script,
                timeout: timeout
            )
            if result.succeeded { return .text(result.stdout.trimmingCharacters(in: .newlines)) }

            // osascript's own errors are the useful diagnostic; surface them intact
            // so the model can correct its script rather than guess.
            return ToolOutput(
                content: [.text("Script failed:\n\(result.stderr.trimmingCharacters(in: .newlines))")],
                isError: true
            )
        } catch let error as Subprocess.Error {
            return .failure(error.description)
        }
    }

    private func firstLine(of script: String) -> String {
        let line = script.split(separator: "\n").first.map(String.init) ?? script
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
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
    """

    public var inputSchema: JSONValue {
        .schema([
            "name": .string(describing: "Shortcut name to run. Omit to list all available shortcuts."),
            "input": .string(describing: "Text passed to the shortcut as its input."),
        ], required: [])
    }

    public init() {}

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

        var arguments = ["run", name]
        if let text = input["input"]?.stringValue {
            arguments += ["--input-path", "-"]
            let result = try await Subprocess.run(
                executable: "/usr/bin/shortcuts", arguments: arguments, stdin: text, timeout: 120
            )
            return result.succeeded ? .text(result.combined) : .failure(result.combined)
        }

        let result = try await Subprocess.run(
            executable: "/usr/bin/shortcuts", arguments: arguments, timeout: 120
        )
        return result.succeeded
            ? .text(result.stdout.isEmpty ? "Shortcut '\(name)' completed." : result.stdout)
            : .failure(result.combined)
    }
}

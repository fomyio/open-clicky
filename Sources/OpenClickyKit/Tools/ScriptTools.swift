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

    public func risk(for input: JSONValue) -> Risk {
        guard let script = input["script"]?.stringValue else { return .read }
        let lowered = script.lowercased()

        // Sending a message or mail leaves the machine and cannot be recalled.
        let outward = ["send", "delete", "empty trash", "erase", "quit application", "shut down", "restart"]
        if outward.contains(where: { lowered.contains($0) }) {
            return .dangerous(summary: firstLine(of: script))
        }

        // Reading properties is by far the common case; treat a script with no
        // obvious mutation verb as read-only so queries stay prompt-free.
        let mutating = ["make new", "set ", "click", "keystroke", "key code", "open ", "close ",
                        "add ", "remove", "move ", "duplicate", "save", "activate", "launch"]
        return mutating.contains(where: { lowered.contains($0) })
            ? .write(summary: firstLine(of: script))
            : .read
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let script = try input.string("script")
        let language = input.string("language", default: "applescript")
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
        guard let name = input["name"]?.stringValue else { return .read }
        // A shortcut's body is opaque to us, so any run is a potential mutation.
        return .write(summary: "run the shortcut '\(name)'")
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

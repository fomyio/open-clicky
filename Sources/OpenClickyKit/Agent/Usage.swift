import Foundation

/// The `--help` text.
///
/// In the kit rather than the executable for the reason `RunReport` and `WaitingLine`
/// are: it is user-facing output, and until it could be produced without an API key
/// nothing could check that it agrees with the parser beside it.
///
/// That agreement is not decoration. Three flags and a subcommand were added in one
/// sitting, each documented only because someone remembered to; a flag the parser
/// accepts and the help omits is invisible, and one the help promises and the parser
/// rejects sends a user to a documented option that errors. `UsageTests` holds the
/// second direction structurally — every flag named here must parse — and the first
/// still rests on inspection, which is worth saying rather than implying otherwise.
public enum Usage {

    /// - Parameter bold: how to emphasise a heading. The CLI passes its ANSI styling;
    ///   a test passes identity, so the text it inspects is the text a piped terminal
    ///   would receive.
    public static func text(bold: (String) -> String = { $0 }) -> String {
        """
        \(bold("openclicky")) — an agent that operates your Mac

        \(bold("USAGE"))
          openclicky "<task>"            Run a task (exit 2 if it did not finish)
          openclicky -i ["<task>"]       Stay open for more instructions afterwards
          openclicky --version           Print the build
          openclicky auth                Store an API key, and check that it works
                                         (--provider chooses whose)
                                         Keys live in ~/.openclicky/config.json, mode 600
          openclicky doctor              Check permissions and configuration (exit 1 if not ready)
          openclicky transcripts [n]     List recorded sessions, newest first (default 20)
          openclicky transcript [id]     Replay one (default: the latest)
          openclicky forget <days>       Delete sessions older than <days>, after confirming
          openclicky bench               Report where recorded runs spent their time
          openclicky forget-key          Delete a stored key (--provider chooses which)

        \(bold("OPTIONS"))
          --mode <mode>      read-only | ask | auto | bypass          (default: ask)
          --max-tier <0-3>   Highest capability tier the agent may use (default: 3)
                               0 shell/files · 1 AppleScript · 2 accessibility · 3 screenshots
          --provider <name>  anthropic | openai | ollama | litellm | groq
                               (default: $OPENCLICKY_PROVIDER, the stored choice,
                                then anthropic)
          --base-url <url>   Endpoint for an OpenAI-compatible provider
                               (default: the provider's own, or $OPENCLICKY_BASE_URL)
          --model <id>       Model id
                               (default: $OPENCLICKY_MODEL, the stored choice, then
                                the provider's own; \(DefaultModel.id) for anthropic)
                               A model that cannot be sent images caps the run at tier 2.
          --effort <level>   low | medium | high | xhigh | max         (default: high)
                               Ignored on models older than Claude 4.6, which reject it.
          --planner <id>     Ask a stronger model how to approach the task first
                               (default: $OPENCLICKY_PLANNER, then the stored choice)
                               Costs one extra round-trip; off unless chosen.
          --max-turns <n>    Cap on agent turns                        (default: 40)
          --no-sandbox       Run shell commands without sandbox-exec
          --interactive      Keep the session open and take the next instruction, with
                             the conversation carried forward (short form: -i)
                               Leave with ctrl-D, `quit` or `exit`. Cost accumulates
                               across the session; each task reports its own verdict.

        \(bold("EXAMPLES"))
          openclicky "what's taking up space in my Downloads folder?"
          openclicky --max-tier 1 "how many unread emails do I have?"
          openclicky --mode auto "open the OpenClicky repo in Finder"
          openclicky --provider ollama --model llama3.2 "which windows are open?"

        \(bold("STOPPING IT"))
          Ctrl-C stops the agent at the next action boundary — it will not be killed
          between a mouse-down and its mouse-up. Press it twice to force an exit.
          In an interactive session it stops the task in flight and hands you back the
          prompt; pressed at an idle prompt, it leaves.

        \(bold("THE APP"))
          ./Scripts/bundle.sh builds OpenClicky.app: a menu-bar agent summoned with
          ⌥space, which shows what it is doing and asks before it changes anything.
          Its Settings window picks the provider, the model and the planner, and
          writes them to the same ~/.openclicky/config.json this CLI reads.
        """
    }

    /// Every subcommand the help names.
    ///
    /// Derived for the same reason the flags are, and added after `forget-key` was
    /// promised by `auth`'s output, documented nowhere, and implemented not at all —
    /// so running it was read as a *task* and sent to a model. A hand-kept list would
    /// not have caught that, because nobody adding a command edits a list they have
    /// not noticed.
    public static var documentedSubcommands: [String] {
        text().split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "openclicky" else { return nil }
            let word = String(parts[1])
            // Not `openclicky "<task>"`, and not the EXAMPLES lines, which start
            // with a flag: `openclicky --mode auto "open the repo"`.
            guard !word.hasPrefix("-"), word.allSatisfy({ $0.isLetter || $0 == "-" })
            else { return nil }
            return word
        }
    }

    /// Every long option the help names, in the order it names them.
    ///
    /// Parsed out of the text rather than kept beside it, so the two cannot disagree:
    /// a second list would be one more thing to update, which is the failure this
    /// whole type exists to make impossible.
    public static var documentedFlags: [String] {
        text().split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--") else { return nil }
            return trimmed.split(whereSeparator: { $0 == " " || $0 == "<" }).first.map(String.init)
        }
    }
}

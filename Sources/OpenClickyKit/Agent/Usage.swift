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
          openclicky "<task>"            Run a task (exit 2 if it changed nothing)
          openclicky --version           Print the build
          openclicky auth                Store an API key, and check that it works
                                         (--provider chooses whose)
          openclicky doctor              Check permissions and configuration (exit 1 if not ready)
          openclicky transcripts [n]     List recorded sessions, newest first (default 20)
          openclicky transcript [id]     Replay one (default: the latest)
          openclicky forget <days>       Delete sessions older than <days>, after confirming
          openclicky bench               Report where recorded runs spent their time

        \(bold("OPTIONS"))
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

        \(bold("EXAMPLES"))
          openclicky "what's taking up space in my Downloads folder?"
          openclicky --max-tier 1 "how many unread emails do I have?"
          openclicky --mode auto "open the OpenClicky repo in Finder"
          openclicky --provider ollama --model llama3.2 "which windows are open?"

        \(bold("STOPPING IT"))
          Ctrl-C stops the agent at the next action boundary — it will not be killed
          between a mouse-down and its mouse-up. Press it twice to force an exit.

        \(bold("THE APP"))
          ./Scripts/bundle.sh builds OpenClicky.app: a menu-bar agent summoned with
          ⌥space, which shows what it is doing and asks before it changes anything.
        """
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

# OpenClicky

An agent that operates your Mac. Local-first, macOS-native, single Swift binary.

It reaches for the cheapest capability that can do the job — a shell command, an
AppleScript, the accessibility tree — and only looks at pixels when it has to.

## Requirements

macOS 14+, Swift 6, and an Anthropic API key.

## Getting started

### The app

```bash
./Scripts/bundle.sh          # builds build/OpenClicky.app
open build/OpenClicky.app    # menu bar icon; ⌥space to summon
```

A menu-bar agent with no Dock icon. Press ⌥space anywhere, type what you want, and
watch it work in a translucent overlay that never steals focus from the app you are
in. Escape dismisses it when idle and stops the agent when it is working.

### The CLI

```bash
swift build -c release
./.build/release/openclicky auth      # store your API key, and check that it works
./.build/release/openclicky doctor    # permissions and credentials; exits 1 if not ready
./.build/release/openclicky "what's taking up space in my Downloads folder?"

./.build/release/openclicky transcripts     # what has been run, newest first
./.build/release/openclicky transcript      # replay the most recent
./.build/release/openclicky forget 30       # delete records older than 30 days
```

Grant **Accessibility** and **Screen Recording** in System Settings ▸ Privacy &
Security. A CLI inherits its terminal's grants, so grant them to Terminal or iTerm
rather than to the binary. `doctor` tells you what is missing; Tiers 0 and 1 work
without either.

## The capability ladder

| Tier | Tools | Cost |
|---|---|---|
| 0 · shell | `shell`, `read_file`, `write_file` | no vision tokens |
| 1 · script | `app_script`, `run_shortcut` | no vision tokens, deterministic |
| 2 · accessibility | `ax_capture`, `ax_press`, `ax_set_value` | cheap text, reliable targeting |
| 3 · pixels | `screenshot`, `zoom`, `click`, `drag`, `type`, `key`, `scroll`, `wait` | ~1,500 vision tokens per capture |

"How much disk space is left?" is a shell command, not a screenshot of Disk Utility.
"How many unread emails?" is an AppleScript against Mail. "Click Save" is an
accessibility capture and a press by element id — which always hits, where a
predicted coordinate may not. A screenshot is for when appearance is the point.

Cap the ladder with `--max-tier`: `--max-tier 1` will never look at your screen.

Clicks are visible before they land: a ring animates along an arc to the target, so
you can see what the agent is about to do and stop it.

Actions verify themselves. A click reports what actually changed — which app came
forward, which window, what took focus — and says so explicitly when nothing did,
because a click that lands on nothing otherwise looks exactly like one that worked.

## Options

```
--mode <mode>      read-only | ask | auto | bypass          (default: ask)
--max-tier <0-3>   highest tier the agent may use           (default: 3)
--model <id>       model id                                 (default: claude-opus-5)
--effort <level>   low | medium | high | xhigh | max        (default: high)
--max-turns <n>    cap on agent turns                       (default: 40)
--no-sandbox       run shell commands without sandbox-exec
```

## Safety

There is no VM and no undo — the agent acts on your real machine.

**Classification is conservative.** A tool call is treated as mutating unless it can
be *proved* to only read: every command in a chain must be a known read-only command,
with an allowlisted subcommand where one applies, no redirection, and nothing that
defeats static analysis. This matters because a read classification skips the
permission prompt in every mode, so an unsound "looks read-only" heuristic is a total
bypass rather than a missed prompt.

**Approval.** In the default `ask` mode every state-changing action needs your
approval. Destructive ones — recursive deletes, `sudo`, disk operations, writes to
launch agents or shell rc files, running a Shortcut whose contents can't be inspected —
prompt every time, including after you choose "always allow" for that tool.

**Secrets.** Credential paths (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, …) are
refused through every tool in every mode. Paths are canonicalised before comparison
rather than matched as text, so `$HOME/.ssh/id_rsa`, `~user/.ssh/id_rsa`,
`~/Documents/../.ssh/id_rsa` and `cd ~/.ssh && cat id_rsa` all reach the same refusal.
Output that is itself a credential — `security find-generic-password -w` — is withheld
even when you approve the command, because approving the action was not consent to
send the secret to the model and write it into a session record. API keys are
stripped from the environment of every command the agent runs, so a command cannot
read them even if it were misclassified. The key itself lives in the login keychain —
note that it can therefore travel in an encrypted backup or a Migration Assistant
transfer, because the attribute that would prevent that needs an entitlement a
command-line binary cannot have.

**Confinement.** Shell commands run under `sandbox-exec`, which denies writes to
system locations and to user-level persistence paths (`~/Library/LaunchAgents`,
`~/.ssh`), and denies reads of the credential directories. AppleScript cannot be
confined this way — it drives already-running apps over Apple events — so `do shell
script` and the JXA ObjC bridge are always classified destructive and always prompt.

**Self-authorisation.** The dialog macOS shows to ask whether this agent may drive an
app is an ordinary window with an ordinary button, so acting on one is treated as
destructive and always prompts — a gate its subject can operate is not a gate. The
same applies to System Settings' privacy panes, Keychain Access, and to writing the
agent's own binary or app bundle.

The deny-list of catastrophic commands is a narrow backstop for the handful of things
no prompt should be able to authorise by accident. It is not exhaustive and is not
meant to be — containment comes from the classifier and the gate.

**Stopping it.** Ctrl-c stops the agent at the next action boundary — it will not be
killed between a mouse-down and its mouse-up. Press it twice to force an exit.

Sessions are recorded as JSONL under `~/.openclicky/sessions/`, in full — including
screenshots — and are never pruned automatically. `openclicky doctor` reports what
they occupy; `openclicky forget <days>` deletes old ones after showing you exactly
what would go.

## Development

```bash
swift test                            # 317 tests
swift test --filter CoordinateTests   # one suite
./Scripts/mutation-sweep.sh           # check the tests defend what they claim
```

`mutation-sweep.sh` breaks each safety-critical invariant in turn and reports how many
tests notice. A line reading `NOT CAUGHT` is an invariant nothing defends — it found
fourteen that way. It mutates the working tree, so do not run it alongside other work.

```bash
./Scripts/preflight.sh --install      # run every pre-commit check, and install it as a hook
```

`preflight.sh` is everything that must hold before a commit: the release build, the
tests, no mutation left behind by an interrupted sweep, `CLAUDE.md` inside its budget,
no build artifacts tracked, no credentials staged, no machine identifiers. Installing
it as a hook makes those the gate rather than a habit.

Some tests drive real macOS APIs (`osascript`, `sandbox-exec`, the accessibility
API) rather than mocks, because mocking them would prove nothing about the code
being tested. They stay read-only or confined to a temporary directory.

Design rationale lives in `computer-use-research/`; decisions and their trade-offs
in `docs/DISCOVERIES/`.

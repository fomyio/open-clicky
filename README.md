# OpenClicky

An agent that operates your Mac. Local-first, macOS-native, single Swift binary.

It reaches for the cheapest capability that can do the job — a shell command, an
AppleScript, the accessibility tree — and only looks at pixels when it has to.

## Requirements

macOS 14+, Swift 6, and an Anthropic API key.

## Getting started

```bash
swift build -c release
./.build/release/openclicky auth      # store your API key in the Keychain
./.build/release/openclicky doctor    # check macOS permissions
./.build/release/openclicky "what's taking up space in my Downloads folder?"
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

There is no VM and no undo — the agent acts on your real machine. In the default
`ask` mode every state-changing action needs your approval, and destructive ones
ask even after you have chosen "always allow". A deny-list refuses catastrophic
commands and credential paths in every mode, and shell commands run under
`sandbox-exec`, which keeps writes away from system locations.

Sessions are recorded as JSONL under `~/.openclicky/sessions/`.

## Development

```bash
swift test                            # 48 tests
swift test --filter CoordinateTests   # one suite
```

Some tests drive real macOS APIs (`osascript`, `sandbox-exec`, the accessibility
API) rather than mocks, because mocking them would prove nothing about the code
being tested. They stay read-only or confined to a temporary directory.

Design rationale lives in `computer-use-research/`; decisions and their trade-offs
in `docs/DISCOVERIES/`.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenClicky is a **macOS-native agent that operates the user's Mac**. Single Swift binary, no VM — a VM isolates a *background* agent from the host and therefore cannot control the host's UI. Containment is the permission gate, a deny-list, and `sandbox-exec` on shell commands.

## Commands

```bash
swift build && swift test            # 108 tests; several drive the real OS
swift test --filter CoordinateTests  # one suite
swift run openclicky doctor          # TCC grants + credentials
swift run openclicky auth            # store the API key in the Keychain
swift run openclicky "<task>"        # run a task
```

Flags: `--mode read-only|ask|auto|bypass` (default `ask`), `--max-tier 0..3`, `--model`, `--effort`, `--max-turns`, `--no-sandbox`.

**A CLI inherits its terminal's TCC grants** — Accessibility and Screen Recording go to Terminal/iTerm, not to the binary. `doctor` reports what's missing.

## The capability ladder — the core idea

`Tier` (`Tools/Tool.swift`) orders every tool 0–3; the ordering drives the system prompt, sorts the tool list, and is what `--max-tier` caps.

| Tier | Tools | Cost |
|---|---|---|
| 0 shell | `shell`, `read_file`, `write_file` | no vision tokens |
| 1 script | `app_script` (AppleScript/JXA), `run_shortcut` | no vision tokens, deterministic |
| 2 accessibility | `ax_capture`, `ax_press`, `ax_set_value` | ~hundreds of tokens, reliable targeting |
| 3 pixels | `screenshot`, `zoom`, `click`, `drag`, `type`, `key`, `scroll`, `wait` | ~1,500 vision tokens + ~1s, can miss |

**Add new capabilities at the lowest tier that can do the job.** Tier 1 is the differentiator — most "control my Mac" tasks are scriptable with no pixels. Tier 2 is grounding: `ax_capture` renders elements as text with ids so the model presses `#e12` rather than predicting a coordinate.

## Invariants — breaking these fails silently

- **A `.read` classification skips the permission gate in every mode**, `read-only` included. Classification must therefore be *conservative*: mutating unless provably read-only. Never write a heuristic that looks for evidence of mutation and defaults to read — that turns any gap from "missed prompt" into "total bypass", which is how every finding in the 2026-09-04 audit arose.
- **Newlines are shell command separators.** `zsh -c` treats `\n` like `;`. Swift treats `\r\n` as a *single* grapheme cluster matching neither `"\n"` nor `"\r"` — split with `isNewline`, never a character set.
- **Every route to execution needs the same checks.** `Policy.validateShell` covers `shell` *and* `app_script`. AppleScript can't be sandboxed (Apple events; `do shell script` escapes any wrapper), so its shell escapes are always destructive.
- **Secrets never reach a child process.** `Subprocess` sets an explicit scrubbed environment; the default inherits the parent's.
- **Image coordinates are not screen points.** Screenshots are downscaled, so model coordinates are in *image pixel space* — everything acting on them goes through `ScreenContext.screenPoint(fromImage:)`.
- **The transcript is append-only.** Assistant turns replay verbatim, thinking blocks included. Unmodelled blocks round-trip via `ContentBlock.passthrough`, which must claim the encoder *before* any keyed container opens.
- **All `tool_result` blocks for a turn go back in one user message.** A skipped or denied call still needs its result, or its `tool_use` is orphaned and the request 400s.
- **Batches fail fast** — the model planned them against state that no longer holds.
- **Nothing session-specific in `SystemPrompt.stable`.** It carries the cache breakpoint; drift re-bills the whole prompt each turn. `CostMeter.cacheHitRate` is the canary.
- **AX element ids expire** on any UI change, and a clipped tree must say so — silent truncation reads as "the control doesn't exist".

## API specifics (Opus 5 family)

`claude-opus-5`, `thinking: {type: "adaptive"}`, `output_config.effort` (default `high`). `budget_tokens`, `temperature`, `top_p` and prefill are **400s**. Tools are `strict: true` with `additionalProperties: false`.

## Layout & conventions

`Agent/` wire types, client, loop, transcript, cost, prompt · `Tools/` one file per tier · `Perception/` capture, AX, probe · `Action/` CGEvent · `Safety/` policy + gate · `Support/` Keychain, subprocess.

Tests drive the real OS on purpose (`osascript`, `sandbox-exec`, AX, a spawned child); the loop uses a scripted `MessagesClient`. Everything above the HTTP boundary is still **untested live** — no API key here yet.

Work goes on stacked branches off `chore/project-scaffold`; nothing is pushed without asking. Design rationale in `computer-use-research/` (`_raw/` outranks the prose); decisions and history in `docs/DISCOVERIES/YYYY-MM.md`. This file stays under 5000 characters.

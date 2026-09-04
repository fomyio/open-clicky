# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

OpenClicky is a **macOS-native agent that operates the user's Mac**. Single Swift binary, no VM — a VM isolates a *background* agent from the host and therefore cannot control the host's UI, which is the whole point here. Isolation comes from the permission gate, the deny-list, and `sandbox-exec` on shell commands.

## Commands

```bash
swift build                          # build
swift test                           # all tests (48; several hit the real OS — see below)
swift test --filter CoordinateTests  # one suite
swift run openclicky doctor          # check TCC grants + credentials
swift run openclicky auth            # store the API key in the Keychain
swift run openclicky "<task>"        # run a task
```

Flags: `--mode read-only|ask|auto|bypass` (default `ask`), `--max-tier 0..3`, `--model`, `--effort`, `--max-turns`, `--no-sandbox`.

**A CLI inherits its terminal's TCC grants** — Accessibility and Screen Recording must be granted to Terminal/iTerm, not to the `openclicky` binary. `doctor` reports what is missing.

## The capability ladder — the core idea

`Tier` (`Sources/OpenClickyKit/Tools/Tool.swift`) orders every tool 0–3, and the ordering is load-bearing: it drives the system prompt, sorts the tool list, and is what `--max-tier` caps.

| Tier | Tools | Cost |
|---|---|---|
| 0 shell | `shell`, `read_file`, `write_file` | no vision tokens |
| 1 script | `app_script` (AppleScript/JXA), `run_shortcut` | no vision tokens, deterministic |
| 2 accessibility | `ax_capture`, `ax_press`, `ax_set_value` | ~hundreds of tokens, reliable targeting |
| 3 pixels | `screenshot`, `zoom`, `click`, `drag`, `type`, `key`, `scroll`, `wait` | ~1,500 vision tokens + ~1s, coordinates can miss |

**Always add a new capability at the lowest tier that can do the job.** Tier 1 is the differentiator — most "control my Mac" tasks are scriptable with no pixels at all. Tier 2 is our grounding layer: `ax_capture` renders elements as text with ids, so the model presses `#e12` instead of predicting a coordinate. That is Set-of-Marks at a fraction of the cost, and it is why clicks land.

## Invariants — breaking these fails silently

- **Image coordinates are not screen points.** Screenshots are downscaled (1920 long edge), so the model's coordinates are in *image pixel space*. Everything that acts on them must go through `ScreenContext.screenPoint(fromImage:)`. Skipping it produces clicks that land plausibly but wrong. Pinned by `CoordinateTests`.
- **The transcript is append-only.** Assistant turns are echoed back verbatim, thinking blocks included — they are bound to the producing model. Unmodelled block types round-trip via `ContentBlock.passthrough`, which must claim the encoder *before* any keyed container is opened.
- **All `tool_result` blocks for a turn go back in one user message.** Splitting them teaches the model to stop batching.
- **Batches fail fast.** After a failed call the rest of the turn is skipped, because the model planned the batch against state that no longer holds.
- **AX element ids expire** on any UI change. A stale id must error, never act on the wrong element.

## API specifics (Opus 5 family)

`claude-opus-5`, `thinking: {type: "adaptive"}`, `output_config.effort` (we default `high` — computer use is measurably better there). `budget_tokens`, `temperature`, `top_p` and assistant prefill are all **400s** on this family. Tools are `strict: true` with `additionalProperties: false`. Cache breakpoints: the stable system prefix and the last tool definition — never interpolate session state into `SystemPrompt.stable`.

## Layout

`Agent/` wire types, HTTP client, loop, transcript, system prompt · `Tools/` one file per tier · `Perception/` ScreenCaptureKit, AX tree, context probe · `Action/` CGEvent injection · `Safety/` policy + gate · `Support/` Keychain, subprocess.

Tests hit the real OS on purpose (`osascript`, `sandbox-exec`, the AX API) — mocking them would prove nothing about the thing being tested. They stay read-only or confined to a temp dir. Everything above the HTTP boundary is **untested live**: no API key on this machine yet.

## Conventions

Research corpus in `computer-use-research/` is the design rationale; `_raw/` is first-hand evidence from the installed Claude.app and outranks the prose. Deep detail and history go in `docs/DISCOVERIES/YYYY-MM.md`, not here — this file stays under 5000 characters.

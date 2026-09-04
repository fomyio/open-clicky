# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Swift package with `OpenClickyKit` library and `openclicky` CLI, targeting macOS 14+.
- Anthropic Messages API client (`claude-opus-5`, adaptive thinking, effort control)
  with retry/backoff, typed errors, and prompt-cache breakpoints on the stable system
  prefix and the tool block.
- Agent loop with batched tool execution and fail-fast semantics, JSONL transcript
  persistence, and a progress-event stream for the UI.
- Four-tier capability ladder: Tier 0 `shell`/`read_file`/`write_file`;
  Tier 1 `app_script` (AppleScript & JXA) and `run_shortcut`; Tier 2 `ax_capture`,
  `ax_press`, `ax_set_value`; Tier 3 `screenshot`, `zoom`, `click`, `drag`, `type`,
  `key`, `scroll`, `wait`.
- Accessibility-tree capture rendering elements as addressable ids, used as the
  grounding layer in place of raw coordinate prediction.
- ScreenCaptureKit capture with downscaling to a 1,920px long edge and explicit
  image-to-screen coordinate mapping.
- CGEvent input injection: click, drag with interpolation, scroll, key combinations,
  and text entry that switches to clipboard paste for long or multi-line input.
- Permission gate with `read-only`, `ask`, `auto` and `bypass` modes, a session
  allowlist that never covers destructive actions, and a deny-list for catastrophic
  commands and credential paths.
- `sandbox-exec` confinement for shell commands, with `--no-sandbox` to opt out.
- Keychain storage for the Anthropic API key (`openclicky auth`).
- `openclicky doctor` for TCC grant and credential diagnostics.
- 48 tests covering coordinate mapping, wire encoding, permission logic, the
  deny-list, and live execution of Tiers 0–2 against macOS.

### Security

- Shell commands and credential paths are checked against a deny-list before
  execution, in every permission mode.
- API keys are read from the environment or the macOS Keychain and never written
  to disk, a transcript, or a log.
- The system prompt instructs the model to treat all read content as untrusted
  data rather than instructions.

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
- Act-then-verify: `click`, `drag`, `type`, `key` and `ax_press` capture a
  lightweight UI fingerprint either side of the action and report what changed —
  frontmost app, window, focused element and its value. When nothing changed they
  say so and direct the model to a different strategy rather than a repeat of the
  same coordinates. Costs ~50 tokens against ~1,500 for a re-screenshot.
- **Menu-bar app with a global hotkey.** `Scripts/bundle.sh` builds `OpenClicky.app`:
  a `LSUIElement` agent with a status item, a global hotkey (⌥space by default) and a
  translucent non-activating overlay. The panel does not steal focus — the app the
  user is working in is usually the one the agent was summoned to act on — is excluded
  from screen capture so the agent never sees its own overlay, and floats above
  full-screen apps. Escape dismisses when idle and stops the run when working.
- **Phantom cursor.** Clicks and drags animate a visible ring along an eased bézier
  arc to the target before acting, then hide it so the real event lands unobstructed.
  An agent that moves the pointer invisibly is one the user cannot anticipate or
  interrupt; the arc makes each action legible and gives them a moment to press
  Escape. The geometry lives in the kit as pure functions, so it is tested without a
  window server, and the stage is inert when no presenter is installed — the CLI is
  unaffected.
- `SessionController`, a state machine driving the overlay from agent events, kept
  free of AppKit so its transitions are testable.
- `HotKey`, a Carbon `RegisterEventHotKey` wrapper. A bare key with no modifier is
  refused: a global hotkey without one fires while the user is typing anywhere.
- Interruption: ctrl-c stops the agent at the next action boundary rather than
  killing the process mid-click, and a second ctrl-c forces an exit. Cancellation
  is checked before every action in a batch, not once per turn.
- `ContextPolicy` controls how much observation history is resent each turn:
  recent screenshots and tool results in full, older results cut to a head-and-tail
  excerpt. Error results are never abbreviated.
- Screenshot pruning: only the most recent captures stay in the sent context,
  with older ones replaced by a note. Cuts a 12-screenshot session from ~18k
  tokens of images to under 4k.
- `ax_capture` reports when a tree was clipped by the node or depth limit, with
  advice for widening it; `max_nodes` is exposed to the model.
- Cost accounting: per-turn and session totals, cache hit rate, and an estimate
  of what caching saved, printed by the CLI and recorded in the transcript. A
  cache hit rate below 10% across multiple turns raises a warning.
- `MessagesClient` protocol so the agent loop can be driven by a scripted
  responder in tests.
- 166 tests covering coordinate mapping, wire encoding, permission logic, the
  deny-list and its bypasses, transcript pruning, cost accounting, the agent
  loop's batching and gating, and live execution of Tiers 0–2 against macOS.

### Fixed

- The API client's `Retry-After` handling was documented but not implemented, so a
  429 backed off on the computed schedule and could retry before capacity returned.
  A server-sent `Retry-After` now wins, capped at 60s.

- A reply cut off at the `max_tokens` limit was treated as a finished answer, so a
  half-written response reached the user with nothing marking it incomplete. It is
  now reported as truncated; if tool calls survived the cut, they still run and the
  clipped reasoning is flagged to the model.

### Security

- **Options are allowlisted, not denylisted.** Three audits each found a writing or
  executing mode hiding behind an option nobody had enumerated (`man -P`,
  `git log --output`, `sort -o`, `rg --pre`). A denylist can only exclude what is
  already known, so the rule is inverted: each read-only command allowlists the
  options that keep it a read, and anything unrecognised — including options that
  do not exist yet — goes to the permission gate. Verified in both directions:
  18 attack forms gated, 39 everyday commands still prompt-free.
- **Options are matched by meaning, not by token.** A third audit found `deniedTokens`
  used exact-string matching, so `sort -ro out in` (the `-o` inside a flag bundle) and
  `sort --output=out in` (the equals form) both wrote files while classified read-only.
  Arguments are now normalised — bundles expanded, `--flag=value` split, `--` honoured
  — before any option is matched. This is the same mistake as substring-matching
  verbs, in a different guise: comparing surface form instead of meaning.
- **Fixed: `git log --output=<path>` wrote arbitrary attacker-controlled content.**
  A repo whose HEAD commit message is chosen by an attacker could overwrite `~/.zshrc`
  while the agent believed it was reading history. `--output`, `--ext-diff` and
  `--textconv` are now denied for git's reading subcommands.
- **Fixed: `man -P '<command>'` was unprompted arbitrary execution.** `man` sets
  MANPAGER from `-P` and evals it — documented behaviour — and `man` had no argument
  constraints at all.
- **Fixed: a symlink defeated the credential deny-list entirely.** The check compared
  path strings while `open()` follows links, so `notes.txt` pointing at `~/.ssh/id_rsa`
  passed and was read straight through — and a malicious repo or archive can create
  such a link on checkout. Paths are now resolved, parent chain included, before any
  prefix comparison, and `read_file` resolves before opening so the checked path and
  the opened path are the same.
- **Fixed: `jq` could read the environment** via `jq -n 'env'`, from inside the filter
  expression where no flag rule reaches. Removed from the read-only set, as
  `printenv` and `env` already were.
- **Approval prompts are sanitised.** A raw ESC or CR in a command summary could
  reposition the cursor and overwrite the badge and text already printed, so the line
  the user read was not the command that ran. Control characters are now rendered
  visibly rather than emitted.
- **Secure text fields are never read.** `ax_capture` read every node's value, so one
  password field anywhere in a window put its contents into the model's context and
  the transcript. The subrole needed to detect them was already being fetched.
- **Session transcripts are `0600` in a `0700` directory.** They hold command output,
  file contents and screenshots in full and are never pruned on disk; the default
  umask made them world-readable, and every local macOS account is in `staff`.
- **Fixed: a failed paste discarded the user's clipboard.** The restore ran only on
  the success path, so a throw from the key event left the agent's text in the
  pasteboard and whatever the user had copied — possibly a password — gone.
- **Arguments are validated, not just executables.** A second audit found the first
  round had fixed the reported payloads without fixing the model: an allowlist of
  leading executables with no check on their arguments. `find . -exec sh -c '…'` was
  unprompted arbitrary code execution in read-only mode, and `awk 'BEGIN{system(…)}'`,
  `sed -i`, `plutil -replace`, `networksetup -setdnsservers` and `sysctl -w` the same.
  Every read-only command now declares how its arguments are constrained, and a
  command with no such declaration is never read-only. Commands whose argument space
  cannot be constrained confidently (`awk`, `sed`, `sqlite3`, `networksetup`,
  `sysctl`, `printenv`) were removed from the read-only set entirely.
- **Fixed: path checks were case-sensitive on a case-insensitive filesystem.**
  `~/.SSH/id_rsa` is the same file as `~/.ssh/id_rsa`, so one capital letter defeated
  the whole credential deny-list, and `~/library/launchagents/` downgraded a
  persistence write to an ordinary one. All path comparison now goes through a single
  case-insensitive helper.
- **Fixed: `git config credential.helper` classified as a read**, letting a durable
  credential exfiltrator be installed with no prompt. `git config`, `remote`, `branch`
  and `tag` are no longer read-only in any form.
- **Fixed: AppleScript read-verbs matched inside ordinary words.** `"get "` occurs in
  "budget", "target" and "forget", so a note containing one of those words classified
  as a read. Verbs now match at word boundaries, and object creation is always a
  mutation. This could fire by accident, not only on crafted input.
- **Fixed: string concatenation defeated shell-escape detection.** Splitting
  `do shell script` across `set p1 to "do shell "` … `run script (p1 & p2)` evaded
  every substring check. `run script` and `load script` are now escapes in their own
  right — a script assembled at runtime cannot be analysed statically at all.
- **Fixed: secret scrubbing missed the commonest naming convention.** The markers all
  required a leading underscore, so they matched only credential words used as a
  suffix — `SECRET_KEY`, `PASSWORD`, `TOKEN`, `DATABASE_URL` were all inherited by
  every command the agent ran. Detection is now component-based.
- **Fixed: the `"dd "` destructive marker matched `"add "`**, so `git remote add`
  was flagged as a raw disk write while genuinely unguarded commands passed.
  Destructive executables are matched as whole tokens.
- **Conservative command classification.** A shell command is read-only only if every
  segment provably reads. Previously a heuristic looked for evidence of mutation and
  defaulted to read — and because a read classification skips the permission gate in
  every mode, each gap in that heuristic was a full bypass.
- **Fixed: newline command chaining bypassed every permission mode.** `zsh -c` treats
  a newline as a separator, but the chaining guard checked only `;|&<>` backtick `$`.
  `ls\nrm -rf ~` presented `ls` as its leading token and ran unprompted, including in
  read-only mode. Newlines are now separators; CRLF is handled via `isNewline` because
  Swift treats `\r\n` as a single grapheme cluster.
- **Fixed: credential deny-list was only enforced in `read_file`.** `shell` with `cat`
  read any credential file and classified read-only, so the gate never asked. The
  deny-list now applies to shell and AppleScript, matched by directory prefix.
- **Fixed: `app_script` was a strictly more permissive shell.** `do shell script`
  matched no mutation keyword, so it classified read-only, and the tool applied neither
  the deny-list nor the sandbox. Shell escapes and the JXA ObjC bridge are now
  destructive and deny-listed.
- **Fixed: API keys were inherited by every child process.** `Process` with no explicit
  environment inherits the parent's, putting `ANTHROPIC_API_KEY` in reach of any
  command. Secrets are now stripped at the process boundary.
- **Fixed: `shell` could never be classified destructive**, so "always allow" on one
  benign command silently authorised `rm -rf` for the session.
- **Fixed: `write_file` classified on file existence alone**, so creating a new
  `~/Library/LaunchAgents` plist — the actual persistence attack — was a plain write.
- Sandbox profile extended to deny writes to `~/Library/LaunchAgents` and `~/.ssh`,
  and reads of the credential directories.
- Shortcut execution is destructive, so it cannot be covered by a session allowlist.
- Keychain items scoped `ThisDeviceOnly`, keeping the key out of backups and migration.
- API keys are read from the environment or the macOS Keychain and never written
  to disk, a transcript, or a log.
- The system prompt instructs the model to treat all read content as untrusted
  data rather than instructions.

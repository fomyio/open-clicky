# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Five mutation-sweep entries covering the completion guard and the latency
  accounting.** A guarantee whose test cannot fail is not a guarantee, and the guard
  added this cycle had no entry in the sweep that is supposed to prove exactly that.
  Each was verified individually rather than assumed: "a run that changed nothing
  reports success" is caught by 20 tests, "observing counts as having acted" by 4,
  "a failed action counts as an action taken" by 3, "every exit stops recording an
  outcome" by 8, and "the user wait is charged to the tools" by 7. The second of those
  is the one that matters most — it is the exact mistake a naive guard would make, and
  the one that would have let session `DE641705` through, since that run did emit a
  tool call.

### Added

- **The completion verdict is written to the record and shown in `transcripts`.** The
  guard says "nothing was done" on a terminal that scrolls away; the transcript is
  what remains, and a listing that could not tell a run which did the work from one
  which explained why it could not was the same failure one layer further out. A run
  that was asked to act and changed nothing is now marked `⚠ did nothing` in the
  listing. Sessions recorded before this existed carry no verdict and are left
  unmarked rather than defaulted to successful — absent and negative are different
  claims, and defaulting would relabel every historical run as fine, which is the
  precise error the guard was written to stop.

### Fixed

- **A second run on the same loop can no longer report the first one's verdict.**
  `run(task:)` can throw — a cancelled task, a client error — leaving `conclude`
  uncalled and the previous outcome readable. A stale "it acted" is exactly the
  reading this type exists to prevent, so the field is cleared at the start of a run
  rather than only written at the end.

### Changed

- **`pgrep` is classified read-only, removing a permission prompt from a common
  path.** It cost 3.43s of a 14.6s recorded run — all of it a person reading a prompt
  for a command that only prints PIDs, while `ps` has been read-only here all along.
  The entry was checked rather than assumed, because `pgrep` and `pkill` are the same
  inode on macOS: one binary, hard-linked, dispatching on `argv[0]`. Invoked as
  `pgrep` it rejects `-9`, `-HUP` and `-TERM` as illegal options and prints a usage
  line naming a strictly smaller option set than `pkill`'s, so signalling is
  unreachable through this name; `pkill` has no entry and still prompts. `-F pidfile`
  is the only option that opens a file, and on failure it names the path without
  echoing any of its contents — verified against a file of key-shaped text. Tests
  cover both names, the signal flags, and the renamed-binary case.

### Fixed

- **Time spent waiting on the user is no longer reported as tool time.** The first
  `bench` output read "tools 12%" over the two recorded sessions — 7.08s for
  `open -a Spotify` and 3.43s for `pgrep -l Code`. Measured directly, `sandbox-exec`
  adds ~5ms and `pgrep -l Code` runs end-to-end in ~25ms: neither command is in
  `Policy.readOnlyCommands`, so both stopped at the permission gate, and the seconds
  were a human reading a prompt. Reported together, the machine gets credit for the
  user's reaction time and Tier 0 — the tier the whole ladder exists to push work
  into — looks slow. The gate is now timed with a `ContinuousClock` and noted in the
  transcript, so `LatencyReport` can subtract it. Waits under 50ms are not recorded:
  an approval that never asked returns in microseconds and would measure nothing but
  an actor hop. Sessions recorded before this existed cannot be separated after the
  fact, so they render `tools†` with a footnote rather than quietly claiming a
  precision the record does not have, and one unaccounted session marks the whole
  aggregate.

### Added

- **`openclicky bench` — where a run's wall-clock time actually went.** Nothing
  measured time: `CostMeter` counts tokens and prices them, which answers "what did
  that cost" and says nothing about "why did that take a minute" — and the ladder's
  central claim, that `ax_capture` is ~26ms where a screenshot is ~1s, was one no part
  of this codebase could check. No new instrumentation was needed, because the record
  already had it: `Transcript` stamps every entry, so every run ever recorded was a
  latency measurement nobody read as one. `LatencyReport` derives per-turn model and
  tool time by walking the user/assistant spine in `sequence` order — never timestamp
  order, since several entries a turn share one millisecond stamp — and
  `LatencyBenchmark` aggregates sessions, reporting a median rather than a mean so one
  cold start cannot speak for the run. Deriving rather than instrumenting means a
  baseline exists for runs that predate the change, which is the only before-and-after
  that cannot be shaped by the change it measures. The report states its own limit: a
  turn's time includes retries the client made inside it, and retries are not recorded.

### Fixed

- **A run can no longer report success when it changed nothing.** The loop treated
  `stop_reason == "end_turn"` as completion, so "the model stopped talking" and "the
  task is done" printed the same closing line. In session `DE641705`, asked to format
  the markdown in the active VS Code tab, the agent ran one `shell` probe, found
  Accessibility ungranted, wrote a paragraph of instructions for the user to follow by
  hand, and closed with `── end_turn` — byte-identical to a run that did the work.
  `RunOutcome` now counts invocations that actually ran and changed state, using the
  `Risk` classification the permission gate already computes: `.read` observes,
  `.write` and `.dangerous` act. A task phrased as an instruction that ends with zero
  successful actions closes with "nothing was done", rendered as a warning rather than
  a status, and `openclicky "<task>"` exits 2 so a shell chain does not run on. Note
  that observing is not acting — the VS Code run made a tool call, and a guard that
  only asked "were there any tool calls?" would have missed it.

### Added

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

- **`openclicky forget <days>` deletes old session records.** `doctor` has been
  reporting that they accumulate and are never pruned while offering no way to act on
  it. It lists exactly what would go, with sizes, and requires typing `delete` — a
  keypress is not enough for something irreversible, the same reasoning that stopped a
  stray Return approving a destructive tool call. `doctor` now names it.

- **`openclicky transcripts [n]` shows a page.** It printed every session, which is
  fine at six and unusable at two hundred. Twenty by default, with a line saying how
  many there are and how to see them all.

- **`openclicky transcripts` reads the ends of each record, not all of it.** A run
  that takes screenshots stores each as ~240KB of base64, and the listing was decoding
  every one to print a task and a cost: 0.15s per session, so a hundred sessions would
  have been fifteen seconds for a hundred lines. Everything a listing needs is at one
  end of the file — 0.19s of CPU down to 0.03s across six large sessions.

- **`openclicky transcript <id>` exits 1 when no session matches.** It printed "No
  session matching…" and returned success.

- **`openclicky transcripts` lists recorded sessions, newest first** — id, when, turns,
  cost, and what was asked. A session is named by a UUID, so with more than one of them
  the only ways to find a record were to replay the latest or already know its id.

- **`Scripts/verify-gates.sh` breaks each preflight check and confirms it goes red.**
  Three of the nine were vacuous when written — one measured the build cache, one
  reported problems and exited 0, one covered every target except the tests — so a
  gate's own evidence is worth having. All nine object when what they guard is broken;
  the verifier itself was checked by making a gate incapable of failing and confirming
  it reports `STAYED GREEN` and exits non-zero.

- **`openclicky auth` trims the key and then checks it works.** A key pasted from a
  password manager routinely carries a space, and untrimmed it failed both ways: a
  leading one made a valid key be rejected as "not an Anthropic API key", a trailing
  one stored a key that 401s on every request afterwards. And "stored in the Keychain"
  was never the same claim as "this key works" — it now sends one token and says which
  it is, distinguishing a rejected key from an unreachable API. It also warns before
  replacing a key that is already stored.

- **`openclicky transcript [id]` replays a recorded session.** The record was written
  on every run and read by nothing — megabytes a session, reported by `doctor`, never
  pruned, and openable only with `jq` and patience. "The transcript exists to
  reconstruct what happened" was a claim with no implementation behind it. Images are
  named rather than printed, a record truncated by a crash still opens, and multi-line
  scripts keep their lines.

- **`Scripts/preflight.sh`** — everything that must hold before a commit, in one
  command, installable as a git pre-commit hook. Written after committing twice on top
  of a failed check: once with a failing test, once with `CLAUDE.md` over its budget.
  Both times the check had run, just beside the commit rather than as its gate. Each
  check is verified to catch its own failure.

- **`Scripts/mutation-sweep.sh`** breaks each safety-critical invariant in turn and
  reports how many tests notice. It found two that nothing defended: secure-field
  redaction (the tests exercised the predicate but never its application) and the
  vendor-key branch of the secret heuristic.

### Changed

- **The default model is now Haiku 4.5**, roughly 5x cheaper than Opus 5 ($1/$5 per
  million tokens against $5/$25). Tier 3 coordinate grounding is measurably weaker on
  it, which is what `--model claude-opus-5` and `--max-tier 2` are for: the
  accessibility tree is both cheaper and deterministic, so the cheap default pushes
  work toward the tier that was always meant to carry it. The default had four
  independent definitions — `Invocation`, `AgentLoop.Configuration`, the `--help` text
  and `Credentials.verify` — which agreed only by coincidence; `verify` in particular
  would have proven a key against a model the agent never calls. There is now one,
  `DefaultModel.id`.

- **Requests are shaped for the model they are sent to.** `thinking: {type:
  "adaptive"}` and `output_config.effort` are Claude 4.6+ fields, and older families
  reject them with a 400 rather than ignoring them — so the encoder, which sent
  adaptive thinking unconditionally, was correct only for as long as the default
  happened to be Opus 5. `ModelCapabilities` derives the shape from the model id.
  Unknown models get the conservative form: omitting both is valid everywhere, while
  sending them where they are not understood fails every request, so a guess errs
  towards off.

- **`ax_capture` is 2.2x faster** — 58ms to 26ms on a 264-node window. Every
  `AXUIElementCopyAttributeValue` is IPC to the target app, and the walk made nine
  per node; they are now a single batched
  `AXUIElementCopyMultipleAttributeValues`. This is the tool the ladder leans on
  hardest, and its cost is what decides whether the model uses it or escalates to a
  screenshot.

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

- Regression tests for the approval flow: a subprocess running between two prompts
  must not consume the second answer, destructive actions prompt even after
  "always allow", and only an explicit yes counts as consent.

- **Subprocesses no longer inherit the terminal's stdin.** A command as ordinary as
  `cat` or `sort` with no file blocked until the user pressed Ctrl-D — and worse, a
  child reading stdin competed with the approval prompt for their keystrokes,
  swallowing the y/n meant for the permission gate. `shortcuts run` hung the same way.

- **`run_shortcut` was discarding the output it promised to return.** `shortcuts run`
  writes results to `--output-path` and prints nothing useful to stdout; the tool
  never passed one. It now collects the output, and passes input as the file path the
  CLI actually expects rather than through stdin.

- **`ax_capture` now names each element's actions**, so `#e12 [AXShowMenu,AXRaise]`
  tells the model what that control actually supports. It could previously only guess
  `AXPress`, and an element offering something else failed for a reason nothing on
  the line explained.

- **`ax_press`'s action argument is no longer a closed enum.** Under strict tool use
  that made anything outside the list impossible to invoke — and a live window
  advertises `AXRaise`, which was not on it. The capture is a better source of valid
  values than any fixed list.

- **Corrected the AppleScript recipes in the tool description.** They were unguarded,
  so `tell application "Mail" to …` would *launch* Mail — a slow side effect the user
  did not ask for. The description now teaches the `is running` guard and lists only
  patterns verified to parse.

- **A first script against an app blocks on the macOS consent dialog**, indefinitely,
  until the user answers. A timeout now says so and names the app to look for,
  because the model would otherwise conclude its script was wrong and rewrite
  something correct. A denied app returns "Not authorized to send Apple events"
  immediately, which is a different and permanent condition — also documented.

- **Shell output is capped at 16KB, down from 100KB, and keeps both ends.** A single
  `ps aux` or `find /usr/share` returned ~25,000 tokens, and a handful of those would
  exhaust the context mid-task. Truncation was also head-only, losing the part of
  command output that usually matters — the errors, the summary, the last line.

- **A sandbox denial now explains itself.** `sandbox-exec` drops setgid privileges, so
  `/bin/ps` fails with a bare "operation not permitted"; unexplained, the model reads
  that as transient and retries. The failure now says the cause is structural and
  names `pgrep`/`launchctl` as alternatives that work. Tested across the whole
  read-only allowlist: `ps` is the only casualty.

- **The app and `doctor` now ask macOS for the permissions they need**, rather than
  reporting them missing and leaving the user to find System Settings. The API to
  raise the system's own one-click prompt was already there and unused — found by
  sweeping for unreferenced symbols. The follow-up notice about Screen Recording
  needing a relaunch is included, since otherwise screenshots keep failing after an
  apparently successful grant.

- Removed four genuinely dead symbols left behind by the accessibility batching work
  (`stringAttribute`, `boolAttribute`, `Capture.isComplete`, `lastScreenshot`).

- End-to-end tests driving the real tool registry through the real agent loop,
  permission gate and transcript, with only the HTTP call scripted. The units were
  each covered — the loop against stub tools, the tools against the real OS — but
  nothing exercised the wiring between them.

- **Corrected the ladder's cost figures to measured values.** The system prompt
  claimed tier 2 cost "a few hundred tokens" (a capture of a busy window is ~1,100)
  and a screenshot "~1,500 vision tokens" (a 1920px image is ~2,000). The real gap
  between the two tiers is about 2x, not 5x — so the guidance now leads with
  reliability, which is the stronger and truthful argument: an element id hits what
  you meant, a predicted coordinate may quietly miss.

- Removed three unused helpers from `JSONValue` (`strings(_:)`, `compactDescription`,
  `stringArray(describing:)`). Untested dead code invites use and drifts.

- **Action verification polls instead of sleeping a fixed interval** — a responsive
  UI is now confirmed in ~30ms rather than 180ms, so a batch of ten clicks no longer
  spends over a second waiting. A fingerprint costs 0.08ms, so polling is effectively
  free next to the wait it replaces. The budget before declaring an action a no-op
  rose to 300ms deliberately: a premature "nothing changed" tells the model to
  abandon a strategy that actually worked, which is worse than being slow on the
  rarer path where the action genuinely missed.

- **Transcript writes are 3.8x faster** — 18.8ms to 4.9ms for 500 entries. The file
  handle is held open for the session instead of being reopened, sought and closed
  for each of the several entries every turn produces.

- The cached system prefix and tool block are built once per run rather than per
  turn. Both carry a prompt-cache breakpoint and must be byte-identical across turns;
  building them once makes that a property of the structure rather than a convention.

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

- **Input larger than the pipe buffer deadlocked permanently.** Writing to a
  subprocess's stdin before launching it meant `write` blocked waiting for a reader
  that could never start — and the timeout could not intervene, since it is only
  reached after `run()` returns. AppleScript passes whole scripts this way, so a long
  script hung the agent with no recovery. Input is now written after launch and off
  the calling thread; 5MB completes in 4ms.

- **An `ax_press` approval never said what it would do.** Opening the action argument
  left the risk classifier reading only the element id, so every press produced the
  identical "activate element e12" — and because that is a `.write`, one "always
  allow" covered every later press whatever its action. Approvals now name the action
  and the element ("AXShowMenu on Button \"Delete\" (#e12)"), and an app-defined verb
  is destructive, since its effect cannot be judged from its name.

- **The scroll walk is off the polling path.** It costs ~14ms against the cheap
  fingerprint's 0.25ms, and polling ran it every 20ms — spending the entire settle
  budget on IPC instead of watching for the change. Taken twice per action now:
  once as the baseline, once if nothing else moved.

- **The menu bar's "Reveal Session Logs" uses the library's path, not a copy.** It
  rebuilt `.openclicky/sessions` by hand, so a change to where sessions live would
  have opened the wrong folder — silently, since Finder just shows nothing and the
  user concludes no sessions were recorded.

- **The Keychain service name has one definition.** `auth` printed it as a literal, so
  a change would have sent someone looking in the wrong place in Keychain Access.

- **`openclicky --version` prints the build, architecture and OS.** The version
  existed only inside `Scripts/bundle.sh`, written straight into the app's Info.plist,
  so the CLI could not report which build it was and nothing could disagree with the
  app because nothing else knew. One definition now, which the script reads — and
  refuses to build if it cannot.

- **The sweep counts a crash as detection.** A mutation that terminates the suite
  produces no `✘ Test` lines, so counting them alone read a hard crash as NOT CAUGHT —
  under-reporting coverage on exactly the invariants whose violation is most severe.

- **`verify-gates.sh` checks every gate is green before breaking anything.** It
  reports that a check "went red", which is only evidence if it was green first — a
  preflight already failing for an unrelated reason would have made every case look
  like a success. That is the exact hole it exists to find, one layer up.

- **The mutation sweep checks the suite passes before breaking anything.** It counts
  failing tests, so a suite that was already failing would have made every mutation
  report one extra failure and the sweep declare all invariants defended — a check
  measuring itself. It refuses to start now, and names the failures.

- **The system prompt states the confinement the run actually has.** Its Judgement
  section said "Shell commands run confined" as fixed text — the sentence that tells
  the model how much a mistake costs — while `--no-sandbox` makes it false. The
  identical claim in `shell`'s own description was made conditional earlier; this one
  was left standing, because the fix went where the bug was found rather than
  everywhere the belief was written down.

- **The README is checked against the code.** The help text has been since it was
  written; the README never was, and it was four commands and several behaviours out
  of date. Tests now assert every default it documents is real, every command it names
  parses, and every flag it lists is accepted.

- **A cancelled cursor animation no longer claims to have arrived.** It recorded the
  destination regardless, so the next arc began from a point the cursor never reached
  and the following action appeared to leap in from nowhere — during an interruption,
  which is when the user is watching most closely.

- **The stage's record of travels is bounded.** Nothing in production reads it, so it
  grew for as long as the process ran.

- **Screenshots are sent at 1568px, not 1920.** That is the largest long edge the API
  preserves — anything longer is scaled down server-side, so the extra pixels are paid
  for in upload bandwidth and transcript size and then discarded. Measured on a
  3024×1964 display: 297KB of base64 for ~2,129 vision tokens at 1920 against 241KB
  for ~2,130 at 1568. Same cost to the model, 19% fewer bytes, resent with every
  subsequent turn. `zoom` drops from 2400 to the same cap for the same reason — its
  density comes from cropping, not from sending more pixels of the crop.

- **The overlay grows to fit an approval prompt.** The panel was fixed at 160pt while
  an approval is around 224pt — a header, a scroll area of up to 120pt, a button row
  and padding — so Approve and Deny sat below its bottom edge. An approval whose
  buttons are off screen is not an approval. **Unverified visually**: it needs
  Accessibility and Screen Recording granted to the app to see.

- **`doctor` exits 1 when the machine is not ready**, so `openclicky doctor &&
  openclicky "…"` guards a run. It reported missing permissions and absent credentials
  and then exited 0, which tells a script everything is fine. An unreachable API is
  not counted against it — a laptop on a train is not a broken machine.

- **The environment probe's comment now matches what it does.** It claimed to ride
  along on every turn; it is captured once, before the loop. Left that way
  deliberately — every capture names the app it read and `UIFingerprint` reports a
  change of frontmost app, so repeating it each turn would restate what those already
  say. That reasoning depends on the capture header, which is now asserted and swept.

- **A stopped run is recognised by a shared constant, not by matching prose.** The
  overlay chose between "stopped" and "finished" with `reason.contains("interrupted")`
  — a control-flow decision resting on wording owned by another module. Rephrasing
  that message would have silently turned every stopped run into a completed one.

- **Promised pasteboard types are matched case-insensitively.** Apple spells them both
  ways, so a lowercase match caught `public.file-promise` while needing an exact
  string for `com.apple.NSFilePromiseItemMetaData` — any capital-P type nobody had
  listed would have been resolved, blocking the typing path on its owner app.

- **A retry says so instead of going quiet.** A rate limit carrying `Retry-After: 60`
  with three retries is three minutes during which the CLI printed "· thinking…" and
  the overlay said "Thinking…" — indistinguishable from a hang, and the reasonable
  response to a hang is to kill the run. Both surfaces now name the failure, the wait,
  and which attempt it is.

- **The CLI and the menu bar app now build their tool list from one definition.** Each
  had its own: they agreed, but nothing made them, so a tool added to one and
  forgotten in the other would simply be absent from that surface with no error
  anywhere. `ToolRegistry.standard(maxTier:sandbox:excludedBundleIDs:)` takes exactly
  what differs between the two callers.

- **`read-only` and `bypass` explain what they mean for the run.** The mode was named
  and its consequences left to be inferred: a read-only run still holds `write_file`,
  `click`, `type` and six more that can never succeed, and the only way to learn that
  was to spend turns being refused. `bypass` now says plainly that no prompt will stop
  anything. `ask` and `auto` stay terse — a warning on every run is one nobody reads.

- **`--no-sandbox` no longer tells the model its commands are confined.** The
  confinement sentence in `shell`'s description was fixed text, so an unsandboxed run
  claimed `sandbox-exec` was in force. That steers the model away from `ps` for a
  reason that no longer holds, and gives it a wrong picture of its own containment
  while deciding what is safe to run.

- **The system prompt no longer describes tools the run does not have.** `--max-tier`
  is a hard ceiling — a capped tool is absent from the registry — but the advice after
  the ladder was a fixed block, so `--max-tier 0` told a model with three tools it had
  "four tiers", that clicking Save is `ax_capture` then `ax_press`, and to weigh
  whether a screenshot was warranted. It is now built from the tiers present, which
  also takes the tier-0 prompt from 851 tokens to 532, and a capped run is told the
  ceiling exists so a blocked task is a limit to report rather than a puzzle.

- **A replayed run ends with what it cost.** The per-turn usage notes rendered raw,
  with a running cost on every line and no total anywhere, so the question a person
  opens an old transcript to answer had to be answered by finding the last one and
  reading a float off it. Now: `── 2 turns · 42.0s · $0.0612`, and the same cold-cache
  warning the live run gives — two of this project's costliest defects looked like
  that and nothing else.

- **The warning gate now covers the test target.** The release build it rode on never
  compiles tests, so two warnings sat there ungated — the third time a preflight check
  has been measuring less than its name claimed.

- **`doctor` checks the credentials against the API rather than only finding them.** A
  diagnostic exists to answer "why is this not working", and "a key is present" is not
  an answer to that — a key that is present and rejected looked identical to one that
  works.

- **Preflight verifies every mutation still matches its source.** An entry whose
  target has moved tests nothing, and three rotted that way on code changed the same
  day — each found only by a full sweep, which takes half an hour. `mutation-sweep.sh
  --check` matches the strings and runs no tests, so the rot is caught at the commit
  that causes it.

- **The path walk is bounded, and fails closed at the bound.** It costs a filesystem
  resolution per token and the token count comes from input the model writes. Past 512
  distinct paths a command is refused rather than cleared from a prefix — being unable
  to check a command is not evidence that it is safe. Denied paths are expanded once
  rather than once per token, cutting the walk's cost by about a quarter; a typical
  command classifies and validates in 0.4ms.

- **Credential paths are compared as paths, not matched as text.** The check
  substring-matched the command, so it recognised one spelling and missed the rest:
  `~user/.ssh/id_rsa`, `~/Documents/../.ssh/id_rsa`, `~/./.ssh/id_rsa`,
  `~//.ssh//id_rsa`, `cd ~ && cat .ssh/id_rsa` and `cd ~/.ssh && cat id_rsa` all
  reached the same file. Path-like tokens are now canonicalised and compared through
  `path(_:isAtOrBeneath:)` — the comparison this file already names as the only
  correct one — including tokens made relative by an earlier `cd`.

- **AppleScript bundle-identifier addressing is covered**, and Keychain Access and the
  Passwords app are treated as security surfaces.

- **Scripts that drive a permission dialog are destructive.** The frontmost check
  cannot see `tell application "System Events" to tell process "System Settings"`:
  that drives the window without activating it, and the risk is classified before the
  script runs. Matched on the script text instead, as the deny-list is.

- **Transcript values render as a person would write them.** Falling back to string
  interpolation printed the enum: a turn's usage read `input_tokens=number(4200.0)
  session_cost_usd=number(0.027549999999999998)` — the case name, a float for a count,
  and fifteen digits of binary rounding on a figure in dollars.

- **Transcript timing has sub-second resolution.** A whole run can finish inside one
  second, and at one decimal every entry in it read `0.0s` — exactly the run whose
  timing someone is trying to understand.

- **`mutation-sweep.sh --only "<label>"` runs a single entry.** A new entry checked by
  typing `mutate.sh` at the shell verifies different text than the script will run —
  an apostrophe quoted one way by hand and another way in the file left an entry
  matching nothing, which only a full sweep revealed. This runs the line itself.

- **The prompt cache breakpoint is now defended.** `SystemPrompt.stable` carries it,
  so anything session-specific inside re-bills the whole prefix every turn — an
  invariant CLAUDE.md names, with nothing testing it: a `Date()` spliced into its
  first line went entirely unnoticed. Three tests now cover it, and the walk of
  CLAUDE.md's other named invariants found `Subprocess` environment scrubbing and the
  `ContentBlock.passthrough` encoder ordering already defended but unswept; both have
  entries now.

- **`app_script`'s deny-list check is now in the mutation sweep.** The one route to
  execution that cannot be sandboxed had no entry; it is defended by 5 tests.

- **The clipboard borrow is now a testable seam.** The guard protecting a newer
  clipboard lived in `paste`, which drives the real machine and no test can reach —
  so the mutation sweep found it defended by nothing while three tests exercised the
  helpers around it. Extracted as `borrowing(_:placing:_:)`, covered by tests that
  drive the wiring rather than the parts.

- **The clipboard is only restored if it is still the one the agent put there.** A
  paste holds it for about 160ms; copying something in that window had your new
  clipboard silently replaced by a snapshot of the old one.

- **The clipboard snapshot is bounded.** It skipped no types and had no size ceiling,
  so a promised type could block the typing path on a busy or departed owner app, and
  a video on the clipboard was held twice in memory through a keystroke.

- **`doctor` reports what the session records occupy.** A run that takes screenshots
  writes them into the record in full — 2.8 MB for twelve turns, measured — and
  nothing prunes the directory. That trade is deliberate, but it was invisible; the
  only way to find a tool growing on your disk was to go looking.

- **`doctor` no longer appears to leak internals.** It ended by printing the raw
  `<environment>` block with no explanation, which reads as scaffolding escaping into
  a diagnostic rather than as the answer to "what does the agent know before I speak".

- **The mutation sweep now fails when a mutation stops matching the code.** Three
  entries had rotted against the injectability refactor — still naming
  `ScreenContext.shared` where the code takes an injected seam — and reported "target
  not found", which is neither caught nor NOT CAUGHT. They had been testing nothing
  through a dozen green sweeps. The sweep's own exit code is now the verdict, and a
  missing target fails it.

- **The model is warned before the turn limit cuts it off.** The run stopped dead at
  `--max-turns`, severing the model mid-plan and handing the user "Stopped after 40
  turns without finishing" — a run with no account of what had been done. It is now
  told when one turn remains, so it can spend it summarising what it did, what it
  verified, and what is left.

- **`ax_capture` filtering now runs to a fixpoint** — dropping a container's only
  children turned the container into an empty leaf, leaving a chain of them behind in
  deeply nested windows.

- **Accessibility failures now say what to do about them.** Every `AXError` rendered
  as a bare number — `failed (AXError -25206)` — so the agent could not tell "this
  element will never accept that action" from "the element is gone, re-capture" from
  "the app is busy, wait". All three read identically, and the only available response
  was to repeat the call. Each code now names its own recovery.

- **`click` and `key` document what they already accept** — triple-click, and a repeat
  ceiling of 50. Both worked; neither was in the manual the model reads.

- **The build is warning-free, and preflight now keeps it that way.** One of the two
  cleared was a real Sendable violation: a non-Sendable `ISO8601DateFormatter`
  captured in the transcript encoder's `@Sendable` closure, replaced with a value-type
  format style.

- **`ax_capture` drops leaves that say nothing** — no label, no value, nothing to
  press — while keeping anything with children, since the nesting is the structure.

- **A dialog's message is no longer truncated at 60 characters.** Values were cut like
  a text field's contents, so "what does this dialog say?" returned an ellipsis.
  Text-bearing roles get room; field values still only need to be recognisable.

- The CLI's event rendering moved into the library as `RunReport`, so a whole run's
  output can be produced and read without an API key — which is how both of the above
  were found.

- **Transcript entries carry a monotonic sequence number.** Every entry in a run had
  the identical timestamp — ISO8601 resolves to milliseconds and several entries a
  turn are written inside one — so the record could not order its own contents.
  Timestamps also gained fractional seconds, which remain useful for duration but
  cannot be relied on for order.

- The help text's claims are checked: every documented flag and value parses, every
  example resolves to a task, and every printed default is the real one. Two examples
  are verified to do what they say rather than merely parse. The help also now
  mentions Ctrl-C — which matters for a tool that moves the pointer — and the app,
  which a reader of `--help` had no way to discover.

- **Fixed 19 mangled bullets in the system prompt.** Swift keeps whatever indentation
  a continued line carries beyond the closing delimiter, so the prompt reached the
  model as "and `ax_press`   report what changed" throughout. Found by printing the
  prompt and reading it — it compiled and every test passed.

- **Fixed two user-facing messages mangled by scripted edits.** A collapsed line
  continuation left the indentation inside the string, so a permission alert read
  "Screen Recording lets it        take screenshots". It compiled, it tested, and only
  someone reading the output would have noticed — so `preflight.sh` now checks for it.

- Documented which `Info.plist` usage descriptions macOS actually renders. Only
  `NSAppleEventsUsageDescription` is known to be shown; the others appear inert, so
  neither the app nor the CLI relies on them — both explain what they need before
  requesting it.

- **Corrected a security claim that was never true.** The Keychain code asks for
  `ThisDeviceOnly`, which would keep the API key out of encrypted backups and
  Migration Assistant transfers — but that attribute only applies in the
  data-protection keychain, which needs an entitlement a command-line binary cannot
  have. The login keychain accepts it on write and silently drops it. Opting in
  properly fails with "a required entitlement isn't present", and adding it to the
  signed app alone would put the app and the CLI in different keychains, so
  `openclicky auth` would store a key the app could not find. The limitation is now
  documented in the README and asserted by a test, rather than claimed.

- Transcript file permissions are tested. They were fixed to `0600` once and never
  covered, so a mutation making them world-readable walked straight past the suite.

- **Command-line parsing moved into the library as `Invocation`.** `--mode` and
  `--max-tier` decide whether the agent asks before acting and whether it can see the
  screen, and both sat in `main` where no test could reach them. Now covered: every
  mode selectable, a tier cap genuinely removing the tools above it, unrecognised
  values refused rather than silently defaulted, and a flag with a missing value not
  swallowing the next one.

- **The cursor stage is injectable**, the fourth and last piece of shared state
  removed from the tools.

- **Screen context is injectable**, so tests no longer share one. `CoordinateTests`
  and `VerificationTests` both wrote the shared instance while Swift Testing runs
  suites in parallel — a race by construction, and the third seam (after pointer
  actions and screen capture) that turned shared global state into an argument.

- **`scroll` and `ax_set_value` never verified their effect at all** — found by
  writing the verification test at the level of the set rather than one tool at a
  time. A scroll that moves nothing, because the view is already at its end, looked
  identical to one that worked.

- Screen capture is injectable, so the arguments a tool passes can be checked without
  Screen Recording. That closed three more undefended invariants: exclusions being
  forwarded (or the agent photographs its own overlay), the region and display being
  forwarded, and `zoom` asking for higher fidelity than the overview it refines.

- Cost metering and the retry bound are covered. The retry test carries a time limit:
  with the bound removed the client retries forever, so the test hung rather than
  failed — and a hanging test in CI is a timeout with no indication of what broke.

- Four more invariants found undefended by the sweep and now covered: a screenshot
  recording itself for later conversion (without which the whole pixel tier fails one
  call later), the phantom cursor animating before a click, typing reporting what
  changed, and long text going via the clipboard rather than per-character events.

- Nothing verified that a click was verified, either: `click` could drop
  `Verified.act` and no test objected.

- **A test that the loop actually prunes**, not just that the transcript can. Every
  pruning test exercised `Transcript.conversation(policy:)` directly, so a mutation
  making the loop send the whole conversation passed the entire suite — the same
  predicate-tested-but-not-its-application gap found earlier in secure-field
  redaction. Now in the mutation sweep.

- Measured the property the pruning exists for: across 40 turns of screenshots and
  accessibility dumps the unpruned conversation reaches 1,949KB while what is sent
  plateaus at 138KB, and that bound is now asserted rather than assumed.

- Tests for credential resolution order and the Keychain round trip. Picking the
  wrong credential source is silent — the request goes out signed by something the
  user did not intend, and the only symptom is an authentication error they cannot
  explain. An exported-but-empty variable now provably falls through rather than
  being used.

- **Secure-field redaction moved into one function** used by both the fingerprint and
  the full capture. Each applied the check itself, so removing it from either was
  invisible.

- **Secret detection broadened.** Requiring a recognised qualifier beside `KEY` missed
  every vendor nobody had listed — `MAILGUN_KEY`, `POSTHOG_KEY`, `SENTRY_DSN`,
  `NGROK_AUTHTOKEN`. A bare `KEY` or `DSN` component is now enough; no benign variable
  has one (`KEYBOARD_LAYOUT` and `KEYMAP` do not).

- Tests that could not run for want of a permission reported a pass they had not
  earned. They now skip visibly via `.enabled(if:)`, an empty capture is a required
  precondition rather than a silent return, and a test whose assertions only ran in
  the failure branch now asserts unconditionally.

- **`Tool.risk(for:)` no longer has a default implementation.** It defaulted to
  `.read` — the most dangerous default available here, since a read skips the
  permission gate in every mode including `read-only`. A tool added later that simply
  forgot to classify itself would have been silently exempt from every control, and
  the omission would look like nothing in review. Every existing tool already answers
  it, so the compiler now asks each new one.

- **Approval summaries are sanitised structurally, in `Risk.summary`**, rather than by
  each tool remembering to. The per-tool version of this fix was applied to the shell
  and forgotten for accessibility and AppleScript, and every tool added later would
  have been one more chance to forget. There is now no path to the approval prompt
  that skips it, and a property test drives every tool in the registry with hostile
  input — so tools that do not exist yet are covered too.

- **The whole package now builds in Swift 6 language mode**, so data races are
  compile errors rather than latent behaviour. Two real hazards surfaced: an imported
  C global read across isolation domains, and a lock held across a suspension point
  in the test client.

- **A finished run could hide the overlay of the run that replaced it.** The
  auto-dismiss timer only checked whether the overlay was still accepting input, so
  summoning and submitting a new task inside its four-second window left the agent
  working invisibly. Runs now carry a generation token and stale callbacks stand down.

- **The phantom cursor rendered at the wrong position on a multi-display setup.**
  Quartz and AppKit are both anchored to the primary display, so the coordinate flip
  must always use that display's height — deriving it from whichever screen the point
  is over is wrong the moment a second display differs in height or offset. Invisible
  on a single-display Mac, which is why it needed writing down.

- Cancelling mid-click animated out the remaining path instead of stopping: the sleep
  swallowed cancellation. The animation exists so the user can interrupt, so this
  defeated its own purpose.

- The per-step animation delay divided only the sub-second part of the duration,
  which would have silently broken had the duration cap ever risen above a second.

- `bundle.sh` had a "verification" step whose `codesign` call discarded its own output
  and ran before signing — it verified nothing. Replaced with a real
  `codesign --verify` after signing.

- Escape on an approval prompt could have both denied the tool and aborted the run.
  One handler now owns the key and routes it by state.

- **Every click on a secondary display landed on the primary one.**
  `SCStreamConfiguration.sourceRect` is relative to its own display's origin, but the
  captured rect was reported as though it were global — and CGEvent works in the
  global space, where a second monitor may start at x=3440. Captures now convert
  between the two spaces explicitly, and a region is routed to the display it
  actually falls on rather than always the main one.

- `zoom` took its region in screen points while every other tool speaks the last
  screenshot's pixel space, putting the conversion on the model's side of the
  boundary — which is where coordinate errors come from. It now takes `x`, `y`,
  `width`, `height` in image pixels, exactly like `click`.

- The API client's `Retry-After` handling was documented but not implemented, so a
  429 backed off on the computed schedule and could retry before capacity returned.
  A server-sent `Retry-After` now wins, capped at 60s.

- A reply cut off at the `max_tokens` limit was treated as a finished answer, so a
  half-written response reached the user with nothing marking it incomplete. It is
  now reported as truncated; if tool calls survived the cut, they still run and the
  clipped reasoning is flagged to the model.

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

- **Conservative command classification.** A shell command is read-only only if every
  segment provably reads. Previously a heuristic looked for evidence of mutation and
  defaulted to read — and because a read classification skips the permission gate in
  every mode, each gap in that heuristic was a full bypass.

- Sandbox profile extended to deny writes to `~/Library/LaunchAgents` and `~/.ssh`,
  and reads of the credential directories.

- Shortcut execution is destructive, so it cannot be covered by a session allowlist.

- Keychain items scoped `ThisDeviceOnly`, keeping the key out of backups and migration.

- API keys are read from the environment or the macOS Keychain and never written
  to disk, a transcript, or a log.

- The system prompt instructs the model to treat all read content as untrusted
  data rather than instructions.

### Fixed

- **Fixed: `--effort` was accepted and then silently discarded.** On a model that
  predates the field it is stripped before the request is sent, so the run proceeded,
  cost the same, and looked identical to one where the flag had applied. It now says
  so before the run, and only when the flag was actually typed — the default is
  dropped on those models too, but nobody asked for it, and a warning on every run is
  noise that teaches people to skip warnings.

- **Fixed: a test asserted the screen holds still.** The no-op verification test read
  the real frontmost window for its before and after fingerprints and required them to
  match, so a menu-bar clock ticking between the two samples failed it — about two runs
  in six. The subject is the wording of the advice, which has nothing to do with the
  live UI, so it now uses the injected capture the neighbouring tests already used.

- **Fixed: the commonest first error sent users to a dead end.** The missing-credentials
  message told them to run `openclicky auth --set`, which exits with
  "Unknown option '--set'". It now names the real command and offers the environment
  variable as an alternative, with a link to where keys come from.

- **Fixed: verification watched only one scrollable pane.** The fingerprint read the
  first `AXScrollArea` a bounded walk found, which in Mail, Xcode, Finder or any split
  view is plausibly the sidebar — so scrolling the content pane reported "no
  observable change" and told the model its action had missed, reintroducing the
  false negative the field exists to remove, in the apps most likely to be driven.
  Every pane is read now, and compared only when both samples found the same number.

- **Fixed: a turn-limit notice was written where nothing could read it.** On the final
  iteration the loop appends and exits, so the "will stop now" message reached no
  request. Removed; the warning that matters arrives one turn earlier.

- **Fixed: three unchecked force-casts on values from other apps.** Accessibility
  attributes come from whatever the user has open, and an app is free to return a
  string where the API documents an element — a force-cast on that would take the
  agent down mid-run, with a crash naming an app the user was merely looking at. Four
  such casts were guarded and three were not.

- **Fixed: a listing reported 0, 1 or 2 turns for the same file.** Transcript entries
  were written with unsorted keys, and Swift seeds dictionary ordering per process, so
  `kind` landed at a different offset on every line — sometimes outside the short
  prefix the listing scans to find usage entries without decoding the images beside
  them. Keys are sorted now, and the scan is wide enough that a future encoder change
  cannot reintroduce it. Found by an end-to-end test that replays a real run.

- **Fixed: a hotkey could register with nothing listening.** `InstallEventHandler`'s
  status was discarded, so if it failed while `RegisterEventHotKey` succeeded, `init`
  returned cleanly, the app reported the hotkey installed, and pressing it did
  nothing — indistinguishable from a hotkey another app had taken, which is the one
  case the code did report.

- **Fixed: the sandbox explanation had never once appeared.** It matched
  `"operation not permitted"` in lowercase against output that says "Operation not
  permitted" — one capital, the mistake this project already recorded about path
  comparison — and writes are refused as "Permission denied", which it never matched
  at all. The model saw a bare denial with no reason to suspect the sandbox, and the
  obvious next move from there is `sudo`.

- **Fixed: the deny-list tests executed `rm -rf /` for real whenever the sweep broke
  the deny-list.** The AppleScript bypass tests feed the tool the exact payloads the
  deny-list names, which are safe only while the deny-list works — and breaking it is
  precisely what the mutation sweep does. A sweep therefore ran `rm -rf /` against the
  machine (refused by `rm` itself) and read the user's real SSH private key into the
  test log. `app_script` now takes an injectable `ScriptRunning`, so the tests assert
  execution is never *reached*.

- **Fixed: the sweep called caught mutations "structural".** It decided compilation by
  grepping the test output for `error:`, and osascript's own failure text contains
  "execution error:" — so a mutation caught by three tests was reported as one that
  could not be broken. Compilation is now decided by the build's exit code.

- **Fixed: the test suite wrote a session file into the user's home on every run.** A
  test constructed a default `Transcript` to check that the reader and writer agree on
  where sessions live — which created a real record each time it ran. Preflight now
  fails if the suite changes the contents of `~/.openclicky/sessions`.

- **Fixed: a missing mutation target could overwrite source with a stale backup.**
  `mutate.sh` restored from a hardcoded `/tmp/mut.bak` left behind by older runs,
  rather than the per-run backup its own trap already handles.

- **Fixed: only the user was told when a turn was truncated.** A reply cut off at the
  token limit can still carry tool calls, and the loop flagged that through the
  observer — which draws to the terminal and nothing else. The model carried on
  believing its plan had arrived intact, from a turn whose second half was discarded.
  The notice now travels back in the results message, after the tool_results as the
  API requires.

- **Fixed: verification was blind to scrolling.** The fingerprint taken either side of
  every action compares the frontmost app, window and focused element — none of which
  a scroll changes. So every scroll, including the ones that worked, reported "no
  observable change", which tells the model the action missed. The one action whose
  purpose is to move content was the one action verification could not see. It now
  reads the frontmost scroll area's offset and reports direction and position; a
  fingerprint costs 1.3ms, up from 0.3ms.

- **Fixed: typing long text destroyed a non-text clipboard.** `type` pastes anything
  longer than a line, borrowing the clipboard and handing it back — but the restore
  read the old contents with `string(forType:)`, which sees only text. A copied image,
  file or styled snippet read back as nil, the restore was skipped, and the user was
  left holding the agent's text. Every type is now carried across, and an empty
  clipboard is restored as empty.

- **Fixed: the cached prompt prefix never hit across runs.** Tool schemas are held in
  Swift dictionaries and Swift seeds its hashing per process, so the same tool block
  serialised to different bytes in every invocation. Tools sit first in the cached
  prefix, so this invalidated the tool definitions *and* the system prompt with them —
  ~4,500 tokens re-read at full price on every run. Requests now go through one
  encoder with `.sortedKeys`, making the bytes a function of the content alone.

- **Fixed: token counts were rendered in the machine's locale**, so 4,200 printed as
  "4.200" — which reads as four-point-two. Grouped without a locale now.

- **Fixed: a tool result containing a newline broke the run display**, leaving its
  second line unindented and unmarked among the agent's own words.

- **Fixed: the app could not run a task at all.** The overlay's text field held the
  draft; `AppDelegate` discarded it on submit and read the controller's own copy,
  which nothing ever populated — so `submit` always returned nil and typing a task
  and pressing Return did nothing. `submit` now takes the text as an argument, and the
  method that was supposed to carry it is gone: its existence was the bug, offering a
  path that looked intended and that nothing took.

- **Fixed: "always allow" did nothing.** The prompt offered it, the gate implemented
  it, tests covered it and the README described it — but no caller ever told the gate,
  so answering it approved one action and asked again next time. The prompt returned a
  `Bool`, which made "allow, and stop asking" inexpressible; it returns an `Approval`
  now and the gate applies it. Destructive actions no longer offer the choice at all,
  since the gate ignores it there by design.

- **Fixed: every session prompt named the permission mode twice** — "Permission mode:
  ask — ask — you approve each action". The explanation began with the mode's own
  name and the caller prefixed it too. Found by rendering a complete API request and
  reading it.

- **Fixed: the prompt told the model there was no sandbox.** Shell commands do run
  under `sandbox-exec`; it now says so, and confines the "no undo" claim to what is
  actually true.

- **Fixed: a hotkey failure blamed the wrong half.** `cmd+` was reported as having no
  modifier — it has one, and needs a key. The guard meant to catch the genuine
  no-modifier case turned out to be unreachable, since an earlier check rejected every
  single-part combination first: it read as a guard while guarding nothing. Found by
  mutating it and watching nothing fail.

- **Fixed: an interrupted mutation sweep left the working tree broken.**
  `Scripts/mutate.sh` restored the file only on the success path, so a timeout left a
  deliberately-removed guarantee sitting in a tree that looked clean. It now restores
  on any exit, and that is proven by interrupting it.

- **Fixed: nothing verified that a click applied the coordinate conversion.** A tool
  treating image pixels as screen points — the exact failure the whole coordinate path
  exists to prevent — passed the entire suite, because every coordinate test drove the
  mapping directly and none went through a tool. Pointer actions are now injectable,
  so a test can see the screen point a tool aimed at without a mouse moving, and the
  conversion is asserted for `click`, `drag` and `scroll` including on a secondary
  display.

- **Fixed: a screenshot reported a size one pixel off what it produced.** The encoder
  computed the output dimensions independently of Core Image and disagreed with its
  rounding — a 6880×2880 display downscaled to a 1920 long edge reported 803 pixels
  tall and produced 804. Since that figure is what every click coordinate is scaled
  by, each one was off by a fraction of a pixel, worsening toward the bottom of the
  screen, and a coordinate at the image edge mapped past the edge of the display. The
  size of the rendered image is now reported rather than predicted.

- **Fixed: `scroll` delivered less than it was asked for.** A scroll is split into
  several events so momentum-aware views read it as a gesture, and dividing the total
  by the step count truncated the remainder — a request to scroll 11 pixels delivered
  6, and 100 delivered 96. The model would see less movement than it asked for and
  scroll again, or conclude the view had not responded. The remainder is now spread
  across steps so the total is exact and the motion stays even.

- **Fixed: `git log --output=<path>` wrote arbitrary attacker-controlled content.**
  A repo whose HEAD commit message is chosen by an attacker could overwrite `~/.zshrc`
  while the agent believed it was reading history. `--output`, `--ext-diff` and
  `--textconv` are now denied for git's reading subcommands.

- **Fixed: a symlink defeated the credential deny-list entirely.** The check compared
  path strings while `open()` follows links, so `notes.txt` pointing at `~/.ssh/id_rsa`
  passed and was read straight through — and a malicious repo or archive can create
  such a link on checkout. Paths are now resolved, parent chain included, before any
  prefix comparison, and `read_file` resolves before opening so the checked path and
  the opened path are the same.

- **Fixed: `jq` could read the environment** via `jq -n 'env'`, from inside the filter
  expression where no flag rule reaches. Removed from the read-only set, as
  `printenv` and `env` already were.

- **Fixed: a failed paste discarded the user's clipboard.** The restore ran only on
  the success path, so a throw from the key event left the agent's text in the
  pasteboard and whatever the user had copied — possibly a password — gone.

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

### Security

- **`app_script` no longer recommends `shell` for being confined when it is not.** The
  third place the same belief was written down, each fixed only where it was found:
  `shell`'s own description, the system prompt's Judgement section, and this. Under
  `--no-sandbox` it told the model to prefer a tool for a property that tool did not
  have.

- **`a` no longer approves a destructive action.** The destructive prompt offers only
  `[y]es / [n]o`, and `a` approved it anyway — so a user who had been typing `a` for
  routine writes could authorise an irreversible one out of habit, with an answer the
  prompt never listed. The offer and its reading now come from the same place.

- **A destructive action can no longer be approved by a stray Return.** The overlay
  bound Return to Approve for every action, including one it had just labelled "This
  is destructive" — while the CLI requires typing `y` and treats a bare Return as
  denial. The graphical surface was the more permissive of the two at exactly the
  moment that matters most. Destructive approvals take Command-Return now.

- **The agent can no longer overwrite its own program unprompted.** Writing to the
  binary currently running — or to any part of the `.app` bundle enclosing it —
  classified as an ordinary write, so in `auto` mode the agent could replace itself
  silently, swapping the program the user approved for one they did not. The same
  reasoning as refusing to answer its own consent dialogs: a constraint its subject
  can rewrite is not a constraint.

- **Writing a persistence path is destructive however it is written.** A sensitive
  path was only checked when it was a redirection target, so
  `echo … > ~/Library/LaunchAgents/x.plist` prompted while
  `cp /tmp/x.plist ~/Library/LaunchAgents/` — the same launch agent, no `>` anywhere
  in it — was an ordinary write that ran unprompted in `auto`. `cp`, `mv`, `ln`,
  `touch` and `install` all reach it now. Reads of those paths stay free: reading
  shell config is ordinary, writing it is persistence.

- **Fixed: `$HOME` walked past the credential deny-list.** `cat $HOME/.ssh/id_rsa` was
  not recognised as touching `~/.ssh`, and classified `.read` — which skips the
  permission gate in every mode. The sandbox refused it, so this was defence in depth
  working while the layer above silently did not; with `--no-sandbox`, a documented
  flag, the same command printed the private key. Both spellings are now substituted
  during normalisation, so the deny-list and the classifier see the same command.
  `$HOMEBREW_PREFIX` is untouched.

- **A field labelled as a secret is redacted whatever its role.** Redaction keyed only
  on the role, so `AXSecureTextField` was caught while a field an app draws with an
  ordinary role and the label "Password" was not — and a capture reads every node's
  value, so one such field put its contents into the model's context and into a
  session record kept in full and never pruned. Ordinary labels (Email, Search, Note,
  Subject, URL) are untouched.

- **Output that is itself a credential is withheld.** Classifying the action was half
  of it: approving `security find-generic-password -w` because the prompt said "reads
  the keychain" also sent the password to the model and wrote it into the session
  record, which is kept in full and never pruned. Allowing the action was never
  consent to transmit the secret. Applies on both routes (`shell` and `do shell
  script`) and on the failure path too, which returned combined output. Deliberately
  narrow — `grep -w security notes.txt` and `git log -w` are untouched.

- **Fixed: a trusted command name at an untrusted path skipped the gate entirely.**
  `cp /usr/bin/osascript /tmp/rg` then `/tmp/rg -e '<script>'` matched `rg`'s
  read-only rule — whose options include `-e` with an operand — and a `.read` skips
  the permission gate in every mode, `read-only` included. Unprompted arbitrary
  execution by renaming a file. A read-only classification now also requires the
  executable to resolve into a system location.

- **Fixed: `env`, `nice` and friends hid the command they ran.** Only a segment's
  first token was checked, so `env security find-generic-password -w -s login`
  classified as an ordinary write and ran unprompted in `auto`. Wrappers are stepped
  through by name, so `grep -rn security ~/notes` is still a read.

- **Fixed: capturing a consent dialog by bundle id defeated the frontmost check.**
  `ax_capture` reads a named app *instead of* the frontmost one and an accessibility
  action needs no activation, so the agent could read the dialog while Finder was
  frontmost and press "Allow" unescalated. The owning app of the captured elements is
  now checked alongside the frontmost one.

- **Commands that change privileges now always prompt.** `tccutil reset All` wipes
  every permission the user has granted anything on the machine; `security
  find-generic-password -w` prints a stored password on stdout, which is a tool result
  and so reaches the model and the transcript; `systemsetup` changes system
  configuration; and `osascript` reaches AppleScript — which no sandbox confines —
  without going through `app_script`. All four ran silently in `auto` mode.

- **The agent can no longer answer its own permission dialogs unprompted.** The
  containment model assumes the user decides what the agent may do — but the dialog
  that asks them is an ordinary window with an ordinary button. Capturing
  `com.apple.UserNotificationCenter` and pressing "Allow" classified as a routine
  write, which runs without prompting in `auto` mode: the agent granting itself
  Automation access, or toggling Accessibility in System Settings. Any non-read action
  while a macOS security surface is frontmost is now destructive, so it always asks.
  Applied centrally in the loop, because `ax_press`, `click`, `key` and `app_script`
  all reach that button.

- **Fixed: `man -P '<command>'` was unprompted arbitrary execution.** `man` sets
  MANPAGER from `-P` and evals it — documented behaviour — and `man` had no argument
  constraints at all.

- **Arguments are validated, not just executables.** A second audit found the first
  round had fixed the reported payloads without fixing the model: an allowlist of
  leading executables with no check on their arguments. `find . -exec sh -c '…'` was
  unprompted arbitrary code execution in read-only mode, and `awk 'BEGIN{system(…)}'`,
  `sed -i`, `plutil -replace`, `networksetup -setdnsservers` and `sysctl -w` the same.
  Every read-only command now declares how its arguments are constrained, and a
  command with no such declaration is never read-only. Commands whose argument space
  cannot be constrained confidently (`awk`, `sed`, `sqlite3`, `networksetup`,
  `sysctl`, `printenv`) were removed from the read-only set entirely.

- **Fixed: newline command chaining bypassed every permission mode.** `zsh -c` treats
  a newline as a separator, but the chaining guard checked only `;|&<>` backtick `$`.
  `ls\nrm -rf ~` presented `ls` as its leading token and ran unprompted, including in
  read-only mode. Newlines are now separators; CRLF is handled via `isNewline` because
  Swift treats `\r\n` as a single grapheme cluster.


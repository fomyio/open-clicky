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
- **Fixed: the commonest first error sent users to a dead end.** The missing-credentials
  message told them to run `openclicky auth --set`, which exits with
  "Unknown option '--set'". It now names the real command and offers the environment
  variable as an alternative, with a link to where keys come from.
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
- **`ax_capture` is 2.2x faster** — 58ms to 26ms on a 264-node window. Every
  `AXUIElementCopyAttributeValue` is IPC to the target app, and the walk made nine
  per node; they are now a single batched
  `AXUIElementCopyMultipleAttributeValues`. This is the tool the ladder leans on
  hardest, and its cost is what decides whether the model uses it or escalates to a
  screenshot.
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
- **Corrected a security claim that was never true.** The Keychain code asks for
  `ThisDeviceOnly`, which would keep the API key out of encrypted backups and
  Migration Assistant transfers — but that attribute only applies in the
  data-protection keychain, which needs an entitlement a command-line binary cannot
  have. The login keychain accepts it on write and silently drops it. Opting in
  properly fails with "a required entitlement isn't present", and adding it to the
  signed app alone would put the app and the CLI in different keychains, so
  `openclicky auth` would store a key the app could not find. The limitation is now
  documented in the README and asserted by a test, rather than claimed.
- **Fixed: a hotkey failure blamed the wrong half.** `cmd+` was reported as having no
  modifier — it has one, and needs a key. The guard meant to catch the genuine
  no-modifier case turned out to be unreachable, since an earlier check rejected every
  single-part combination first: it read as a guard while guarding nothing. Found by
  mutating it and watching nothing fail.
- Transcript file permissions are tested. They were fixed to `0600` once and never
  covered, so a mutation making them world-readable walked straight past the suite.
- **`Scripts/preflight.sh`** — everything that must hold before a commit, in one
  command, installable as a git pre-commit hook. Written after committing twice on top
  of a failed check: once with a failing test, once with `CLAUDE.md` over its budget.
  Both times the check had run, just beside the commit rather than as its gate. Each
  check is verified to catch its own failure.
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
- **Fixed: an interrupted mutation sweep left the working tree broken.**
  `Scripts/mutate.sh` restored the file only on the success path, so a timeout left a
  deliberately-removed guarantee sitting in a tree that looked clean. It now restores
  on any exit, and that is proven by interrupting it.
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
- **Fixed: nothing verified that a click applied the coordinate conversion.** A tool
  treating image pixels as screen points — the exact failure the whole coordinate path
  exists to prevent — passed the entire suite, because every coordinate test drove the
  mapping directly and none went through a tool. Pointer actions are now injectable,
  so a test can see the screen point a tool aimed at without a mouse moving, and the
  conversion is asserted for `click`, `drag` and `scroll` including on a secondary
  display.
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
- **`Scripts/mutation-sweep.sh`** breaks each safety-critical invariant in turn and
  reports how many tests notice. It found two that nothing defended: secure-field
  redaction (the tests exercised the predicate but never its application) and the
  vendor-key branch of the secret heuristic.
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

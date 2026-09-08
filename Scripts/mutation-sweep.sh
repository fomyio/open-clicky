#!/bin/bash
#
# Breaks each safety-critical invariant in turn and reports how many tests notice.
#
# A guarantee whose test cannot fail is not a guarantee. Three security audits found
# real bypasses in this code, and the tests written afterwards are the only thing
# standing between a future refactor and reintroducing them — so it is worth knowing
# they would actually object. Two invariants were found undefended this way: secure
# field redaction, and the vendor-key branch of the secret heuristic.
#
# Run after any change to Policy, PermissionGate, AgentLoop or the perception layer.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MUTATE="$(dirname "${BASH_SOURCE[0]}")/mutate.sh"
STATUS=0

# Called as "$M", which bash resolves to this function. Every result is totalled, so
# the sweep's own exit code is the verdict — a sweep that reports a problem and then
# exits 0 is a sweep nobody has to read.
# --only "<label>" runs a single entry. Adding an entry and checking it by typing
# mutate.sh at the shell verifies different text than the script will run: an
# apostrophe quoted one way by hand and another way in the file left an entry that
# matched nothing, and only a full sweep revealed it. This runs the line itself.
ONLY=""
CHECK=0
if [ "${1:-}" = "--only" ]; then ONLY="${2:-}"; fi
# --check verifies every mutation still matches its source and runs no tests. An
# entry whose target has moved tests nothing, and three of them have rotted that way
# on code I changed the same day — each discovered only by a full sweep, which takes
# half an hour. Matching a string takes milliseconds, so preflight can do it on every
# commit and the rot is caught where it is made.
if [ "${1:-}" = "--check" ]; then CHECK=1; fi
# --changed <ref> runs only the mutations whose target file differs from <ref>.
#
# A full sweep is 99 mutations, each a build and the whole suite, and it has outgrown
# the sitting most people will give it — twice in one session it was killed partway,
# and a gate that cannot finish is not a gate. The invariants a change can break are
# overwhelmingly the ones living in the files it touched, so scoping to those turns a
# half-hour wait into a minute or two and makes the sweep something you run *while*
# working rather than once at the end.
#
# It is not a replacement for the whole sweep, and deliberately says so in its own
# output: a change can break a detector in a file it never opened, and only the full
# run finds that. Fast enough to be habitual, honest about what it did not look at.
CHANGED_REF=""
if [ "${1:-}" = "--changed" ]; then CHANGED_REF="${2:-HEAD}"; fi

# --resume continues a full sweep that was interrupted.
#
# A whole sweep is 99 builds and has been killed partway more than once — by a
# timeout, a closed laptop, an impatient ctrl-c. Every one of those threw away up to
# an hour of correct work and left the only complete verdict unobtainable in
# practice, which is how a project ends up trusting `--check` and a memory of the
# last green run.
#
# Entries that already passed are recorded and skipped. The record is keyed to the
# exact tree it was produced from — `git rev-parse HEAD` plus a hash of every file
# any mutation targets — because a resumed sweep whose code moved underneath it would
# report a verdict half of which describes code that no longer exists. That is a
# false clean bill, the one thing this script must never produce, so a key mismatch
# discards the record and says so rather than silently blending two trees.
RESUME=0
if [ "${1:-}" = "--resume" ]; then RESUME=1; fi
PROGRESS_FILE=".sweep-progress"
SWEEP_KEY=""
sweep_key() {
    # Both halves matter: the commit identifies the tree, and the file hash catches
    # uncommitted edits, which is the normal state while working on the safety layer.
    local files
    files="$(grep -oE '^"\$M" \$K/[^ ]+' "$0" | sed 's|^"\$M" \$K/|Sources/OpenClickyKit/|' | sort -u)"
    printf '%s\n' "$(git rev-parse HEAD 2>/dev/null || echo nogit)" \
        "$(printf '%s\n' "$files" | xargs shasum 2>/dev/null | shasum | cut -d' ' -f1)"
}
DONE_LABELS=""
if [ "$RESUME" -eq 1 ]; then
    SWEEP_KEY="$(sweep_key)"
    if [ -f "$PROGRESS_FILE" ]; then
        if [ "$(head -2 "$PROGRESS_FILE")" = "$SWEEP_KEY" ]; then
            DONE_LABELS="$(tail -n +3 "$PROGRESS_FILE")"
            echo "Resuming: $(printf '%s\n' "$DONE_LABELS" | grep -c . ) entries already passed on this tree."
        else
            echo "The tree changed since that record was written — starting over."
            rm -f "$PROGRESS_FILE"
        fi
    fi
    if [ ! -f "$PROGRESS_FILE" ]; then printf '%s\n' "$SWEEP_KEY" > "$PROGRESS_FILE"; fi
fi

# An unrecognised flag is an error, not a full sweep.
#
# Every mode was opt-in by exact string, so anything unmatched — `--changd`,
# `--only` misspelt, a stray `-c` — fell through to the default and ran all 99
# mutations. A typo cost eight minutes and looked like it was doing what was asked,
# which is the worst of both: slow *and* not the thing you wanted. `--only` already
# refuses a label it does not know; this is the same courtesy for the flag itself.
case "${1:-}" in
    ""|--check|--only|--changed|--resume) ;;
    *)
        cat >&2 <<USAGE
Unknown option: $1

  mutation-sweep.sh                 break every invariant in turn (slow: 99 builds)
  mutation-sweep.sh --check         verify every mutation still matches its source
  mutation-sweep.sh --only "<label>"   run one entry
  mutation-sweep.sh --changed <ref>    run only entries in files that differ from <ref>
  mutation-sweep.sh --resume        continue a full sweep that was interrupted

USAGE
        exit 2
        ;;
esac
CHANGED_FILES=""
if [ -n "$CHANGED_REF" ]; then
    # Both committed and uncommitted differences: the reason to run this is usually
    # work that is not committed yet.
    # Blank lines are filtered deliberately, not defensively: an empty line in a
    # `grep -f` pattern file matches *every* input line, so one stray blank here would
    # silently turn a scoped run back into a full one — which looks like it worked.
    CHANGED_FILES="$(
        { git diff --name-only "$CHANGED_REF" 2>/dev/null
          git diff --name-only 2>/dev/null
        } | grep -v '^[[:space:]]*$' | sort -u
    )"
    if [ -z "$CHANGED_FILES" ]; then
        echo "Nothing differs from ${CHANGED_REF} — no mutations to run."
        exit 0
    fi
    # A change can touch only files no mutation targets — a script, a test, a
    # changelog. Saying so and stopping is better than running the baseline suite to
    # then run nothing, which looks like a sweep and proves nothing.
    if ! grep -oE '^"\$M" \$K/[^ ]+' "$0" | sed 's|^"\$M" \$K/|Sources/OpenClickyKit/|' \
        | grep -qxF -f <(printf '%s\n' "$CHANGED_FILES"); then
        echo "Nothing that differs from ${CHANGED_REF} carries a mutation — none to run."
        echo "That is not a clean bill: run the full sweep for one."
        exit 0
    fi
fi

run_mutation() {
    if [ -n "$ONLY" ] && [ "$2" != "$ONLY" ]; then return 0; fi
    # $1 is the mutation's target file, relative to the repo root exactly as the
    # entries below spell it, which is what `git diff --name-only` prints.
    if [ -n "$CHANGED_REF" ] && ! printf '%s\n' "$CHANGED_FILES" | grep -qxF "$1"; then
        return 0
    fi
    # Only entries that *passed* are recorded, so a failure is retried on resume —
    # the point of resuming is to finish the sweep, not to inherit its verdict.
    if [ "$RESUME" -eq 1 ] && printf '%s\n' "$DONE_LABELS" | grep -qxF "$2"; then
        return 0
    fi
    MATCHED=1
    if [ "$CHECK" -eq 1 ]; then
        if ! python3 -c "
import sys
target = sys.argv[2]
if target not in open(sys.argv[1]).read():
    raise SystemExit(1)
" "$1" "$3"; then
            printf "  %-44s %s\n" "$2" "!! TARGET MISSING"
            STATUS=1
        fi
        return 0
    fi
    # 4 is "defended, but only after a retry" — see Scripts/mutate.sh. Not a failure:
    # the invariant is defended. Counted separately so the closing verdict cannot read
    # as clean when a detection was decided by a coin toss.
    "$MUTATE" "$@"
    case $? in
        0) if [ "$RESUME" -eq 1 ]; then printf '%s\n' "$2" >> "$PROGRESS_FILE"; fi ;;
        4) FLAKY=$((FLAKY + 1)); FLAKY_LABELS="$FLAKY_LABELS
    $2"
           if [ "$RESUME" -eq 1 ]; then printf '%s\n' "$2" >> "$PROGRESS_FILE"; fi ;;
        *) STATUS=1 ;;
    esac
}
M=run_mutation
MATCHED=0
FLAKY=0
FLAKY_LABELS=""

# Every mutation restores on exit, including an interrupt — see Scripts/mutate.sh.
# Verify the tree is clean afterwards regardless:  git status --short
if [ -n "$CHANGED_REF" ]; then
    echo "Breaking only the invariants in files that differ from ${CHANGED_REF}…"
    echo
elif [ "$CHECK" -eq 1 ]; then
    echo "Checking every mutation still matches its source…"
else
    # A baseline, because this counts failing tests. If the suite is already failing,
    # every mutation reports one more failure than it caused and the sweep declares
    # everything defended while that one broken test does all the work — a check
    # measuring itself. Costs one run against a sweep that takes half an hour.
    echo "Checking the suite passes before breaking anything…"
    if ! BASELINE=$(swift test 2>&1); then
        echo "$BASELINE" | grep -E "^✘ Test \"" | head -5
        echo
        echo "The suite fails before any mutation, so the counts below would be"
        echo "meaningless. Fix that first."
        exit 1
    fi

    echo "Mutating safety-critical invariants… (a full sweep runs the suite once per invariant)"
fi
echo

K=Sources/OpenClickyKit
"$M" $K/Safety/Policy.swift "classifier always says read-only" \
  'for phrase in destructivePhrases where normalized.contains(phrase.pattern) {' \
  'if true { return .readOnly }; for phrase in destructivePhrases where normalized.contains(phrase.pattern) {'
"$M" $K/Safety/Policy.swift "newlines stop separating commands" \
  'separators.contains(character) || character.isNewline' 'separators.contains(character)'
"$M" $K/Safety/Policy.swift "path comparison becomes case-sensitive" \
  'let resolved = expand(path).lowercased()
        let base = expand(prefix).lowercased()' \
  'let resolved = expand(path)
        let base = expand(prefix)'
"$M" $K/Safety/Policy.swift "option allowlist accepts anything" \
  'guard options.allSatisfy({ $0.isPermitted(by: rule.allowedOptions) }) else { return false }' '_ = options'
"$M" $K/Safety/PermissionGate.swift "always-allow stops being recorded" \
  'sessionAllowlist.insert(tool)' '_ = tool'
"$M" $K/Safety/PermissionGate.swift "allowlist starts covering destructive calls" \
  'case .ask, .auto:
                // A session allowlist entry never covers a destructive call —' \
  'case .ask, .auto:
                if sessionAllowlist.contains(tool) { return .allow }
                // A session allowlist entry never covers a destructive call —'
"$M" $K/Agent/AgentLoop.swift "batch keeps running after a failure" \
  'if output.isError { batchFailed = true }' '_ = output.isError'
"$M" $K/Agent/LatencyReport.swift "the tier ceiling drops out of the configuration" \
  'if let maxTier { parts.append("tiers 0–\(maxTier)") }' '_ = maxTier'
"$M" $K/Agent/LatencyReport.swift "a turn loses its first-token time when tools close" \
  'timeToFirstToken: turn.timeToFirstToken,' 'timeToFirstToken: nil,'
"$M" $K/Agent/WaitingLine.swift "the waiting ticker outlives its turn" \
  'ticker.cancel()' '_ = ticker'
"$M" $K/Agent/StreamAssembler.swift "streamed tool arguments are replaced, not joined" \
  'partial.arguments += value' 'partial.arguments = value'
"$M" $K/Agent/RunReport.swift "a streamed reply is printed twice" \
  'guard !streamsText else { return [Line(text: "", emphasis: .detail)] }' '_ = streamsText'
"$M" $K/Agent/Usage.swift "a documented subcommand is read as a task" \
  'guard !word.hasPrefix("-"), word.allSatisfy({ $0.isLetter || $0 == "-" })' \
  'guard false, word.allSatisfy({ $0.isLetter || $0 == "-" })'
"$M" $K/Agent/Usage.swift "a documented subcommand is read as a task" \
  'guard !word.hasPrefix("-"), word.allSatisfy({ $0.isLetter || $0 == "-" })' \
  'guard false, word.allSatisfy({ $0.isLetter || $0 == "-" })'
"$M" $K/Support/ConfigFile.swift "a world-readable key file is used anyway" \
  'if mode & 0o077 != 0 {' 'if false {'
"$M" $K/Support/ConfigFile.swift "a write erases the keys it did not come to change" \
  'var stored = (try? load()) ?? Stored()
        stored.providers[provider] = Stored.Entry(apiKey: key)' \
  'var stored = Stored()
        stored.providers[provider] = Stored.Entry(apiKey: key)'
"$M" $K/Agent/Provider.swift "a stored model is handed to the wrong provider" \
  'let applicable = stored.applies(to: kind.rawValue) ? stored : ConfigFile.Settings()' \
  'let applicable = stored'
"$M" $K/Agent/ProviderSelection.swift "a provider default is pinned on switch" \
  'model: model == kind.defaultModel ? nil : model,' \
  'model: model,'
"$M" $K/Agent/ProviderSelection.swift "asking to type a model id changes nothing" \
  'choseToType = true
            return false' \
  'return false'
"$M" $K/Agent/OpenAICompatibleClient.swift "a model id is tidied on its way to the picker" \
  '.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }' \
  '.map { ModelCapabilities.normalized($0.id) }'
"$M" $K/Agent/ModelCatalog.swift "a listing sends the key in cleartext to another machine" \
  'if endpoint.scheme?.lowercased() == "http", !Provider.isLoopback(endpoint.host) {' \
  'if false {'
"$M" $K/Support/ConfigFile.swift "an exposed key file reads as no key at all" \
  'try refusePermissiveFile()
            return nil' \
  'return nil'
"$M" $K/Agent/Usage.swift "the help stops naming a flag it documents" \
  'guard trimmed.hasPrefix("--") else { return nil }' 'return nil'
"$M" $K/Agent/OpenAICompatibleClient.swift "a bad request is retried until quota runs out" \
  'status == 408 || status == 409 || status == 429 || status >= 500' 'true'
"$M" $K/Agent/OpenAICompatibleClient.swift "a date-form Retry-After is discarded" \
  'return max(0, date.timeIntervalSince(now))' 'return nil'
"$M" $K/Agent/OpenAICompatibleClient.swift "strict mode ignores nested schemas" \
  'return properties.values.allSatisfy { property in' 'return true; return properties.values.allSatisfy { property in'
"$M" $K/Agent/OpenAICompatibleClient.swift "a content filter is blamed on the model" \
  'if finishReason == "content_filter" {' 'if false {'
"$M" $K/Perception/ContextProbe.swift "advice asks for permissions the run cannot use" \
  'let wantsScreenRecording = tier >= .pixels && !screenRecording' \
  'let wantsScreenRecording = !screenRecording'
"$M" $K/Perception/AXTree.swift "an app that publishes no tree says nothing" \
  '!hitNodeLimit && !hitDepthLimit && nodes.count < 10' 'false'
"$M" $K/Agent/LatencyReport.swift "the plan is read as part of the task" \
  'let withoutPlan = afterProbe.components(separatedBy: Planner.briefMarker).first ?? afterProbe' \
  'let withoutPlan = afterProbe'
"$M" $K/Agent/Provider.swift "a local run is billed at a made-up rate" \
  'kind != .ollama || !Self.isLoopback(baseURL?.host)' 'true'
"$M" $K/Agent/LatencyReport.swift "a turn loses its retries when tools close" \
  'retries: turn.retries,
                retrySeconds: turn.retrySeconds,' \
  'retries: 0,
                retrySeconds: 0,'
"$M" $K/Tools/Tool.swift "a tool name maps to the wrong tier in reports" \
  'case "screenshot", "zoom", "click", "drag", "type", "key", "scroll", "wait":
            return .pixels' \
  'case "screenshot", "zoom", "click", "drag", "type", "key", "scroll", "wait":
            return .shell'
"$M" $K/Agent/LatencyReport.swift "bench compares different tasks as if they matched" \
  '.filter { Set($0.value.compactMap { $0.configuration?.label }).count > 1 }' \
  '.filter { _ in true }'
"$M" $K/Agent/AgentLoop.swift "planning silently does not happen" \
  'await observer(.planningFailed(model: planner.model, reason: reason))' '_ = reason'
"$M" $K/Agent/AgentLoop.swift "a run dies without recording why" \
  'await transcript.note(kind: "failed", [' 'await transcript.note(kind: "ignored", ['
"$M" $K/Agent/CostMeter.swift "the planning model bills at nothing" \
  'public var totalCost: Double { executionCost + planningCost }' \
  'public var totalCost: Double { executionCost }'
"$M" $K/Agent/Planner.swift "the planner is handed tools it could act with" \
  'tools: []' 'tools: registry.definitions'
"$M" $K/Agent/RunOutcome.swift "a run that changed nothing reports success" \
  'intent == .action && actionsTaken == 0' 'false'
"$M" $K/Agent/AgentLoop.swift "observing counts as having acted" \
  'if case .read = risk {
                    observationsMade += 1
                } else if verifiedNoOp {' \
  'if false {
                    observationsMade += 1
                } else if verifiedNoOp {'
"$M" $K/Agent/AgentLoop.swift "a failed action counts as an action taken" \
  'if !output.isError {
                let verifiedNoOp' \
  'if true {
                let verifiedNoOp'
"$M" $K/Agent/AgentLoop.swift "an action the UI says did nothing counts as done" \
  'let verifiedNoOp = output.changeVerdict == .unchanged' \
  'let verifiedNoOp = false'
"$M" $K/Perception/UIFingerprint.swift "a verified no-op reports itself as a change" \
  'observedChange: false)' 'observedChange: true)'
"$M" $K/Tools/Tool.swift "a tool that never verified itself is read as a no-op" \
  'changeVerdict: ChangeVerdict = .unverified' \
  'changeVerdict: ChangeVerdict = .unchanged'
"$M" $K/Agent/AgentLoop.swift "every exit stops recording an outcome" \
  'outcome = result' '_ = result'
"$M" $K/Agent/RunOutcome.swift "a run cut off mid-task reports success" \
  'stopReason.disposition == .cutShort' 'false'
"$M" $K/Agent/RunOutcome.swift "the exit code stops noticing an unfinished run" \
  'isUnfulfilled || wasCutShort' 'isUnfulfilled'
"$M" $K/Agent/RunOutcome.swift "an interruption is booked as the agent falling short" \
  'sentence: "interrupted by the user", disposition: .interrupted' \
  'sentence: "interrupted by the user", disposition: .cutShort'
"$M" $K/Agent/AgentLoop.swift "the turn limit is recorded as a clean finish" \
  'reason: .cutShort("turn limit (\(config.maxTurns)) reached")' \
  'reason: .concluded("turn limit (\(config.maxTurns)) reached")'
"$M" $K/Agent/AgentLoop.swift "a truncated reply is recorded as a clean finish" \
  'reason: .cutShort("response truncated at the \(config.maxTokens)-token limit")' \
  'reason: .concluded("response truncated at the \(config.maxTokens)-token limit")'
"$M" $K/Agent/AgentLoop.swift "a refusal is recorded as a clean finish" \
  'reason: .cutShort("the model declined this request (\(detail))")' \
  'reason: .concluded("the model declined this request (\(detail))")'
"$M" $K/Agent/TranscriptReport.swift "the listing stops flagging a run that did not finish" \
  '(incomplete == true ? "  ⚠ did not finish" : "")' '""'
"$M" $K/Agent/LatencyReport.swift "the user wait is charged to the tools" \
  'toolSeconds: max(0, window - gateWaitThisTurn),' 'toolSeconds: window,'
"$M" $K/Agent/Transcript.swift "the record loses its ordering" \
  'nextSequence += 1' '_ = nextSequence'
"$M" $K/Agent/Transcript.swift "transcripts become world-readable" \
  'attributes: [.posixPermissions: 0o600]' 'attributes: [.posixPermissions: 0o644]'
"$M" $K/Support/HotKey.swift "a bare-key hotkey becomes acceptable" \
  'guard modifiers != 0 else { throw Error.noModifier(combo) }' '_ = modifiers'
"$M" $K/Tools/Tool.swift "the tier cap stops filtering tools" \
  'return ToolRegistry(all.filter { $0.tier <= maxTier })' 'return ToolRegistry(all)'
"$M" $K/Agent/Transcript.swift "pruning drops the tool_result entirely" \
  'content[blockIndex] = .toolResult(
                        toolUseID: toolUseID, content: rewritten, isError: isError
                    )' \
  'content[blockIndex] = .text("")'
"$M" $K/Perception/ScreenCapture.swift "coordinates ignore the display offset" \
  'x: screenRect.origin.x + point.x * scaleX,
            y: screenRect.origin.y + point.y * scaleY' \
  'x: point.x * scaleX,
            y: point.y * scaleY'
"$M" $K/Perception/UIFingerprint.swift "secure fields are read like any other" \
  'isSecure(role: role, subrole: subrole, label: label) ? "(secure field)" : value' 'value'
"$M" $K/Support/Subprocess.swift "heuristic stops catching vendor keys" \
  'if components.contains("KEY") { return true }' '_ = components'
"$M" $K/Tools/ScreenTools.swift "zoom stops recording its crop" \
  'await context.record(shot)
            return .image(
                mediaType: "image/jpeg",
                base64: shot.jpegBase64,
                note: "Zoom:' \
  'return .image(
                mediaType: "image/jpeg",
                base64: shot.jpegBase64,
                note: "Zoom:'
"$M" $K/Tools/AccessibilityTools.swift "ax_set_value stops setting the value" \
  'try await AXCapture.shared.setValue(value, on: id)' '_ = (value, id)'
"$M" $K/Perception/AXTree.swift "captures stop publishing element labels" \
  'Self.labels.replace(with: Dictionary(' 'Self.labels.replace(with: [String: String]()); _ = (Dictionary('
"$M" $K/Agent/AgentLoop.swift "cost stops being metered" \
  'meter.record(response.usage)' '_ = response.usage'
"$M" $K/Tools/ScreenTools.swift "screenshots stop excluding our own windows" \
  'excludingBundleIDs: excludedBundleIDs' 'excludingBundleIDs: []'
"$M" $K/Tools/ScreenTools.swift "zoom stops capturing at full resolution" \
  'space: space, quality: Self.detailQuality,' \
  'space: ImageSpace(name: "mutant", longEdge: 400), quality: Self.detailQuality,'
# The per-provider image space, in the three places it can silently stop being one.
# Each failure is a click that lands on the wrong thing and reports success.
"$M" $K/Tools/ScreenTools.swift "a resampled screenshot is converted anyway" \
  'guard last.reachesTheModelIntact else {' 'if false {'
"$M" $K/Tools/Tool.swift "the registry stops threading its image space" \
  'ScreenshotTool(excludedBundleIDs: excludedBundleIDs, space: imageSpace),
            ZoomTool(space: imageSpace),' \
  'ScreenshotTool(excludedBundleIDs: excludedBundleIDs),
            ZoomTool(),'
"$M" $K/Perception/ImageSpace.swift "a short-edge cap stops binding" \
  'return min(longEdge, shortEdge * (long / short))' 'return longEdge'
# Provider configuration. A key sent in cleartext and a tier ceiling that stops
# applying both fail silently: the run works, and something the user relied on is gone.
"$M" $K/Agent/Provider.swift "an API key travels over plaintext HTTP" \
  'throw Error.insecureBaseURL(baseURL.host ?? baseURL.absoluteString)' \
  '_ = baseURL'
"$M" $K/Agent/Invocation.swift "the tier ceiling of a blind model stops applying" \
  'public var effectiveMaxTier: Tier { min(maxTier, capabilities.maxTier) }' \
  'public var effectiveMaxTier: Tier { maxTier }'
"$M" $K/Agent/AgentLoop.swift "a blind model gets the prompt for a seeing one" \
  'registry: registry, grounding: .forModel(config.model)' \
  'registry: registry, grounding: .visual'
"$M" $K/Tools/ScreenTools.swift "the phantom cursor stops animating before clicks" \
  'await cursor.travel(to: screenPoint)' '_ = screenPoint'
"$M" $K/Action/InputInjector.swift "long text stops using the clipboard" \
  'text.count > threshold || text.contains("\n") ? .clipboard : .keystrokes' \
  '.keystrokes'
"$M" $K/Tools/ScreenTools.swift "clicks skip the coordinate conversion" \
  'let screenPoint = try await context.screenPoint(fromImage: imagePoint)' \
  'let screenPoint = imagePoint'
"$M" $K/Agent/AgentLoop.swift "the loop stops consulting the gate" \
  'let decision = await gate.decide(tool: tool.name, risk: risk)' \
  'let decision = PermissionGate.Decision.allow'
# Anchored on a heading rather than the opening sentence: that line contains an
# apostrophe, and quoting it through this script mangled the target silently — which
# the sweep now reports rather than skipping.
"$M" $K/Agent/SystemPrompt.swift "session state leaks into the cached prompt" \
  '# The capability ladder' \
  '# The capability ladder \(Date())'
"$M" $K/Support/Subprocess.swift "subprocesses inherit the parent environment" \
  'process.environment = scrubbedEnvironment()' '_ = scrubbedEnvironment()'
"$M" $K/Perception/AXTree.swift "an attribute is bridged without checking its type" \
  'guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }' \
  'guard let value else { return nil }'
"$M" $K/Agent/Transcript.swift "transcript entries stop having a stable key order" \
  'encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]' \
  'encoder.outputFormatting = [.withoutEscapingSlashes]'
"$M" $K/Tools/ScriptTools.swift "app_script claims shell is confined regardless" \
  'Self.confinementNote(sandbox: sandbox)' 'Self.confinementNote(sandbox: .enabled)'
"$M" $K/Agent/SystemPrompt.swift "the prompt claims confinement it does not have" \
  'let sandboxed = (registry["shell"] as? ShellTool).map { tool in' \
  'let sandboxed = true; _ = (registry["shell"] as? ShellTool).map { tool in'
"$M" $K/Agent/TranscriptReport.swift "forget selects records it should keep" \
  '.filter { $0.started < cutoff }' '.filter { _ in true }'
"$M" $K/Action/CursorPath.swift "a cancelled travel claims to have arrived" \
  'if !Task.isCancelled { lastPoint = point }' 'lastPoint = point'
"$M" $K/Support/HotKey.swift "a hotkey registers with nothing listening" \
  'guard handler == noErr else { throw Error.handlerFailed(handler) }' \
  '_ = handler'
"$M" $K/Safety/PermissionGate.swift "an unoffered key approves a destructive action" \
  'return isDestructive ? .deny : .allowAlways' 'return isDestructive ? .allow : .allowAlways'
"$M" $K/Agent/SessionController.swift "a stray Return can approve a destructive action" \
  'public var acceptsBareReturn: Bool { !isDestructive }' \
  'public var acceptsBareReturn: Bool { true }'
"$M" $K/Agent/TranscriptReport.swift "a listing stops widening its tail search" \
  'for window in [64 * 1024, 1024 * 1024, size] where window > 0 {' \
  'for window in [64 * 1024] where window > 0 {'
"$M" $K/Perception/ContextProbe.swift "doctor reports a broken machine as ready" \
  'if tier >= .pixels, !screenRecording { return false }' '_ = tier'
# The other half of the same verdict: a ceiling that stops limiting which grants
# matter makes `doctor --provider ollama` refuse a machine that is ready for that run.
"$M" $K/Perception/ContextProbe.swift "the readiness ceiling stops applying" \
  'if tier >= .accessibility, !accessibility { return false }' \
  'if !accessibility { return false }'
"$M" $K/Tools/AccessibilityTools.swift "a capture stops naming the app it read" \
  'var header = "\(capture.app) — \(capture.nodes.count) elements"' \
  'var header = "\(capture.nodes.count) elements"'
"$M" $K/Tools/ShellTool.swift "a sandbox refusal goes unexplained" \
  'guard lowered.contains("operation not permitted")' \
  'guard lowered.contains("no such sentinel")'
"$M" $K/Agent/AnthropicClient.swift "a backoff happens with nothing said" \
  'await onRetry?(attempt, maxRetries, delay, error.description)' '_ = onRetry'
"$M" $K/Agent/SystemPrompt.swift "read-only and bypass stop explaining themselves" \
  'switch mode {
        case .readOnly:' \
  'switch PermissionMode.ask {
        case .readOnly:'
"$M" $K/Tools/ShellTool.swift "an unsandboxed run still claims confinement" \
  'let confinement = switch sandbox {' 'let confinement = switch ShellSandbox.enabled {'
"$M" $K/Agent/SystemPrompt.swift "the prompt describes tools the run does not have" \
  'if cap >= .accessibility {' 'if true {'
"$M" $K/Agent/AgentLoop.swift "the agent may answer its own consent dialogs" \
  'let risk = Policy.escalate(' \
  'let risk = Policy.identity('
"$M" $K/Safety/Policy.swift "the agent may overwrite its own program" \
  'for image in runningImagePaths where path(candidate, isAtOrBeneath: image) {' \
  'for image in [String]() where path(candidate, isAtOrBeneath: image) {'
"$M" $K/Safety/Policy.swift "padding hides a denied path past the cap" \
  'return walk.truncated ? "more paths than can be checked" : nil' 'return nil'
"$M" $K/Safety/Policy.swift "persistence needs a redirection to be noticed" \
  'if let sensitive = isSensitiveWrite(path: expand(token)) {' \
  'if let sensitive = String?.none {'
"$M" $K/Safety/Policy.swift "credential paths are matched as text again" \
  'for token in walk.tokens {
            let candidate = expand(token)' \
  'for token in [normalized] {
            let candidate = token'
"$M" $K/Safety/Policy.swift "the shell's spelling of home evades the deny-list" \
  'return substitutingHome(in: collapsed.lowercased())' 'return collapsed.lowercased()'
"$M" $K/Perception/UIFingerprint.swift "a field labelled as a secret is not redacted" \
  'return secretLabels.contains { label.contains($0) }' 'return false'
"$M" $K/Tools/ShellTool.swift "credential output reaches the model" \
  'if Policy.printsSecret(command) {' 'if false {'
"$M" $K/Tools/ScriptTools.swift "credential output reaches the model via osascript" \
  'if Policy.printsSecret(script) { return .text(Policy.withheldSecretNote) }' \
  ''
"$M" $K/Safety/Policy.swift "an executable is trusted by name alone" \
  'guard executableTrust(first) else { return false }' '_ = executableTrust'
"$M" $K/Safety/Policy.swift "a wrapper hides the command it runs" \
  'guard commandWrappers.contains(name) else { return name }' 'return name'
"$M" $K/Agent/AgentLoop.swift "an element owned by a security surface is not checked" \
  'targetBundleIdentifier: targetBundleIdentifier()' \
  'targetBundleIdentifier: nil'
"$M" $K/Tools/ScriptTools.swift "scripts may drive permission dialogs silently" \
  'if Policy.namesSecuritySurface(script) {' 'if false {'
"$M" $K/Safety/Policy.swift "privilege-changing commands stop being destructive" \
  '"tccutil": "resets the privacy permissions the user has granted",' ''
"$M" $K/Tools/ScriptTools.swift "app_script stops applying the deny-list" \
  'try Policy.validateShell(script)' 'try Policy.validateShell("")'
"$M" $K/Tools/ShellTool.swift "shell stops applying the deny-list" \
  'try Policy.validateShell(command)' '_ = command'
"$M" $K/Tools/FileTools.swift "read_file stops checking credential paths" \
  'try Policy.validateRead(path: path)' '_ = path'
"$M" $K/Agent/AgentLoop.swift "the loop sends the unpruned conversation" \
  'messages: await transcript.conversation(policy: config.context),' \
  'messages: await transcript.conversation,'
"$M" $K/Perception/ScreenCapture.swift "reported image size becomes a prediction" \
  'return (data, scaled.extent.size)' \
  'return (data, CGSize(width: (width * scale).rounded(.down), height: (height * scale).rounded(.down)))'
"$M" $K/Action/InputInjector.swift "scroll loses its remainder again" \
  'return (0..<count).map { sign * (base + ($0 < remainder ? 1 : 0)) }' \
  'return (0..<count).map { _ in sign * base }'
"$M" $K/Tools/Tool.swift "approval summaries stop being sanitised" \
  'case let .write(text), let .dangerous(text): return Policy.summarize(text)' \
  'case let .write(text), let .dangerous(text): return text'
"$M" $K/Agent/Wire.swift "requests stop serialising deterministically" \
  'encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]' \
  'encoder.outputFormatting = [.withoutEscapingSlashes]'
"$M" $K/Action/InputInjector.swift "the clipboard snapshot forgets every type but text" \
  'for type in item.types where !Self.isPromised(type) {' \
  'for type in [NSPasteboard.PasteboardType.string] {'
"$M" $K/Perception/AXTree.swift "accessibility failures collapse to a bare code" \
  'return "Accessibility action '"'"'\(action)'"'"' failed: \(Self.explain(code))"' \
  'return "Accessibility action '"'"'\(action)'"'"' failed (AXError \(code.rawValue))."'
"$M" $K/Perception/UIFingerprint.swift "only the first scrollable pane is watched" \
  'guard previous.scrollPositions.count == scrollPositions.count else { return nil }' \
  'guard previous.scrollPositions.count == scrollPositions.count, scrollPositions.count < 2 else { return nil }'
"$M" $K/Perception/UIFingerprint.swift "the agent's own terminal counts as evidence" \
  '!after.isSelfNoise(since: before, selfBundleIDs: selfBundleIDs)' \
  'true'
"$M" $K/Perception/UIFingerprint.swift "self-suppression swallows a real window change" \
  '&& previous.windowTitle == windowTitle' \
  '&& true'
"$M" $K/Perception/UIFingerprint.swift "the scroll walk moves onto the polling path" \
  'after = capture(false)' 'after = capture(true)'
"$M" $K/Agent/AgentLoop.swift "the model is not told its turn was truncated" \
  'for notice in notices { results.append(.text(notice)) }' \
  'if notices.isEmpty { results.append(.text("")) }'
"$M" $K/Agent/AgentLoop.swift "the turn limit arrives without warning" \
  'if requestsRemaining == 1 {' \
  'if false {'
"$M" $K/Action/InputInjector.swift "the restore clobbers a newer clipboard" \
  'if isUnchanged(pasteboard, since: ours) { restore(saved, to: pasteboard) }' \
  'restore(saved, to: pasteboard)'

echo
if [ -n "$ONLY" ] && [ "$MATCHED" -eq 0 ]; then
    echo "No entry labelled \"$ONLY\". Nothing was run."
    STATUS=1
elif [ "$CHECK" -eq 1 ]; then
    if [ "$STATUS" -ne 0 ]; then
        echo "A mutation no longer matches the code, so it has been testing nothing."
    else
        echo "All $(grep -c '^"\$M"' "$0") mutations still match their source."
    fi
elif [ "$STATUS" -ne 0 ]; then
    echo "FAILED. NOT CAUGHT means an invariant nothing defends; TARGET MISSING means"
    echo "the mutation no longer matches the code, so it has been testing nothing."
elif [ "$FLAKY" -ne 0 ]; then
    echo "All invariants are defended, but $FLAKY needed more than one run of the suite:"
    echo "$FLAKY_LABELS"
    echo
    echo "Each of those is a test that agrees with the mutation some of the time, and"
    echo "would have been reported NOT CAUGHT before the retry existed. Fix the test —"
    echo "the retry keeps the sweep honest, it does not make the detector reliable."
elif [ -n "$CHANGED_REF" ]; then
    # Never "All invariants are defended" from a scoped run: it did not look at all of
    # them, and a verdict that overstates its own coverage is the thing this script
    # exists to prevent one level down.
    echo "Every invariant in the changed files is defended."
    echo "This was a scoped run — the rest were not tried. Run the full sweep before"
    echo "trusting it as a clean bill."
else
    echo "All invariants are defended."
    # The sweep finished; the record has nothing left to say. Left behind, it would
    # make the next `--resume` skip everything and declare victory without running.
    if [ "$RESUME" -eq 1 ]; then rm -f "$PROGRESS_FILE"; fi
fi
echo
echo "Not listed: the retry bound in AnthropicClient. Removing it makes the client"
echo "retry forever, so the sweep hangs rather than reporting — which is why that"
echo "test carries a .timeLimit. A hanging test is worse than a failing one."

exit $STATUS

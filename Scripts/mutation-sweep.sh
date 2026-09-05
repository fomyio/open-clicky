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
if [ "${1:-}" = "--only" ]; then ONLY="${2:-}"; fi

run_mutation() {
    if [ -n "$ONLY" ] && [ "$2" != "$ONLY" ]; then return 0; fi
    MATCHED=1
    "$MUTATE" "$@" || STATUS=1
}
M=run_mutation
MATCHED=0

# Every mutation restores on exit, including an interrupt — see Scripts/mutate.sh.
# Verify the tree is clean afterwards regardless:  git status --short
echo "Mutating safety-critical invariants… (a full sweep runs the suite once per invariant)"
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
"$M" $K/Agent/Transcript.swift "the record loses its ordering" \
  'nextSequence += 1' '_ = nextSequence'
"$M" $K/Agent/Transcript.swift "transcripts become world-readable" \
  'attributes: [.posixPermissions: 0o600]' 'attributes: [.posixPermissions: 0o644]'
"$M" $K/Support/HotKey.swift "a bare-key hotkey becomes acceptable" \
  'guard modifiers != 0 else { throw Error.noModifier(combo) }' '_ = modifiers'
"$M" $K/Agent/Invocation.swift "the tier cap stops filtering tools" \
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
  'static let fullResolutionEdge: CGFloat = 2400' 'static let fullResolutionEdge: CGFloat = 400'
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
"$M" $K/Agent/AgentLoop.swift "the agent may answer its own consent dialogs" \
  'let risk = Policy.escalate(' \
  'let risk = Policy.identity('
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
  'if previous.scrollPositions.count == scrollPositions.count,' \
  'if previous.scrollPositions.count == scrollPositions.count, scrollPositions.count < 2,'
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
elif [ "$STATUS" -ne 0 ]; then
    echo "FAILED. NOT CAUGHT means an invariant nothing defends; TARGET MISSING means"
    echo "the mutation no longer matches the code, so it has been testing nothing."
else
    echo "All invariants are defended."
fi
echo
echo "Not listed: the retry bound in AnthropicClient. Removing it makes the client"
echo "retry forever, so the sweep hangs rather than reporting — which is why that"
echo "test carries a .timeLimit. A hanging test is worse than a failing one."

exit $STATUS

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
M="$(dirname "${BASH_SOURCE[0]}")/mutate.sh"

echo "Mutating safety-critical invariants…"
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
"$M" $K/Safety/PermissionGate.swift "allowlist starts covering destructive calls" \
  'case .ask, .auto:
                // A session allowlist entry never covers a destructive call —' \
  'case .ask, .auto:
                if sessionAllowlist.contains(tool) { return .allow }
                // A session allowlist entry never covers a destructive call —'
"$M" $K/Agent/AgentLoop.swift "batch keeps running after a failure" \
  'if output.isError { batchFailed = true }' '_ = output.isError'
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
  'isSecure(role: role, subrole: subrole) ? "(secure field)" : value' 'value'
"$M" $K/Support/Subprocess.swift "heuristic stops catching vendor keys" \
  'if components.contains("KEY") { return true }' '_ = components'
"$M" $K/Tools/ScreenTools.swift "clicks skip the coordinate conversion" \
  'let screenPoint = try await ScreenContext.shared.screenPoint(fromImage: imagePoint)' \
  'let screenPoint = imagePoint'
"$M" $K/Agent/AgentLoop.swift "the loop stops consulting the gate" \
  'let decision = await gate.decide(tool: tool.name, risk: risk)' \
  'let decision = PermissionGate.Decision.allow'
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

echo
echo "Any line reading NOT CAUGHT is an invariant nothing defends."

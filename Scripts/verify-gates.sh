#!/bin/bash
#
# Breaks each preflight check in turn and confirms it goes red.
#
# A gate is worth exactly as much as the evidence that it fails when it should, and
# three of these did not when they were written: the warning check measured the build
# cache, the sweep's own check reported problems and exited 0, and the warning check
# again covered every target except the tests. Each was found by looking at something
# the check said was fine, which is not a strategy.
#
# Slow — each case runs a full preflight. Run after changing Scripts/preflight.sh.
# Like the sweep, it mutates the tree, so never run it alongside other work.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STATUS=0
MATCHED=0

# --only "<label>" runs a single case. Each case is a full preflight, so the whole
# run is minutes; checking one after editing it should not be.
ONLY=""
if [ "${1:-}" = "--only" ]; then ONLY="${2:-}"; fi

# Runs `break`, checks the named preflight line went red, then runs `restore`.
verify() {
    local label="$1" pattern="$2" breaker="$3" restorer="$4"
    if [ -n "$ONLY" ] && [ "$label" != "$ONLY" ]; then return 0; fi
    MATCHED=1
    eval "$breaker"
    local line
    line=$(./Scripts/preflight.sh 2>&1 | grep -E "^  [✓✗] $pattern" | head -1)
    eval "$restorer"

    if [[ "$line" == *"✗"* ]]; then
        printf "  %-46s went red\n" "$label"
    else
        printf "  %-46s !! STAYED GREEN\n" "$label"
        STATUS=1
    fi
}

echo "Breaking each preflight check to confirm it objects…"
echo

verify "a warning in the library" "builds in release" \
    'cp Sources/OpenClickyKit/Agent/CostMeter.swift /tmp/g.bak
     printf "\nfunc _gateProbe() { let x = 1 }\n" >> Sources/OpenClickyKit/Agent/CostMeter.swift' \
    'cp /tmp/g.bak Sources/OpenClickyKit/Agent/CostMeter.swift; rm -f /tmp/g.bak'

verify "a warning in the tests" "tests pass" \
    'cp Tests/OpenClickyKitTests/CostMeterTests.swift /tmp/g.bak
     printf "\nfunc _gateProbe() { let x = 1 }\n" >> Tests/OpenClickyKitTests/CostMeterTests.swift' \
    'cp /tmp/g.bak Tests/OpenClickyKitTests/CostMeterTests.swift; rm -f /tmp/g.bak'

verify "a mutation whose target has moved" "every mutation" \
    'cp Scripts/mutation-sweep.sh /tmp/g.bak
     sed -i "" "s|guard executableTrust(first) else { return false }|NO SUCH LINE|" Scripts/mutation-sweep.sh' \
    'cp /tmp/g.bak Scripts/mutation-sweep.sh; rm -f /tmp/g.bak'

verify "a mutation left in the tree" "no mutation left behind" \
    'cp Sources/OpenClickyKit/Tools/Tool.swift /tmp/g.bak
     sed -i "" "s|case let .write(text), let .dangerous(text): return Policy.summarize(text)|case let .write(text), let .dangerous(text): return text|" Sources/OpenClickyKit/Tools/Tool.swift' \
    'cp /tmp/g.bak Sources/OpenClickyKit/Tools/Tool.swift; rm -f /tmp/g.bak'

verify "a collapsed line continuation" "no collapsed line" \
    'cp Sources/OpenClickyKit/Tools/ShellTool.swift /tmp/g.bak
     sed -i "" "s|Run a shell command on|Run a shell command that        lets it take on|" Sources/OpenClickyKit/Tools/ShellTool.swift' \
    'cp /tmp/g.bak Sources/OpenClickyKit/Tools/ShellTool.swift; rm -f /tmp/g.bak'

verify "CLAUDE.md over budget" "CLAUDE.md" \
    'cp CLAUDE.md /tmp/g.bak 2>/dev/null; printf "%0.sx" {1..400} >> CLAUDE.md' \
    'cp /tmp/g.bak CLAUDE.md 2>/dev/null; rm -f /tmp/g.bak'

verify "a build artifact tracked" "no build artifacts" \
    'git add -f build/OpenClicky.app/Contents/Info.plist 2>/dev/null' \
    'git rm -q --cached build/OpenClicky.app/Contents/Info.plist 2>/dev/null'

# The probe key is assembled at runtime. Written whole, this file would itself trip
# the credential check it is testing — which it duly did, on the commit that added it.
verify "a credential staged" "no credentials staged" \
    'printf "let k = \"sk-%s\"\n" "ant-abcdefghij0123456789XY" > Sources/OpenClickyKit/GateProbe.swift
     git add Sources/OpenClickyKit/GateProbe.swift' \
    'git rm -q --cached Sources/OpenClickyKit/GateProbe.swift 2>/dev/null
     rm -f Sources/OpenClickyKit/GateProbe.swift'

verify "a machine identifier" "no machine identifiers" \
    'printf "// see /Users/%s/Documents\n" "$(whoami)" > docs/gate-probe.md
     git add docs/gate-probe.md' \
    'git rm -q --cached docs/gate-probe.md 2>/dev/null; rm -f docs/gate-probe.md'

echo
if [ -n "$ONLY" ] && [ "$MATCHED" -eq 0 ]; then
    echo "No case labelled \"$ONLY\". Nothing was run."
    STATUS=1
elif [ "$STATUS" -ne 0 ]; then
    echo "FAILED. A check that stays green while what it guards is broken is not a check."
else
    echo "Every preflight check objects when what it guards is broken."
fi
exit $STATUS

#!/bin/bash
#
# Everything that must be true before a commit, in one command.
#
# Written because the same mistake happened twice in one session: a commit with a
# failing test, and a commit with CLAUDE.md over its character budget. Both times the
# check had been run — just beside the commit rather than as its gate, where a `&&`
# chain let a later success carry an earlier failure through.
#
# The rule this encodes is the same one the codebase applies to itself: when a
# guarantee can be forgotten, move it to the single point everything passes through.
#
#   ./Scripts/preflight.sh            check
#   ./Scripts/preflight.sh --install  also install it as a git pre-commit hook
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAILURES=0
check() {
    local label="$1"; shift
    if "$@" >/tmp/preflight.$$ 2>&1; then
        printf "  ✓ %s\n" "$label"
    else
        printf "  ✗ %s\n" "$label"
        sed 's/^/      /' /tmp/preflight.$$ | tail -12
        FAILURES=$((FAILURES + 1))
    fi
    rm -f /tmp/preflight.$$
}

if [ "${1:-}" = "--install" ]; then
    mkdir -p .git/hooks
    printf '#!/bin/sh\nexec ./Scripts/preflight.sh\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    echo "Installed as .git/hooks/pre-commit — commits now run this first."
    echo
fi

echo "Preflight"

check "builds in release" swift build -c release
check "tests pass" swift test

# A mutation left behind by an interrupted sweep looks like nothing in `git status`:
# the file is modified, which is normal, and the change is a plausible line of code.
check "no mutation left behind by a sweep" bash -c '
    ! git diff -- Sources/ | grep -qE "^\+.*(// MUTATED|// TEMPORARILY BROKEN)" &&
    ! git diff -- Sources/OpenClickyKit/Tools/Tool.swift | grep -qE "^\+.*return text$"'

# The workspace rule: this file is a context budget, not a document.
check "CLAUDE.md within its 5000-character budget" bash -c '
    [ ! -f CLAUDE.md ] || [ "$(wc -c < CLAUDE.md)" -lt 5000 ]'

# Generated output does not belong in the repository.
check "no build artifacts tracked" bash -c '[ "$(git ls-files build/ | wc -l)" -eq 0 ]'

# Test fixtures use obvious dummies; a real key would match these shapes.
check "no credentials staged" bash -c '
    ! git diff --cached -U0 2>/dev/null | grep -qE "^\+.*(sk-ant-[a-zA-Z0-9]{20}|ghp_[a-zA-Z0-9]{20}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)"'

# The home path and MAC address were redacted from the research corpus once already.
check "no machine identifiers in tracked files" bash -c '
    ! git grep -qE "Users/$(whoami)|([0-9a-f]{2}:){5}[0-9a-f]{2}" -- ":!Scripts/preflight.sh" 2>/dev/null'

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$FAILURES check(s) failed — nothing should be committed on top of this."
    exit 1
fi

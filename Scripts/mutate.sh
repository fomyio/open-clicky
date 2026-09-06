#!/bin/bash
# Break one invariant, count failing tests, restore.
FILE="$1"; LABEL="$2"; OLD="$3"; NEW="$4"

# Restore on any exit, including an interrupt or a timeout.
#
# Without this a sweep killed mid-run leaves the mutation applied, and the working
# tree silently holds a deliberately broken invariant — which is exactly how the
# approval-sanitising guarantee came to be sitting removed in a tree that looked clean.
BACKUP="$(mktemp)"
cp "$FILE" "$BACKUP"
restore() { cp "$BACKUP" "$FILE"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM
python3 -c "
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old not in s:
    raise SystemExit(2)
open(p,'w').write(s.replace(old, new, 1))
" "$FILE" "$OLD" "$NEW" || {
  # The trap restores the file; the stale `cp /tmp/mut.bak` that used to live here
  # was both redundant and a hazard — that path is left behind by older runs, so a
  # missing target could overwrite the source with an unrelated backup.
  #
  # Exits non-zero. A mutation whose target has moved tests nothing, and printing a
  # note that is neither "caught" nor "NOT CAUGHT" is how three of these sat rotted
  # through a dozen green sweeps.
  printf "  %-44s %s\n" "$LABEL" "!! TARGET MISSING — this invariant is no longer tested"
  exit 3
}
# Compilation is decided by the build's exit code, not by grepping for "error:" in
# the test output. A test that catches a mutation can easily print that substring —
# `app_script` reported "does not compile" because osascript's own failure text says
# "execution error:", which reads as "this invariant cannot be broken" when in fact
# it was being caught by three tests. The same misreading would hide a real gap.
if ! swift build --build-tests >/dev/null 2>&1; then
  RESULT="does not compile (invariant is structural)"
else
  OUT=$(swift test 2>&1)
  STATUS=$?
  N=$(echo "$OUT" | grep -cE '^✘ Test "')
  if [ "$N" -gt 0 ]; then
    RESULT="caught by $N test(s)"
  elif [ "$STATUS" -ne 0 ]; then
    # A mutation that crashes the suite produces no "✘ Test" lines at all, so counting
    # them alone read a hard crash as NOT CAUGHT — under-reporting coverage on exactly
    # the invariants whose violation is most severe. Removing a type check on values
    # another app controls does not fail a test, it terminates the process.
    RESULT="caught (the suite did not survive it)"
  else
    RESULT="!! NOT CAUGHT"
  fi
fi
printf "  %-44s %s\n" "$LABEL" "$RESULT"
# The exit code is what the sweep totals up, so a mutation nothing objects to fails
# the run rather than relying on a human spotting one line in forty.
[ "${RESULT#!!}" = "$RESULT" ] || exit 1
exit 0

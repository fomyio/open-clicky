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
ATTEMPT=0
if ! swift build --build-tests >/dev/null 2>&1; then
  RESULT="does not compile (invariant is structural)"
else
  # One passing run is not evidence that nothing objected.
  #
  # Some mutations are detected probabilistically, because what they break is
  # observed through something the suite does not control. Removing `.sortedKeys`
  # from the transcript encoder leaves the key order to Swift's per-process
  # dictionary seed, so the test that reads the order agrees with the mutation about
  # one run in three; removing the environment scrub is caught by a test that sets
  # ANTHROPIC_API_KEY, which the credential suite unsets and restores in parallel, so
  # a quarter of runs launch the child during that window and see nothing to leak.
  # Measured on one binary built once and run twenty times: 7/20 and 5/20 spurious
  # NOT CAUGHT respectively — which is why a full sweep failed on a different entry
  # every time and every failing entry passed under --only.
  #
  # Re-running only when a run reports nothing costs a green sweep nothing: the extra
  # runs are spent solely on entries that are about to be declared undefended, and
  # those are the ones worth spending on. The direction is safe by construction — a
  # retry can only turn NOT CAUGHT into caught, never the reverse — but it does give a
  # test that fails on its own four chances instead of one to be mistaken for a
  # detection, so a catch that needed a retry says so rather than passing for a clean
  # one.
  ATTEMPTS="${MUTATION_TEST_ATTEMPTS:-4}"
  while true; do
    ATTEMPT=$((ATTEMPT + 1))
    OUT=$(swift test 2>&1)
    STATUS=$?
    N=$(echo "$OUT" | grep -cE '^✘ Test "')
    if [ "$N" -gt 0 ] || [ "$STATUS" -ne 0 ]; then break; fi
    if [ "$ATTEMPT" -ge "$ATTEMPTS" ]; then break; fi
  done
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
  # Reported, not swallowed. A detector that agrees with the mutation some of the time
  # is a defect in the test, and the only moment it is visible is the run that needed
  # the retry — silence here is how it stays that way.
  if [ "$ATTEMPT" -gt 1 ] && [ "${RESULT#!!}" = "$RESULT" ]; then
    RESULT="$RESULT — only on run $ATTEMPT of $ATTEMPTS"
  elif [ "$RESULT" = "!! NOT CAUGHT" ]; then
    RESULT="!! NOT CAUGHT (in $ATTEMPTS runs)"
  fi
fi
printf "  %-44s %s\n" "$LABEL" "$RESULT"
# The exit code is what the sweep totals up, so a mutation nothing objects to fails
# the run rather than relying on a human spotting one line in forty.
[ "${RESULT#!!}" = "$RESULT" ] || exit 1
# Same reasoning for a detection that took more than one run: the invariant is
# defended, so this is not a failure, but "All invariants are defended" printed under
# a line nobody read is the same false reassurance in a friendlier voice. 4 is the
# sweep's cue to name it in the summary.
[ "$ATTEMPT" -le 1 ] || exit 4
exit 0

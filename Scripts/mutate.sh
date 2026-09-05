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
    print('TARGET-NOT-FOUND'); raise SystemExit(2)
open(p,'w').write(s.replace(old, new, 1))
" "$FILE" "$OLD" "$NEW" || { cp /tmp/mut.bak "$FILE"; printf "  %-44s %s\n" "$LABEL" "target not found"; exit 0; }
OUT=$(swift test 2>&1)
if echo "$OUT" | grep -q "error:"; then
  RESULT="does not compile (invariant is structural)"
else
  N=$(echo "$OUT" | grep -cE '^✘ Test "')
  [ "$N" -gt 0 ] && RESULT="caught by $N test(s)" || RESULT="!! NOT CAUGHT"
fi
printf "  %-44s %s\n" "$LABEL" "$RESULT"

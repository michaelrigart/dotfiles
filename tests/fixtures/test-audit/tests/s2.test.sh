#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/s2.ran"
. "$here/../bin/s.sh"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; fi; }

check "add handles a one" "$(add 1 1)" 2
check "p.py doubles" "$(python3 "$here/../bin/p.py" 4)" 8
check "p.py doubles" "$(python3 "$here/../bin/p.py" 5)" 10
check "add handles zero" "$(add 0 0)" 0

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

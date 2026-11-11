#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/s.ran"
. "$here/../bin/s.sh"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; fi; }

check "add returns the sum" "$(add 2 3)" 5
FLAG=off
flag
check "flag is set" "$FLAG" on
check "greet says hello" "$(greet)" hello
d=$(scratch)
[ -d "$d" ] && ok "scratch dir exists at $d" || bad "scratch dir exists at $d"
rm -rf "$d"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

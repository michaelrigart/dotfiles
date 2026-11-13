#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$here/.." && pwd)
FRAG="$SRC/docs"
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/pins.ran"
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
[ -n "${AUDIT_MARKERS:-}" ] && [ -e "$AUDIT_MARKERS/red-now" ] && _fail "forced red" "marker"
need() { # need <fragment> <fixed text> <label>
  if grep -qF -- "$2" "$FRAG/$1"; then _pass "$3"; else _fail "$3" "missing: $2"; fi
}
need_flat() { # need_flat <fragment> <fixed text> <label>
  if tr '\n' ' ' < "$FRAG/$1" | tr -s ' ' | grep -qF -- "$2"; then _pass "$3"; else _fail "$3" "missing: $2"; fi
}
need_in() { # need_in <path under $SRC> <fixed text> <label>
  if [ ! -f "$SRC/$1" ]; then _fail "$3" "missing file: $1"
  elif tr '\n' ' ' < "$SRC/$1" | tr -s ' ' | grep -qF -- "$2"; then _pass "$3"
  else _fail "$3" "missing: $2"; fi
}
R=docs/rules.md
need_in "$R" 'Never push, delete or merge without asking.' "the confirm rule asks first"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

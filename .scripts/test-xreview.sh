#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview — the review round cap.
#
# Rounds iterate until the models converge or genuinely disagree, so the cap is the only
# thing standing between "iterate" and "loop until the usage limit does it for you". It
# is asserted as an exact refusal at an exact round, not as "eventually stops".
set -uo pipefail
XREVIEW="$(cd "$(dirname "$0")/.." && pwd)/dot_local/bin/executable_xreview"
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xreview.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init
printf 'body\n' > b.md

# A fake thread makes `codex queue` fail after the round has been counted, which is
# exactly the boundary under test: the cap must bind before the turn is spent.
capped() { bash "$XREVIEW" dispatch faketh b.md 2>&1 | grep -c 'exceeds the cap'; }

is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
capped >/dev/null; capped >/dev/null; capped >/dev/null
is "three rounds are permitted"   "$(bash "$XREVIEW" round)" 3
is "the fourth round is refused"  "$(capped)"                1
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 4

bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
is "dispatch is permitted again after reset" "$(capped)" 0

XREVIEW_MAX_ROUNDS=1; export XREVIEW_MAX_ROUNDS
bash "$XREVIEW" round --reset >/dev/null
capped >/dev/null
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(capped)" 1
unset XREVIEW_MAX_ROUNDS

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

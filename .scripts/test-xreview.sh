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
# Global config signs commits; a fixture that inherits it fails wherever the signing
# key is unavailable, and an unasserted setup failure would let the suite run against
# a broken fixture and still report green.
git config commit.gpgsign false
git commit -q --allow-empty -m init || { printf 'fixture setup failed\n' >&2; exit 1; }
printf 'body\n' > b.md

# A fake thread makes `codex queue` fail after the round has been counted, which is
# exactly the boundary under test: the cap must bind before the turn is spent.
capped() { bash "$XREVIEW" dispatch faketh b.md 2>&1 | grep -c 'exceeds the cap'; }

# `capped` is 0 when the dispatch went through and 1 when it was refused. Assert on
# THAT, not on the counter: a refused round still increments, so "the counter reached
# ten" is true at any cap and proves nothing about where the boundary sits.
# The default boundary is only the default when nothing overrides it. Inheriting
# XREVIEW_MAX_ROUNDS from whoever ran the suite makes this section assert the shipped
# number against someone else's, and it fails for a reason that has nothing to do with
# the code. The override gets its own section further down, where it is set on purpose.
unset XREVIEW_MAX_ROUNDS

is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 9); do capped >/dev/null; done
is "nine rounds are permitted"       "$(bash "$XREVIEW" round)" 9
is "the tenth round is still allowed" "$(capped)"               0
is "the eleventh round is refused"    "$(capped)"               1
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11

bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
is "dispatch is permitted again after reset" "$(capped)" 0

XREVIEW_MAX_ROUNDS=1; export XREVIEW_MAX_ROUNDS
bash "$XREVIEW" round --reset >/dev/null
capped >/dev/null
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(capped)" 1
unset XREVIEW_MAX_ROUNDS

# SQL boundary. The nonce reaches a LIKE pattern, where _ and % are wildcards: a nonce
# of xr-________-________ would otherwise match turns it was never minted for.
refused() { bash "$XREVIEW" collect "$1" "$2" 1 2>&1 | grep -c 'refusing'; }
is "a quote in the thread id is refused"    "$(refused "a'; DROP--" xr-abc)" 1
is "a quote in the nonce is refused"        "$(refused abc "xr-'; DROP--")" 1
is "a LIKE _ wildcard nonce is refused"     "$(refused abc "xr-________")"  1
is "a LIKE % wildcard nonce is refused"     "$(refused abc "xr-%")"         1
is "a path traversal thread id is refused"  "$(refused "../../etc/passwd" xr-abc)" 1
is "an underscore in the thread id is fine" "$(refused "msg_03d99e" xr-abc)" 0

# sqlite3 silently creates an empty database for a missing path, which would turn
# "Codex has not written this yet" into a confusing "no such table".
missing="$ROOT/no-codex-home"
out="$(CODEX_HOME="$missing" bash "$XREVIEW" collect 01a05422 xr-abc 1 2>&1)"
is "a missing history store is reported" "$(printf '%s' "$out" | grep -c 'history store not found')" 1
is "a missing history store is not created" "$([ -e "$missing/thread_history_1.sqlite" ] && echo yes || echo no)" no

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

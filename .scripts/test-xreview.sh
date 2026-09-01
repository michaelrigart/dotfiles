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

# --- inline diffs (dispatch --diff) ------------------------------------------
#
# A dispatch that names a path makes the reviewer go and read it, and every search and
# open is a full-context model step. Measured 2026-09-01 across 69 real reviews: ~16
# model steps and ~2.0M tokens per review, with the per-turn cost barely moving between
# an 8-turn thread and a 37-turn one — so the steps, not the thread length, are where
# the allowance goes. Carrying the diff in the message lets the reviewer answer from
# what it was handed.
# Derive the state dir from git's own idea of the root, not from $ROOT: on macOS
# mktemp hands back /tmp/... while git resolves the symlink to /private/tmp/..., and
# a hand-built path would seed fixtures into a directory the script never reads.
STATE="$XDG_STATE_HOME/xreview/$(git rev-parse --show-toplevel | tr '/' '_' | sed 's|^_||')"

printf 'change\n' > tracked.txt && git add tracked.txt
git commit -q -m "a change to review"
bash "$XREVIEW" round --reset >/dev/null 2>&1

rm -f b.md.wrapped
bash "$XREVIEW" dispatch --diff HEAD~1..HEAD faketh b.md >/dev/null 2>&1
if grep -q 'tracked.txt' b.md.wrapped 2>/dev/null; then
  _pass "--diff carries the diff text in the dispatched message"
else
  _fail "--diff carries the diff text in the dispatched message" "$(head -c 120 b.md.wrapped 2>/dev/null)"
fi
if grep -q 'body' b.md.wrapped 2>/dev/null; then
  _pass "--diff keeps the caller's body as well as the diff"
else
  _fail "--diff keeps the caller's body as well as the diff" "body text missing"
fi

# An oversized diff is refused, never truncated: a reviewer handed half a change
# reviews half a change and reports no findings on the rest.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --diff HEAD~1..HEAD faketh b.md 2>&1)
is "an oversized diff is refused rather than truncated" "$(printf '%s' "$out" | grep -c 'too large')" 1

# An unusable range must fail loudly rather than dispatching an empty review.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --diff no-such-ref..HEAD faketh b.md 2>&1)
is "an unresolvable diff range is refused" "$(printf '%s' "$out" | grep -c 'cannot diff')" 1

# A valid range that resolves to nothing is the more dangerous case than a broken one:
# git exits 0, so an unguarded dispatch would send an empty review and the reviewer
# would truthfully report no findings — indistinguishable from a clean review.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --diff HEAD..HEAD faketh b.md 2>&1)
is "an empty but valid range is refused" "$(printf '%s' "$out" | grep -c 'nothing to review')" 1

# --- thread rotation ---------------------------------------------------------
#
# Every dispatch queues into one cached thread per repo, so round N is read by a
# reviewer holding rounds 1..N-1 — including its own earlier findings and every
# artifact already sent. The cold-ask rule is what makes the second opinion worth
# having, and a thread that never rotates quietly voids it. --reset ends a checkpoint,
# so it drops the thread as well as the counter.
mkdir -p "$STATE" && printf 'stale-thread-id\n' > "$STATE/thread"
bash "$XREVIEW" round --reset >/dev/null 2>&1
if [ -e "$STATE/thread" ]; then
  _fail "round --reset drops the cached thread, not just the counter" "thread file survived"
else
  _pass "round --reset drops the cached thread, not just the counter"
fi

# Nothing signalled that one chezmoi thread had absorbed 37 reviews. A warning is the
# right shape rather than a refusal: rotating means starting a Codex session by hand,
# and a guard that blocks work it cannot itself complete gets switched off.
bash "$XREVIEW" round --reset >/dev/null 2>&1
: > "$STATE/reviews.jsonl"
for _ in $(seq 8); do
  printf '{"ts":"t","branch":"b","head":"h","thread":"faketh","nonce":"n"}\n' >> "$STATE/reviews.jsonl"
done
out=$(bash "$XREVIEW" dispatch faketh b.md 2>&1)
is "a thread past the review threshold warns that it is no longer cold" \
   "$(printf '%s' "$out" | grep -c 'no longer cold')" 1

# The warning counts reviews on THIS thread, not every review in the repo — otherwise
# rotating the thread would not clear it and the warning would be permanent noise.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch other-thread b.md 2>&1)
is "the warning is scoped to the thread, so rotating clears it" \
   "$(printf '%s' "$out" | grep -c 'no longer cold')" 0

# --- reviewer tier (model/effort) before dispatch -----------------------------
#
# Codex records the model and reasoning effort of every turn in its rollout file, one
# `turn_context` record per turn, so the LAST one is the setting a dispatch would
# actually reach. A real 168-turn review session read gpt-5.6-sol/xhigh on all 168 —
# the top tier was never once stepped down for a narrow verification round, and nothing
# in the workflow said so out loud.
export CODEX_HOME="$ROOT/codex"
ROLL="$CODEX_HOME/sessions/2026/09/01"
mkdir -p "$ROLL"
tc() { printf '{"type":"turn_context","payload":{"model":"%s","effort":"%s"}}\n' "$1" "$2"; }
{ tc gpt-5.6-sol xhigh; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"

is "tier reports the thread's model and effort" \
   "$(bash "$XREVIEW" tier faketh 2>&1)" "gpt-5.6-sol/xhigh"

# A mid-session /model switch writes a further turn_context, so the last record wins.
# Reading the first would report the setting the session opened with and silently miss
# every change the user made since.
{ tc gpt-5.6-sol xhigh; tc gpt-5.6-terra high; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"
is "tier reflects a mid-session switch, not the opening setting" \
   "$(bash "$XREVIEW" tier faketh 2>&1)" "gpt-5.6-terra/high"

# The point of the check: refuse before spending the turn, naming both sides, so there
# is time to change it. A warning after the fact would be a report on money already gone.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --expect gpt-5.6-sol/xhigh faketh b.md 2>&1)
is "a tier mismatch refuses the dispatch" "$(printf '%s' "$out" | grep -c 'reviewer tier')" 1
is "the refusal names what is set now"    "$(printf '%s' "$out" | grep -c 'gpt-5.6-terra/high')" 1
is "the refusal names what was expected"  "$(printf '%s' "$out" | grep -c 'gpt-5.6-sol/xhigh')" 1

# A matching tier must not obstruct: the round is spent, so the dispatch proceeds.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --expect gpt-5.6-terra/high faketh b.md 2>&1)
is "a matching tier does not block the dispatch" "$(printf '%s' "$out" | grep -c 'reviewer tier')" 0

# Effort alone is the common case — same model, cheaper round.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --expect /xhigh faketh b.md 2>&1)
is "an effort-only expectation still catches a mismatch" "$(printf '%s' "$out" | grep -c 'reviewer tier')" 1

# Fail open. If the tier cannot be read there is no evidence of a mismatch, and a check
# that blocks reviews whenever Codex changes its on-disk layout would be turned off.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --expect gpt-5.6-sol/xhigh no-rollout-thread b.md 2>&1)
is "an unreadable tier does not block the dispatch" "$(printf '%s' "$out" | grep -c 'reviewer tier')" 0

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

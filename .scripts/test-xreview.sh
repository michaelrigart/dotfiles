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
# Name the command. It is `/models`, plural, and it is a picker rather than a command
# taking the model as an argument — Codex documents an inline form for /goal, /ide,
# /keymap, /mcp, /pwd, /raw, /sandbox and /usage, and none for this one. "Change the
# model" would send the reader looking for a `/model <name>` that does not exist.
is "the refusal names the /models command" "$(printf '%s' "$out" | grep -c '/models')" 1

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

# --- the tier is recorded, so a lazy recommendation is visible -----------------
#
# --expect only checks the pane against what the caller asked for. Ask for the top tier
# every time and the check confirms the top tier every time and reports success — it
# catches a mis-set pane, never a caller that stopped choosing. That is the failure
# already on record: 168 consecutive turns at sol/xhigh, not chosen so much as never
# reconsidered. Recording the tier each review actually ran at turns "is anyone still
# picking?" into something countable rather than something to take on trust.
mkdir -p "$STATE"
: > "$STATE/reviews.jsonl"
{ tc gpt-5.6-terra high; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"
printf '{"ts":"t","branch":"b","head":"h","thread":"faketh","nonce":"n","tier":"gpt-5.6-sol/xhigh"}\n' \
  >> "$STATE/reviews.jsonl"
is "receipts expose the tier a review ran at" \
   "$(bash "$XREVIEW" receipts 2>/dev/null | jq -r '.tier' | head -1)" "gpt-5.6-sol/xhigh"

# The summary is the part a person reads. A run of one tier is the thing to notice, so
# it has to be visible without piping receipts through jq by hand.
for _ in $(seq 4); do
  printf '{"ts":"t","branch":"b","head":"h","thread":"faketh","nonce":"n","tier":"gpt-5.6-sol/xhigh"}\n' \
    >> "$STATE/reviews.jsonl"
done
out=$(bash "$XREVIEW" receipts --tiers 2>&1)
is "the tier summary counts each tier"  "$(printf '%s' "$out" | grep -c 'gpt-5.6-sol/xhigh')" 1
is "the tier summary shows the count"   "$(printf '%s' "$out" | grep -oE '[0-9]+' | head -1)" 5

# A receipt written before this field existed must not break the summary.
printf '{"ts":"t","branch":"b","head":"h","thread":"faketh","nonce":"n"}\n' >> "$STATE/reviews.jsonl"
out=$(bash "$XREVIEW" receipts --tiers 2>&1)
is "a receipt with no tier is counted as unrecorded" \
   "$(printf '%s' "$out" | grep -ci 'unrecorded')" 1

# Drive a real collect, so the code that WRITES the tier is exercised rather than a
# hand-seeded line that would pass with the field never populated at all. Every guard
# above reads receipts the test wrote itself; only this one proves record_receipt fills
# the field from the thread's actual rollout.
: > "$STATE/reviews.jsonl"
{ tc gpt-5.6-terra high; } > "$ROLL/rollout-2026-09-01T10-00-00-collectth.jsonl"
DB="$CODEX_HOME/thread_history_1.sqlite"
sqlite3 "$DB" "CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INT, status TEXT,
                 first_user_item_id TEXT, final_agent_item_id TEXT);
               CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, item_json TEXT);
               INSERT INTO thread_turns VALUES ('collectth', 1, 'completed', 'u1', 'a1');
               INSERT INTO thread_items VALUES ('collectth','u1','{\"text\":\"xr-testnonce\"}');
               INSERT INTO thread_items VALUES ('collectth','a1','{\"text\":\"the review\"}');" 2>/dev/null
is "collect returns the reviewer's answer" \
   "$(bash "$XREVIEW" collect collectth xr-testnonce 2>&1)" "the review"
is "the receipt records the tier the review actually ran at" \
   "$(bash "$XREVIEW" receipts 2>/dev/null | jq -r '.tier' | tail -1)" "gpt-5.6-terra/high"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

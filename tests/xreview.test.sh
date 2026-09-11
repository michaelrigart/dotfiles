#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview — the review round cap.
#
# Rounds iterate until the models converge or genuinely disagree, so the cap is the only
# thing standing between "iterate" and "loop until the usage limit does it for you". It
# is asserted as an exact refusal at an exact round, not as "eventually stops".
set -uo pipefail
XREVIEW="$(cd "$(dirname "$0")/.." && pwd)/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing CLI under test: $XREVIEW" >&2; exit 2; }
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

# --- reviewer tier is reported, never enforced --------------------------------
#
# Codex records the model and reasoning effort of every turn in its rollout file, one
# `turn_context` record per turn, so the LAST one is the setting a dispatch would
# actually reach. That is worth reporting and worth recording in a receipt; it is not
# worth blocking on, which is what the removed --expect gate did — it refused every
# dispatch whose model name was not in a hard-coded table, so each new model release
# broke every review until someone edited the table.
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

# A dispatch must go out whatever the pane is set to. Everywhere else in this suite
# `codex queue` is left to fail on the fake thread; here it has to succeed, because the
# assertion is that a nonce comes back — i.e. that the turn was actually queued and not
# refused on the way in.
STUB="$ROOT/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/codex"; chmod +x "$STUB/codex"
OLD_PATH="$PATH"; PATH="$STUB:$PATH"

bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch faketh b.md 2>&1)
is "a dispatch is never refused over the tier" "$(printf '%s' "$out" | grep -ci 'reviewer tier')" 0
is "a dispatch at any tier returns a nonce"    "$(printf '%s' "$out" | grep -c '^xr-')" 1

# The rollout above reads gpt-5.6-terra/high. An unfamiliar model must be just as
# acceptable, because the failure being fixed is a gate that treated "a model I have not
# heard of" as an error and so broke every review on the day a new one shipped.
bash "$XREVIEW" round --reset >/dev/null 2>&1
{ tc astra-9 medium; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"
out=$(bash "$XREVIEW" dispatch faketh b.md 2>&1)
is "a model the table never knew about still dispatches" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "and it is reported, not judged" "$(bash "$XREVIEW" tier faketh 2>&1)" "astra-9/medium"

# --expect is gone from the CLI entirely, not merely ignored: a flag that silently does
# nothing is worse than one that does not exist, because callers keep passing it and
# believing it checked something. With no handler it lands as a thread id, so the
# dispatch fails outright rather than quietly queueing to the wrong place.
bash "$XREVIEW" round --reset >/dev/null 2>&1
out=$(bash "$XREVIEW" dispatch --expect astra-9/medium faketh b.md 2>&1); rc=$?
is "--expect is rejected, not absorbed" "$rc" 1
is "and no review is queued for it"     "$(printf '%s' "$out" | grep -c '^xr-')" 0
is "no --expect handling survives in the source" \
   "$(grep -c -- '--expect' "$XREVIEW")" 0

PATH="$OLD_PATH"

# --- thread resolution ---------------------------------------------------------
# A cached thread id proves a thread EXISTED, not that anything is alive to answer on
# it. Codex has no session id until its first turn, so a pane that has just been built
# reports none — and the fallback for "no live id" then handed back a thread cached
# weeks earlier. `codex queue` accepts it, because the id is well formed, and the packet
# lands in a dead session: nothing appears in the pane, and `collect` waits out its full
# budget against a thread the dispatch never used. Observed 2026-09-11, when a review
# went to a thread cached on 31 August while the live pane sat empty.
TRES="$ROOT/tres"; mkdir -p "$TRES"
AGENTS="$ROOT/agents.json"; export AGENTS
cat > "$TRES/herdr" <<'H'
#!/bin/sh
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then cat "$AGENTS"; fi
exit 0
H
chmod +x "$TRES/herdr"
OLD_PATH="$PATH"; PATH="$TRES:$PATH"
CWD="$(git rev-parse --show-toplevel)"
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$STATE"

agents() { # agents <session-json>
  printf '{"result":{"agents":[{"agent":"codex","cwd":"%s","agent_session":%s}]}}\n' \
    "$CWD" "$1" > "$AGENTS"
}

# A live pane with a thread resolves to that thread, and supersedes a stale record.
printf 'stale-thread-id\n' > "$STATE/thread"
agents '{"value":"live-thread-id"}'
is "a live pane supersedes the cached thread" "$(bash "$XREVIEW" thread)" "live-thread-id"
is "and the cache is rewritten to it"         "$(cat "$STATE/thread")"    "live-thread-id"

# The regression: pane present, no session yet, stale record on disk.
printf 'stale-thread-id\n' > "$STATE/thread"
agents 'null'
out=$(bash "$XREVIEW" thread 2>&1); rc=$?
is "a pane with no thread yet is refused, not served from cache" "$rc" 1
is "and the stale id is never printed" "$(printf '%s' "$out" | grep -c 'stale-thread-id')" 0
is "the refusal says what to do about it" \
   "$(printf '%s' "$out" | grep -c 'no thread yet')" 1

# A dispatch must refuse for the same reason rather than queueing into the dead thread.
# `codex` is stubbed to SUCCEED here on purpose: everywhere else in this suite `codex
# queue` fails on the fake thread, so a non-zero dispatch would prove nothing about where
# the refusal came from. With the queue working, only thread resolution can refuse.
printf '#!/bin/sh\nexit 0\n' > "$TRES/codex"; chmod +x "$TRES/codex"
bash "$XREVIEW" round --reset >/dev/null 2>&1
printf 'stale-thread-id\n' > "$STATE/thread"
out=$(bash "$XREVIEW" dispatch b.md 2>&1); rc=$?
is "a dispatch onto a threadless pane is refused" "$rc" 1
is "and mints no nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 0
is "and it is refused for the thread, not the queue" \
   "$(printf '%s' "$out" | grep -c 'no thread yet')" 1

# An explicit override still wins: it is the documented escape hatch, and the pane state
# is not allowed to veto it.
printf 'stale-thread-id\n' > "$STATE/thread"
is "XREVIEW_THREAD overrides pane state" \
   "$(XREVIEW_THREAD=pinned-id bash "$XREVIEW" thread)" "pinned-id"

# Deliberately unchanged: with no pane list at all there is nothing to contradict the
# record, and `xreview init <id>` exists to pin a thread herdr cannot see. Only a pane
# that is present AND threadless is proof the record is dead.
printf 'stale-thread-id\n' > "$STATE/thread"
printf '{"result":{"agents":[]}}\n' > "$AGENTS"
is "a pane list with no Codex pane still uses the cached thread" \
   "$(bash "$XREVIEW" thread)" "stale-thread-id"

# herdr present but failing - server down, socket denied, mid-restart. Under `set -e` the
# non-zero pipeline killed xreview outright: rc=1, no message, and a caller that cannot
# tell a dead tool from a dead thread. Driven by a stub rather than by whatever the
# ambient herdr happens to do, so the assertion means the same thing on every machine.
cat > "$TRES/herdr" <<'H'
#!/bin/sh
exit 1
H
chmod +x "$TRES/herdr"
printf 'stale-thread-id\n' > "$STATE/thread"
out=$(bash "$XREVIEW" thread 2>&1); rc=$?
is "a failing herdr does not abort xreview"        "$rc" 0
is "it falls back to the cached thread instead"    "$out" "stale-thread-id"

rm -f "$STATE/thread"
PATH="$OLD_PATH"

# --- the tier is still recorded, because reporting is not enforcing ------------
#
# Dropping the gate must not drop the record. Which tier reviews actually ran at stays
# countable — it is the only way to answer "is anyone still picking?" — but nothing acts
# on it, and no dispatch is refused because of it.
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

# --- running out of budget is two different outcomes --------------------------
#
# Collapsing them into one "ambiguous, do NOT retry" is what made long reviews look like
# failures: a turn that is on record and still running has demonstrably not been lost, so
# waiting longer is correct. Only a nonce with no turn against it is ambiguous — the queue
# may never have landed — and that is the one a caller must not turn into a re-dispatch.
sqlite3 "$DB" "INSERT INTO thread_turns VALUES ('collectth', 2, 'in_progress', 'u2', NULL);
               INSERT INTO thread_items VALUES ('collectth','u2','{\"text\":\"xr-slownonce\"}');" 2>/dev/null

out=$(bash "$XREVIEW" collect collectth xr-slownonce 0 2>&1); rc=$?
is "a still-running turn exits 3, not 1"        "$rc" 3
is "and says it is still running"               "$(printf '%s' "$out" | grep -ci 'still running')" 1
is "and does not call it ambiguous"             "$(printf '%s' "$out" | grep -ci 'ambiguous')" 0
is "and tells the caller how to keep waiting"   "$(printf '%s' "$out" | grep -c 'xreview collect xr-slownonce')" 1

out=$(bash "$XREVIEW" collect collectth xr-nosuchnonce 0 2>&1); rc=$?
is "a nonce with no turn on record exits 1"     "$rc" 1
is "and is the one called ambiguous"            "$(printf '%s' "$out" | grep -ci 'ambiguous')" 1
is "and is the one told not to retry"           "$(printf '%s' "$out" | grep -ci 'do NOT retry')" 1

# The default budget is the patience limit, not a verdict. 900s was short enough that
# reviews still working were being abandoned and escalated as timeouts.
is "the default collect budget is at least 30 minutes" \
   "$(grep -E '^COLLECT_BUDGET_DEFAULT=' "$XREVIEW" | cut -d= -f2 | awk '{print ($1 >= 1800)}')" 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

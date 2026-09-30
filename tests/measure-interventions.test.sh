#!/usr/bin/env bash
# Tests for .scripts/measure-interventions.py against a tiny synthetic transcript tree.
#
# The fixture is written at runtime with timestamps relative to NOW, so the --days window
# means the same thing on every run. Each entry exists to pin one counting rule: what is
# a genuine human turn and what is not, which tool results are denials, what a sandbox
# escape and an xreview failure look like, and how an autonomous stretch is measured.
#
#   ./tests/measure-interventions.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/.scripts/measure-interventions.py"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/measure.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PROJ="$ROOT/projects/-Users-x-Code-demo"
mkdir -p "$PROJ/sess-a/subagents"

# The system python on purpose: the script must run on what every Mac has.
/usr/bin/python3 - "$PROJ" <<'PY'
import datetime, json, os, sys, time
proj = sys.argv[1]
now = time.time()
t0 = now - 3600
def ts(offset_min):
    return datetime.datetime.fromtimestamp(t0 + offset_min * 60, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def human(m, text):
    return {"type": "user", "timestamp": ts(m), "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}
def tool_use(tid, name, inp):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}
def result(tid, text, err=True):
    return {"type": "tool_result", "tool_use_id": tid, "is_error": err, "content": text}
main = [
    # a human turn from 30 days ago: outside the 14-day window, never counted
    {"type": "user", "timestamp": datetime.datetime.fromtimestamp(now - 30 * 86400, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
     "origin": {"kind": "human"}, "message": {"role": "user", "content": "ancient"}},
    human(0, "start the task"),                                      # human turn 1 (the first)
    {"type": "assistant", "timestamp": ts(1), "message": {"role": "assistant", "content": [
        {"type": "text", "text": "working"},
        tool_use("t1", "Bash", {"command": "ls", "dangerouslyDisableSandbox": True}),
        # the form the cross-review skill teaches: the dispatch inside $( ... )
        tool_use("t2", "Bash", {"command": "NONCE=$(xreview dispatch --checkpoint plan --diff a..b b.md)"}),
        tool_use("t3", "Read", {"file_path": "/x"}),
        tool_use("t4", "Bash", {"command": "xreview collect xr-1-abc 60"}),
        tool_use("t5", "Bash", {"command": "rg \"xreview dispatch\" docs/"}),   # a mention, not a call
        # single-quoted, so never executed: the form the skill teaches, printed as text
        tool_use("t6", "Bash", {"command": "printf %s 'NONCE=$(xreview dispatch --checkpoint plan b.md)'"}),
    ]}},
    {"type": "user", "timestamp": ts(2), "message": {"role": "user", "content": [
        result("t1", "ok", err=False),
        result("t2", "Exit code 1\nxreview: the Codex pane is mid-turn"),
        result("t3", "Compound command starting with `cd`.\n\nA compound command..."),
        result("t4", "{\"verdict\":\"approve\",\"findings\":[]}", err=False),
        result("t5", "docs/x.md: xreview dispatch", err=False),
        result("t6", "NONCE=$(xreview dispatch --checkpoint plan b.md)", err=False),
    ]}},
    {"type": "user", "timestamp": ts(3), "message": {"role": "user", "content": [
        result("t9", "Permission for this action was denied by the Claude Code auto mode classifier. Reason: x"),
    ]}},
    # an error that merely QUOTES a guard message is not a denial
    {"type": "user", "timestamp": ts(4), "message": {"role": "user", "content": [
        result("t8", "grep: Compound command starting with `cd` appears in guard.sh"),
    ]}},
    {"type": "attachment", "timestamp": ts(5), "attachment": {                  # human turn 2 (queued)
        "type": "queued_command", "prompt": "also do y", "origin": {"kind": "human"}}},
    {"type": "user", "timestamp": ts(6), "origin": {"kind": "peer", "from": "a1"},  # not human
     "message": {"role": "user", "content": "peer says hi"}},
    {"type": "user", "timestamp": ts(7), "origin": {"kind": "task-notification"},   # not human
     "message": {"role": "user", "content": "<task-notification>done</task-notification>"}},
    {"type": "user", "timestamp": ts(8), "isMeta": True, "origin": {"kind": "human"},  # not human
     "message": {"role": "user", "content": "meta"}},
    {"type": "user", "timestamp": ts(9), "origin": {"kind": "human"},               # an interrupt
     "message": {"role": "user", "content": "[Request interrupted by user]"}},
    human(10, "next step"),                                          # human turn 3
    "this line is not JSON",
]
with open(os.path.join(proj, "sess-a.jsonl"), "w") as fh:
    for e in main:
        fh.write((e if isinstance(e, str) else json.dumps(e)) + "\n")
sub = [
    {"type": "assistant", "timestamp": ts(1), "message": {"role": "assistant", "content": [
        tool_use("s1", "Bash", {"command": "rg foo .", "dangerouslyDisableSandbox": True})]}},
    {"type": "user", "timestamp": ts(2), "message": {"role": "user", "content": [
        result("s1", "Recursive search rooted at `.`.")]}},
    # a subagent prompt with a human origin is still not one of Michael's turns
    human(3, "subagent brief"),
]
with open(os.path.join(proj, "sess-a", "subagents", "agent-1.jsonl"), "w") as fh:
    for e in sub:
        fh.write(json.dumps(e) + "\n")
# a whole session last touched 30 days ago
old = os.path.join(proj, "sess-old.jsonl")
with open(old, "w") as fh:
    fh.write(json.dumps(human(0, "recent-looking but the file is old")) + "\n")
os.utime(old, (now - 30 * 86400, now - 30 * 86400))
PY

OUT="$(/usr/bin/python3 "$SCRIPT" --days 14 --projects-dir "$ROOT/projects" 2>&1)"; rc=$?
is() { # is <jq filter> <expected> <label>
  local got; got="$(printf '%s' "$OUT" | jq -r "$1" 2>&1)"
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
[ "$rc" -eq 0 ] && _pass "runs on the system python and exits 0" || _fail "runs on the system python and exits 0" "rc=$rc: $OUT"
is '.sessions'                        1   "only sessions active in the window count"
is '.human_turns.total'               3   "human turns: typed, queued and typed again"
is '.human_turns.after_first'         2   "the first turn of a session is not an intervention"
is '.human_turns.queued'              1   "a queued_command with a human origin is a human turn"
is '.interrupts'                      1   "an interrupt is counted apart, never as a turn"
is '.sandbox_escapes.main'            1   "a main-session sandbox escape"
is '.sandbox_escapes.subagent'        1   "a subagent sandbox escape"
is '.xreview.dispatches'              1   "an xreview dispatch inside \$( ); a quoted or single-quoted mention is not one"
is '.xreview.dispatch_failures'       1   "an xreview dispatch that failed"
is '.xreview.collects'                1   "an xreview collect"
is '.xreview.collect_failures'        0   "a collect that succeeded is no failure"
is '.xreview.dispatch_failure_rate == 1' true "the dispatch failure rate"
is '.denials["path-resolution-guard"].main'     1 "a guard denial, main session"
is '.denials["path-resolution-guard"].subagent' 1 "a guard denial, subagent"
is '.denials["classifier-deny"].main' 1   "a classifier denial"
is '[.denials[][]] | add'             3   "a quoted guard message is not a denial"
is '.autonomous_stretch.n'            1   "one stretch closed by a turn the agent waited for"
is '.autonomous_stretch.tool_calls.median == 6' true "the stretch counts every tool call since the last turn"
is '.autonomous_stretch.minutes.median == 4' true "the stretch runs to the last agent activity"

out="$(/usr/bin/python3 "$SCRIPT" --days 0 --projects-dir "$ROOT/projects" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && _pass "--days 0 is a usage error" || _fail "--days 0 is a usage error" "rc=$rc"
out="$(/usr/bin/python3 "$SCRIPT" --projects-dir "$ROOT/nope" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && _pass "a missing projects dir is a usage error" || _fail "a missing projects dir is a usage error" "rc=$rc"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

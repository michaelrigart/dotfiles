#!/usr/bin/env bash
# Tests for the herdr-app resume helpers. Run: ./tests/herdr-app-resume.test.sh
set -uo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
H=$SRC/dot_config/herdr-app/bin/executable_session-running
D=$SRC/dot_config/herdr-app/mods/resume/decide.js
J=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
for f in "$H" "$D"; do
  [ -f "$f" ] || { echo "missing ${f#"$SRC"/}" >&2; exit 2; }
done
[ -x "$J" ] || { echo "INCONCLUSIVE: no jsc" >&2; exit 2; }
root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-app-resume.XXXXXX") || exit 1
trap 'rm -rf "$root"' EXIT
export HOME=$root
unset CODEX_HOME

passed=0 total=0
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  total=$((total + 1))
  if "$@"; then passed=$((passed + 1)); echo "  PASS: $what"; else echo "  FAIL: $what"; fi
}
rc() { "$H" "$@" >/dev/null 2>&1; echo $?; }

# --- session-running ------------------------------------------------------------------------
c=11111111-1111-4111-8111-111111111111 x=22222222-2222-4222-8222-222222222222 u=33333333-3333-4333-8333-333333333333
mkdir -p "$HOME/.claude/sessions" "$HOME/.codex/sessions/2026/11/15" "$HOME/.config/herdr"
printf '{"pid":1,' > "$HOME/.claude/sessions/1.json"
sleep 60 & live=$!
printf '{"pid":%d,"sessionId":"%s"}' "$live" "$c" > "$HOME/.claude/sessions/$live.json"
check "a Claude session whose registry pid is alive is running" test "$(rc claude $c)" = 0
kill "$live"; wait "$live" 2>/dev/null
check "...and is not once that pid is dead" test "$(rc claude $c)" = 1
f="$HOME/.codex/sessions/2026/11/15/rollout-2026-11-15T00-00-00-$x.jsonl"; : > "$f"
exec 3<"$f"
check "a Codex session whose rollout is held open is running" test "$(rc codex $x)" = 0
exec 3<&-
check "...and is not once it is closed" test "$(rc codex $x)" = 1
printf '{"workspaces":[{"tabs":[{"panes":[{"agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"%s"}}]}]}]}' "$u" > "$HOME/.config/herdr/session.json"
check "a session the herdr TUI keeps is running" test "$(rc codex $u)" = 0

# --- decide.js ------------------------------------------------------------------------------
mkdir -p "$root/decide"
cp "$D" "$root/decide/decide.js"
cat > "$root/decide/test.js" <<'JS'
import { SETTLE, classify, reserve, claim } from "./decide.js";
const check = (what, ok) => print(`  ${ok ? "PASS" : "FAIL"}: ${what}`);
const agent = (id) => ({ app: "claude", id, cwd: "/w", cmd: `claude --resume ${id}`, fresh: "claude" });
const rec = (id, pid, more = {}) => ({ ...agent(id), pid, ...more });
const T = 1000000;

// A core restart or update keeps every terminal: the same root pids.
{
  const saved = { t1: rec("X", 100), t2: rec("Y", 200) };
  const seen = [{ address: "t1", pid: 100, shell: false, now: agent("X") },
                { address: "t2", pid: 200, shell: true, now: null }];
  const r = classify(saved, seen, {}, T);
  check("core restart: nothing is lost", r.lost.length === 0 && !r.again);
  check("core restart: an agent quit in its shell gets the button", r.button.join() === "t2" && r.saved.t2.quit === true);
}
// A loss: every root pid is new.
{
  const saved = { a: rec("X", 100), b: rec("X", 101), q: rec("Y", 102, { quit: true }), e: rec("Z", 103) };
  const seen = [["a", 900], ["b", 901], ["q", 902], ["e", 903]].map(([address, pid]) => ({ address, pid, shell: true, now: null }));
  const r1 = classify(saved, seen, {}, T);
  check("loss: nothing resumes before the new shells settle", r1.lost.length === 0 && r1.again
    && classify(r1.saved, seen, r1.firstSeen, T + SETTLE - 1).lost.length === 0);
  const r2 = classify(r1.saved, seen, r1.firstSeen, T + SETTLE);
  check("loss: settled terminals are lost, a quit one only gets the button", r2.lost.join() === "a,b,e" && r2.button.join() === "q");
  const { go, held } = reserve(r2.lost, r2.saved, seen, new Set(["Z"]));
  check("loss: one terminal per session, none whose session runs elsewhere", go.join() === "a" && held.join() === "b,e");
  const after = claim(r2.saved, go, { firstSeen: r2.firstSeen, sent: true });
  check("claim: the new shell's pid, and sent", after.a.pid === 900 && after.a.sent === true);
  check("a later settle, from the persisted records alone, is held while a's launch is unresolved", reserve(["b"], after, seen, new Set()).go.length === 0);
  const r3 = classify(after, seen, {}, T + SETTLE + 1500);
  check("a resume that did not start falls to the button, not lost again", r3.button.includes("a") && !r3.lost.includes("a"));
  const running = seen.map((s) => (s.address === "a" ? { ...s, now: agent("X") } : s));
  const r4 = classify(after, running, {}, T + 10000);
  check("seen running clears sent", r4.saved.a.sent !== true);
  check("...and the session stays taken while it runs", reserve(["b"], r4.saved, running, new Set()).go.length === 0);
}
JS
out=$("$J" -m "$root/decide/test.js" 2>&1); jrc=$?
printf '%s\n' "$out"
p=$(printf '%s\n' "$out" | grep -c '^  PASS:'); f=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
passed=$((passed + p)); total=$((total + p + f))
if [ "$jrc" -ne 0 ] || [ $((p + f)) -eq 0 ]; then total=$((total + 1)); echo "  FAIL: decide.js test did not run cleanly (jsc exit $jrc)"; fi

echo "$passed/$total passed"
[ "$passed" -eq "$total" ]

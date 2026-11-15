#!/usr/bin/env bash
# Tests for dot_local/bin/executable_codex-memory-share, the exchange of Codex memory inputs
# between two Macs (spec 2026-11-15-hercules-agent-machine section 4), and its LaunchAgent.
# Every case runs the script with a throwaway HOME; nothing touches the real ~/.codex.
#
#   ./tests/codex-memory-share.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/dot_local/bin/executable_codex-memory-share"
PLIST="$SRC/Library/LaunchAgents/be.netronix.codex-memory-share.plist.tmpl"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
[ -f "$PLIST" ] || { echo "missing plist under test: $PLIST" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
ok() { if "${@:2}"; then _pass "$1"; else _fail "$1" "$*"; fi; }
no() { if "${@:2}"; then _fail "$1" "$*"; else _pass "$1"; fi; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/codex-memory-share.XXXXXX")" && pwd -P)"
HOLDER=""
cleanup() { [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

# run: the script under a throwaway HOME $T, as launchd would start it
run() { env -u CODEX_MEMORY_SHARE_LOCKED HOME="$T" "$SCRIPT"; }
# mkman <dir>: <dir>/MANIFEST for the managed files in it, in shasum format, sorted
mkman() {
  local files=() f
  [ -f "$1/raw_memories.md" ] && files+=(raw_memories.md)
  for f in "$1"/rollout_summaries/*.md; do [ -f "$f" ] && files+=("rollout_summaries/${f##*/}"); done
  if [ "${#files[@]}" -eq 0 ]; then : > "$1/MANIFEST"
  else (cd "$1" && shasum -a 256 "${files[@]}" | LC_ALL=C sort -k2 > MANIFEST); fi
}
lines() { wc -l < "$1" | tr -d ' '; }
# fresh: a new HOME with a source, and the peer's inbox with one complete generation
fresh() {
  T="$ROOT/home.$((++n))"
  S="$T/.codex/memories"
  STATE="$T/.local/state/codex-memory-share"
  OUT="$STATE/outbox"; INB="$STATE/inbox/testpeer"; EXT="$S/extensions/testpeer"
  mkdir -p "$S/rollout_summaries" "$INB/rollout_summaries"
  printf 'raw v1' > "$S/raw_memories.md"
  printf 'a' > "$S/rollout_summaries/a.md"; printf 'b' > "$S/rollout_summaries/b.md"
  printf 'peer v1' > "$INB/raw_memories.md"; printf 'x' > "$INB/rollout_summaries/x.md"
  mkman "$INB"
}
n=0

echo "A. round trip, run after run"
fresh
run; is "the first run exits 0" "$?" 0
is "the outbox MANIFEST lists three files" "$(lines "$OUT/MANIFEST")" 3
ok "the outbox generation verifies against its own MANIFEST, as the peer will check it" sh -c 'cd "$1" && shasum -a 256 -c --status MANIFEST' _ "$OUT"
ok "Codex's lock file is still there (lockf kept it)" test -f "$T/.codex/memories.lock"
ok "outbox raw_memories.md matches the source" cmp -s "$S/raw_memories.md" "$OUT/raw_memories.md"
ok "outbox a.md matches the source" cmp -s "$S/rollout_summaries/a.md" "$OUT/rollout_summaries/a.md"
ok "outbox b.md matches the source" cmp -s "$S/rollout_summaries/b.md" "$OUT/rollout_summaries/b.md"
is "the peer's raw_memories.md reaches the extension" "$(cat "$EXT/memory/raw_memories.md" 2>&1)" "peer v1"
ok "and its summary x.md" test -f "$EXT/memory/rollout_summaries/x.md"
ok "instructions.md carries the peer's tag" grep -qF '[from testpeer]' "$EXT/instructions.md"

printf 'stray' > "$EXT/memory/notes.md"; printf 'stray' > "$EXT/memory/rollout_summaries/x.md.bak"
run
no "a stray file in memory/ is removed when nothing else changed" test -e "$EXT/memory/notes.md"
no "and a stray file next to the summaries" test -e "$EXT/memory/rollout_summaries/x.md.bak"
ok "while the generation itself stays" test -f "$EXT/memory/rollout_summaries/x.md"
ino="$(stat -f %i "$EXT/memory/raw_memories.md")"; run
is "a run that finds memory/ already exact rewrites nothing" "$(stat -f %i "$EXT/memory/raw_memories.md")" "$ino"

rm "$S/rollout_summaries/b.md"
rm "$INB/rollout_summaries/x.md"; printf 'y' > "$INB/rollout_summaries/y.md"; mkman "$INB"
run; is "a second run exits 0" "$?" 0
no "the outbox drops the deleted b.md" test -e "$OUT/rollout_summaries/b.md"
is "and its MANIFEST lists two files" "$(lines "$OUT/MANIFEST")" 2
ok "the extension gains y.md" test -f "$EXT/memory/rollout_summaries/y.md"
no "and loses x.md" test -e "$EXT/memory/rollout_summaries/x.md"

printf 'peer v2' > "$INB/raw_memories.md"
run
is "a delivery the MANIFEST does not describe is not imported" "$(cat "$EXT/memory/raw_memories.md")" "peer v1"

printf 'secret' > "$STATE/inbox/outside.md"
printf '%s  ../outside.md\n' "$(shasum -a 256 "$STATE/inbox/outside.md" | cut -d' ' -f1)" > "$INB/MANIFEST"
run
ok "a MANIFEST path that leaves its folder refuses the generation" test -f "$EXT/memory/rollout_summaries/y.md"
is "and nothing from it lands in stage or extensions" "$(find "$STATE/stage" "$S/extensions" -name outside.md | wc -l | tr -d ' ')" 0

mkdir "$T/elsewhere"; printf 'z' > "$T/elsewhere/z.md"; rm -rf "$INB/rollout_summaries"; ln -s "$T/elsewhere" "$INB/rollout_summaries"
printf '%s  rollout_summaries/z.md\n' "$(shasum -a 256 "$T/elsewhere/z.md" | cut -d' ' -f1)" > "$INB/MANIFEST"
run
no "a symlinked rollout_summaries in the inbox is not imported" test -e "$EXT/memory/rollout_summaries/z.md"
rm "$INB/rollout_summaries"; mkdir "$INB/rollout_summaries"

: > "$INB/MANIFEST"; rm -f "$INB/raw_memories.md" "$INB"/rollout_summaries/*.md
run; is "an empty generation exits 0" "$?" 0
no "and empties the extension's raw_memories.md" test -e "$EXT/memory/raw_memories.md"
is "and its summaries" "$(find "$EXT/memory/rollout_summaries" -name '*.md' | wc -l | tr -d ' ')" 0

echo "B. busy lock"
fresh
run
lockf -k -s "$T/.codex/memories.lock" sleep 5 & HOLDER=$!
held=no
for _ in $(seq 50); do
  lockf -k -s -t 0 "$T/.codex/memories.lock" true; [ $? -eq 75 ] && { held=yes; break; }
  sleep 0.1
done
is "the lock is held by another process" "$held" yes
printf 'raw v2' > "$S/raw_memories.md"
rm -f "$INB/raw_memories.md"; printf 'peer v2' > "$INB/raw_memories.md"; mkman "$INB"
run; is "a run against a busy lock exits 0" "$?" 0
is "and leaves the outbox alone" "$(cat "$OUT/raw_memories.md")" "raw v1"
is "and the extension alone" "$(cat "$EXT/memory/raw_memories.md")" "peer v1"
kill "$HOLDER" 2>/dev/null; pkill -P "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
run
is "the next run exports" "$(cat "$OUT/raw_memories.md")" "raw v2"
is "and imports" "$(cat "$EXT/memory/raw_memories.md")" "peer v2"

echo "C. the LaunchAgent"
rendered="$ROOT/agent.plist"
mkdir -p "$ROOT/decoy/chezmoi/.chezmoidata"; echo '= not toml' > "$ROOT/decoy/chezmoi/.chezmoidata/broken.toml"
XDG_DATA_HOME="$ROOT/decoy" chezmoi execute-template --source "$SRC" --file "$PLIST" > "$rendered" 2>"$ROOT/tpl.err" \
  || _fail "the plist template renders" "$(head -c 200 "$ROOT/tpl.err")"
if plutil -lint "$rendered" >/dev/null 2>&1; then _pass "the rendered plist is valid"; else _fail "the rendered plist is valid" "$(plutil -lint "$rendered" 2>&1)"; fi
first="$(plutil -extract ProgramArguments.0 raw -o - "$rendered" 2>&1)"
case "$first" in */.local/bin/codex-memory-share) _pass "it starts codex-memory-share from ~/.local/bin" ;; *) _fail "it starts codex-memory-share from ~/.local/bin" "$first" ;; esac

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]

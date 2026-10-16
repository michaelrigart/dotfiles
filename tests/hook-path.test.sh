#!/usr/bin/env bash
# Every hook and statusline command the settings configure runs outside the sandbox. Each is
# executed here exactly as configured, with a hostile directory first on PATH holding stubs
# for the shells and every tool the hooks use; each stub writes a marker. No marker may
# appear (spec 2026-10-16, sandbox write boundary, section 2). The command list comes from
# the settings, so a hook added later without the pin fails here.
#
#   ./tests/hook-path.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$SRC/dot_claude/modify_private_settings.json"
[ -f "$MOD" ] || { echo "missing script under test: $MOD" >&2; exit 2; }
[ -x /opt/homebrew/bin/bash ] || { echo "no /opt/homebrew/bin/bash" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/hook-path.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# A mirror of ~/.claude built from the source, at $T/.claude: HOME=$T makes the commands'
# $HOME/.claude/<script> resolve to it.
mkdir -p "$T/.claude/hooks"
for f in "$SRC"/dot_claude/executable_*.sh "$SRC"/dot_claude/*.py; do
  b=$(basename "$f"); cp "$f" "$T/.claude/${b#executable_}"
done
for f in "$SRC"/dot_claude/hooks/executable_*.sh; do
  b=$(basename "$f"); cp "$f" "$T/.claude/hooks/${b#executable_}"
done

HOSTILE="$T/hostile"; mkdir -p "$HOSTILE"
for t in bash sh zsh jq git python3 python cat sed awk grep rg fd tr head tail wc cut sort \
         date stat mktemp env herdr tagteam glab gh gitleaks; do
  printf '#!/bin/sh\necho "%s" >> "%s/marker"\nexit 0\n' "$t" "$T" > "$HOSTILE/$t"
  chmod 755 "$HOSTILE/$t"
done

# A real repository for the payloads, and an empty state home.
git init -q "$T/repo" && git -C "$T/repo" commit -q --allow-empty -m init
PAYLOAD=$(jq -cn --arg d "$T/repo" '{hook_event_name:"PreToolUse",tool_name:"Bash",
  session_id:"hook-path",cwd:$d,tool_input:{command:"git push origin main"},
  transcript_path:"/nonexistent"}')
STATUS=$(jq -cn --arg d "$T/repo" '{model:{display_name:"Opus"},workspace:{current_dir:$d}}')

SETTINGS=$(printf '{}' | HOME="$T" /bin/bash "$MOD") || { echo "settings did not render" >&2; exit 2; }
n=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case $cmd in echo\ *) continue ;; esac          # the SessionStart env export runs no script
  n=$((n + 1)); rm -f "$T/marker"
  input=$PAYLOAD; case $cmd in *statusline*) input=$STATUS ;; esac
  printf '%s' "$input" | env -i HOME="$T" XDG_STATE_HOME="$T/state" TMPDIR="$T" \
    PATH="$HOSTILE:/usr/bin:/bin:/opt/homebrew/bin" /bin/sh -c "$cmd" >/dev/null 2>&1
  if [ -e "$T/marker" ]; then _fail "no hostile tool runs: $cmd" "$(tr '\n' ' ' < "$T/marker")"
  else _pass "no hostile tool runs: ${cmd#/opt/homebrew/bin/bash }"; fi
done < <(printf '%s' "$SETTINGS" | jq -r '.hooks[][]?.hooks[]?.command, .statusLine.command')
[ "$n" -ge 9 ] && _pass "all $n configured hook and statusline commands were exercised" \
  || _fail "all configured commands were exercised" "only $n"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Every hook and statusline command the settings configure runs outside the sandbox. Each is
# executed here exactly as configured, with a hostile directory first on PATH holding stubs
# for every executable the system directories hold; each stub writes a marker. No marker may
# appear (spec 2026-10-16, sandbox write boundary, section 2). The command list comes from
# the settings, so a hook added later without the pin fails here, and so does one whose
# script is missing from the mirror of ~/.claude this suite builds from the source.
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
# $HOME/.claude/<script> resolve to it. It covers every executable source under dot_claude/ and
# dot_claude/hooks/ (chezmoi prefixes stripped) plus the Python helpers. A .tmpl source cannot
# be rendered here, so it must not pass silently.
unprefix() {
  local b=$1
  while :; do
    case $b in
      executable_*) b=${b#executable_} ;;
      private_*) b=${b#private_} ;;
      readonly_*) b=${b#readonly_} ;;
      *) break ;;
    esac
  done
  printf '%s' "$b"
}
mkdir -p "$T/.claude/hooks"
for d in "" hooks/; do
  for f in "$SRC"/dot_claude/${d}*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    case $b in
      *executable_*)
        case $b in
          *.tmpl) echo "cannot mirror a templated executable: $f" >&2; exit 2 ;;
        esac
        cp "$f" "$T/.claude/$d$(unprefix "$b")" ;;
      *.py) cp "$f" "$T/.claude/$d$b" ;;
    esac
  done
done

# Stubs for every executable in the system directories a hook could fall back to, all links to
# one marker script that records the name it was run as.
HOSTILE="$T/hostile"; mkdir -p "$HOSTILE"
printf '#!/bin/sh\necho "${0##*/}" >> "%s/marker"\nexit 0\n' "$T" > "$HOSTILE/.marker"
chmod 755 "$HOSTILE/.marker"
for d in /usr/bin /bin /opt/homebrew/bin; do
  while IFS= read -r p; do
    t=${p##*/}
    case $t in .*|*[[:space:]]*) continue ;; esac
    [ -e "$HOSTILE/$t" ] || ln -s .marker "$HOSTILE/$t"
  done < <(find "$d" -maxdepth 1 \( -type f -o -type l \) -perm -u+x 2>/dev/null)
done
# Tools that may live elsewhere on Michael's PATH but not in those directories.
for t in herdr tagteam glab gh gitleaks python python3 jq git bash zsh sh; do
  [ -e "$HOSTILE/$t" ] || ln -s .marker "$HOSTILE/$t"
done

# A real repository for the payloads, built with git isolated from the real global config (no
# signing through the 1Password agent, so no prompt), and an empty state home.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$T/repo" \
  && git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
       commit -q --allow-empty -m init
git -C "$T/repo" rev-parse -q --verify HEAD >/dev/null \
  || { echo "fixture repository has no HEAD" >&2; exit 2; }
PAYLOAD=$(jq -cn --arg d "$T/repo" '{hook_event_name:"PreToolUse",tool_name:"Bash",
  session_id:"hook-path",cwd:$d,tool_input:{command:"git push origin main"},
  transcript_path:"/nonexistent"}')
STATUS=$(jq -cn --arg d "$T/repo" '{model:{display_name:"Opus"},workspace:{current_dir:$d}}')

SETTINGS=$(printf '{}' | HOME="$T" /bin/bash "$MOD") || { echo "settings did not render" >&2; exit 2; }
total=$(printf '%s' "$SETTINGS" | jq '[.hooks[][]?.hooks[]?.command, .statusLine.command]
  | map(select(type == "string")) | length')
n=0; skipped=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  # The SessionStart env export runs no script: only a bare echo is skipped.
  case $cmd in
    echo\ *) case $cmd in *'|'*|*';'*|*'&'*|*'$('*) ;; *) skipped=$((skipped + 1)); continue ;; esac ;;
  esac
  n=$((n + 1)); rm -f "$T/marker"
  expanded=${cmd//\$HOME/$T}
  re="$T/\.claude/([^ '\"]+)"
  if [[ $expanded =~ $re ]] && [ -f "$T/.claude/${BASH_REMATCH[1]}" ]; then :
  else _fail "the configured script is in the mirror: $cmd" "not found under \$HOME/.claude"; continue; fi
  input=$PAYLOAD; case $cmd in *statusline*) input=$STATUS ;; esac
  printf '%s' "$input" | env -i HOME="$T" XDG_STATE_HOME="$T/state" TMPDIR="$T" \
    PATH="$HOSTILE:/usr/bin:/bin:/opt/homebrew/bin" /bin/sh -c "$cmd" >/dev/null 2>&1
  if [ -e "$T/marker" ]; then _fail "no hostile tool runs: $cmd" "$(tr '\n' ' ' < "$T/marker")"
  else _pass "no hostile tool runs: ${cmd#/opt/homebrew/bin/bash }"; fi
done < <(printf '%s' "$SETTINGS" | jq -r '(.hooks[][]?.hooks[]?.command, .statusLine.command) | select(type == "string")')
[ "$n" -gt 0 ] && [ "$n" -eq $((total - skipped)) ] \
  && _pass "all $n configured hook and statusline commands were exercised ($skipped echo skipped)" \
  || _fail "all configured commands were exercised" "ran $n, skipped $skipped, settings name $total"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

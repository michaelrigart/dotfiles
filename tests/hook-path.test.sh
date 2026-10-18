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

# Four real repositories for the payloads, built with git isolated from the real global config
# (no signing through the 1Password agent, so no prompt), and an empty state home. A sandboxed
# command can write a repository's configuration, so each carries configuration that would
# run a command if any hook's git read it, every command writing its own marker in $T/marks:
# core.fsmonitor, a clean/smudge/process filter and a diff driver (command and textconv), all
# applied by .gitattributes, on a worktree, index or commit read; and on a network read of
# origin, which each names as the forge project, an ext:: rewrite of its URL through
# insteadOf with protocol.ext.allow=always ("repo"), core.sshCommand on an ssh URL
# ("repo-ssh"), or neither on a plain local origin that main is ahead of ("repo-plain"), so
# the outgoing commits are read to the end. Each also sets core.hooksPath to a post-index-change
# hook, and b.txt gets a new mtime before every run (a stat change with no content change): any
# git that refreshes the index and writes it back runs the hook. The mtime is set to a distinct
# whole second each time, because git compares seconds, so a plain touch can look unchanged.
# "repo-hook" carries only that hook: with the failing process filter above, Apple's git 2.54
# aborts the refresh before it writes the index, which would hide the hook in the others.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
MARKS="$T/marks"; EVIL="$T/evil"; mkdir -p "$MARKS" "$EVIL"
evil() { printf '#!/bin/sh\ntouch "%s/%s"\n%bexit 0\n' "$MARKS" "$1" "$2" > "$EVIL/$1"; chmod 755 "$EVIL/$1"; }
evil fsmonitor ''; evil clean 'cat\n'; evil smudge 'cat\n'; evil process ''
evil diff ''; evil textconv 'cat "$1"\n'
mkdir -p "$EVIL/hooks"; printf '#!/bin/sh\ntouch "%s/hook"\n' "$MARKS" > "$EVIL/hooks/post-index-change"
chmod 755 "$EVIL/hooks/post-index-change"
printf '#!/bin/sh\ntouch "%s/ssh"\nexit 1\n' "$MARKS" > "$EVIL/ssh"; chmod 755 "$EVIL/ssh"
BUMP=0
bump() { BUMP=$((BUMP + 1)); touch -t "$(date -v-${BUMP}d +%Y%m%d%H%M.%S)" "$1/b.txt"; }
GIT_T=(-c user.name=t -c user.email=t@t -c commit.gpgsign=false)
mkrepo() {
  local r=$1 rewrite=$2
  git init -q -b main "$r" || return 1
  printf 'one\n' > "$r/a.txt"; printf 'same\n' > "$r/b.txt"
  printf '* filter=m diff=m\n' > "$r/.gitattributes"
  git -C "$r" add a.txt b.txt && git -C "$r" "${GIT_T[@]}" commit -q -m init || return 1
  git -C "$r" branch feat
  [ -z "${3:-}" ] || { git -C "$r" config core.hooksPath "$EVIL/hooks"; return; }   # repo-hook
  git -C "$r" remote add origin 'git@forge.example:acme/app.git'
  git -C "$r" config "url.$rewrite.insteadOf" 'git@forge.example:acme/app.git'
  git -C "$r" config core.fsmonitor "$EVIL/fsmonitor"
  git -C "$r" config filter.m.clean "$EVIL/clean"
  git -C "$r" config filter.m.smudge "$EVIL/smudge"
  git -C "$r" config filter.m.process "$EVIL/process"
  git -C "$r" config diff.m.command "$EVIL/diff"
  git -C "$r" config diff.m.textconv "$EVIL/textconv"
  git -C "$r" config core.sshCommand "$EVIL/ssh"
  git -C "$r" config protocol.ext.allow always
  git -C "$r" config core.hooksPath "$EVIL/hooks"
}
mkrepo "$T/repo-hook" "" hook-only && mkrepo "$T/repo" "ext::touch $MARKS/ext" && mkrepo "$T/repo-ssh" "ssh://forge.example/acme/app.git" \
  && git init -q --bare "$T/origin.git" && git -C "$T/origin.git" fetch -q "$T/repo" main:main \
  && mkrepo "$T/repo-plain" "$T/origin.git" \
  && git -C "$T/repo-plain" fetch -q origin main:refs/remotes/origin/main \
  && printf 'one\ntwo\n' > "$T/repo-plain/a.txt" \
  && git -C "$T/repo-plain" "${GIT_T[@]}" commit -q -am "ahead" \
  || { echo "fixture repositories were not built" >&2; exit 2; }
for r in repo repo-ssh repo-plain; do   # modified, so a diff runs the filter
  printf 'three\n' > "$T/$r/a.txt"
done
git -C "$T/repo" rev-parse -q --verify HEAD >/dev/null \
  || { echo "fixture repository has no HEAD" >&2; exit 2; }
rm -f "$MARKS"/*                                              # building them ran nothing that counts
# The PreToolUse payloads: a push, and the two creations that make the pre-merge gate read
# origin's head with ls-remote.
payload() { jq -cn --arg d "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",
  session_id:"hook-path",cwd:$d,tool_input:{command:$c},transcript_path:"/nonexistent"}'; }
COMMANDS=("git push origin main"
          "gh pr create --base main --head feat --title t --body b"
          "glab mr create -s feat -b main --title t")

# The fixtures are live: plain git runs each configured command, so a silent hook is a result.
# (The sandbox's own GIT_SSH_COMMAND would outrank core.sshCommand, so it is dropped here.)
bump "$T/repo-hook"
git -C "$T/repo-hook" diff --name-only >/dev/null 2>&1
env -u GIT_SSH_COMMAND git -C "$T/repo" diff --quiet >/dev/null 2>&1
env -u GIT_SSH_COMMAND git -C "$T/repo" ls-remote origin >/dev/null 2>&1
env -u GIT_SSH_COMMAND git -C "$T/repo-ssh" ls-remote origin >/dev/null 2>&1
live=$(ls "$MARKS" | tr '\n' ' ')
if [ -e "$MARKS/fsmonitor" ] && [ -e "$MARKS/ext" ] && [ -e "$MARKS/ssh" ] \
   && [ -e "$MARKS/hook" ] && { [ -e "$MARKS/clean" ] || [ -e "$MARKS/process" ]; }; then
  _pass "the fixture repositories run their configured commands under plain git"
else _fail "the fixture repositories run their configured commands under plain git" "$live"; fi
rm -f "$MARKS"/*

SETTINGS=$(printf '{}'| HOME="$T" /bin/bash "$MOD") || { echo "settings did not render" >&2; exit 2; }
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
  # Every hook runs against both repositories with each payload (the statusline reads only the
  # directory); a marker from the hostile PATH or from the repositories' configuration fails it.
  rm -f "$MARKS"/*; ran=""
  for r in "$T/repo" "$T/repo-ssh" "$T/repo-plain" "$T/repo-hook"; do
    inputs=("$(jq -cn --arg d "$r" '{model:{display_name:"Opus"},workspace:{current_dir:$d}}')")
    case $cmd in *statusline*) ;; *)
      inputs=(); for c in "${COMMANDS[@]}"; do inputs+=("$(payload "$r" "$c")"); done ;; esac
    for input in "${inputs[@]}"; do
      bump "$r"
      printf '%s' "$input" | env -i HOME="$T" XDG_STATE_HOME="$T/state" TMPDIR="$T" \
        PATH="$HOSTILE:/usr/bin:/bin:/opt/homebrew/bin" /bin/sh -c "$cmd" >/dev/null 2>&1
      what=$(printf '%s' "$input" | jq -r '.tool_input.command // "statusline"')
      [ -e "$T/marker" ] && ran="$ran[PATH: $(tr '\n' ' ' < "$T/marker")| ${r##*/}, $what] "
      [ -n "$(ls "$MARKS")" ] && ran="$ran[config: $(ls "$MARKS" | tr '\n' ' ')| ${r##*/}, $what] "
      rm -f "$T/marker" "$MARKS"/*
    done
  done
  if [ -n "$ran" ]; then _fail "no hostile tool or repository-configured command runs: $cmd" "$ran"
  else _pass "no hostile tool or repository-configured command runs: ${cmd#/opt/homebrew/bin/bash }"; fi
done < <(printf '%s' "$SETTINGS" | jq -r '(.hooks[][]?.hooks[]?.command, .statusLine.command) | select(type == "string")')
[ "$n" -gt 0 ] && [ "$n" -eq $((total - skipped)) ] \
  && _pass "all $n configured hook and statusline commands were exercised ($skipped echo skipped)" \
  || _fail "all configured commands were exercised" "ran $n, skipped $skipped, settings name $total"

# The pin itself, exactly. Running with a hostile PATH proves the pin works today; a pin widened
# to the mise shims, or to $PATH, would still pass that, so the text is pinned here: one pin line
# per script, equal to the expected text, ahead of every command. Hook and statusline scripts
# carry the system form; the unsandboxed helpers keep ~/.local/bin first for the codex launcher,
# which the sandbox cannot write. Every shell script mirrored from dot_claude/ is checked, which
# covers every configured hook, and a configured command must name one of them.
SYS_PIN='PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH'
BIN_PIN='PATH=${PINNED_PATH:-$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH'
# check_pin <label> <file> <expected line>: exactly one PATH= assignment, equal to the expected
# text, and no command before it (blank lines, comments, set and the locale export aside).
check_pin() {
  local label=$1 f=$2 want=$3 count first
  count=$(grep -c '^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}PATH=' "$f")
  first=$(awk '/^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
               /^set[[:space:]]/ || /^export LC_ALL=/ { next } { print; exit }' "$f")
  if [ "$count" = 1 ] && [ "$first" = "$want" ]; then _pass "$label pins its PATH exactly, before any command"
  else _fail "$label pins its PATH exactly, before any command" "PATH assignments: $count; first command: $first"; fi
}
for f in "$T"/.claude/*.sh "$T"/.claude/hooks/*.sh; do
  [ -f "$f" ] || continue
  check_pin "${f#$T/.claude/}" "$f" "$SYS_PIN"
done
while IFS= read -r cmd; do
  expanded=${cmd//\$HOME/$T}
  case $expanded in echo\ *) continue ;; esac
  re="$T/\.claude/([^ '\"]+)"
  if [[ $expanded =~ $re ]] && [[ ${BASH_REMATCH[1]} == *.sh ]]; then :
  else _fail "a configured command runs a pinned shell script: $cmd" "no .sh under \$HOME/.claude"; fi
done < <(printf '%s' "$SETTINGS" | jq -r '(.hooks[][]?.hooks[]?.command, .statusLine.command) | select(type == "string")')
for b in xreview codex-daemon; do
  check_pin "$b" "$SRC/dot_local/bin/executable_$b" "$BIN_PIN"
done
# xreview-rpc is Python: its pin is a two-line assignment, the only one, before any subprocess.
RPC="$SRC/dot_local/bin/executable_xreview-rpc"
want_rpc='os.environ["PATH"] = os.environ.get("PINNED_PATH") or (
    os.path.expanduser("~/.local/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")'
pin_line=$(grep -n '^os\.environ\["PATH"\] =' "$RPC" | cut -d: -f1)
got_rpc=$(sed -n "${pin_line:-0},$((${pin_line:-0} + 1))p" "$RPC")
first_use=$(grep -n 'subprocess\.\(run\|Popen\|call\|check_output\|check_call\)\|os\.exec\|os\.system' "$RPC" | head -1 | cut -d: -f1)
if [ "$(grep -c 'os\.environ\["PATH"\]' "$RPC")" = 1 ] && [ "$got_rpc" = "$want_rpc" ] \
   && [ -n "$first_use" ] && [ "$pin_line" -lt "$first_use" ]; then
  _pass "xreview-rpc pins its PATH exactly, before any subprocess"
else _fail "xreview-rpc pins its PATH exactly, before any subprocess" "pin at line ${pin_line:-none}: $got_rpc; first subprocess at line ${first_use:-none}"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Tests for dot_config/zsh/config: where shell history lives, and its one-time move.
#
# History is state, not cache: it moved from $XDG_CACHE_HOME/zsh to $XDG_STATE_HOME/zsh
# (spec 2026-09-30, section 4 item 6). The first shell start after the change moves the
# old file across; it must never clobber a history file that already exists at the new
# place, because two shells can start at once.
#
# Sources the SOURCE config in a clean zsh with stub starship/direnv/mise/zoxide on PATH,
# and a temp HOME, so nothing real is read or written.
#
#   ./tests/zsh-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SRC/dot_config/zsh/config"
[ -f "$CONFIG" ] || { echo "missing script under test: $CONFIG" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshconfig.XXXXXX")"
trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; mkdir -p "$STUB"
for tool in starship direnv mise zoxide; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$tool"; chmod 755 "$STUB/$tool"
done

start_shell() { # start_shell <home> -> prints $HISTFILE after sourcing the config
  env -i HOME="$1" XDG_CACHE_HOME="$1/.cache" XDG_STATE_HOME="$1/.local/state" \
    PATH="$STUB:/usr/bin:/bin" /bin/zsh -f -c "source \"$CONFIG\"; print -r -- \$HISTFILE" 2>/dev/null
}

H="$T/fresh"; mkdir -p "$H"
is "HISTFILE is under XDG_STATE_HOME" "$(start_shell "$H")" "$H/.local/state/zsh/zsh_history"
is "its directory is created, so zsh can write history" \
   "$([ -d "$H/.local/state/zsh" ] && echo yes || echo no)" yes

H="$T/migrate"; mkdir -p "$H/.cache/zsh"; printf 'old history\n' > "$H/.cache/zsh/zsh_history"
start_shell "$H" >/dev/null
is "the old cache history is moved on first start" "$(cat "$H/.local/state/zsh/zsh_history" 2>/dev/null)" "old history"
is "and is gone from the cache" "$([ -e "$H/.cache/zsh/zsh_history" ] && echo kept || echo gone)" gone
start_shell "$H" >/dev/null
is "a second start leaves the moved history alone" "$(cat "$H/.local/state/zsh/zsh_history" 2>/dev/null)" "old history"

H="$T/both"; mkdir -p "$H/.cache/zsh" "$H/.local/state/zsh"
printf 'old\n' > "$H/.cache/zsh/zsh_history"; printf 'new\n' > "$H/.local/state/zsh/zsh_history"
start_shell "$H" >/dev/null
is "an existing new history is never overwritten" "$(cat "$H/.local/state/zsh/zsh_history")" new
is "and the old file is left for a human to look at" "$(cat "$H/.cache/zsh/zsh_history")" old

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Tests what a suite does when a file it reads is gone: it must stop with exit 2 before it
# asserts anything (AGENTS.md, Testing). Each row hides one file in a throwaway copy of the
# tracked tree and runs one suite there.
#
# Bugs caught: a guard that exits 1, which reads as a failed assertion where there is none; and
# a suite with no guard for a file, whose absence checks then pass on nothing.
#
# Run: ./tests/missing-subject.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "INCONCLUSIVE: $SRC is not a git checkout, so its tracked files cannot be listed" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/missing-subject.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
COPY="$T/copy"
mkdir "$COPY" || exit 2
# The working tree's files, not the index's, so an uncommitted suite is the one that runs.
git -C "$SRC" ls-files -z | (cd "$SRC" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$COPY"

# bounded <command>...: run it for at most 20 s, so a suite with no guard fails its row here
# instead of running to its end under the machine-wide test lock. The suite leads its own
# process group and each run has its own output file, so nothing a killed suite started can
# outlive its row or write into the next one's output. Sets OUT and RC.
runs=0
bounded() {
  runs=$((runs + 1))
  perl -e 'setpgrp(0, 0); exec @ARGV' "$@" </dev/null >"$T/out.$runs" 2>&1 & local pid=$!
  ( sleep 20; kill -TERM -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 & local watcher=$!
  wait "$pid" 2>/dev/null; RC=$?
  kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  kill -TERM -- "-$pid" 2>/dev/null
  OUT=$(<"$T/out.$runs")
}

# verdict <label> <name>: exit 2, saying what is missing, and no assertion passed on the way
# there. The name keeps another exit 2 (a cold cache, a broken fixture) from passing the row.
verdict() {
  local passed named=no
  passed=$(printf '%s\n' "$OUT" | grep -cE '^[[:space:]]*(ok|PASS)([[:space:]]|:)')
  printf '%s\n' "$OUT" | grep -qF -- "$2" && named=yes
  if [ "$RC" -eq 2 ] && [ "$passed" -eq 0 ] && [ "$named" = yes ]; then _pass "$1"
  else _fail "$1" "exit=$RC, $passed assertions passed, names $2: $named"; fi
}

# missing <suite> <path>: the suite, run in the copy without that file.
missing() {
  local suite="$COPY/tests/$1.test.sh" file="$COPY/$2"
  if [ ! -f "$suite" ] || [ ! -f "$file" ]; then
    echo "missing file under test: tests/$1.test.sh or $2" >&2; exit 2
  fi
  mv "$file" "$file.hidden"
  bounded "$suite"
  mv "$file.hidden" "$file"
  verdict "$1 stops with exit 2 when ${2##*/} is missing" "$2"
}

RELAY="Library/Application Support/Alfred/Alfred.alfredpreferences/snippets/Relay"
missing alfred-relay          "$RELAY/info.plist"
missing alfred-relay          "$RELAY/From Codex.json"
missing alfred-relay          "$RELAY/From Claude Code.json"
missing claude-settings       dot_config/agents/plugins.conf
missing codex-code-mode-host  dot_local/bin/executable_codex-code-mode-host
missing codex-code-mode-host  dot_local/bin/executable_codex
missing codex-code-mode-host  dot_local/bin/executable_codex-daemon
missing codex-config          dot_codex/modify_private_config.toml
missing codex-config          dot_codex/modify_private_hooks.json
missing dev                   dot_config/zsh/functions
missing dev                   dot_config/herdr/executable_layout.sh
missing dev                   dot_config/herdr/executable_tab-goto.sh
missing dev                   dot_config/herdr/config.toml
missing dev                   dot_config/nvim/lua/plugins/smart-splits.lua
missing git-forge-guard       dot_claude/executable_git-forge-guard.sh
missing herdr-phase           dot_config/herdr/executable_phase.sh
missing path-resolution-guard dot_claude/executable_path-resolution-guard.sh
missing run                   .scripts/test-audit/subjects.tsv
missing worktree-guard        dot_claude/executable_worktree-guard.sh
missing xreview-skill         .chezmoitemplates/agents/global.md

# A missing tool is the same case: the suite cannot decide. /usr/bin and /bin hold bash but
# no chezmoi.
bounded env PATH=/usr/bin:/bin "$COPY/tests/codex-config.test.sh"
verdict "codex-config stops with exit 2 when chezmoi is not on PATH" chezmoi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

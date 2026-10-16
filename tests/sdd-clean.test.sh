#!/usr/bin/env bash
# Tests for dot_local/bin/executable_sdd-clean: it deletes a finished SDD plan workspace,
# <top>/.superpowers/sdd/<name>, only when git ignores it and tracks nothing in it, and
# refuses everything else without deleting anything.
#
#   ./tests/sdd-clean.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SC="$SRC/dot_local/bin/executable_sdd-clean"
[ -f "$SC" ] || { echo "missing script under test: $SC" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/sdd-clean.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

# repo <name>: a work tree that ignores .superpowers/, as this repository does.
repo() {
  git init -q "$T/$1"
  printf '.superpowers/\n' > "$T/$1/.gitignore"
  git -C "$T/$1" add .gitignore && git -C "$T/$1" commit -q -m init
}
# ws <path>: a workspace with a ledger in it.
ws() { mkdir -p "$1" && printf '# SDD ledger\n' > "$1/progress.md"; }
# deleted <label> <args...>: exit 0, and every argument is gone.
deleted() {
  local label=$1 a gone=1 rc; shift
  "$SC" "$@" 2>"$T/err"; rc=$?
  for a in "$@"; do [ -e "$a" ] && gone=0; done
  if [ "$rc" = 0 ] && [ "$gone" = 1 ]; then _pass "$label"
  else _fail "$label" "rc=$rc, stderr: $(cat "$T/err")"; fi
}
# refused <label> <reason text> <args...>: exit 1, the reason on stderr, and every argument
# that existed before the call still in place.
refused() {
  local label=$1 why=$2 a kept=1 rc pre=(); shift 2
  for a in "$@"; do if [ -e "$a" ] || [ -L "$a" ]; then pre+=("$a"); fi; done
  "$SC" "$@" 2>"$T/err"; rc=$?
  for a in ${pre[@]+"${pre[@]}"}; do [ -e "$a" ] || [ -L "$a" ] || kept=0; done
  if [ "$rc" = 1 ] && [ "$kept" = 1 ] && grep -qF -- "$why" "$T/err"; then _pass "$label"
  else _fail "$label" "rc=$rc kept=$kept, stderr: $(cat "$T/err")"; fi
}

repo r; R="$T/r"
ws "$R/.superpowers/sdd/a";             deleted "an ignored workspace is deleted" "$R/.superpowers/sdd/a"
ws "$R/.superpowers/sdd/b"; ws "$R/.superpowers/sdd/c"
deleted "two workspaces in one call" "$R/.superpowers/sdd/b" "$R/.superpowers/sdd/c"
ws "$R/.superpowers/sdd/d"
( CDPATH= cd -- "$R" && "$SC" .superpowers/sdd/d/ ) 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$R/.superpowers/sdd/d" ] && _pass "a relative path with a trailing slash" \
  || _fail "a relative path with a trailing slash" "rc=$rc, stderr: $(cat "$T/err")"

mkdir -p "$R/docs";                     refused "a directory outside .superpowers/sdd/" "not a workspace directly under" "$R/docs"
ws "$R/.superpowers/sdd/e/deeper";      refused "a directory two levels down" "not a workspace directly under" "$R/.superpowers/sdd/e/deeper"
refused "the sdd directory itself" "not a workspace directly under" "$R/.superpowers/sdd"
refused "a path that does not exist" "not a directory" "$R/.superpowers/sdd/none"
ws "$T/elsewhere"; ln -s "$T/elsewhere" "$R/.superpowers/sdd/link"
refused "a symlink to a directory elsewhere" "symlink" "$R/.superpowers/sdd/link"
ws "$R/.superpowers/sdd/nested"; git init -q "$R/.superpowers/sdd/nested"
refused "a nested work tree" "not a workspace directly under" "$R/.superpowers/sdd/nested"
ws "$R/.superpowers/sdd/tracked"; git -C "$R" add -f .superpowers/sdd/tracked/progress.md
git -C "$R" commit -q -m "track a workspace"
refused "a workspace git tracks files in" "tracks" "$R/.superpowers/sdd/tracked"

ws "$R/.superpowers/sdd/g"; git init -q "$R/.superpowers/sdd/g/inner"
git -C "$R/.superpowers/sdd/g/inner" commit -q --allow-empty -m "unpushed work"
refused "a workspace holding an independent repository" "holds a git repository" "$R/.superpowers/sdd/g"
ws "$R/.superpowers/sdd/h"; git -C "$R" worktree add -q -b wt-h "$R/.superpowers/sdd/h/wt"
printf 'uncommitted\n' > "$R/.superpowers/sdd/h/wt/new.txt"
refused "a workspace holding a linked worktree" "holds a git repository" "$R/.superpowers/sdd/h"

repo plain; printf '' > "$T/plain/.gitignore"; git -C "$T/plain" commit -q -am "ignore nothing"
ws "$T/plain/.superpowers/sdd/x";       refused "a workspace git does not ignore" "does not ignore" "$T/plain/.superpowers/sdd/x"
ws "$T/norepo/.superpowers/sdd/x";      refused "a directory outside any repository" "not inside a git work tree" "$T/norepo/.superpowers/sdd/x"
repo other; ws "$T/other/real/sdd/x"; mkdir -p "$T/other/.superpowers"
ln -s "$T/other/real/sdd" "$T/other/.superpowers/sdd"
refused "a workspace reached through a symlinked sdd directory" "not a workspace directly under" "$T/other/.superpowers/sdd/x"

ws "$R/.superpowers/sdd/f"
refused "one refusal deletes nothing" "not a workspace directly under" "$R/.superpowers/sdd/f" "$R/docs"

"$SC" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -qF 'usage: sdd-clean' "$T/err" && _pass "no argument is a usage error (exit 2)" \
  || _fail "no argument is a usage error (exit 2)" "rc=$rc, stderr: $(cat "$T/err")"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

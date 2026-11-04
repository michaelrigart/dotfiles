#!/usr/bin/env bash
# Tests for dot_claude/executable_xreview-apply-guard.sh — the apply-window guard.
#
# This guard has a wildcard matcher, so it runs on every tool call. Its most important
# property is being INERT with no window open: a regression there blocks ordinary edits
# everywhere. That case is asserted first and deliberately.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_xreview-apply-guard.sh"
[ -f "$GUARD" ] || { echo "missing guard under test: $GUARD" >&2; exit 2; }
XREVIEW="$(cd "$(dirname "$0")/.." && pwd)/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing xreview under test: $XREVIEW" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

decide() {
  local out; out="$(cat)"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
    || printf 'allow'
}
# guard_out <payload> [<cwd>] - the guard's raw answer, run from <cwd> (default: the suite's own).
# PINNED_PATH is the suite's PATH unless the caller set one, as the spy cases do.
guard_out() { ( cd "${2:-.}" && printf '%s' "$1" | PINNED_PATH="${PINNED_PATH:-$PATH}" bash "$GUARD" 2>/dev/null ); }
edit() { guard_out "$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Edit}" "$1")" "${3:-.}" | decide; }
nbedit() { guard_out "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$1")" "${2:-.}" | decide; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrapply.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo/src" "$ROOT/repo/tests" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
printf 'x\n' > src/in-diff.txt; printf 'y\n' > src/untouched.txt
git config commit.gpgsign false          # see xreview.test.sh for why
git add -A
if ! git commit -q -m init; then printf 'fixture setup failed\n' >&2; exit 1; fi
printf 'changed\n' > src/in-diff.txt      # working-tree change → in scope

KEY="$(printf '%s' "$(git rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
MARKER="$XDG_STATE_HOME/xreview/$KEY/applying"

is "INERT with no window open (most important)" "$(edit "$ROOT/repo/src/untouched.txt")" allow

mkdir -p "$(dirname "$MARKER")"
{ printf 'nonce=xr-test\n'; printf 'file=src/in-diff.txt\n'; } > "$MARKER"

is "file in the branch diff is allowed"      "$(edit "$ROOT/repo/src/in-diff.txt")"   allow
is "file outside the diff is denied"         "$(edit "$ROOT/repo/src/untouched.txt")" deny
is "a test path is allowed (RED-test rule)"  "$(edit "$ROOT/repo/tests/new_spec.rb")" allow
is "a *_test.* file is allowed"              "$(edit "$ROOT/repo/src/thing_test.go")" allow
is "Write is guarded too"                    "$(edit "$ROOT/repo/src/untouched.txt" Write)" deny
is "a non-editing tool is ignored"           "$(edit "$ROOT/repo/src/untouched.txt" Bash)"  allow
is "a path outside the repo is not policed"  "$(edit "/etc/hosts")"                   allow

XREVIEW_GUARD=off; export XREVIEW_GUARD
is "XREVIEW_GUARD=off bypasses"              "$(edit "$ROOT/repo/src/untouched.txt")" allow
unset XREVIEW_GUARD

rm -f "$MARKER"
is "inert again once the window is closed"   "$(edit "$ROOT/repo/src/untouched.txt")" allow

# --- K. The window is keyed by the edited file's checkout, never the hook's cwd (spec 2026-11-03 §3)
A="$ROOT/repo"; B="$ROOT/repo-b"; H="$ROOT/repo/.claude/worktrees/h"
mkdir -p "$ROOT/norepo"
git -C "$A" worktree add -q "$B" -b b 2>/dev/null && git -C "$A" worktree add -q "$H" -b h 2>/dev/null \
  || { echo "worktree fixture setup failed" >&2; exit 1; }
printf 'changed b\n' > "$B/src/in-diff.txt"
printf 'changed h\n' > "$H/src/in-diff.txt"
BTOP="$(git -C "$B" rev-parse --show-toplevel)"
# window <checkout> - open a window on that checkout, as the existing marker is written, under
# its own key; only src/in-diff.txt is in scope.
window() {
  local top key; top="$(git -C "$1" rev-parse --show-toplevel)"
  key="$(printf '%s' "$top" | tr '/' '_' | sed 's/^_//')"
  mkdir -p "$XDG_STATE_HOME/xreview/$key"
  { printf 'nonce=xr-k\n'; printf 'file=src/in-diff.txt\n'; } > "$XDG_STATE_HOME/xreview/$key/applying"
}
no_windows() { rm -rf "$XDG_STATE_HOME/xreview"; }
REAL_GIT="$(command -v git)"; REAL_JQ="$(command -v jq)"
mkdir -p "$ROOT/spy"
for t in git jq; do
  real="$REAL_GIT"; [ "$t" = jq ] && real="$REAL_JQ"
  printf '#!/bin/sh\necho %s >> "%s/spy.log"\nexec "%s" "$@"\n' "$t" "$ROOT" "$real" > "$ROOT/spy/$t"
  chmod +x "$ROOT/spy/$t"
done

no_windows; : > "$ROOT/spy.log"
is "K0: no window anywhere is allowed" \
   "$(PINNED_PATH="$ROOT/spy:$PATH" edit "$A/src/untouched.txt")" allow
is "K0: no window anywhere runs no git and no jq" "$(cat "$ROOT/spy.log")" ""

# The writer's own exit status: a guard that exits before reading stdin hands it SIGPIPE.
no_windows
head -c 300000 /dev/zero | tr '\0' x | PINNED_PATH="$PATH" bash "$GUARD" >/dev/null 2>&1
printf '%s' "${PIPESTATUS[1]}" > "$ROOT/writer.status"
is "K0b: with no window the guard still reads all of stdin (writer exits 0)" "$(cat "$ROOT/writer.status")" 0

no_windows; window "$B"
is "K1: B's window denies B's file outside the diff, from A" "$(edit "$B/src/untouched.txt")" deny
is "K1: B's window allows B's file in the diff"              "$(edit "$B/src/in-diff.txt")"  allow
is "K2: B's window leaves A's file alone"                    "$(edit "$A/src/untouched.txt")" allow
is "K5: B's window holds when the hook runs outside any repository" \
   "$(edit "$B/src/untouched.txt" Edit "$ROOT/norepo")" deny
is "K6: a Write into a new directory of B is denied"   "$(edit "$B/src/new/dir/f.txt" Write)" deny
is "K6: a Write of a new test file in B is allowed"    "$(edit "$B/tests/new/x_test.rb" Write)" allow
is "K7: NotebookEdit is policed by its notebook_path"  "$(nbedit "$B/src/nb.ipynb")" deny
reason="$(guard_out "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$B/src/untouched.txt")" \
          | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
is "K8: the deny reason starts with the classified first line" \
   "$(printf '%s' "$reason" | head -1)" "Outside the cross-review apply window: src/untouched.txt"
case "$reason" in
  *"xreview -C $BTOP apply --done"*) is "K8: the remedy names B's checkout" ok ok ;;
  *) is "K8: the remedy names B's checkout" "$reason" "a reason holding: xreview -C $BTOP apply --done" ;;
esac

no_windows; window "$H"
is "K3: H's window denies H's file, from A's cwd" "$(edit "$H/src/untouched.txt")" deny

no_windows; window "$A"
is "K4: A's window does not claim H's file" "$(edit "$H/src/untouched.txt")" allow
is "K4: A's window still denies A's own file" "$(edit "$A/src/untouched.txt")" deny

no_windows
PINNED_PATH="$PATH" bash "$XREVIEW" -C "$B" apply xr-k9 >/dev/null 2>&1
is "K9: xreview apply opened a window the guard finds (B's file outside the diff)" \
   "$(edit "$B/src/untouched.txt")" deny
is "K9: and B's file in the diff" "$(edit "$B/src/in-diff.txt")" allow
no_windows

# --- L. The classified checkout is the one the edit lands in, not the one the path starts in
# L1: a `..` through a missing directory climbs out of the checkout the walk stopped at.
no_windows; window "$A"
is "L1: A's window denies A's file reached through B/src/<missing>/../../../" \
   "$(edit "$B/src/nope/../../../repo/src/untouched.txt")" deny
is "L1: and still allows A's file in the diff reached that way" \
   "$(edit "$B/src/nope/../../../repo/src/in-diff.txt")" allow
no_windows; window "$B"
is "L1: B's window denies B's file reached through A/src/<missing>/../../../" \
   "$(edit "$A/src/nope/../../../repo-b/src/untouched.txt")" deny
is "L1: a missing directory that is entered and left stays in its checkout" \
   "$(edit "$B/src/nope/../untouched.txt")" deny
is "L1: B's window leaves A's file alone, reached through B/src/<missing>/../" \
   "$(edit "$B/src/nope/../../../repo/src/untouched.txt")" allow

# L2: a symlinked file is classified by its target, not by the link's directory.
ln -s "$B/src/untouched.txt" "$A/src/link.txt"
ln -s "$B/src/in-diff.txt" "$A/src/link-diff.txt"
ln -s link.txt "$A/src/chain.txt"                       # relative, two hops
ln -s "$A/src/untouched.txt" "$B/src/rlink.txt"
ln -s loop.txt "$A/src/loop.txt"
is "L2: B's window denies a link in A whose target is B's file outside the diff" \
   "$(edit "$A/src/link.txt")" deny
is "L2: and allows a link in A whose target is B's file in the diff" \
   "$(edit "$A/src/link-diff.txt")" allow
is "L2: a relative chain of links is followed to its target" "$(edit "$A/src/chain.txt")" deny
is "L2: a link in B to A's file is A's, which has no window" "$(edit "$B/src/rlink.txt")" allow
is "L2: a plain file in A stays allowed" "$(edit "$A/src/untouched.txt")" allow
is "L2: a link loop fails open" "$(edit "$A/src/loop.txt")" allow

# L3: the remedy line is shell-safe for a checkout whose path holds a space.
SP="$ROOT/sp ace"
git -C "$A" worktree add -q "$SP" -b sp 2>/dev/null || { echo "worktree fixture setup failed" >&2; exit 1; }
no_windows; window "$SP"
reason="$(guard_out "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$SP/src/untouched.txt")" \
          | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
SPTOP="$(git -C "$SP" rev-parse --show-toplevel)"
remedy="$(printf '%s\n' "$reason" | grep 'apply --done')"
is "L3: the remedy, evaluated by a shell, names the checkout with the space" \
   "$( xreview() { printf '%s' "$2"; }; eval "$remedy" )" "$SPTOP"
no_windows

# L4: `..` has one model, the lexical one, in the existing head and the missing tail alike.
# B/src/alink is a symlink to A/src: climbing out of alink lexically lands in B/src, and a
# physical climb would land in A.
no_windows; window "$B"
ln -s "$A/src" "$B/src/alink"
is "L4: a .. after a symlinked directory is read lexically, so B's file is denied" \
   "$(edit "$B/src/nope/../alink/../untouched.txt")" deny
is "L4: and with no missing directory before it" \
   "$(edit "$B/src/alink/../untouched.txt")" deny
is "L4: entering the symlinked directory without climbing is A's file, which has no window" \
   "$(edit "$B/src/alink/untouched.txt")" allow

# L5: the hop cap is the kernel's (32), not a smaller one that fails open on a chain it follows.
mkchain() {   # mkchain <prefix> <n> <target>: <prefix>1 -> target, <prefix>k -> <prefix>(k-1)
  local i; ln -s "$3" "$A/src/$1-1"
  for ((i = 2; i <= $2; i++)); do ln -s "$1-$((i - 1))" "$A/src/$1-$i"; done
}
mkchain c11 11 "$B/src/untouched.txt"; mkchain c32 32 "$B/src/untouched.txt"
mkchain c33 33 "$B/src/untouched.txt"
is "L5: an 11-link chain ending at B's file is denied" "$(edit "$A/src/c11-11")" deny
is "L5: a 32-link chain ending at B's file is denied"  "$(edit "$A/src/c32-32")" deny
is "L5: a chain past the kernel's limit is unexpected and fails open" "$(edit "$A/src/c33-33")" allow
no_windows

# --- M. The path model, one row per rule (see the guard's header). B/src/alink -> A/src from L4.
# t <window: A|B|none> <path> <expect> <label> - one window open, one Edit, one verdict.
t() {
  no_windows; [ "$1" = none ] || window "${!1}"
  is "$4" "$(edit "$2")" "$3"
}
ln -s alink/../src/untouched.txt "$B/src/evil"           # kernel: alink -> A/src, .. -> A: A/src/untouched.txt
ln -s "$B/src/alink/../src/untouched.txt" "$B/src/evil-abs"
ln -s alink/../src/in-diff.txt "$B/src/evil-diff"
ln -s nope/../untouched.txt "$B/src/gap"                  # kernel: ENOENT at nope
ln -s "$B/src/nope/../untouched.txt" "$B/src/gap-abs"
ln -s alink/newdir/f.txt "$B/src/tail"                    # missing tail appended after the walk
ln -s alink/../../repo/src/untouched.txt "$B/src/up2"     # two physical parents: A/src -> A -> $ROOT
ln -s untouched.txt "$A/src/relnest"                      # relative text against the link's physical directory
mkchain_up() {   # mkchain_up <prefix> <n>: <prefix>-1 -> A's file, <prefix>-k -> ../src/<prefix>-(k-1)
  local i; ln -s "$A/src/untouched.txt" "$A/src/$1-1"
  for ((i = 2; i <= $2; i++)); do ln -s "../src/$1-$((i - 1))" "$A/src/$1-$i"; done
}
mkchain_up m32 32; mkchain_up m33 33
# rule 1: lexical, first
t B "$B/src/nope/../alink/../untouched.txt" deny  "M1: .. after a symlinked directory is lexical (B's file)"
t B "$B/src/./alink/../untouched.txt"       deny  "M1: . and .. are folded before anything is resolved"
# rule 2: the existing prefix is physical, the missing tail is appended
t A "$B/src/alink/untouched.txt"            deny  "M2: a symlinked directory in the prefix is entered physically"
t B "$B/src/alink/untouched.txt"            allow "M2: and it is A's file, so B's window leaves it alone"
t A "$B/src/alink/newdir/f.txt"             deny  "M2: the missing tail lands in A's checkout"
# rule 3: the final symlink is followed physically
t A "$B/src/evil"                           deny  "M3: relative text with .. through a symlinked directory lands in A (review case)"
t A "$B/src/evil-abs"                       deny  "M3: absolute text with .. through a symlinked directory lands in A"
t B "$B/src/evil"                           allow "M3: the same link is not B's file"
t A "$B/src/evil-diff"                      allow "M3: the walk lands on A's file in the diff, not just anywhere in A"
t A "$B/src/up2"                            deny  "M3: two .. climb two physical parents"
t A "$B/src/alink/relnest"                  deny  "M3: relative text is taken against the link's physical directory"
t A "$B/src/tail"                           deny  "M3: a missing component ends the walk and the rest is appended"
t B "$B/src/gap"                            allow "M3: .. after a missing component (relative text) fails open"
t B "$B/src/gap-abs"                        allow "M3: .. after a missing component (absolute text) fails open"
t B "$A/src/m32-32"                         allow "M3: a 32-hop chain with .. in each hop is followed to A's file (B has no say)"
t A "$A/src/m32-32"                         deny  "M3: ... and A's window denies it"
t A "$A/src/m33-33"                         allow "M3: 33 hops is past the kernel's limit and fails open"
no_windows

git -C "$A" worktree remove --force "$SP" 2>/dev/null; git -C "$A" branch -D sp >/dev/null 2>&1
git -C "$A" worktree remove --force "$B" 2>/dev/null; git -C "$A" worktree remove --force "$H" 2>/dev/null
git -C "$A" branch -D b h >/dev/null 2>&1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

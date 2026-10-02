#!/usr/bin/env bash
# Tests for dot_claude/xreview-ledger.py: the pre-merge review ledger and the identity of a
# reviewed change (spec docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md,
# sections 3.1-3.3 and the decision in 3.6).
#
# Fixtures are real git repositories under $TMPDIR, with a private git configuration and a
# private XDG_STATE_HOME. Every assertion pins an exact value or decision.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
[ -f "$LEDGER" ] || { echo "missing helper under test: $LEDGER" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
differs() { if [ -n "$2" ] && [ "$2" != "$3" ]; then _pass "$1"; else _fail "$1" "$2 = $3"; fi; }
L() { /usr/bin/python3 "$LEDGER" "$@"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrledger.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" GIT_CEILING_DIRECTORIES="$ROOT"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
unset XREVIEW_LEDGER_LOCK_WAIT

# mkrepo <dir>: a repository on main whose one commit holds a.txt, s.py, b.bin and run.sh.
mkrepo() {
  mkdir -p "$1" && git -C "$1" init -q
  printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > "$1/a.txt"
  printf 'x = "a b"\n    y = 1\n' > "$1/s.py"
  printf '\000\001\002\003\004' > "$1/b.bin"
  printf 'echo hi\n' > "$1/run.sh"
  git -C "$1" add -A && git -C "$1" commit -q -m init
}
commit() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
# variant <repo> <branch>: a fresh branch off main, checked out, for one edit.
variant() { git -C "$1" switch -q -c "$2" main; }
fp() { L fingerprint "$1" "$2" "$3"; }

echo "A. the fingerprint names the exact change (spec 3.1)"
R="$ROOT/fp"; mkrepo "$R"
variant "$R" feature
sed -i '' 's/^two$/TWO/' "$R/a.txt"; commit "$R" "edit a"
F0="$(fp "$R" main feature)"
is "A1 a change has a 64-hex fingerprint" "$(printf '%s' "$F0" | grep -cE '^[0-9a-f]{64}$')" 1
is "A2 it is stable" "$(fp "$R" main feature)" "$F0"
git -C "$R" switch -q main; printf 'beta\n' > "$R/other.txt"; commit "$R" "main adds another file"
git -C "$R" switch -q feature; git -C "$R" rebase -q main
is "A3 a clean rebase onto a destination change in another file keeps it" "$(fp "$R" main feature)" "$F0"
git -C "$R" switch -q main; sed -i '' 's/^seven$/SEVEN/' "$R/a.txt"; commit "$R" "main edits a"
git -C "$R" switch -q feature; git -C "$R" rebase -q main
differs "A4 a rebase over a destination change in the same file changes it" "$(fp "$R" main feature)" "$F0"
F1="$(fp "$R" main feature)"
sed -i '' 's/^three$/THREE/' "$R/a.txt"; commit "$R" "one more line"
differs "A5 a one-line text change changes it" "$(fp "$R" main feature)" "$F1"
variant "$R" ws1; sed -i '' 's/^    y = 1$/  y = 1/' "$R/s.py"; commit "$R" "indent 2"
variant "$R" ws2; sed -i '' 's/^    y = 1$/   y = 1/' "$R/s.py"; commit "$R" "indent 3"
differs "A6 a whitespace-only change (indentation) changes it" "$(fp "$R" main ws1)" "$(fp "$R" main ws2)"
variant "$R" str1; sed -i '' 's/"a b"/"a  b"/' "$R/s.py"; commit "$R" "two spaces in a string"
is "A7 a whitespace-only change inside a string is a change" "$(fp "$R" main str1 | grep -cE '^[0-9a-f]{64}$')" 1
variant "$R" str2; sed -i '' 's/"a b"/"a   b"/' "$R/s.py"; commit "$R" "three spaces in a string"
differs "A8 and two such changes differ" "$(fp "$R" main str1)" "$(fp "$R" main str2)"
variant "$R" loc1; sed -i '' 's/^two$/edited/' "$R/a.txt"; commit "$R" "edit line 2"
variant "$R" loc2; sed -i '' 's/^six$/edited/' "$R/a.txt"; commit "$R" "edit line 6"
variant "$R" loc3; sed -i '' 's/^two$/edited/' "$R/a.txt"; commit "$R" "line 2 again"
is "A9 the same edit at the same place is the same change" "$(fp "$R" main loc3)" "$(fp "$R" main loc1)"
differs "A10 the same edit applied at a different location changes it" "$(fp "$R" main loc1)" "$(fp "$R" main loc2)"
variant "$R" bin; printf '\000\001\002\003\005' > "$R/b.bin"; commit "$R" "one byte"
B0="$(fp "$R" main bin)"
printf '\000\001\002\003\006' > "$R/b.bin"; commit "$R" "another byte"
differs "A11 a one-byte binary change changes it" "$(fp "$R" main bin)" "$B0"
# executable <repo>: run.sh becomes executable, on disk and in the index, and is committed.
executable() { chmod +x "$1/run.sh"; git -C "$1" update-index --chmod=+x run.sh; git -C "$1" commit -q -m "mode"; }
variant "$R" mode; executable "$R"
is "A12 a mode-only change is a change" "$(fp "$R" main mode | grep -cE '^[0-9a-f]{64}$')" 1
variant "$R" content; printf 'echo hi\n# x\n' > "$R/run.sh"; commit "$R" "content"
M1="$(fp "$R" main content)"
executable "$R"
differs "A13 a mode-only change on top of a content change changes it" "$(fp "$R" main content)" "$M1"
git -C "$R" config diff.ignoreSubmodules all
variant "$R" sub
git -C "$R" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sub
git -C "$R" commit -q -m "add a gitlink"
G1="$(fp "$R" main sub)"
is "A14 a gitlink is a change even with diff.ignoreSubmodules=all" "$(printf '%s' "$G1" | grep -cE '^[0-9a-f]{64}$')" 1
git -C "$R" update-index --cacheinfo 160000,2222222222222222222222222222222222222222,sub
git -C "$R" commit -q -m "move the gitlink"
differs "A15 a gitlink (submodule pointer) change changes it" "$(fp "$R" main sub)" "$G1"
git -C "$R" config --unset diff.ignoreSubmodules
out="$(fp "$R" main main)"; rc=$?
is "A16 an empty range has no fingerprint (exit 3, nothing printed)" "$rc/$out" "3/"
git -C "$R" config diff.renames copies
variant "$R" mv; git -C "$R" mv a.txt moved.txt; commit "$R" "rename"
is "A17 a rename is a delete plus an add, whatever diff.renames says" \
   "$(fp "$R" main mv | grep -cE '^[0-9a-f]{64}$')" 1
git -C "$R" config --unset diff.renames
variant "$R" rel; mkdir -p "$R/deep"; printf 'in\n' > "$R/deep/in.txt"; printf 'out\n' > "$R/out.txt"
commit "$R" "one file inside deep/, one outside"
F_ROOT="$(fp "$R" main rel)"
git -C "$R" config diff.relative true
is "A18 run from a subdirectory under diff.relative, the fingerprint is the same" "$(fp "$R/deep" main rel)" "$F_ROOT"
# The patch the reviewer reads, under every setting that could hide a path or rewrite content:
# diff.relative from a subdirectory, an external driver that prints nothing, and a textconv.
printf '#!/bin/sh\nexit 0\n' > "$ROOT/silent-diff"; chmod +x "$ROOT/silent-diff"
git -C "$R" config diff.external "$ROOT/silent-diff"
git -C "$R" config diff.upper.textconv 'tr a-z A-Z'
printf '*.txt diff=upper\n' > "$R/.git/info/attributes"
out="$(L diff "$R/deep" main rel)"
is "A19 the patch names every path the fingerprint names" \
   "$(printf '%s\n' "$out" | sed -n 's/^diff --git a\/\([^ ]*\) .*/\1/p' | sort | tr '\n' ' ')" "deep/in.txt out.txt "
is "A20 with the content as committed, never converted" "$(printf '%s\n' "$out" | grep -c '^+in$')" 1
is "A21 and the fingerprint ignores all three settings too" "$(fp "$R/deep" main rel)" "$F_ROOT"
git -C "$R" config --unset diff.relative; git -C "$R" config --unset diff.external
git -C "$R" config --unset diff.upper.textconv; rm "$R/.git/info/attributes"
# Binary is decided by content, never by gitattributes: a text path marked -diff, or bound to a
# driver with binary=true, must still show its changed lines in the packet.
variant "$R" attr; sed -i '' 's/^two$/TWO2/' "$R/a.txt"; commit "$R" "text under attributes"
printf '*.txt -diff\n' > "$R/.git/info/attributes"
is "A22 a path marked -diff still shows its changed line" "$(L diff "$R" main attr | grep -c '^+TWO2$')" 1
printf '*.txt diff=hide\n' > "$R/.git/info/attributes"; git -C "$R" config diff.hide.binary true
is "A23 so does a diff driver with binary=true" "$(L diff "$R" main attr | grep -c '^+TWO2$')" 1
git -C "$R" config --unset diff.hide.binary; rm "$R/.git/info/attributes"
variant "$R" bn; printf '\000\001\002\003\007' > "$R/b.bin"; commit "$R" "binary change"
L diff "$R" main bn > "$ROOT/bn.patch"
is "A24 a true binary file gets one summary line with both blob ids" \
   "$(cat "$ROOT/bn.patch")" "Binary file b.bin: $(git -C "$R" rev-parse main:b.bin) -> $(git -C "$R" rev-parse bn:b.bin)"
is "A25 and the patch holds no NUL byte" "$(tr -d '\000' < "$ROOT/bn.patch" | wc -c | tr -d ' ')" "$(wc -c < "$ROOT/bn.patch" | tr -d ' ')"
variant "$R" glob; printf 'g\n' > "$R/*.txt"; printf 'a\000b\n' > "$R/a.txt"; commit "$R" "a file named *.txt, and a binary a.txt"
L diff "$R" main glob > "$ROOT/glob.patch"
is "A26 a file named *.txt is read literally: its own line shows" "$(grep -c '^+g$' "$ROOT/glob.patch")" 1
is "A27 and does not pull in another .txt path as text" "$(grep -c '^diff --git a/a.txt' "$ROOT/glob.patch")" 0
is "A28 which is summarized as binary" "$(grep -c '^Binary file a.txt: ' "$ROOT/glob.patch")" 1
git -C "$R" switch -q main

echo "B. range normalization (spec 3.1)"
N="$ROOT/norm"; mkrepo "$N"
variant "$N" feature; printf 'f\n' > "$N/f.txt"; commit "$N" "feature"
git -C "$N" switch -q main; printf 'm\n' > "$N/m.txt"; commit "$N" "main moves on"
MB="$(git -C "$N" merge-base main feature)"
t="$(L normalize "$N" main..feature)"
is "B1 main..feature after main advanced is full" "$(printf '%s' "$t" | jq -r .full)" true
is "B2 its base is the merge-base, not main's head" "$(printf '%s' "$t" | jq -r .base)" "$MB"
is "B3 dest and dest_ref are main" "$(printf '%s' "$t" | jq -r '"\(.dest)/\(.dest_ref)"')" "main/main"
is "B4 the branch is the tip's" "$(printf '%s' "$t" | jq -r .branch)" feature
is "B5 the fingerprint is the merge-base diff's" "$(printf '%s' "$t" | jq -r .fingerprint)" "$(fp "$N" "$MB" feature)"
is "B6 the range is kept as written" "$(printf '%s' "$t" | jq -r .range)" "main..feature"
is "B7 main...feature normalizes to the same change" \
   "$(L normalize "$N" main...feature | jq -r '"\(.base) \(.fingerprint) \(.full)"')" \
   "$(printf '%s' "$t" | jq -r '"\(.base) \(.fingerprint) \(.full)"')"
# hotfix starts at main's head; the remote release/1.2 is there too, while a stale local
# release/1.2 still sits on the root commit, so the two refs give different merge-bases.
git -C "$N" switch -q -c hotfix main; printf 'h\n' > "$N/h.txt"; commit "$N" "hotfix"
git -C "$N" update-ref refs/remotes/origin/release/1.2 main
REMOTE_MB="$(git -C "$N" merge-base origin/release/1.2 hotfix)"
t="$(L normalize "$N" origin/release/1.2...hotfix)"
is "B8 origin/release/1.2...hotfix with no local release/1.2 is full" "$(printf '%s' "$t" | jq -r .full)" true
is "B9 for the destination release/1.2" "$(printf '%s' "$t" | jq -r .dest)" "release/1.2"
is "B10 with the ref as written" "$(printf '%s' "$t" | jq -r .dest_ref)" "origin/release/1.2"
is "B11 its base comes from the remote ref" "$(printf '%s' "$t" | jq -r .base)" "$REMOTE_MB"
git -C "$N" branch release/1.2 "$(git -C "$N" rev-list --max-parents=0 main)"   # a stale local branch
differs "B12 the stale local release/1.2 would give another base" "$(git -C "$N" merge-base release/1.2 hotfix)" "$REMOTE_MB"
is "B13 and it is not used" "$(L normalize "$N" origin/release/1.2...hotfix | jq -r .base)" "$REMOTE_MB"
SHA="$(git -C "$N" rev-parse main~1)"
t="$(L normalize "$N" "${SHA:0:7}..feature")"
is "B14 a commit-based left side is partial" "$(printf '%s' "$t" | jq -r '"\(.full)/\(.dest)"')" "false/null"
is "B15 and keeps its literal base" "$(printf '%s' "$t" | jq -r .base)" "$SHA"
is "B16 HEAD~1..HEAD is partial" "$(L normalize "$N" HEAD~1..HEAD | jq -r .full)" false
out="$(L normalize "$N" feature 2>&1)"; rc=$?
is "B17 a range without .. is refused" "$rc/$(printf '%s' "$out" | grep -c '<base>..<tip>')" "1/1"
out="$(L normalize "$N" no-such..feature 2>&1)"; rc=$?
is "B18 an unresolvable side is refused" "$rc/$(printf '%s' "$out" | grep -c 'cannot resolve no-such')" "1/1"
is "B19 an empty range normalizes with no fingerprint" "$(L normalize "$N" main...main | jq -r .fingerprint)" null
C="$(git -C "$N" rev-parse hotfix)"     # diverged from feature: their merge-base is the root
t="$(L normalize "$N" "$C...feature")"
is "B20 a divergent commit...branch keeps its literal base, not the merge-base" \
   "$(printf '%s' "$t" | jq -r '"\(.base) \(.full)"')" "$C false"
is "B21 and names the change base..tip" "$(printf '%s' "$t" | jq -r .fingerprint)" "$(fp "$N" "$C" feature)"

echo "C. one ledger per repository (spec 3.3)"
REAL="$(cd "$N" && pwd -P)"
COMMON="$(cd "$(git -C "$N" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
is "C1 key is the SHA-256 of the path" "$(L key /a_b/.git)" "$(printf '%s' /a_b/.git | shasum -a 256 | cut -d' ' -f1)"
differs "C2 paths that collide under / -> _ get different keys" "$(L key /a_b/.git)" "$(L key /a/b/.git)"
KEY="$(printf '%s' "$COMMON" | shasum -a 256 | cut -d' ' -f1)"
is "C3 path is the ledger of the repository's common dir" "$(L path "$N")" "$XDG_STATE_HOME/xreview/ledgers/$KEY/reviews.jsonl"
is "C4 the normalized target names that common dir" "$(L normalize "$N" main...feature | jq -r .repo)" "$COMMON"
git -C "$N" worktree add -q "$ROOT/norm-wt" feature 2>/dev/null
is "C5 a worktree resolves to the same ledger" "$(L path "$ROOT/norm-wt")" "$(L path "$N")"
ln -s "$REAL" "$ROOT/norm-link"
is "C6 a symlinked path resolves to the same ledger" "$(L path "$ROOT/norm-link")" "$(L path "$N")"
is "C7 and the same target repo" "$(L normalize "$ROOT/norm-link" main...feature | jq -r .repo)" "$COMMON"
out="$(L path "$ROOT" 2>&1)"; rc=$?
is "C8 outside a repository there is no ledger" "$rc/$(printf '%s' "$out" | grep -c 'not inside a git repository')" "1/1"

echo "D. the default branch and the default target (spec 3.1, 3.4)"
D="$ROOT/dflt"; mkrepo "$D"
is "D1 no origin: main" "$(L default-branch "$D")" main
git -C "$D" branch -m main master
is "D2 a master-only repository: master" "$(L default-branch "$D")" master
git -C "$D" update-ref refs/remotes/origin/trunk master
git -C "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
is "D3 origin/HEAD wins" "$(L default-branch "$D")" trunk
git -C "$D" switch -q -c topic
is "D4 the default target uses origin's default branch" "$(L default-range "$D")" "origin/trunk...topic"
git -C "$D" symbolic-ref --delete refs/remotes/origin/HEAD; git -C "$D" update-ref -d refs/remotes/origin/trunk
is "D5 without origin, the local default branch" "$(L default-range "$D")" "master...topic"
git -C "$D" switch -q --detach
is "D6 a detached HEAD targets HEAD" "$(L default-range "$D")" "master...HEAD"
is "D7 now is UTC to the microsecond" "$(L now | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$')" 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

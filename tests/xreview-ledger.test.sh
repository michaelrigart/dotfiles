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
   "$(cat "$ROOT/bn.patch")" "Binary file b.bin: 100644 $(git -C "$R" rev-parse main:b.bin) -> 100644 $(git -C "$R" rev-parse bn:b.bin)"
is "A25 and the patch holds no NUL byte" "$(tr -d '\000' < "$ROOT/bn.patch" | wc -c | tr -d ' ')" "$(wc -c < "$ROOT/bn.patch" | tr -d ' ')"
variant "$R" glob; printf 'g\n' > "$R/*.txt"; printf 'a\000b\n' > "$R/a.txt"; commit "$R" "a file named *.txt, and a binary a.txt"
L diff "$R" main glob > "$ROOT/glob.patch"
is "A26 a file named *.txt is read literally: its own line shows" "$(grep -c '^+g$' "$ROOT/glob.patch")" 1
is "A27 and does not pull in another .txt path as text" "$(grep -c '^diff --git a/a.txt' "$ROOT/glob.patch")" 0
is "A28 which is summarized as binary" "$(grep -c '^Binary file a.txt: ' "$ROOT/glob.patch")" 1
# The pathspec environment variables a reviewed repository's mise.toml or direnv could set must
# not change what the packet holds.
is "A29 GIT_LITERAL_PATHSPECS=1 does not hide the text change" \
   "$(GIT_LITERAL_PATHSPECS=1 L diff "$R" main glob | grep -c '^+g$')" 1
is "A30 GIT_GLOB_PATHSPECS=1 leaves the packet unchanged" \
   "$(GIT_GLOB_PATHSPECS=1 L diff "$R" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
is "A31 and so does GIT_NOGLOB_PATHSPECS=1" \
   "$(GIT_NOGLOB_PATHSPECS=1 L diff "$R" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
git -C "$R" config diff.relative true; mkdir -p "$R/sub"
is "A32 with binary paths, run from a subdirectory under diff.relative, the packet is the same" \
   "$(L diff "$R/sub" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
git -C "$R" config --unset diff.relative; rmdir "$R/sub"
git -C "$R" reset -q --hard
# x.txt (text) and X.txt (binary), built through the index: case-colliding paths.
h_text="$(printf 'lower\n' | git -C "$R" hash-object -w --stdin)"
h_bin="$(printf 'a\000b\n' | git -C "$R" hash-object -w --stdin)"
variant "$R" icase
git -C "$R" update-index --add --cacheinfo "100644,$h_text,x.txt"
git -C "$R" update-index --add --cacheinfo "100644,$h_bin,X.txt"
git -C "$R" commit -q -m "x.txt and X.txt"; git -C "$R" switch -q -f main   # the two collide on disk
GIT_ICASE_PATHSPECS=1 L diff "$R" main icase > "$ROOT/icase.patch"
is "A33 GIT_ICASE_PATHSPECS=1: no NUL byte in the packet" \
   "$(tr -d '\000' < "$ROOT/icase.patch" | wc -c | tr -d ' ')" "$(wc -c < "$ROOT/icase.patch" | tr -d ' ')"
ZERO="$(printf '0%.0s' {1..40})"
is "A34 X.txt is a summary line" "$(grep -cxF "Binary file X.txt: 000000 $ZERO -> 100644 $h_bin" "$ROOT/icase.patch")" 1
is "A35 and x.txt still shows its text" "$(grep -c '^+lower$' "$ROOT/icase.patch")" 1
variant "$R" bmode; chmod +x "$R/b.bin"; git -C "$R" update-index --chmod=+x b.bin; git -C "$R" commit -q -m "binary mode"
B_ID="$(git -C "$R" rev-parse main:b.bin)"
is "A36 a binary mode-only change shows both modes" "$(L diff "$R" main bmode)" \
   "Binary file b.bin: 100644 $B_ID -> 100755 $B_ID"
variant "$R" nl; printf 'a\000b\n' > "$R/$(printf 'bad\nforged')"; commit "$R" "a binary file with a newline in its name"
L diff "$R" main nl > "$ROOT/nl.patch"
is "A37 a newline in a file name cannot start a packet line" "$(grep -c '^forged' "$ROOT/nl.patch")" 0
is "A38 the name appears quoted" "$(grep -c '^Binary file "bad\\nforged": ' "$ROOT/nl.patch")" 1
is "A39 a packet that does not match the change is refused" "$(/usr/bin/python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = m.git
m.git = lambda repo, *a, raw=False: b"" if "--text" in a else real(repo, *a, raw=raw)
try:
    m.patch(sys.argv[2], "main", "attr"); print("accepted")
except m.Fail as e:
    print("refused" if "does not match the change" in str(e) else str(e))
' "$LEDGER" "$R")" refused
# A change between a regular file, a symlink and a gitlink is a delete plus a create in a patch:
# two headers for one raw record, which the cross-check must expect.
variant "$R" tc; rm "$R/a.txt"; ln -s target "$R/a.txt"; commit "$R" "a.txt becomes a symlink"
out="$(L diff "$R" main tc 2>&1)"
is "A40 a file turned symlink renders the old side" "$(printf '%s\n' "$out" | grep -c '^-one$')" 1
is "A41 and the new side" "$(printf '%s\n' "$out" | grep -c '^+target$')" 1
git -C "$R" switch -q -c tc2 tc; rm "$R/a.txt"; printf 'back\n' > "$R/a.txt"; commit "$R" "a.txt is a file again"
out="$(L diff "$R" tc tc2 2>&1)"
is "A42 a symlink turned file renders the new side" "$(printf '%s\n' "$out" | grep -c '^+back$')" 1
is "A43 and the old side" "$(printf '%s\n' "$out" | grep -c '^-target$')" 1
variant "$R" tg
git -C "$R" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,a.txt
git -C "$R" commit -q -m "a.txt becomes a gitlink"; git -C "$R" switch -q -f main
out="$(L diff "$R" main tg 2>&1)"
is "A44 a file turned gitlink renders the old side" "$(printf '%s\n' "$out" | grep -c '^-one$')" 1
is "A45 and the new side" "$(printf '%s\n' "$out" | grep -c '^+Subproject commit 1111111111111111111111111111111111111111$')" 1
# Path quoting is git's own: short escapes, octal for the rest, bytes of 0x80 and up in octal.
QN=$'q\a\b\v\f\r\001\303\251"\\z'
variant "$R" qp; printf 'a\000b\n' > "$R/$QN"; commit "$R" "a binary file with an awkward name"
git -C "$R" diff --raw --no-renames main qp | cut -f2 > "$ROOT/qp.git"
L diff "$R" main qp | sed -n 's/^Binary file \(.*\): 000000 .*/\1/p' > "$ROOT/qp.ours"
is "A46 the quoted name is what git writes for it" "$(cat "$ROOT/qp.ours")" "$(cat "$ROOT/qp.git")"
is "A47 as spelled out: short escapes, then octal" "$(cat "$ROOT/qp.ours")" '"q\a\b\v\f\r\001\303\251\"\\z"'
git -C "$R" switch -q main
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

echo "E. appends are locked and idempotent (spec 3.2, 3.3)"
E="$ROOT/app"; mkrepo "$E"
EC="$(L normalize "$E" HEAD..HEAD | jq -r .repo)"
EF="$(L path "$E")"
# entry <kind> <nonce> [repo]: a minimal v2 entry for the ledger of <repo> (default: E's).
entry() {
  jq -nc --arg k "$1" --arg n "$2" --arg r "${3:-$EC}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:"2026-10-02T10:00:00.000000Z",checkpoint:"pre-merge",
      targets:[{repo:$r,dest:"main",full:true,fingerprint:"f"}]}'
}
is "E1 a pending entry is appended" "$(L append "$EC" "$(entry pending xr-1)")" appended
is "E2 the ledger directory names its repository" "$(cat "$(dirname "$EF")/repo")" "$EC"
is "E3 the same pending again is already present" "$(L append "$EC" "$(entry pending xr-1)")" present
is "E4 its receipt is appended" "$(L append "$EC" "$(entry receipt xr-1)")" appended
is "E5 a second receipt for that nonce is not" "$(L append "$EC" "$(entry receipt xr-1)")" present
is "E6 so the ledger holds two lines" "$(wc -l < "$EF" | tr -d ' ')" 2
out="$(L append "$EC" "$(entry receipt xr-2 /elsewhere/.git)" 2>&1)"; rc=$?
is "E7 an entry whose target is another repository is refused" "$rc/$(printf '%s' "$out" | grep -c 'not a v2 ledger entry')" "1/1"
out="$(L append "$EC" '{"branch":"main","verdict":"approve"}' 2>&1)"; rc=$?
is "E8 a v1-shaped entry is refused" "$rc" 1
P="$ROOT/par"; mkrepo "$P"; PC="$(L normalize "$P" HEAD..HEAD | jq -r .repo)"; PF="$(L path "$P")"
for i in $(seq 1 20); do L append "$PC" "$(entry pending "xr-par-$i" "$PC")" >/dev/null & done
wait
is "E9 20 concurrent appends produce 20 lines" "$(wc -l < "$PF" | tr -d ' ')" 20
is "E10 every one of them valid JSON" "$(jq -c . < "$PF" 2>/dev/null | wc -l | tr -d ' ')" 20
is "E11 with 20 distinct nonces" "$(jq -r .nonce < "$PF" | sort -u | wc -l | tr -d ' ')" 20
is "E12 and no lock left behind" "$([ -e "$PF.lock" ] && echo held || echo free)" free
mkdir "$PF.lock"
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.3 L append "$PC" "$(entry pending xr-held "$PC")" 2>&1)"; rc=$?
is "E13 a held lock refuses at the bound" "$rc/$(printf '%s' "$out" | grep -c 'is held')" "1/1"
is "E14 and appends nothing" "$(grep -c xr-held "$PF")" 0
is "E15 a fresh lock is never broken" "$([ -d "$PF.lock" ] && echo held || echo free)" held
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$PF.lock"
is "E16 a stale lock is broken" "$(XREVIEW_LEDGER_LOCK_WAIT=0.3 L append "$PC" "$(entry pending xr-stale "$PC")")" appended
is "E17 and released" "$([ -e "$PF.lock" ] && echo held || echo free)" free
L_SHOW="$(L show "$E")"; rc=$?
is "E18 show lists the ledger" "$rc/$(printf '%s\n' "$L_SHOW" | grep -c '"nonce":"xr-1"')" "0/2"
LEG="$XDG_STATE_HOME/xreview/$(printf '%s' "$(git -C "$E" rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$LEG" && printf '{"branch":"main","checkpoint":"pre-merge","verdict":"approve"}\n' > "$LEG/reviews.jsonl"
is "E19 and then the checkout's legacy receipts" "$(L show "$E" | tail -1 | jq -r .branch)" main
out="$(L show "$D")"; rc=$?
is "E20 with nothing on record it exits 1" "$rc/$out" "1/"
# Two writers both find the same stale lock. Breaker A judges it stale and is suspended;
# breaker B breaks it, takes a fresh lock and still holds it when A resumes. The steps run in
# this order, deterministically, through the module's own functions: no sleeps, no races.
LK="$ROOT/interleave.lock"
lines="$(/usr/bin/python3 - "$LEDGER" "$LK" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)
lock, old = sys.argv[2], time.time() - 120

def stale_lock(token):
    os.mkdir(lock)
    with open(os.path.join(lock, "owner"), "w") as fh:
        fh.write(token + "\n")
    os.utime(lock, (old, old))

stale_lock("dead")
seen_by_a = ledger.owner_of(lock)                       # A: "dead", and stale
print("a-saw-stale", seen_by_a, ledger.stale(lock))
token_b = ledger.acquire(lock)                          # B: breaks it, takes a fresh lock
print("b-holds", ledger.owner_of(lock) == token_b)
os.utime(lock, (old, old))      # and is slow: its lock looks stale too, so only the token tells

print("a-breaks", ledger.break_stale(lock, seen_by_a))  # A resumes: the token moved on
print("b-still-holds", ledger.owner_of(lock) == token_b)
ledger.release(lock, "not-the-holder")
print("foreign-release-kept", os.path.isdir(lock))
ledger.release(lock, token_b)
print("own-release-freed", os.path.isdir(lock))
stale_lock("dead2")
os.mkdir(lock + ".break")                               # a writer died holding the break lock
os.utime(lock + ".break", (old, old))
try:
    print("stale-break-lock", "broken", ledger.break_stale(lock, "dead2"))
except ledger.Fail as e:
    print("stale-break-lock", "failed", ("rmdir " + lock + ".break") in str(e))
print("both-left", os.path.isdir(lock + ".break"), os.path.isdir(lock))
os.rmdir(lock + ".break")                               # removed by hand
print("then-broken", ledger.break_stale(lock, "dead2"), os.path.isdir(lock))
stale_lock("dead3")
os.mkdir(lock + ".break")                               # another writer is breaking right now
print("fresh-break-lock-waits", ledger.break_stale(lock, "dead3"), os.path.isdir(lock))
PY
)"
is "E21 breaker A first judges the lock stale" "$(printf '%s\n' "$lines" | grep -c '^a-saw-stale dead True$')" 1
is "E22 breaker B breaks it and holds a fresh lock" "$(printf '%s\n' "$lines" | grep -c '^b-holds True$')" 1
is "E23 A, resuming, never removes B's lock" "$(printf '%s\n' "$lines" | grep -c '^a-breaks False$')" 1
is "E24 B still holds it" "$(printf '%s\n' "$lines" | grep -c '^b-still-holds True$')" 1
is "E25 a release by another token leaves the lock" "$(printf '%s\n' "$lines" | grep -c '^foreign-release-kept True$')" 1
is "E26 B's own release frees it" "$(printf '%s\n' "$lines" | grep -c '^own-release-freed False$')" 1
is "E27 a stale break lock is never removed: breaking fails, naming it to remove by hand" "$(printf '%s\n' "$lines" | grep -c '^stale-break-lock failed True$')" 1
is "E28 both locks are left; removed by hand, the stale lock is then broken" \
   "$(printf '%s\n' "$lines" | grep -c -E '^(both-left True True|then-broken True False)$')" 2
is "E29 a fresh break lock means another breaker is deciding: wait" "$(printf '%s\n' "$lines" | grep -c '^fresh-break-lock-waits False True$')" 1
# A release checks its token and is suspended (the module's test seam) while B, finding A's
# lock stale, tries to break it and take its own. The release holds the break lock, so B must
# wait, and A then removes only its own lock. A release that cannot take the break lock in
# time, or finds it stale, leaves the lock and warns.
LR="$ROOT/release.lock"
lines="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 /usr/bin/python3 - "$LEDGER" "$LR" <<'PY'
import contextlib, importlib.util, io, os, sys, time
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)
lock, old = sys.argv[2], time.time() - 120
token_a = ledger.acquire(lock)
os.utime(lock, (old, old))                    # A is slow: its lock looks stale to B
seen = []

def b_breaks_in():
    try:
        seen.append(("b-acquired", ledger.acquire(lock)))
    except ledger.Fail:
        seen.append(("b-waited", None))

ledger.RELEASE_PAUSE = b_breaks_in
ledger.release(lock, token_a)
ledger.RELEASE_PAUSE = None
print("b-during-release", seen[0][0])
print("release-freed", os.path.isdir(lock), os.path.isdir(lock + ".break"))
token_c = ledger.acquire(lock)
os.mkdir(lock + ".break")                     # a breaker is deciding right now
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ledger.release(lock, token_c)
print("blocked-release-kept", ledger.owner_of(lock) == token_c, "could not take" in err.getvalue())
os.utime(lock + ".break", (old, old))         # that breaker died holding the break lock
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ledger.release(lock, token_c)
print("stale-break-release-kept", ledger.owner_of(lock) == token_c, os.path.isdir(lock + ".break"),
      ("rmdir " + lock + ".break") in err.getvalue())
PY
)"
is "E30 a release holds the break lock: a breaker arriving mid-release waits" "$(printf '%s\n' "$lines" | grep -c '^b-during-release b-waited$')" 1
is "E31 and the release frees its own lock and the break lock" "$(printf '%s\n' "$lines" | grep -c '^release-freed False False$')" 1
is "E32 a release that cannot take the break lock leaves the lock and warns" "$(printf '%s\n' "$lines" | grep -c '^blocked-release-kept True True$')" 1
is "E33 one that finds it stale leaves both, and warns naming it" "$(printf '%s\n' "$lines" | grep -c '^stale-break-release-kept True True True$')" 1
# A writer that died holding the break lock stops every append until it is removed by hand.
mkdir "$PF.lock.break"
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$PF.lock.break"
out="$(L append "$PC" "$(entry pending xr-stuck "$PC")" 2>&1)"; rc=$?
is "E34 a stale break lock: an append fails closed, naming it to remove by hand" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $PF.lock.break)")" "1/1"
is "E35 it appends nothing and leaves the break lock" "$(grep -c xr-stuck "$PF")/$([ -d "$PF.lock.break" ] && echo kept || echo gone)" "0/kept"
rmdir "$PF.lock.break"
is "E36 removed by hand, appends go through again" "$(L append "$PC" "$(entry pending xr-stuck "$PC")")" appended

echo "F. the decision (spec 3.6)"
G="$ROOT/gate"; mkrepo "$G"
variant "$G" feature; printf 'f\n' > "$G/f.txt"; commit "$G" "feature"
git -C "$G" switch -q main
GT="$(L normalize "$G" main...feature)"
GC="$(printf '%s' "$GT" | jq -r .repo)"
# put <nonce> <kind> [verdict] [checkpoint] [target-json] [dispatched_at]: one entry in G's
# ledger; prints appended or present. A pending entry fixes its nonce's dispatch time (now,
# unless given), and the nonce's receipt reuses it.
put() {
  local at="${6:-}"
  if [ -z "$at" ]; then
    if [ "$2" = pending ]; then at="$(L now)"; else at="$(cat "$ROOT/at.$1")"; fi
  fi
  [ "$2" = pending ] && printf '%s' "$at" > "$ROOT/at.$1"
  L append "$GC" "$(jq -nc --arg n "$1" --arg k "$2" --arg v "${3:-}" --arg cp "${4:-pre-merge}" \
      --arg at "$at" --argjson t "${5:-$GT}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:[$t]}
     + (if $k == "receipt" then {verdict:$v,findings:0,thread:"t",turn:"u",tier:""} else {} end)')"
}
# gate [dest] [dest-rev] [tip]: allow or deny for tip landing on dest (default feature on main).
gate() { L decide "$G" "${1:-main}" "${2:-main}" "${3:-feature}" | jq -r 'if .allow then "allow" else "deny" end'; }
why() { L decide "$G" "${1:-main}" "${2:-main}" "${3:-feature}" --branch feature | jq -r .reason; }
is "F1 nothing on record denies" "$(gate)" deny
is "F2 saying so" "$(why)" "no full-range pre-merge review of this change is on record"
put r1 pending >/dev/null
is "F3 a pending review alone denies" "$(gate)" deny
put r1 receipt approve >/dev/null
is "F4 an approved full change allows" "$(gate)" allow
L decide "$G" main main feature >/dev/null; rc=$?
is "F5 decide exits 0 on allow" "$rc" 0
git -C "$G" branch release main
is "F6 the same change into another branch is denied" "$(gate release release)" deny
put r2 pending >/dev/null
is "F7 a newer pending review closes it" "$(gate)" deny
is "F8 and names it" "$(why | grep -c 'pre-merge/pending r2')" 1
L decide "$G" main main feature >/dev/null; rc=$?
is "F9 decide exits 1 on deny" "$rc" 1
put r2 receipt changes >/dev/null
is "F10 a later changes verdict closes it" "$(gate)" deny
put r3 pending >/dev/null; put r3 receipt approve >/dev/null
is "F11 a fresh approving round reopens it" "$(gate)" allow
is "F12 re-collecting a receipt appends nothing" "$(put r3 receipt approve)" present
OLDER="$(L now)"
put r4 pending >/dev/null; put r4 receipt changes >/dev/null
put r5 pending "" pre-merge "$GT" "$OLDER" >/dev/null; put r5 receipt approve >/dev/null
is "F13 an older review's approve collected after a newer changes does not reopen it" "$(gate)" deny
put r6 pending >/dev/null; put r6 receipt approve >/dev/null
is "F14 the latest dispatch decides, whatever the ledger order" "$(gate)" allow
put r7 pending >/dev/null
is "F15 a failed receipt write (its pending entry newest) leaves it closed" "$(gate)" deny
put r7 receipt approve >/dev/null
is "F16 until a later collect records the receipt" "$(gate)" allow
git -C "$G" switch -q feature; printf 'g\n' > "$G/g.txt"; commit "$G" "one extra commit"; git -C "$G" switch -q main
is "F17 one extra commit closes it" "$(gate)" deny
GT2="$(L normalize "$G" main...feature)"
PART="$(L normalize "$G" "$(git -C "$G" rev-parse main)..feature")"
put r8 pending "" pre-merge "$PART" >/dev/null; put r8 receipt approve pre-merge "$PART" >/dev/null
is "F18 a partial-range approve does not open it" "$(gate)" deny
put r9 pending "" spec "$GT2" >/dev/null; put r9 receipt approve spec "$GT2" >/dev/null
put r10 pending "" plan "$GT2" >/dev/null; put r10 receipt approve plan "$GT2" >/dev/null
is "F19 approved spec and plan reviews do not open it" "$(gate)" deny
LEGG="$XDG_STATE_HOME/xreview/$(printf '%s' "$(git -C "$G" rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$LEGG" && printf '{"branch":"feature","checkpoint":"pre-merge","verdict":"approve"}\n' > "$LEGG/reviews.jsonl"
is "F20 a v1 approve does not open it" "$(gate)" deny
rec="$(L decide "$G" main main feature --branch feature | jq -r '.on_record_branch | join("|")')"
is "F21 the branch record lists the v1 receipt" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve (v1, never opens the gate)')" 1
is "F22 the spec review, full" "$(printf '%s' "$rec" | grep -c 'spec/approve r9 at [^ ]* (dest main, full,')" 1
is "F23 and the partial approve" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve r8 at [^ ]* (dest none, partial,')" 1
put r11 pending "" pre-merge "$GT2" >/dev/null; put r11 receipt approve pre-merge "$GT2" >/dev/null
is "F24 a full-range approve of the new head opens it" "$(gate)" allow
AT="$(L now)"
put r12 pending "" pre-merge "$GT2" "$AT" >/dev/null; put r12 receipt approve pre-merge "$GT2" >/dev/null
put r13 pending "" pre-merge "$GT2" "$AT" >/dev/null
is "F25 a review dispatched in the same microsecond, later on record, wins the tie" "$(gate)" deny
put r13 receipt approve pre-merge "$GT2" >/dev/null
git -C "$G" switch -q -c moved main; printf 'm\n' > "$G/m.txt"; commit "$G" "main moves on, elsewhere"
git -C "$G" switch -q main; git -C "$G" merge -q --ff-only moved
git -C "$G" switch -q -c rebased feature; git -C "$G" rebase -q main; git -C "$G" switch -q main
is "F26 a rebased head with an unchanged fingerprint is allowed" "$(gate main main rebased)" allow
is "F27 an empty change is denied" "$(gate main main main)" deny
is "F28 saying so" "$(L decide "$G" main main main | jq -r .reason | grep -c '^the change is empty')" 1
is "F29 a head that is not available locally is denied" \
   "$(L decide "$G" main main 1234567890123456789012345678901234567890 | jq -r .reason | grep -c 'is not available locally; fetch it')" 1
is "F30 a destination that is not available locally is denied" \
   "$(L decide "$G" ghost refs/remotes/origin/ghost feature | jq -r .reason | grep -c '^the destination ghost')" 1
is "F31 outside a repository it is denied" \
   "$(L decide "$ROOT" main main feature | jq -r '"\(.allow) \(.reason)"' | grep -c '^false not inside a git repository')" 1
GF="$(L path "$G")"
chmod 000 "$GF"
is "F32 an unreadable ledger is denied" \
   "$(L decide "$G" main main rebased | jq -r '"\(.allow) \(.reason)"' | grep -c '^false the review ledger .* is unreadable')" 1
chmod 644 "$GF"
is "F33 readable again, it allows" "$(gate main main rebased)" allow

echo "G. repositories never share a ledger (spec 3.3, isolation)"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
for d in "$ROOT/iso/a_b" "$ROOT/iso/a/b"; do
  mkrepo "$d"; variant "$d" feature; printf 'same\n' > "$d/s.txt"; commit "$d" "same change"; git -C "$d" switch -q main
done
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
is "G1 the two repositories hold identical commits" "$(git -C "$ROOT/iso/a_b" rev-parse feature)" "$(git -C "$ROOT/iso/a/b" rev-parse feature)"
is "G2 their old per-checkout keys collide" \
   "$(printf '%s' "$ROOT/iso/a_b" | tr '/' '_')" "$(printf '%s' "$ROOT/iso/a/b" | tr '/' '_')"
differs "G3 their ledgers do not" "$(L path "$ROOT/iso/a_b")" "$(L path "$ROOT/iso/a/b")"
T="$(L normalize "$ROOT/iso/a_b" main...feature)"; C="$(printf '%s' "$T" | jq -r .repo)"
L append "$C" "$(jq -nc --argjson t "$T" '{v:2,kind:"pending",nonce:"xr-iso",dispatched_at:"2026-10-02T00:00:00.000000Z",checkpoint:"pre-merge",targets:[$t]}')" >/dev/null
L append "$C" "$(jq -nc --argjson t "$T" '{v:2,kind:"receipt",nonce:"xr-iso",dispatched_at:"2026-10-02T00:00:00.000000Z",checkpoint:"pre-merge",verdict:"approve",targets:[$t]}')" >/dev/null
is "G4 the approval opens a_b" "$(L decide "$ROOT/iso/a_b" main main feature | jq -r .allow)" true
is "G5 and never a/b, for identical blobs and destination" "$(L decide "$ROOT/iso/a/b" main main feature | jq -r .allow)" false

echo "H. a damaged ledger never lets the gate fail open"
D="$ROOT/dmg"; mkrepo "$D"
variant "$D" feature; printf 'd\n' > "$D/d.txt"; commit "$D" "feature"; git -C "$D" switch -q main
DT="$(L normalize "$D" main...feature)"; DC="$(printf '%s' "$DT" | jq -r .repo)"; DF="$(L path "$D")"
dentry() {
  jq -nc --arg k "$1" --arg n "$2" --argjson t "${3:-$DT}" --arg at "${4-$(L now)}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:$at,checkpoint:"pre-merge",targets:[$t]}
     + (if $k == "receipt" then {verdict:"approve",findings:0,thread:"t",turn:"u",tier:""} else {} end)'
}
DAT="$(L now)"
L append "$DC" "$(dentry pending r1 "$DT" "$DAT")" >/dev/null; L append "$DC" "$(dentry receipt r1 "$DT" "$DAT")" >/dev/null
is "H1 an approved change allows" "$(L decide "$D" main main feature | jq -r .allow)" true
printf '{"v":2,"kind":"receipt","nonce":"other","dispa' >> "$DF"
is "H2 a later pending entry is appended after a partial line" "$(L append "$DC" "$(dentry pending r2)")" appended
is "H3 it is readable" "$(grep -c '"nonce":"r2"' "$DF")" 1
is "H4 and it closes the gate" "$(L decide "$D" main main feature | jq -r .allow)" false
is "H5 on a line of its own" "$(grep -c '^{"v":2,"kind":"pending","nonce":"r2"' "$DF")" 1
before="$(wc -c < "$DF" | tr -d ' ')"
for bad in "2026-10-02T00:00:00Z" "" "x"; do
  out="$(L append "$DC" "$(dentry pending r3 "$DT" "$bad")" 2>&1)"; rc=$?
  is "H6 dispatched_at '$bad' is refused" "$rc/$(printf '%s' "$out" | grep -c 'not a v2 ledger entry')" "1/1"
done
is "H7 and nothing is appended" "$(wc -c < "$DF" | tr -d ' ')" "$before"
NUMT="$(printf '%s' "$DT" | jq -c '.fingerprint = 12345 | .branch = "numeric"')"
L append "$DC" "$(dentry pending r4 "$NUMT")" >/dev/null
out="$(L decide "$D" main main feature --branch numeric 2>&1)"; rc=$?
is "H8 a numeric fingerprint is no traceback" "$([ "$rc" -le 1 ] && printf '%s' "$out" | jq -e 'has("allow")' >/dev/null && ! printf '%s' "$out" | grep -q Traceback && echo ok)" ok
is "H9 and the branch record shows it" "$(printf '%s' "$out" | jq -r '.on_record_branch | join("|")' | grep -c 'pending r4')" 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

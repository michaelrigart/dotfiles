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
# verdict <repo> <dest> <dest-rev> <tip>: allow, or deny and the gate's reason, with any review's
# dispatch time left out of the reason so that a deny test can pin why it is denied.
VERDICT='if .allow then "allow" else "deny: " + (.reason | gsub(" at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z"; "")) end'
verdict() { L decide "$@" | jq -r "$VERDICT"; }

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
# diff.submodule=diff makes a patch of a bumped gitlink start a child `git diff` inside the
# submodule, which has no --no-ext-diff of its own: the submodule's diff.external and textconv
# driver would run. Each writes its own marker; the patch must still show the gitlink.
SMR="$ROOT/sm-super"; SMS="$ROOT/sm-src"; SMK="$ROOT/sm-marks"; mkdir -p "$SMK"
mkrepo "$SMS"; mkrepo "$SMR"
git -C "$SMR" -c protocol.file.allow=always submodule add -q "$SMS" sm 2>/dev/null
git -C "$SMR" commit -q -m "add the submodule"
variant "$SMR" bump
printf 'changed\n' > "$SMR/sm/a.txt"; git -C "$SMR/sm" commit -q -am "move the submodule"
git -C "$SMR" add sm; git -C "$SMR" commit -q -m "bump the gitlink"
printf '#!/bin/sh\ntouch "%s/external"\nexit 0\n' "$SMK" > "$ROOT/sm-external"; chmod +x "$ROOT/sm-external"
printf '#!/bin/sh\ntouch "%s/textconv"\ncat "$1"\n' "$SMK" > "$ROOT/sm-textconv"; chmod +x "$ROOT/sm-textconv"
git -C "$SMR/sm" config diff.external "$ROOT/sm-external"
git -C "$SMR/sm" config diff.m.textconv "$ROOT/sm-textconv"
printf '*.txt diff=m\n' > "$(git -C "$SMR/sm" rev-parse --path-format=absolute --git-path info/attributes)"
SM_FP="$(fp "$SMR" main bump)"
git -C "$SMR" config diff.submodule diff
rm -f "$SMK"/*
out="$(L diff "$SMR" main bump 2>&1)"
is "A48 a bumped gitlink under diff.submodule=diff renders as a gitlink" \
   "$(printf '%s\n' "$out" | grep -c '^+Subproject commit [0-9a-f]\{40\}$')" 1
is "A49 and neither the submodule's diff.external nor its textconv ran" "$(ls "$SMK" | tr '\n' ' ')" ""
git -C "$SMR/sm" config --unset diff.external; rm -f "$SMK"/*   # the external driver outranks textconv
L diff "$SMR" main bump >/dev/null 2>&1
is "A49b nor the textconv driver alone" "$(ls "$SMK" | tr '\n' ' ')" ""
is "A50 the fingerprint ignores diff.submodule too" "$(fp "$SMR" main bump)" "$SM_FP"
git -C "$SMR" config diff.submodule log
is "A51 diff.submodule=log does not turn the gitlink into prose" \
   "$(L diff "$SMR" main bump 2>&1 | grep -c '^+Subproject commit [0-9a-f]\{40\}$')" 1

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
# A symbolic left side names the branch it points at: origin/HEAD is origin's default branch,
# never a destination called HEAD.
git -C "$N" update-ref refs/remotes/origin/main main
git -C "$N" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
t="$(L normalize "$N" origin/HEAD...feature)"
is "B22 origin/HEAD...feature lands on origin's main" \
   "$(printf '%s' "$t" | jq -r '"\(.dest) \(.dest_ref) \(.full)"')" "main origin/main true"
is "B23 and names the same change as origin/main...feature" "$(printf '%s' "$t" | jq -r .fingerprint)" \
   "$(L normalize "$N" origin/main...feature | jq -r .fingerprint)"
git -C "$N" symbolic-ref refs/heads/trunk refs/heads/main
is "B24 a local symbolic branch names its target" \
   "$(L normalize "$N" trunk...feature | jq -r '"\(.dest) \(.dest_ref)"')" "main main"
git -C "$N" tag v1 main; git -C "$N" symbolic-ref refs/remotes/origin/HEAD refs/tags/v1
out="$(L normalize "$N" origin/HEAD...feature 2>&1)"; rc=$?
is "B25 one pointing at no branch is refused" "$rc/$(printf '%s' "$out" | grep -c 'neither a branch nor origin')" "1/1"
git -C "$N" symbolic-ref --delete refs/remotes/origin/HEAD; git -C "$N" update-ref refs/remotes/origin/HEAD main
out="$(L normalize "$N" origin/HEAD...feature 2>&1)"; rc=$?
is "B26 a plain ref named HEAD is refused" "$rc/$(printf '%s' "$out" | grep -c 'names HEAD, not a branch')" "1/1"
git -C "$N" update-ref -d refs/remotes/origin/HEAD; git -C "$N" symbolic-ref --delete refs/heads/trunk
git -C "$N" tag -d v1 >/dev/null

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
# gate [dest] [dest-rev] [tip]: allow, or deny and why, for tip landing on dest (default feature
# on main).
gate() { verdict "$G" "${1:-main}" "${2:-main}" "${3:-feature}"; }
why() { L decide "$G" "${1:-main}" "${2:-main}" "${3:-feature}" --branch feature | jq -r .reason; }
NONE="deny: no full-range pre-merge review of this change is on record"
latest() { printf 'deny: the latest review of this change is pre-merge/%s, not an approval' "$1"; }
is "F1 nothing on record denies" "$(gate)" "$NONE"
is "F2 saying so" "$(why)" "no full-range pre-merge review of this change is on record"
put r1 pending >/dev/null
is "F3 a pending review alone denies" "$(gate)" "$(latest 'pending r1')"
put r1 receipt approve >/dev/null
is "F4 an approved full change allows" "$(gate)" allow
L decide "$G" main main feature >/dev/null; rc=$?
is "F5 decide exits 0 on allow" "$rc" 0
git -C "$G" branch release main
is "F6 the same change into another branch is denied" "$(gate release release)" "$NONE"
put r2 pending >/dev/null
is "F7 a newer pending review closes it" "$(gate)" "$(latest 'pending r2')"
is "F8 and names it" "$(why | grep -c 'pre-merge/pending r2')" 1
L decide "$G" main main feature >/dev/null; rc=$?
is "F9 decide exits 1 on deny" "$rc" 1
put r2 receipt changes >/dev/null
is "F10 a later changes verdict closes it" "$(gate)" "$(latest 'changes r2')"
put r3 pending >/dev/null; put r3 receipt approve >/dev/null
is "F11 a fresh approving round reopens it" "$(gate)" allow
is "F12 re-collecting a receipt appends nothing" "$(put r3 receipt approve)" present
OLDER="$(L now)"
put r4 pending >/dev/null; put r4 receipt changes >/dev/null
put r5 pending "" pre-merge "$GT" "$OLDER" >/dev/null; put r5 receipt approve >/dev/null
is "F13 an older review's approve collected after a newer changes does not reopen it" "$(gate)" "$(latest 'changes r4')"
put r6 pending >/dev/null; put r6 receipt approve >/dev/null
is "F14 the latest dispatch decides, whatever the ledger order" "$(gate)" allow
put r7 pending >/dev/null
is "F15 a failed receipt write (its pending entry newest) leaves it closed" "$(gate)" "$(latest 'pending r7')"
put r7 receipt approve >/dev/null
is "F16 until a later collect records the receipt" "$(gate)" allow
git -C "$G" switch -q feature; printf 'g\n' > "$G/g.txt"; commit "$G" "one extra commit"; git -C "$G" switch -q main
is "F17 one extra commit closes it" "$(gate)" "$NONE"
GT2="$(L normalize "$G" main...feature)"
PART="$(L normalize "$G" "$(git -C "$G" rev-parse main)..feature")"
put r8 pending "" pre-merge "$PART" >/dev/null; put r8 receipt approve pre-merge "$PART" >/dev/null
is "F18 a partial-range approve does not open it" "$(gate)" "$NONE"
put r9 pending "" spec "$GT2" >/dev/null; put r9 receipt approve spec "$GT2" >/dev/null
put r10 pending "" plan "$GT2" >/dev/null; put r10 receipt approve plan "$GT2" >/dev/null
is "F19 approved spec and plan reviews do not open it" "$(gate)" "$NONE"
LEGG="$XDG_STATE_HOME/xreview/$(printf '%s' "$(git -C "$G" rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$LEGG" && printf '{"branch":"feature","checkpoint":"pre-merge","verdict":"approve"}\n' > "$LEGG/reviews.jsonl"
is "F20 a v1 approve does not open it" "$(gate)" "$NONE"
rec="$(L decide "$G" main main feature --branch feature | jq -r '.on_record_branch | join("|")')"
is "F21 the branch record lists the v1 receipt" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve (v1, never opens the gate)')" 1
is "F22 the spec review, full" "$(printf '%s' "$rec" | grep -c 'spec/approve r9 at [^ ]* (dest main, full,')" 1
is "F23 and the partial approve" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve r8 at [^ ]* (dest none, partial,')" 1
put r11 pending "" pre-merge "$GT2" >/dev/null; put r11 receipt approve pre-merge "$GT2" >/dev/null
is "F24 a full-range approve of the new head opens it" "$(gate)" allow
AT="$(L now)"
put r12 pending "" pre-merge "$GT2" "$AT" >/dev/null; put r12 receipt approve pre-merge "$GT2" >/dev/null
put r13 pending "" pre-merge "$GT2" "$AT" >/dev/null
is "F25 a review dispatched in the same microsecond, later on record, wins the tie" "$(gate)" "$(latest 'pending r13')"
put r13 receipt approve pre-merge "$GT2" >/dev/null
git -C "$G" switch -q -c moved main; printf 'm\n' > "$G/m.txt"; commit "$G" "main moves on, elsewhere"
git -C "$G" switch -q main; git -C "$G" merge -q --ff-only moved
git -C "$G" switch -q -c rebased feature; git -C "$G" rebase -q main; git -C "$G" switch -q main
is "F26 a rebased head with an unchanged fingerprint is allowed" "$(gate main main rebased)" allow
is "F27 an empty change is denied" "$(gate main main main)" "deny: the change is empty: main holds nothing that main lacks"
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
is "G5 and never a/b, for identical blobs and destination" "$(verdict "$ROOT/iso/a/b" main main feature)" \
   "deny: no full-range pre-merge review of this change is on record"

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
is "H4 and it closes the gate" "$(verdict "$D" main main feature)" \
   "deny: the latest review of this change is pre-merge/pending r2, not an approval"
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

echo "I. the diff never lazy-fetches from a partial clone's remote"
# Reading a blob that a blob-filtered partial clone lacks fetches it, which runs the remote's
# uploadpack command, named by a configuration the sandbox can write, outside the sandbox. The
# marker is what that command leaves. The patch needs the blob and so fails closed (non-zero,
# a reason on stderr, nothing on stdout); the fingerprint reads no blob and still answers.
LO="$ROOT/lazy-origin"; LC="$ROOT/lazy-clone"; LM="$ROOT/lazy-marks"; mkdir -p "$LO" "$LM"
git -C "$LO" init -q && git -C "$LO" config uploadpack.allowFilter true
git -C "$LO" config uploadpack.allowAnySHA1InWant true
seq 1 40 > "$LO/a.txt"; git -C "$LO" add . && git -C "$LO" commit -q -m init
git -C "$LO" switch -q -c feat; echo extra >> "$LO/a.txt"; git -C "$LO" add -A && git -C "$LO" commit -q -m edit
git clone -q --no-checkout --filter=blob:none "file://$LO" "$LC" 2>/dev/null
git -C "$LC" update-ref refs/heads/feat refs/remotes/origin/feat
git -C "$LC" update-ref refs/heads/main refs/remotes/origin/main
printf '#!/bin/sh\ntouch "%s/uploadpack"\nexec git upload-pack "$@"\n' "$LM" > "$ROOT/evil-uploadpack"
chmod +x "$ROOT/evil-uploadpack"; git -C "$LC" config remote.origin.uploadpack "$ROOT/evil-uploadpack"
is "I0 the fixture is a blob-filtered partial clone with the new blob missing" \
   "$(git -C "$LC" config remote.origin.partialclonefilter) $(GIT_NO_LAZY_FETCH=1 git -C "$LC" cat-file -e "$(git -C "$LO" rev-parse feat:a.txt)" 2>/dev/null; echo $?)" "blob:none 1"
rm -f "$LM"/*
out="$(L diff "$LC" main feat 2>"$ROOT/lazy.err")"; rc=$?
is "I1 the diff, which needs the blob, fails closed" "$rc $(printf '%s' "$out" | wc -c | tr -d ' ') $(grep -c . "$ROOT/lazy.err")" "1 0 1"
is "I2 the remote's uploadpack never ran for it" "$(ls "$LM" | tr '\n' ' ')" ""
rm -f "$LM"/*
differs "I3 the fingerprint, which reads no blob, still answers" "$(fp "$LC" main feat)" ""
is "I4 and the remote's uploadpack never ran for it either" "$(ls "$LM" | tr '\n' ' ')" ""

echo "J. plan patches and plan blobs (spec 2026-10-25 section 3.5)"
PXR="$ROOT/px"; mkrepo "$PXR"
variant "$PXR" px; sed -i '' 's/^two$/TWO/' "$PXR/a.txt"; sed -i '' 's/^    y = 1$/    y = 2/' "$PXR/s.py"
commit "$PXR" "edit a and s"
out="$(L diff "$PXR" main px --exclude a.txt)"; rc=$?
is "PX1 --exclude drops that file's patch, keeps the others, and the header check passes" \
   "$rc $(printf '%s\n' "$out" | grep -c '^diff --git a/a.txt ') $(printf '%s\n' "$out" | grep -c '^diff --git a/s.py ')" "0 0 1"
is "PX1b every path excluded leaves an empty packet" "$(L diff "$PXR" main px --exclude a.txt --exclude s.py | wc -c | tr -d ' ')" 0
is "PX1c without --exclude both are there" "$(L diff "$PXR" main px | grep -c '^diff --git ')" 2
is "PX1d an exclusion is a literal path: a glob drops nothing" "$(L diff "$PXR" main px --exclude '*.txt' | grep -c '^diff --git ')" 2
is "PX1e and the fingerprint is the range's, whatever is left out of the packet" \
   "$(fp "$PXR" main px | grep -cE '^[0-9a-f]{64}$')" 1
variant "$PXR" pxb; printf '\000\001\002\003\010' > "$PXR/b.bin"; sed -i '' 's/^two$/TWO/' "$PXR/a.txt"; commit "$PXR" "binary and text"
out="$(L diff "$PXR" main pxb --exclude b.bin)"; rc=$?
is "PX2 excluding a binary path removes its summary line too" \
   "$rc $(printf '%s\n' "$out" | grep -c '^Binary file b.bin: ') $(printf '%s\n' "$out" | grep -c '^diff --git a/a.txt ')" "0 0 1"
is "PX2b and without it the summary is there" "$(L diff "$PXR" main pxb | grep -c '^Binary file b.bin: ')" 1
variant "$PXR" pxt; rm "$PXR/a.txt"; ln -s target "$PXR/a.txt"; sed -i '' 's/^    y = 1$/    y = 3/' "$PXR/s.py"
commit "$PXR" "a.txt becomes a symlink, s.py edited"
out="$(L diff "$PXR" main pxt --exclude a.txt)"; rc=$?
is "PX3 excluding a file-to-symlink change (two headers, one record) still passes the header check" \
   "$rc $(printf '%s\n' "$out" | grep -c '^diff --git a/a.txt ') $(printf '%s\n' "$out" | grep -c '^diff --git a/s.py ')" "0 0 1"
is "PX3b and without it both headers of that change are there" "$(L diff "$PXR" main pxt | grep -c '^diff --git a/a.txt ')" 2
OB="$(git -C "$PXR" rev-parse main:a.txt)"; NB="$(git -C "$PXR" rev-parse px:a.txt)"
L blob-patch "$PXR" docs/x.md - "$NB" > "$ROOT/bp-add.patch"; rc=$?
is "PB1 blob-patch from - renders a whole-file add" "$rc/$(cat "$ROOT/bp-add.patch" | head -5 | tr '\n' '|')" \
   "0/diff --git a/docs/x.md b/docs/x.md|new file mode 100644|index 0000000..${NB:0:7}|--- /dev/null|+++ b/docs/x.md|"
is "PB1b with the whole file as additions" "$(grep -c '^+' "$ROOT/bp-add.patch")" 9
is "PB1c under one hunk header" "$(grep -c '^@@ -0,0 +1,8 @@$' "$ROOT/bp-add.patch")" 1
L blob-patch "$PXR" docs/x.md "$OB" "$NB" > "$ROOT/bp-mod.patch"; rc=$?
is "PB2 between two blobs it renders their diff, under the path given" "$rc/$(head -4 "$ROOT/bp-mod.patch" | tr '\n' '|')" \
   "0/diff --git a/docs/x.md b/docs/x.md|index ${OB:0:7}..${NB:0:7} 100644|--- a/docs/x.md|+++ b/docs/x.md|"
is "PB2b with the changed line and nothing of the blob ids as a path" \
   "$(grep -c '^-two$' "$ROOT/bp-mod.patch")/$(grep -c '^+TWO$' "$ROOT/bp-mod.patch")/$(grep -c "a/$OB" "$ROOT/bp-mod.patch")" "1/1/0"
is "PB3 identical blobs give no patch" "$(L blob-patch "$PXR" docs/x.md "$NB" "$NB" | wc -c | tr -d ' ')" 0
out="$(L blob-patch "$PXR" docs/x.md "$OB" 0123456789abcdef0123456789abcdef01234567 2>&1)"; rc=$?
is "PB4 a blob that is not there fails closed" "$rc/$(printf '%s' "$out" | grep -c .)" "1/1"
git -C "$PXR" config diff.external "$ROOT/silent-diff"
is "PB5 a configured external diff driver is not run" "$(L blob-patch "$PXR" docs/x.md "$OB" "$NB" | grep -c '^+TWO$')" 1
git -C "$PXR" config --unset diff.external
# plan_blobs: a plan added within base..tip, named by its blob at the tip.
PL="$ROOT/plans"; mkrepo "$PL"
mkdir -p "$PL/docs/superpowers/plans"
printf 'unchanged plan\n' > "$PL/docs/superpowers/plans/2026-01-01-unchanged.md"
printf 'old plan\n' > "$PL/docs/superpowers/plans/2026-01-02-modified.md"
commit "$PL" "two plans exist"
variant "$PL" pl
printf 'new plan\nline two\n' > "$PL/docs/superpowers/plans/2026-02-01-added.md"
printf 'old plan\nmore\n' > "$PL/docs/superpowers/plans/2026-01-02-modified.md"
printf 'not a plan\n' > "$PL/docs/superpowers/specs-added.md"
mkdir -p "$PL/docs/superpowers/plans/sub"; printf 'nested\n' > "$PL/docs/superpowers/plans/sub/n.md"
commit "$PL" "add a plan, modify one, add a non-plan"
plan_blobs_json() {
  /usr/bin/python3 -c '
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.plan_blobs(sys.argv[2], sys.argv[3], sys.argv[4]), sort_keys=True, separators=(",", ":")))
' "$LEDGER" "$@"
}
is "PL1 plan_blobs names the added plans, by blob at the tip, and not the modified or unchanged ones" \
   "$(plan_blobs_json "$PL" main pl)" \
   "$(jq -nSc --arg a "$(git -C "$PL" rev-parse pl:docs/superpowers/plans/2026-02-01-added.md)" \
        --arg n "$(git -C "$PL" rev-parse pl:docs/superpowers/plans/sub/n.md)" \
        '{"docs/superpowers/plans/2026-02-01-added.md":$a,"docs/superpowers/plans/sub/n.md":$n}')"
is "PL2 a range with no plan added has none" "$(plan_blobs_json "$PL" pl pl)" "{}"
# A plan whose blob holds a NUL byte, at its start or past git's own 8000-byte probe, was shown
# only as a Binary file line: its content was never in the packet.
git -C "$PL" switch -q -c plnul pl
printf 'binary\000plan\n' > "$PL/docs/superpowers/plans/2026-03-01-nul.md"
{ head -c 9000 /dev/zero | tr '\0' x; printf '\000\n'; } > "$PL/docs/superpowers/plans/2026-03-02-late-nul.md"
commit "$PL" "two plans that hold a NUL byte"
is "PL3 a plan whose blob holds a NUL byte is not in plan_blobs" \
   "$(plan_blobs_json "$PL" main plnul)" "$(plan_blobs_json "$PL" main pl)"

echo "K. the gate judges wholeness from the receipt alone (spec 2026-10-25 section 3.4-3.7)"
WH="$ROOT/whole"; mkrepo "$WH"
git -C "$WH" branch other main
variant "$WH" feat
for i in 1 2 3; do printf 'c%s\n' "$i" > "$WH/c$i.txt"; commit "$WH" "c$i"; eval "C$i=\$(git -C \"\$WH\" rev-parse HEAD)"; done
git -C "$WH" switch -q other; printf 'o\n' > "$WH/o.txt"; commit "$WH" "unrelated"; CO="$(git -C "$WH" rev-parse HEAD)"
git -C "$WH" switch -q main
WC="$(L normalize "$WH" main...feat | jq -r .repo)"
SW_OFF='{"framing":false,"fit":false,"delta":false,"omit_plans":false}'
SW_FRAME='{"framing":true,"fit":false,"delta":false,"omit_plans":false}'
SW_FIT='{"framing":true,"fit":true,"delta":false,"omit_plans":false}'
SW_ALL='{"framing":true,"fit":true,"delta":true,"omit_plans":true}'
# tx <packet> [delta_from|null] [history-json] [missing-json] [plans_from-json]: a target's
# new fields. rxj <clean> <compacted|-> <switches-json> [thread] [turn]: a receipt's own.
tx() {
  jq -nc --arg p "$1" --argjson d "$(jq -nc --arg d "${2:-null}" 'if $d == "null" then null else $d end')" \
    --argjson h "${3:-[]}" --argjson m "${4:-[]}" --argjson pl "${5:-[]}" \
    '{packet:$p,missing:$m,delta_from:$d,history:$h,plans_from:$pl}'
}
rxj() {
  jq -nc --argjson c "$1" --arg k "$2" --argjson s "$3" --arg th "${4:-T1}" --arg tu "${5:-u}" \
    '{clean:$c,switches:$s,thread:$th,turn:$tu} + (if $k == "-" then {} else {compacted:($k | fromjson)} end)'
}
# wrec <nonce> <tip> <checkpoint> <verdict> <receipt-json> [target-json]: a pending entry, then
# its receipt, for the change main...<tip>, with the receipt's and the target's extra fields.
wrec() {
  local at t tx="${6:-}"; [ -n "$tx" ] || tx='{}'
  at="$(L now)"; t="$(L normalize "$WH" "main...$2" | jq -c --argjson x "$tx" '. + $x')"
  L append "$WC" "$(jq -nc --arg n "$1" --arg at "$at" --arg cp "$3" --argjson t "$t" \
    '{v:2,kind:"pending",nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:[$t]}')" >/dev/null
  L append "$WC" "$(jq -nc --arg n "$1" --arg at "$at" --arg cp "$3" --arg v "$4" --argjson rx "$5" --argjson t "$t" \
    '{v:2,kind:"receipt",nonce:$n,dispatched_at:$at,checkpoint:$cp,verdict:$v,findings:0,thread:"T1",turn:"u",tier:"",targets:[$t]} + $rx')" >/dev/null
}
# wgate: allow, or deny and why; a reason that the approval is not whole is shortened to
# "not whole: <why>", so every deny case pins the rule that denied it.
short() { sed 's/^deny: the latest approval is not whole: /deny: not whole: /'; }
wgate() { verdict "$WH" main main feat | short; }
wwhy() { L decide "$WH" main main feat | jq -r .reason; }
notwhole() { printf '%s' "$1" | grep -c '^the latest approval is not whole: '; }
NW="deny: not whole:"
GAP="$NW reviewed_files left out files of the packet (missing is not empty)"
COMPACT="$NW the review thread may have compacted during the turn (compacted is not false)"
# wa <nonce> <target-json> <receipt-json>: an approval of the whole change (tip C3).
wa() { wrec "$1" "$C3" pre-merge approve "$3" "$2"; }
# The chain every delta case follows: a full root on T1 at C1, and a delta at C2 from it.
wrec w-root "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 U1)" "$(tx full)"
wrec w-l2 "$C2" pre-merge approve "$(rxj true false "$SW_ALL" T1 U2)" "$(tx delta w-root '["U1"]')"

wa w1 '{}' '{}'
is "W1 a receipt with no packet predates the design and is whole" "$(wgate)" allow
wa w2 "$(tx full)" "$(rxj true false "$SW_FRAME")"
is "W2 a full packet, framing on, nothing missing: allowed" "$(wgate)" allow
wa w2b "$(tx full null '[]' '["a.txt"]')" "$(rxj false false "$SW_FRAME")"
is "W2b framing on and a coverage gap: denied" "$(wgate)" "$GAP"
is "W2c saying the approval is not whole, and why" \
   "$(notwhole "$(wwhy)")/$(wwhy | grep -c 'missing')" "1/1"
wa w2c "$(tx full)" "$(rxj true false "$SW_FRAME" | jq -c 'del(.switches)')"
is "W2d a packeted receipt with no switches is denied: xreview always records them" "$(wgate)" \
   "$NW the switches at dispatch are not recorded"
wa w2e "$(tx full null '[]' '["a.txt"]')" "$(rxj true false "$SW_FRAME")"
is "W2e a coverage gap is denied whatever clean says" "$(wgate)" "$GAP"
wa w2f "$(tx full | jq -c 'del(.missing)')" "$(rxj true false "$SW_FRAME")"
is "W2f a receipt with framing on and no missing field is denied" "$(wgate)" "$GAP"
wa w2g "$(tx full | jq -c '.missing = null')" "$(rxj true false "$SW_FRAME")"
is "W2g and so is missing: null" "$(wgate)" "$GAP"
wa w2h "$(tx full | jq -c '.missing = "none"')" "$(rxj true false "$SW_FRAME")"
is "W2h and a missing that is not a list" "$(wgate)" "$GAP"
wa w3 "$(tx full null '[]' '["a.txt"]')" "$(rxj false false "$SW_OFF")"
is "W3 framing off ignores missing" "$(wgate)" allow
wa w3b "$(tx full null '[]' '["a.txt"]')" "$(rxj false false '{"framing":"true","fit":1,"delta":false,"omit_plans":false}')"
is "W3b a switch that is not exactly true counts as off" "$(wgate)" allow
wa w4 "$(tx delta w-l2 '["U1","U2"]')" "$(rxj true true "$SW_ALL" T1 U3)"
is "W4 a compacted delta is denied" "$(wgate)" "$COMPACT"
is "W4b saying so" "$(wwhy | grep -c 'compact')" 1
wa w5 "$(tx slices)" "$(rxj true true "$SW_FRAME")"
is "W5 a compacted slices receipt is denied, fit on or off" "$(wgate)" "$COMPACT"
wa w5b "$(tx slices)" "$(rxj true false "$SW_FRAME")"
is "W5b an uncompacted one is allowed" "$(wgate)" allow
wa w6 "$(tx full)" "$(rxj false true "$SW_FIT")"
is "W6 a compacted full packet is denied with fit on" "$(wgate)" "$COMPACT"
wa w7 "$(tx full)" "$(rxj false true "$SW_FRAME")"
is "W7 and allowed with fit off, as today" "$(wgate)" allow
wa w7b "$(tx full)" "$(rxj false true "$SW_OFF")"
is "W7b with every switch off too" "$(wgate)" allow
wa w8 "$(tx delta w-l2 '["U1","U2"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W8 a valid two-link delta chain is allowed" "$(wgate)" allow
wa w8b "$(tx delta w-root '["U1"]')" "$(rxj true false "$SW_ALL" T1 U2b)"
is "W8b so is a one-link chain" "$(wgate)" allow
wa w9 "$(tx delta w-nowhere '["U1","U2"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W9 a delta whose delta_from is on no receipt is denied" "$(wgate)" "$NW w9 follows w-nowhere, which is no receipt in this ledger"
is "W9b saying so" "$(notwhole "$(wwhy)")" 1
wa w9c "$(tx delta | jq -c '.delta_from = null')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W9c a delta with no delta_from is denied" "$(wgate)" "$NW the delta of w9c names no receipt it follows"
wrec w-badbase "$C2" pre-merge approve "$(rxj true false "$SW_ALL" T1 UB)" "$(tx delta w-root '["U1"]' | jq -c '.base = "0123456789abcdef0123456789abcdef01234567"')"
wa w10 "$(tx delta w-badbase '["U1","UB"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10 a link on another base is denied" "$(wgate)" "$NW w-badbase has no full-range target on the destination and base of w10"
wrec w-unclean "$C2" pre-merge approve "$(rxj false false "$SW_ALL" T1 UU)" "$(tx delta w-root '["U1"]')"
wa w10b "$(tx delta w-unclean '["U1","UU"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10b a link that is not clean is denied" "$(wgate)" "$NW w-unclean, a link of the chain, is not clean"
wrec w-uncleanroot "$C1" pre-merge approve "$(rxj false false "$SW_ALL" T1 UR)" "$(tx full)"
wa w10c "$(tx delta w-uncleanroot '["UR"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10c and so is a root that is not" "$(wgate)" "$NW w-uncleanroot, a link of the chain, is not clean"
wrec w-cleannull "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UN | jq -c '.clean = "true"')" "$(tx full)"
wa w10d "$(tx delta w-cleannull '["UN"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10d clean is read as exactly true, never for truthiness" "$(wgate)" "$NW w-cleannull, a link of the chain, is not clean"
wrec w-sroot "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T9 US)" "$(tx slices)"
wa w10e "$(tx delta w-sroot '["US"]')" "$(rxj true false "$SW_ALL" T9 U3)"
is "W10e a chain rooted in a sliced round is denied" "$(wgate)" "$NW the chain reaches w-sroot, a slices packet, not a full root"
# The root records everything a link needs (clean, a turn, plans_from) except a packet kind.
wrec w-legacyroot "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UL)" '{"plans_from":[]}'
wa w10f "$(tx delta w-legacyroot '["UL"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10f nor does a receipt with no packet root one" "$(wgate)" \
   "$NW the chain reaches w-legacyroot, which records no packet kind, not a full root"
wrec w-otherthread "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T2 UT)" "$(tx full)"
wa w10g "$(tx delta w-otherthread '["UT"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10g a link on another thread is denied" "$(wgate)" "$NW w-otherthread is not on the thread of w10g"
wrec w-forked "$CO" pre-merge approve "$(rxj true false "$SW_ALL" T1 UF)" "$(tx full)"
wa w10h "$(tx delta w-forked '["UF"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10h a link whose tip is not an ancestor of the delta's tip is denied" "$(wgate)" "$NW the tip of w-forked is not where the delta of w10h starts"
wrec w-cyc2 "$C2" pre-merge approve "$(rxj true false "$SW_ALL" T1 UC2)" "$(tx delta w-cyc '["UC","UC2"]')"
wrec w-cyc "$C3" pre-merge approve "$(rxj true false "$SW_ALL" T1 UC)" "$(tx delta w-cyc2 '["UC2","UC"]')"
is "W10i a cycle is denied, and the walk ends" "$(wgate)" "$NW the delta chain loops back to w-cyc"
wa w10j "$(tx delta w10j '["U3"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W10j a delta that follows itself is denied" "$(wgate)" "$NW the delta chain loops back to w10j"
wrec w-l2c "$C2" pre-merge changes "$(rxj true false "$SW_ALL" T1 U2c)" "$(tx delta w-root '["U1"]')"
wa w11 "$(tx delta w-l2c '["U1","U2c"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W11 a link whose verdict was changes is allowed" "$(wgate)" allow
wa w12 "$(tx delta w-l2 '["U2"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W12 a history that omits a chain turn is denied" "$(wgate)" "$NW the history lacks the chain turn U1, or lists it out of order"
is "W12b saying so" "$(wwhy | grep -c 'history')" 1
wa w12b "$(tx delta w-l2 '["U2","U1"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W12c a history that lists them out of order is denied" "$(wgate)" "$NW the history lacks the chain turn U2, or lists it out of order"
wa w12c "$(tx delta w-l2 '["U1","X","U2","Y"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W12d turns of the thread's own between chain turns are fine" "$(wgate)" allow
wa w12d "$(tx delta w-l2 | jq -c 'del(.history)')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W12e a delta with no history is denied" "$(wgate)" "$NW the history of the thread is not recorded"
wa w12e "$(tx delta w-l2 '["U1","U2"]' | jq -c '.history = "U1,U2"')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W12f and a history that is not a list" "$(wgate)" "$NW the history of the thread is not recorded"
# plans_from: each entry {path, nonce, blob} must be backed by a clean, approved plan receipt.
PP="docs/superpowers/plans/2026-10-25-x.md"
pf() { jq -nc --arg p "$PP" --arg n "$1" --arg b "$2" '[{path:$p,nonce:$n,blob:$b}]'; }
wrec w-plan "$C1" plan approve "$(rxj true false "$SW_ALL" TP UP)" "$(tx full | jq -c --arg p "$PP" '.plan_blobs = {($p): "b1"}')"
wa w13 "$(tx full null '[]' '[]' "$(pf w-plan b1)")" "$(rxj true false "$SW_ALL")"
is "W13 a plan bound to a clean approved plan receipt that lists the path and blob is allowed" "$(wgate)" allow
wa w13b "$(tx full null '[]' '[]' "$(pf w-noplan b1)")" "$(rxj true false "$SW_ALL")"
is "W13b a plans_from naming no receipt is denied" "$(wgate)" "$NW the plan $PP is bound to w-noplan, which is no receipt in this ledger"
is "W13c saying so" "$(notwhole "$(wwhy)")/$(wwhy | grep -c 'plan')" "1/1"
wa w13c "$(tx full null '[]' '[]' "$(pf w-plan b2)")" "$(rxj true false "$SW_ALL")"
is "W13d a blob the plan receipt does not list is denied" "$(wgate)" "$NW the plan $PP at b2 is not in the plan_blobs of w-plan"
wa w13d "$(tx full null '[]' '[]' "$(pf w-plan b1 | jq -c '.[0].path = "docs/superpowers/plans/other.md"')")" "$(rxj true false "$SW_ALL")"
is "W13e a path the plan receipt does not list is denied" "$(wgate)" "$NW the plan docs/superpowers/plans/other.md at b1 is not in the plan_blobs of w-plan"
wrec w-plan-unclean "$C1" plan approve "$(rxj false false "$SW_ALL" TP UP2)" "$(tx full | jq -c --arg p "$PP" '.plan_blobs = {($p): "b1"}')"
wa w13e "$(tx full null '[]' '[]' "$(pf w-plan-unclean b1)")" "$(rxj true false "$SW_ALL")"
is "W13f an unclean plan receipt is denied" "$(wgate)" "$NW the plan $PP is bound to w-plan-unclean, which is not clean"
wrec w-plan-changes "$C1" plan changes "$(rxj true false "$SW_ALL" TP UP3)" "$(tx full | jq -c --arg p "$PP" '.plan_blobs = {($p): "b1"}')"
wa w13f "$(tx full null '[]' '[]' "$(pf w-plan-changes b1)")" "$(rxj true false "$SW_ALL")"
is "W13g a plan receipt that is not an approval is denied" "$(wgate)" "$NW the plan $PP is bound to w-plan-changes, which is not an approved plan review"
wrec w-spec "$C1" spec approve "$(rxj true false "$SW_ALL" TP UP4)" "$(tx full | jq -c --arg p "$PP" '.plan_blobs = {($p): "b1"}')"
wa w13g "$(tx full null '[]' '[]' "$(pf w-spec b1)")" "$(rxj true false "$SW_ALL")"
is "W13h a receipt of another checkpoint is denied" "$(wgate)" "$NW the plan $PP is bound to w-spec, which is not an approved plan review"
# A clean, approved plan receipt that records no plan_blobs, as none from before the design does.
wrec w-plan-legacy "$C1" plan approve "$(rxj true false "$SW_ALL" TP UP5)" '{}'
wa w13h "$(tx full null '[]' '[]' "$(pf w-plan-legacy b1)")" "$(rxj true false "$SW_ALL")"
is "W13i a plan receipt with no plan_blobs is denied, even clean and approved" "$(wgate)" \
   "$NW the plan $PP at b1 is not in the plan_blobs of w-plan-legacy"
wa w13i "$(tx full null '[]' '[]' '[{"path":"p"}]')" "$(rxj true false "$SW_ALL")"
is "W13j a malformed plans_from entry is denied" "$(wgate)" "$NW a plans_from entry is malformed"
wa w13j "$(tx delta w-l2 '["U1","U2"]' '[]' "$(pf w-plan b1)")" "$(rxj true false "$SW_ALL" T1 U3)"
is "W13k a delta with a valid chain and a valid plan binding is allowed" "$(wgate)" allow
# compacted must be exactly false where it applies; unknown is never clean.
wa w14 "$(tx full)" "$(rxj false null "$SW_FIT")"
is "W14 compacted: null on a full packet with fit on is denied" "$(wgate)" "$COMPACT"
wa w14b "$(tx delta w-l2 '["U1","U2"]')" "$(rxj true null "$SW_ALL" T1 U3)"
is "W14b on a delta" "$(wgate)" "$COMPACT"
wa w14c "$(tx slices)" "$(rxj true null "$SW_FRAME")"
is "W14c on slices" "$(wgate)" "$COMPACT"
wa w14d "$(tx full)" "$(rxj false null "$SW_OFF")"
is "W14d and allowed on a full packet with every switch off, as today" "$(wgate)" allow
wa w14e "$(tx full)" "$(rxj true - "$SW_FIT")"
is "W14e a missing compacted key on full with fit on is denied" "$(wgate)" "$COMPACT"
wa w14f "$(tx full)" "$(rxj true '"no"' "$SW_FIT")"
is "W14f a compacted that is the string no is denied" "$(wgate)" "$COMPACT"
wa w14g "$(tx full)" "$(rxj true 0 "$SW_FIT")"
is "W14g and 0 is not false" "$(wgate)" "$COMPACT"
wa w14h "$(tx delta w-l2 '["U1","U2"]')" "$(rxj true - "$SW_ALL" T1 U3)"
is "W14h a delta with no compacted key is denied" "$(wgate)" "$COMPACT"
wa w14i "$(tx bogus)" "$(rxj true false "$SW_OFF")"
is "W14i an unknown packet kind is denied" "$(wgate)" "$NW the packet kind is not recorded"
wa w14j "$(tx full)" "$(rxj true false "$SW_ALL")"
is "W14j a whole full packet with every switch on is allowed" "$(wgate)" allow
# Fix round 1. plans_from is required wherever a packet is recorded.
wa w16 "$(tx full | jq -c 'del(.plans_from)')" "$(rxj true false "$SW_OFF")"
is "W16 a packeted target with no plans_from key is denied" "$(wgate)" "$NW plans_from is not recorded as a list"
wa w16b "$(tx full | jq -c '.plans_from = null')" "$(rxj true false "$SW_OFF")"
is "W16b and so is plans_from: null" "$(wgate)" "$NW plans_from is not recorded as a list"
# Every chain link's plan bindings are checked, the root's included.
wrec w-badroot "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UBR)" "$(tx full null '[]' '[]' "$(pf w-plan-unclean b1)")"
wa w17 "$(tx delta w-badroot '["UBR"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W17 a clean delta behind a root whose plan binding is an unclean plan receipt is denied" "$(wgate)" \
   "$NW w-badroot, a link of the chain: the plan $PP is bound to w-plan-unclean, which is not clean"
is "W17b saying which link" "$(wwhy | grep -c 'w-badroot, a link of the chain')" 1
wrec w-badroot2 "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UBR2)" "$(tx full null '[]' '[]' "$(pf w-plan b9)")"
wa w17c "$(tx delta w-badroot2 '["UBR2"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W17c nor may the root's binding name a blob the plan receipt lacks" "$(wgate)" \
   "$NW w-badroot2, a link of the chain: the plan $PP at b9 is not in the plan_blobs of w-plan"
wrec w-goodroot "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UGR)" "$(tx full null '[]' '[]' "$(pf w-plan b1)")"
wa w17d "$(tx delta w-goodroot '["UGR"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W17d a root with a valid binding is allowed" "$(wgate)" allow
wrec w-badlink "$C2" pre-merge approve "$(rxj true false "$SW_ALL" T1 UBL)" "$(tx delta w-root '["U1"]' '[]' "$(pf w-plan-changes b1)")"
wa w17e "$(tx delta w-badlink '["U1","UBL"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W17e a middle link bound to a plan receipt that was not an approval is denied" "$(wgate)" \
   "$NW w-badlink, a link of the chain: the plan $PP is bound to w-plan-changes, which is not an approved plan review"
wrec w-noplansroot "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UNP)" "$(tx full | jq -c 'del(.plans_from)')"
wa w17f "$(tx delta w-noplansroot '["UNP"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W17f a root with no plans_from key is denied" "$(wgate)" "$NW w-noplansroot, a link of the chain: plans_from is not recorded as a list"
# A receipt can hold several targets of one repository: the link is the one on this destination
# and base with a full range, never the first of the repository.
wmulti() {   # wmulti <nonce> <tip> <receipt-json> <decoy-extra-json> <real-extra-json>
  local at t decoy real
  at="$(L now)"; t="$(L normalize "$WH" "main...$2")"
  decoy="$(printf '%s' "$t" | jq -c --argjson x "$4" '. + {full:false} + $x')"
  real="$(printf '%s' "$t" | jq -c --argjson x "$5" '. + $x')"
  L append "$WC" "$(jq -nc --arg n "$1" --arg at "$at" --argjson a "$decoy" --argjson b "$real" \
    '{v:2,kind:"pending",nonce:$n,dispatched_at:$at,checkpoint:"pre-merge",targets:[$a,$b]}')" >/dev/null
  L append "$WC" "$(jq -nc --arg n "$1" --arg at "$at" --argjson rx "$3" --argjson a "$decoy" --argjson b "$real" \
    '{v:2,kind:"receipt",nonce:$n,dispatched_at:$at,checkpoint:"pre-merge",verdict:"approve",findings:0,thread:"T1",turn:"u",tier:"",targets:[$a,$b]} + $rx')" >/dev/null
}
wmulti w-mt-slices "$C1" "$(rxj true false "$SW_ALL" T1 UMS)" "$(tx full)" "$(tx slices)"
wa w18 "$(tx delta w-mt-slices '["UMS"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W18 a decoy first target (full packet) does not make a sliced link a root" "$(wgate)" \
   "$NW the chain reaches w-mt-slices, a slices packet, not a full root"
wmulti w-mt-ok "$C1" "$(rxj true false "$SW_ALL" T1 UMO)" "$(tx slices)" "$(tx full)"
wa w18b "$(tx delta w-mt-ok '["UMO"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W18b the full-range target is used though it is not the first" "$(wgate)" allow
wrec w-mt-none "$C1" pre-merge approve "$(rxj true false "$SW_ALL" T1 UMN)" "$(tx full | jq -c '.full = false')"
wa w18c "$(tx delta w-mt-none '["UMN"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W18c a link with no full-range target is denied" "$(wgate)" \
   "$NW w-mt-none has no full-range target on the destination and base of w18c"
wmulti w-mt-two "$C1" "$(rxj true false "$SW_ALL" T1 UM2)" "$(tx full | jq -c '.full = true')" "$(tx full)"
wa w18d "$(tx delta w-mt-two '["UM2"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W18d two targets that could both be followed are denied as ambiguous" "$(wgate)" \
   "$NW w-mt-two holds several targets that the delta of w18d could follow"
# Every link and the root are pre-merge reviews.
wrec w-specroot "$C1" spec approve "$(rxj true false "$SW_ALL" T1 USR)" "$(tx full)"
wa w19 "$(tx delta w-specroot '["USR"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W19 a spec review as the root is denied" "$(wgate)" "$NW w-specroot, a link of the chain, is not a pre-merge review"
wrec w-planlink "$C2" plan approve "$(rxj true false "$SW_ALL" T1 UPL)" "$(tx delta w-root '["U1"]')"
wa w19b "$(tx delta w-planlink '["U1","UPL"]')" "$(rxj true false "$SW_ALL" T1 U3)"
is "W19b and a plan review as a middle link" "$(wgate)" "$NW w-planlink, a link of the chain, is not a pre-merge review"
# A target with no packet is old only when its receipt is too: a receipt that records any field
# of a packeted dispatch says the kind went unrecorded.
for field in '{"switches":{"framing":false,"fit":false,"delta":false,"omit_plans":false}}' '{"clean":true}' '{"compacted":false}'; do
  wa "w21-$(printf '%s' "$field" | jq -r 'keys[0]')" '{}' "$field"
  is "W21 a target with no packet whose receipt records $(printf '%s' "$field" | jq -r 'keys[0]') is denied" "$(wgate)" \
     "$NW the packet kind is not recorded"
done
# A delta or slices packet needs framing: with it recorded off, coverage was never judged.
wa w22 "$(tx delta w-l2 '["U1","U2"]' '["a.txt"]')" "$(rxj true false "$SW_OFF" T1 U3)"
is "W22 a delta recorded with framing off is denied, a coverage gap or not" "$(wgate)" \
   "$NW framing is recorded off, and a delta packet needs it"
wa w22b "$(tx slices null '[]' '["a.txt"]')" "$(rxj true false "$SW_OFF")"
is "W22b and so is a slices receipt" "$(wgate)" "$NW framing is recorded off, and a slices packet needs it"
# xreview always writes the switches as an object beside a packet; anything else is not a record.
for sw in '[]' '"on"' 'null'; do
  wa "w23-$(printf '%s' "$sw" | jq -r 'type')" "$(tx full)" "$(rxj true false "$sw")"
  is "W23 a packeted receipt whose switches are $sw is denied" "$(wgate)" "$NW the switches at dispatch are not recorded"
done
# whole() needs a repository for the ancestor rule: without one a delta is never whole.
none="$(/usr/bin/python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rx = {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "thread": "T", "clean": True, "compacted": False,
      "switches": {"framing": True, "fit": True, "delta": True, "omit_plans": True}}
root = dict(rx, nonce="r", turn="U1", targets=[{"repo": "/x", "dest": "main", "base": "b", "tip": "t1", "full": True,
            "packet": "full", "plans_from": []}])
tgt = {"repo": "/x", "dest": "main", "base": "b", "tip": "t2", "full": True, "packet": "delta",
       "delta_from": "r", "history": ["U1"], "plans_from": [], "missing": []}
head = dict(rx, nonce="h", turn="U2", targets=[tgt])
print(m.whole([root, head], head, tgt, None))
try:
    m.whole([root, head], head, tgt)
    print("accepted")
except TypeError:
    print("repo is required")
' "$LEDGER")"
is "W20 whole() without a repository denies a delta, and its repo argument is required" "$none" \
   "$(printf "(False, 'the tip of r is not where the delta of h starts')\nrepo is required")"
# blob_patch takes blobs only: a commit or tree id would render other files' hunks under the path.
CM="$(git -C "$PXR" rev-parse main)"; CP="$(git -C "$PXR" rev-parse px)"
out="$(L blob-patch "$PXR" docs/x.md "$CM" "$CP" 2>&1)"; rc=$?
is "PB6 two commit ids are refused" "$rc/$(printf '%s' "$out" | grep -c 'is not a blob')" "1/1"
out="$(L blob-patch "$PXR" docs/x.md - "$(git -C "$PXR" rev-parse 'px^{tree}')" 2>&1)"; rc=$?
is "PB6b so is a tree id as the new side" "$rc/$(printf '%s' "$out" | grep -c 'is not a blob')" "1/1"
out="$(L blob-patch "$PXR" docs/x.md "$CM" "$NB" 2>&1)"; rc=$?
is "PB6c and a commit id as the old side" "$rc/$(printf '%s' "$out" | grep -c 'is not a blob')" "1/1"
# The gate judges from the receipt: no switches file is read.
CFG="$ROOT/xdg-config"; mkdir -p "$CFG/xreview"
wa w15 "$(tx full null '[]' '["a.txt"]')" "$(rxj false false "$SW_FRAME")"
res=""
for state in on off; do
  printf 'framing=%s\nfit=%s\ndelta=%s\nomit_plans=%s\n' $state $state $state $state > "$CFG/xreview/packets.conf"
  res="$res|$(XDG_CONFIG_HOME="$CFG" L decide "$WH" main main feat | jq -r "$VERDICT" | short)"
done
is "W15 flipping packets.conf changes no decision on record (a gap stays denied)" "$res" "|$GAP|$GAP"
wa w15b "$(tx full null '[]' '["a.txt"]')" "$(rxj false false "$SW_OFF")"
res=""
for state in on off; do
  printf 'framing=%s\nfit=%s\ndelta=%s\nomit_plans=%s\n' $state $state $state $state > "$CFG/xreview/packets.conf"
  res="$res $(XDG_CONFIG_HOME="$CFG" L decide "$WH" main main feat | jq -r "$VERDICT" | short)"
done
is "W15b nor one recorded with the switches off (allowed stays allowed)" "$res" " allow allow"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

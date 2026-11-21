#!/usr/bin/env bash
# Tests for dot_local/bin/executable_merge-state: it prints the first three fields of the merge
# state. One case per row of its condition table, each in a fixture repository with a stub review
# ledger; `safe to merge` only with every row clear; hold; every required option missing in turn;
# the tools it depends on missing; the Checks line read from origin's default branch only.
#
#   ./tests/merge-state.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MS="$SRC/dot_local/bin/executable_merge-state"
CF="$SRC/dot_local/bin/executable_change-facts"
[ -f "$MS" ] || { echo "missing script under test: $MS" >&2; exit 2; }
[ -f "$CF" ] || { echo "missing script under test: $CF" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/merge-state.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

BIN="$T/bin"; mkdir "$BIN" "$T/solo" "$T/ledger" "$T/norepo"
cp "$MS" "$BIN/merge-state"; cp "$CF" "$BIN/change-facts"; cp "$MS" "$T/solo/merge-state"
chmod 755 "$BIN/merge-state" "$BIN/change-facts" "$T/solo/merge-state"
printf 'import os, sys\nd = os.path.dirname(os.path.abspath(__file__))\nopen(d + "/args.log", "a").write(" ".join(sys.argv[1:]) + "\\n")\nsys.stdout.write(open(d + "/answer").read())\n' > "$T/ledger/ledger.py"
export XREVIEW_LEDGER="$T/ledger/ledger.py"
approve() { printf '{"allow":true,"reason":"approved by the pre-merge review xr-1-abc"}\n' > "$T/ledger/answer"; }
refuse() { printf '{"allow":false,"reason":"%s"}\n' "$1" > "$T/ledger/answer"; }
approve

STRONG='**Checks:** strong — ./tests/run.sh --changed; CI required to merge: no'
SPEC=docs/superpowers/specs/2026-01-01-x-design.md
R=""; rc=0
# commit [msg]: commit what is written in $R.
commit() { git -C "$R" add -A && git -C "$R" commit -q --allow-empty -m "${1:-c}"; }
wn() { mkdir -p "$R/$(dirname "$1")"; seq -f "${3:-l}%g" 1 "$2" > "$R/$1"; }
wt() { mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" > "$R/$1"; }
# mk <name> [AGENTS.md text]: a clone of a bare origin; main holds the spec, a test file and AGENTS.md,
# origin/HEAD names main, and feat holds one small code change.
mk() {
  R="$T/$1"; git init -q --bare -b main "$T/$1.git"; git init -q -b main "$R"
  git -C "$R" remote add origin "$T/$1.git"
  wt AGENTS.md "${2-$STRONG}"; wt "$SPEC" spec; wn spec/x_spec.rb 10
  commit base; git -C "$R" push -q origin main
  git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  newhead; wn app/a.rb 5; commit head
}
newhead() { git -C "$R" checkout -q -B feat main; }
ms_in() { local d=$1; shift; ( CDPATH= cd -- "$d" && "$BIN/merge-state" "$@" ) >"$T/out" 2>"$T/err"; rc=$?; }
# the declared facts of the all-clear case; a case changes one before it runs
defaults() {
  A_DEST=main; A_HEAD=HEAD; A_REVIEW=sp-reviewer:HEAD; A_SUITE=10/10; A_LINT=pass; A_CI=green
  A_SPEC=$SPEC; A_BOUNDARY=(none); A_CHECK=(none); A_SKIP=""; A_EXTRA=()
}
ms() {
  local a=("$A_DEST" "$A_HEAD") b c
  [ "$A_SKIP" = --claude-review ] || a+=(--claude-review "$A_REVIEW")
  [ "$A_SKIP" = --suite ] || a+=(--suite "$A_SUITE")
  [ "$A_SKIP" = --lint ] || a+=(--lint "$A_LINT")
  [ "$A_SKIP" = --ci ] || a+=(--ci "$A_CI")
  [ "$A_SKIP" = --spec ] || a+=(--spec "$A_SPEC")
  if [ "$A_SKIP" != --boundary ]; then for b in "${A_BOUNDARY[@]}"; do a+=(--boundary "$b"); done; fi
  if [ "$A_SKIP" != --check ]; then for c in "${A_CHECK[@]}"; do a+=(--check "$c"); done; fi
  if [ "${#A_EXTRA[@]}" -gt 0 ]; then a+=("${A_EXTRA[@]}"); fi
  ms_in "$R" "${a[@]}"
}
numbered() { sed -n 's/^[0-9]*\. //p' "$T/out"; }
# chk <label> <item>...: exit 0, `check first`, and exactly these numbered items
chk() {
  local label=$1 bad="" i n; shift
  n="$(grep -c '^[0-9][0-9]*\. ' "$T/out")"
  grep -qxF '**Merge:** check first' "$T/out" || bad+="[state]"
  for i in "$@"; do numbered | grep -qxF -- "$i" || bad+="[$i]"; done
  [ "$n" = "$#" ] || bad+="[$n items, want $#]"
  [ "$rc" = 0 ] || bad+="[rc=$rc]"
  if [ -z "$bad" ]; then _pass "$label"; else _fail "$label" "$bad | $(head -c 900 "$T/out") | $(cat "$T/err")"; fi
}
# state <label> <Merge text>: exit 0 and that Merge line
state() {
  if [ "$rc" = 0 ] && [ "$(sed -n '1p' "$T/out")" = "**Merge:** $2" ]; then _pass "$1"
  else _fail "$1" "rc=$rc $(head -c 900 "$T/out") | $(cat "$T/err")"; fi
}
# lines_ok <label> <line>...: exit 0 and each is a whole line of the output
lines_ok() {
  local label=$1 l miss="" ; shift
  for l in "$@"; do grep -qxF -- "$l" "$T/out" || miss+="[$l]"; done
  if [ "$rc" = 0 ] && [ -z "$miss" ]; then _pass "$label"; else _fail "$label" "rc=$rc missing: $miss | $(head -c 900 "$T/out")"; fi
}
# usage_err <label>: exit 2, exactly one merge-state: line on stderr, nothing on stdout
usage_err() {
  if [ "$rc" = 2 ] && [ "$(wc -l < "$T/err" | tr -d ' ')" = 1 ] && grep -q '^merge-state: ' "$T/err" && [ ! -s "$T/out" ]; then _pass "$1"
  else _fail "$1" "rc=$rc out: $(head -c 300 "$T/out") err: $(cat "$T/err")"; fi
}

# 1. the all-clear case
mk clear; H="$(git -C "$R" rev-parse HEAD)"
defaults; ms
same_out="**Merge:** safe to merge
**Checked:** Codex pre-merge approve xr-1-abc on $H into main; Claude review approve (sp-reviewer, on $H, whole range); suite 10/10; lint pass; CI green; Checks strong; size 5 / 0 lines; tests deleted 0; new dependencies none; spec $SPEC; safety boundary none
**Check by hand:** nothing"
if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$same_out" ] && [ ! -s "$T/err" ]; then _pass "all clear prints the three lines of safe to merge"
else _fail "all clear prints the three lines of safe to merge" "rc=$rc $(cat "$T/out") | $(cat "$T/err")"; fi
cp "$T/out" "$T/first"
if grep -qxF "decide . main origin/main $H" "$T/ledger/args.log"; then _pass "the ledger is asked about this destination and the head's commit id"
else _fail "the ledger is asked about this destination and the head's commit id" "$(cat "$T/ledger/args.log")"; fi
defaults; A_CI=pending; ms
state "ci pending on the all-clear case" "safe to merge once CI is green"
defaults; A_LINT=none; A_CI=none; ms
state "lint none and ci none (CI not required) are clear" "safe to merge"
defaults; A_REVIEW=sp-architect:HEAD; ms
state "an sp-architect review of the head is clear" "safe to merge"

# 2. row 1: the ledger does not approve
refuse "no full-range pre-merge review of this change is on record"; defaults; ms
chk "row 1: the ledger's own reason" "Codex pre-merge: no full-range pre-merge review of this change is on record"
if sed -n 2p "$T/out" | grep -q '^\*\*Checked:\*\* Codex pre-merge none; Claude review'; then _pass "row 1: Checked says none for Codex"; else _fail "row 1: Checked says none for Codex" "$(sed -n 2p "$T/out")"; fi
printf '{"allow":true,"reason":"approved"}\n' > "$T/ledger/answer"; defaults; ms
chk "row 1: an approval without a nonce is not one" "Codex pre-merge: the ledger approved without a nonce: approved"
approve

# 3. row 2: the Claude review
defaults; A_REVIEW=none; ms
chk "row 2: none" "Claude review: none"
P="$(git -C "$R" rev-parse HEAD~1)"
defaults; A_REVIEW=sp-reviewer:HEAD~1; ms
chk "row 2: another commit than the head" "Claude review read $P, not the head"

# 4. row 3: the suite
for v in none 9/10 0/0; do defaults; A_SUITE=$v; ms; chk "row 3: suite $v" "suite: $v"; done
defaults; A_SUITE=11/10; ms; state "a passed count above the total is not row 3" "safe to merge"

# 5. row 4: lint
for v in fail not-run; do defaults; A_LINT=$v; ms; chk "row 4: lint $v" "lint: $v"; done

# 6. row 5: CI
defaults; A_CI=failed; ms; chk "row 5: failed" "CI: failed"
mk ciyes "**Checks:** strong — make test; CI required to merge: yes"
defaults; A_CI=none; ms; chk "row 5: none where the Checks line requires CI" "CI: none"
defaults; A_CI=green; ms; state "CI green where required is clear" "safe to merge"
defaults; A_CI=pending; ms; state "CI pending where required is still pending" "safe to merge once CI is green"

# 7. row 6: the Checks tier, read from origin's default branch
mk weak "**Checks:** weak — none; CI required to merge: yes"
defaults; ms; chk "row 6: a weak line" "no Checks: strong line on origin's default branch: the missing check"
mk noline "# a repository"
defaults; ms; chk "row 6: no line" "no Checks: strong line on origin's default branch: the missing check"
mk twice "$STRONG
$STRONG"
defaults; ms; chk "row 6: two Checks lines" "no Checks: strong line on origin's default branch: the missing check"
mk bad '**Checks:** strong — ./tests/run.sh --changed'
defaults; ms; chk "row 6: a line it cannot parse" "no Checks: strong line on origin's default branch: the missing check"
mk headonly "# a repository"
newhead; wt AGENTS.md "$STRONG"; commit h
defaults; ms
chk "row 6: a strong line only on the head, not on origin's main" \
  "no Checks: strong line on origin's default branch: the missing check" \
  "the change edits a Checks line: AGENTS.md" "agent instruction text: AGENTS.md"

# 8. row 7: the change touches a Checks line
mk edit; newhead; wt AGENTS.md '**Checks:** weak — none; CI required to merge: no'; commit h
defaults; ms; chk "row 7: a Checks line edited" "the change edits a Checks line: AGENTS.md" "agent instruction text: AGENTS.md"
newhead; wt AGENTS.md '# a repository'; commit h
defaults; ms; chk "row 7: a Checks line deleted" "the change edits a Checks line: AGENTS.md" "agent instruction text: AGENTS.md"
newhead; wt sub/AGENTS.md "$STRONG"; commit h
defaults; ms; chk "row 7: a Checks line added to another AGENTS.md" "the change edits a Checks line: sub/AGENTS.md" "agent instruction text: sub/AGENTS.md"
newhead; printf '%s\nmore\n' "$STRONG" > "$R/AGENTS.md"; commit h
defaults; ms; chk "row 7: an AGENTS.md edit that leaves the Checks line alone is row 8 only" "agent instruction text: AGENTS.md"

# 9. row 8: instruction text, once per path kind
for p in sub/AGENTS.md CLAUDE.md skills/x/SKILL.md .chezmoitemplates/agents/global.md dot_claude/agents/a.md \
         .claude/agents/a.md .codex/agents/a.toml dot_codex/agents/a.toml dot_claude/agents/sub/nested.md; do
  newhead; wt "$p" x; commit h; defaults; ms; chk "row 8: $p" "agent instruction text: $p"
done
newhead; wt sub/AGENTS.md x; wt CLAUDE.md x; commit h
defaults; ms; chk "row 8: two files, comma-separated and sorted" "agent instruction text: CLAUDE.md, sub/AGENTS.md"
for p in dot_claude/skills/a.md agents/a.md foo/agents/a.md dot_claude/x/agents/a.md dot_claude/hooks/agents.sh .chezmoitemplates/other/a.md notes/AGENTS.md.bak; do
  newhead; wt "$p" x; commit h; defaults; ms; state "row 8: $p is not instruction text" "safe to merge"
done

# 10. row 9: safety boundaries
defaults; A_BOUNDARY=(migrations auth); ms
chk "row 9: one item each" "safety boundary: migrations" "safety boundary: auth"
if sed -n '2p' "$T/out" | grep -q 'safety boundary migrations, auth$'; then _pass "row 9: Checked names the values, comma-separated"; else _fail "row 9: Checked names the values, comma-separated" "$(sed -n 2p "$T/out")"; fi

# 11. row 10: dependency lines
newhead; wt Gemfile 'gem "rack"'; commit h
defaults; ms
if [ "$rc" = 0 ] && [ "$(sed -n '/^\*\*Check by hand:\*\*/,$p' "$T/out")" = '**Check by hand:**
1. new dependency lines:
  Gemfile
    + gem "rack"' ] && sed -n 2p "$T/out" | grep -q 'new dependencies 1 lines;'; then _pass "row 10: the lines as change-facts prints them"
else _fail "row 10: the lines as change-facts prints them" "rc=$rc $(cat "$T/out")"; fi

# 12. row 11: size
newhead; wn app/big.rb 150; commit h; defaults; A_SPEC=none; ms; state "row 11: 150 lines without a spec is clear" "safe to merge"
newhead; wn app/big.rb 151; commit h
defaults; A_SPEC=none; ms; chk "row 11: 151 lines without a spec" "size: 151 code lines, over 150"
defaults; ms; state "row 11: 151 lines with a spec is clear" "safe to merge"
newhead; wn app/big.rb 2001; commit h
defaults; ms; chk "row 11: 2001 lines with a spec" "size: 2001 code lines, over 2000"

# 13. row 12: test lines deleted
newhead; wn spec/x_spec.rb 7; commit h
defaults; ms; chk "row 12: three test lines deleted" "3 test lines deleted: look at each"

# 14. row 13: declared checks
newhead; wn app/a.rb 5; commit h
defaults; A_CHECK=("run it by hand" "ruling on the retry waits for Michael"); ms
chk "row 13: each as given" "run it by hand" "ruling on the retry waits for Michael"

# 15. two rows at once, in table order; hold
defaults; A_SUITE=none; A_LINT=fail; A_CHECK=(last); A_BOUNDARY=(auth); ms
if [ "$rc" = 0 ] && [ "$(sed -n '/^\*\*Check by hand:\*\*/,$p' "$T/out")" = '**Check by hand:**
1. suite: none
2. lint: fail
3. safety boundary: auth
4. last' ]; then _pass "several rows list their items numbered, in table order"
else _fail "several rows list their items numbered, in table order" "$(cat "$T/out")"; fi
defaults; A_EXTRA=(--hold "waiting for Michael's manual test"); ms
if [ "$rc" = 0 ] && [ "$(sed -n 1p "$T/out")" = "**Merge:** hold: waiting for Michael's manual test" ] && [ "$(sed -n 3p "$T/out")" = '**Check by hand:** nothing' ]; then _pass "hold with no item"
else _fail "hold with no item" "$(cat "$T/out")"; fi
defaults; A_SUITE=none; A_EXTRA=(--hold "stacked"); ms
if [ "$rc" = 0 ] && [ "$(sed -n 1p "$T/out")" = "**Merge:** hold: stacked" ] && numbered | grep -qxF "suite: none"; then _pass "hold still lists the items that hold"
else _fail "hold still lists the items that hold" "$(cat "$T/out")"; fi

# 16. usage errors
for opt in --claude-review --suite --lint --ci --spec --boundary --check; do defaults; A_SKIP=$opt; ms; usage_err "$opt left out"; done
defaults; A_BOUNDARY=(none auth); ms; usage_err "none beside a --boundary value"
defaults; A_BOUNDARY=(auth none); ms; usage_err "a --boundary value beside none"
defaults; A_CHECK=(none x); ms; usage_err "none beside a --check value"
defaults; A_REVIEW=sp-nope:HEAD; ms; usage_err "a bad reviewer type"
defaults; A_REVIEW=sp-reviewer; ms; usage_err "a review with no commit"
defaults; A_REVIEW=sp-reviewer:nope; ms; usage_err "a review commit that names no commit"
for v in 3 a/b -1/2 3/ 1/2/3 ""; do defaults; A_SUITE=$v; ms; usage_err "suite figure '$v'"; done
defaults; A_LINT=maybe; ms; usage_err "a bad lint outcome"
defaults; A_CI=maybe; ms; usage_err "a bad CI state"
defaults; A_SPEC=docs/other.md; ms; usage_err "a spec outside docs/superpowers/specs/"
defaults; A_SPEC=docs/superpowers/specs/absent.md; ms; usage_err "a spec absent at the head"
defaults; A_SPEC=docs/superpowers/specs; ms; usage_err "a spec that is a directory"
defaults; A_HEAD=nope; ms; usage_err "an unknown head"
defaults; A_HEAD=--stat; ms; usage_err "an option as the head"
defaults; A_EXTRA=(--suite 1/1); ms; usage_err "an option given twice"
defaults; A_EXTRA=(--hold a --hold b); ms; usage_err "--hold given twice"
defaults; A_EXTRA=(--bogus x); ms; usage_err "an unknown option"
defaults; A_EXTRA=(--hold); ms; usage_err "an option without a value"
ms_in "$R"; usage_err "no argument"
ms_in "$R" main; usage_err "one positional"
git -C "$T/norepo" rev-parse --git-dir >/dev/null 2>&1 && _fail "control: the not-a-repository directory has no repository above it" "$T" || _pass "control: the not-a-repository directory has no repository above it"
defaults; R="$T/norepo"; ms; usage_err "a directory that is not a repository"
R="$T/clear"

# 17. a tool it depends on cannot run: check first with an item naming it
defaults; XREVIEW_LEDGER="$T/none.py" ms
chk "no ledger script" "Codex pre-merge: no review ledger script at $T/none.py"
printf 'not json\n' > "$T/ledger/answer"; defaults; ms
chk "a ledger that prints no JSON" "Codex pre-merge: the review ledger gave no usable answer"
printf '["a"]\n' > "$T/ledger/answer"; defaults; ms
chk "a ledger that prints another JSON shape" "Codex pre-merge: the review ledger gave no usable answer"
approve
defaults; ( CDPATH= cd -- "$R" && "$T/solo/merge-state" main HEAD --claude-review sp-reviewer:HEAD --suite 10/10 --lint pass --ci green --spec "$SPEC" --boundary none --check none ) >"$T/out" 2>"$T/err"; rc=$?
chk "no sibling change-facts" "size: unknown, change-facts is not beside merge-state (limit 2000)"
mk gone; git -C "$R" update-ref -d refs/remotes/origin/main
defaults; ms
if [ "$rc" = 0 ] && sed -n 1p "$T/out" | grep -qx '\*\*Merge:\*\* check first' && numbered | grep -qxF 'Codex pre-merge: origin/main is not available locally; fetch it'; then _pass "no origin/<destination>: check first, naming it"
else _fail "no origin/<destination>: check first, naming it" "rc=$rc $(cat "$T/out") | $(cat "$T/err")"; fi
defaults; A_DEST=nobranch; ms
if [ "$rc" = 0 ] && sed -n 1p "$T/out" | grep -qx '\*\*Merge:\*\* check first' && numbered | grep -qxF 'Codex pre-merge: origin/nobranch is not available locally; fetch it'; then _pass "a destination origin does not have"
else _fail "a destination origin does not have" "rc=$rc $(cat "$T/out") | $(cat "$T/err")"; fi
R="$T/clear"

# 18. declared text shows control characters as ?
defaults; A_CHECK=($'a\x01b\nc\x1b[2Kd'); ms
lines_ok "a control character and a line break in --check print as ?" '1. a?b?c?[2Kd'
defaults; A_EXTRA=(--hold $'x\ry\nz'); ms
state "a control character and a line break in --hold print as ?" 'hold: x?y?z'
defaults; A_BOUNDARY=($'b\tt'); ms
lines_ok "a tab in --boundary prints as ?" '1. safety boundary: b?t'

# 19. nothing the caller exports changes the output
mkdir "$T/fakebin"; printf '#!/bin/sh\necho junk\nexit 0\n' > "$T/fakebin/git"; chmod 755 "$T/fakebin/git"
defaults; PATH="$T/fakebin:$PATH" ms
if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "a git first on PATH is never run"; else _fail "a git first on PATH is never run" "rc=$rc $(head -c 400 "$T/out")"; fi
defaults; GIT_DIR="$T/ciyes/.git" ms
if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "GIT_DIR naming another repository does not redirect it"; else _fail "GIT_DIR naming another repository does not redirect it" "rc=$rc $(head -c 400 "$T/out")"; fi
defaults; GIT_DIR="$T/clear/.git" R="$T/norepo" ms
usage_err "GIT_DIR does not make a directory that is no repository one"
R="$T/clear"

# 20. --help
ms_in "$R" --help
miss=""
for c in "the ledger does not approve this change for this destination" "--claude-review none, or its commit is not the head" \
         "--suite none, passed < total, or total 0" "--lint fail or not-run" "--ci failed; or --ci none where the Checks line requires CI" \
         "the tier is weak" "the change touches a Checks line" "the change touches instruction text" "any --boundary but none" \
         "any dependency line" "code over the limit (2000 with --spec, 150 with --spec none), or size unknown" \
         "test lines deleted not 0" "any --check but none" "--hold <reason>"; do
  grep -qF -- "$c" "$T/out" || miss+="[$c]"
done
if [ "$rc" = 0 ] && [ -z "$miss" ] && [ ! -s "$T/err" ]; then _pass "--help exits 0 and holds each of the thirteen conditions"; else _fail "--help exits 0 and holds each of the thirteen conditions" "rc=$rc missing: $miss"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

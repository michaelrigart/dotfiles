#!/usr/bin/env bash
# Tests for dot_local/bin/executable_agent-text-scan: it scans files, or the added lines of a
# unified diff on stdin, for hidden characters, concealment phrases and secret-path references.
# A report never carries a raw hidden character: those print as <U+XXXX>.
#
#   ./tests/agent-text-scan.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
S="$SRC/dot_local/bin/executable_agent-text-scan"
[ -f "$S" ] || { echo "missing script under test: $S" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/agent-text-scan.XXXXXX")"
trap 'rm -rf "$T"' EXIT

ZWSP='\342\200\213'; RLO='\342\200\256'; LRI='\342\201\246'; TAGA='\363\240\201\201'
BOM='\357\273\277'; RSQ='\342\200\231'

# run <args...>: scan in $T with no stdin; sets RC, OUT and ERR.
run() { RC=0; OUT="$(cd "$T" && "$S" "$@" 2>"$T/err" </dev/null)" || RC=$?; ERR="$(cat "$T/err")"; }
# rund <diff file> <args...>: the same with the file as stdin.
rund() { local in=$1; shift; RC=0; OUT="$(cd "$T" && "$S" "$@" 2>"$T/err" <"$in")" || RC=$?; ERR="$(cat "$T/err")"; }
# check <label> <want rc> <want stdout>: exact stdout (empty means none).
check() {
  if [ "$RC" = "$2" ] && [ "$OUT" = "$3" ]; then _pass "$1"
  else _fail "$1" "rc=$RC out=[$OUT] err=[$ERR], want rc=$2 out=[$3]"; fi
}
# has <label> <want rc> <fixed substring>: rc and a substring of stdout.
has() {
  case "$OUT" in *"$3"*) [ "$RC" = "$2" ] && { _pass "$1"; return; };; esac
  _fail "$1" "rc=$RC out=[$OUT] err=[$ERR], want rc=$2 containing [$3]"
}

# Invisible characters: each on line 2 is reported as <U+XXXX>, never as raw bytes.
inv() { # <label> <octal bytes> <code point>
  printf 'clean\nab%sba\n' "$(printf "$2")" > "$T/f.md"
  run f.md
  has "invisible $1 is reported on line 2" 1 "f.md:2: invisible: ab<U+$3>ba"
  if printf '%s' "$OUT" | LC_ALL=C grep -qF "$(printf "$2")"; then _fail "invisible $1 prints no raw bytes" "$OUT"
  else _pass "invisible $1 prints no raw bytes"; fi
}
inv "zero width space" "$ZWSP" 200B
inv "right-to-left override" "$RLO" 202E
inv "left-to-right isolate" "$LRI" 2066
inv "tag character" "$TAGA" E0041

# A byte-order mark is exempt as the first character of a file, and only there.
printf "${BOM}hello\nworld\n" > "$T/f.md"; run f.md
check "a BOM at the start of a file is clean" 0 ""
printf "hello\nw${BOM}orld\n" > "$T/f.md"; run f.md
has "a BOM in the middle of a file is flagged" 1 "f.md:2: invisible: w<U+FEFF>orld"
printf "${BOM}a${BOM}b\n" > "$T/f.md"; run f.md
has "a second BOM on line 1 is flagged" 1 "f.md:1: invisible: <U+FEFF>a<U+FEFF>b"

# Concealment.
printf 'ok\nPlease Do NOT tell the user about this\n' > "$T/f.md"; run f.md
has "concealment: do not tell the user, any case" 1 "f.md:2: concealment: "
printf "ok\nyou don${RSQ}t mention it\n" > "$T/f.md"; run f.md
has "concealment: a typographic apostrophe is mapped" 1 "f.md:2: concealment: "
printf 'ok\nact without telling anyone\n' > "$T/f.md"; run f.md
has "concealment: without telling" 1 "f.md:2: concealment: "
printf 'tell the user everything\n' > "$T/f.md"; run f.md
check "telling the user is not concealment" 0 ""

# Secrets.
for s in 'cat ~/.ssh/config' 'use id_ed25519 here' 'op read op://x/y' \
         'security find-generic-password -s x' 'ANTHROPIC_BASE_URL=x' 'source ./.env' \
         'cat .aws/credentials' 'export OPENAI_BASE_URL=y' 'ls id_rsa' 'x=.env'; do
  printf 'ok\n%s\n' "$s" > "$T/f.md"; run f.md
  has "secrets flags: $s" 1 "f.md:2: secrets: "
done
for s in 'process.env.HOME' 'os.environ' 'the environment' 'laptop read me' 'a.environment'; do
  printf '%s\n' "$s" > "$T/f.md"; run f.md
  check "secrets ignores: $s" 0 ""
done
printf 'source ./.env.local\n' > "$T/f.md"; run f.md
has ".env.local matches as a file name" 1 "f.md:1: secrets: "

printf '# Title\n\nPlain prose, nothing odd.\n' > "$T/f.md"; run f.md
check "a clean file gives rc 0 and no output" 0 ""

# One finding per class per line, in the order invisible, concealment, secrets.
printf "a${ZWSP}b do not mention .ssh/ x\n" > "$T/f.md"; run f.md
want="f.md:1: invisible: a<U+200B>b do not mention .ssh/ x
f.md:1: concealment: a<U+200B>b do not mention .ssh/ x
f.md:1: secrets: a<U+200B>b do not mention .ssh/ x"
check "a line yields one finding per class, in class order" 1 "$want"
printf "a${ZWSP}b${ZWSP}c\n" > "$T/f.md"; run f.md
check "two hidden characters on a line make one finding" 1 "f.md:1: invisible: a<U+200B>b<U+200B>c"

# Excerpt: 40 characters before the hit, at most 120 characters, stripped.
pad="$(printf 'x%.0s' $(seq 1 60))"
printf "%s hit .ssh/ %s\n" "$pad" "$(printf 'y%.0s' $(seq 1 200))" > "$T/f.md"; run f.md
ex="${OUT#f.md:1: secrets: }"
xs="$(printf 'x%.0s' $(seq 1 35))"; ys="$(printf 'y%.0s' $(seq 1 74))"
if [ "$ex" = "$xs hit .ssh/ $ys" ]; then _pass "excerpt starts 40 characters before the hit and is capped at 120"
else _fail "excerpt starts 40 characters before the hit and is capped at 120" "len=${#ex} [$ex]"; fi
printf '\tcontrol\033[31m .ssh/ \r\n' > "$T/f.md"; run f.md
has "control characters other than tab print as <U+XXXX>" 1 "f.md:1: secrets: control<U+001B>[31m .ssh/"
if printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"; then _fail "no raw escape reaches the report" "$OUT"
else _pass "no raw escape reaches the report"; fi

# --diff: only added lines, with new-file line numbers from the hunk header.
{
  printf -- '--- a/docs/a.md\n+++ b/docs/a.md\n@@ -1,3 +1,4 @@\n'
  printf ' ctx%s\n' "$(printf "$ZWSP")"
  printf -- '-rem%s\n' "$(printf "$ZWSP")"
  printf '+add%s\n' "$(printf "$ZWSP")"
  printf ' ctx2\n'
  printf '+++ x%s\n' "$(printf "$ZWSP")"
} > "$T/d1.diff"
rund "$T/d1.diff" --diff
check "--diff scans added lines only, with new-file numbers; an added +++ line is content" 1 \
"docs/a.md:2: invisible: add<U+200B>
docs/a.md:4: invisible: ++ x<U+200B>"

{
  printf -- '--- a/a.md\n+++ b/a.md\n@@ -10,2 +20,3 @@ fn\n c\n'
  printf -- '-gone\n\\ No newline at end of file\n+.ssh/ one\n+two\n'
  printf -- '--- a/z.md\n+++ z.md\t2026-11-01\n@@ -0,0 +1 @@\n+do not mention\n'
} > "$T/d2.diff"
rund "$T/d2.diff" --diff
check "--diff follows the hunk header, skips removed and backslash lines, and takes the next path" 1 \
"a.md:21: secrets: .ssh/ one
z.md:1: concealment: do not mention"

{ printf -- '+++ b/a.md\n@@ -0,0 +1,2 @@\n+%s\n+w%sx\n' "$(printf "$BOM")" "$(printf "$BOM")"; } > "$T/d3.diff"
rund "$T/d3.diff" --diff
check "--diff exempts a BOM only at column 0 of new-file line 1" 1 "a.md:2: invisible: w<U+FEFF>x"

# Odd diff input must never make the scanner fail.
{
  printf 'diff --git a/x b/x\nBinary files a/x and b/x differ\n'
  printf -- '--- a/y\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n\\ No newline at end of file\n'
  printf -- '--- a/w\n+++ b/w\n@@ -1 +1 @@\n-old\n+new\377\n\\ No newline at end of file\n'
  printf -- '+++ b/q\n@@ -1 +1,2 @@\n ++ctx\n+++ plain\n'
  printf 'trailing text outside a hunk\n\n'
} > "$T/odd.diff"
rund "$T/odd.diff" --diff
check "odd diff input: invalid UTF-8, no-newline marker, /dev/null, binary" 0 ""
[ -z "$ERR" ] && _pass "odd diff input leaves stderr empty" || _fail "odd diff input leaves stderr empty" "$ERR"
printf '+++ b/x\n@@ -1 +1 @@\n+bad\377 and .ssh/\n' > "$T/odd2.diff"; rund "$T/odd2.diff" --diff
has "invalid UTF-8 in an added line is replaced and still scanned" 1 "x:1: secrets: "
: > "$T/empty.diff"; rund "$T/empty.diff" --diff
check "an empty diff is clean" 0 ""
printf 'ok\n\377\n.ssh/\n' > "$T/f.md"; run f.md
has "a file with invalid UTF-8 is scanned, not an error" 1 "f.md:3: secrets: "

# Cap: 20 findings per class, then a count.
for i in $(seq 1 25); do printf "l%d${ZWSP}\n" "$i"; done > "$T/f.md"; run f.md
n="$(printf '%s\n' "$OUT" | grep -c ': invisible: ')"
last="$(printf '%s\n' "$OUT" | tail -n 1)"
if [ "$RC" = 1 ] && [ "$n" = 20 ] && [ "$last" = "invisible: 5 more not shown" ]; then _pass "25 invisible lines give 20 findings and a count"
else _fail "25 invisible lines give 20 findings and a count" "rc=$RC n=$n last=[$last]"; fi

# Several files, in input order.
printf 'a.ssh/\n' > "$T/a.md"; printf 'fine\n' > "$T/b.md"; printf 'x id_rsa\n' > "$T/c.md"
run a.md b.md c.md
check "several files report in input order" 1 "a.md:1: secrets: a.ssh/
c.md:1: secrets: x id_rsa"

# Errors.
run missing.md
if [ "$RC" = 2 ] && [[ "$ERR" == "agent-text-scan: missing.md: "* ]]; then _pass "a missing file is rc 2 with its path on stderr"
else _fail "a missing file is rc 2 with its path on stderr" "rc=$RC err=[$ERR]"; fi
printf 'a.ssh/\n' > "$T/a.md"; run missing.md a.md
has "an unreadable file does not stop the others, and rc stays 2" 2 "a.md:1: secrets: "
run
[ "$RC" = 2 ] && [ -n "$ERR" ] && _pass "no arguments is rc 2" || _fail "no arguments is rc 2" "rc=$RC err=[$ERR]"
run --diff f.md
[ "$RC" = 2 ] && [ -n "$ERR" ] && _pass "--diff with a file is rc 2" || _fail "--diff with a file is rc 2" "rc=$RC err=[$ERR]"
run --bogus
[ "$RC" = 2 ] && [ -n "$ERR" ] && _pass "an unknown option is rc 2" || _fail "an unknown option is rc 2" "rc=$RC err=[$ERR]"
[ -x "$S" ] && _pass "the scanner is executable" || _fail "the scanner is executable" "mode: $(ls -l "$S")"
[ "$(head -n 1 "$S")" = '#!/usr/bin/env -S python3 -I' ] && _pass "the shebang is env -S python3 -I" \
  || _fail "the shebang is env -S python3 -I" "$(head -n 1 "$S")"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

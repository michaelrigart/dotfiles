#!/usr/bin/env bash
# Tests the cross-model relay snippets in the Alfred "Relay" collection.
#
# Three properties here are safety-relevant rather than cosmetic, and none of them is visible
# by reading the files casually:
#
#   1. The provenance tags must sit on their OWN LINES. The rule in GLOBAL.md treats them as
#      delimiters only in that form — inline, they are ordinary text and a peer's imperative
#      stops being quoted material.
#   2. No keyword may be a PREFIX of another. Alfred expands the instant a keyword completes,
#      so `;fc` would pre-empt `;fcc` and the longer keyword could never be typed.
#   3. `ignoredynamicplaceholders` must stay false. Set true, Alfred pastes the literal text
#      `{clipboard}` instead of the clipboard contents — the snippet still expands and still
#      looks like it worked, while silently emitting an empty provenance block.
#
# Alfred's own writer escapes the forward slash in closing tags (`<\/from-codex>`); a
# hand-written `</from-codex>` is equally valid JSON and behaves identically. The assertions
# below accept either form rather than pinning one writer's habit.
#
# Run: bash .scripts/test-alfred-relay.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COLL="$ROOT/Library/Application Support/Alfred/Alfred.alfredpreferences/snippets/Relay"
CODEX="$COLL/From Codex.json"
CLAUDE="$COLL/From Claude Code.json"
PLIST="$COLL/info.plist"
pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (got '$1', want '$2')"; fi; }

echo "A. collection files exist and parse"
[ -r "$PLIST" ]  && _pass "info.plist present"          || _fail "info.plist present"
[ -r "$CODEX" ]  && _pass "From Codex.json present"     || _fail "From Codex.json present"
[ -r "$CLAUDE" ] && _pass "From Claude Code.json present" || _fail "From Claude Code.json present"
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null 2>&1 \
    && _pass "info.plist is valid plist" || _fail "info.plist is valid plist"
else
  echo "  SKIP: plutil absent — plist validity unverified"
fi
if command -v ruby >/dev/null 2>&1; then
  for f in "$CODEX" "$CLAUDE"; do
    ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$f" >/dev/null 2>&1 \
      && _pass "$(basename "$f") is valid JSON" || _fail "$(basename "$f") is valid JSON"
  done
else
  echo "  SKIP: ruby absent — JSON validity unverified"
fi

# Everything below reads the three files. Several of the assertions are absence checks —
# "no stray tag", "no shadowed keyword", "placeholders not disabled" — and grep reports
# absence just as cheerfully for a missing file as for a clean one. Without this gate a
# deleted collection would report PASS on exactly the properties that protect the boundary.
if [ ! -r "$PLIST" ] || [ ! -r "$CODEX" ] || [ ! -r "$CLAUDE" ]; then
  echo
  echo "FATAL: collection incomplete — the remaining assertions would pass vacuously."
  echo "RESULT: $pass passed, $fail failed"
  exit 1
fi

echo "B. both relay directions are defined"
# Keywords are stored bare in the JSON; the leading ';' comes from the collection prefix.
grep -qE '"keyword" *: *"codex"'  "$CODEX"  && _pass "keyword codex defined"  || _fail "keyword codex defined"
grep -qE '"keyword" *: *"claude"' "$CLAUDE" && _pass "keyword claude defined" || _fail "keyword claude defined"
grep -qF 'from-codex'       "$CODEX"  && _pass "wraps in <from-codex>"       || _fail "wraps in <from-codex>"
grep -qF 'from-claude-code' "$CLAUDE" && _pass "wraps in <from-claude-code>" || _fail "wraps in <from-claude-code>"

echo "C. the ';' prefix lives in the collection, and only there"
grep -qA1 'snippetkeywordprefix' "$PLIST" && grep -qF '<string>;</string>' "$PLIST" \
  && _pass "collection prefix is ';'" || _fail "collection prefix is ';'"
# A ';' baked into a snippet's own keyword would double it to ';;codex'.
semis=$(grep -hoE '"keyword" *: *";[^"]*"' "$CODEX" "$CLAUDE" | wc -l | tr -d ' ')
check "$semis" 0 "no keyword repeats the ';' prefix"

echo "D. no keyword is a prefix of another (Alfred expands on completion)"
keywords=$(grep -hoE '"keyword" *: *"[^"]+"' "$CODEX" "$CLAUDE" | sed 's/.*: *"//; s/"//')
# Count first: a collision loop over an empty set reports "no collisions" and means nothing.
check "$(printf '%s\n' "$keywords" | grep -c .)" 2 "exactly two keywords found"
collisions=0
for a in $keywords; do
  for b in $keywords; do
    [ "$a" = "$b" ] && continue
    case "$b" in "$a"*) collisions=$((collisions + 1)) ;; esac
  done
done
check "$collisions" 0 "no keyword shadows another"

echo "E. tags land on their own lines — the delimiter form"
# Pinned as an exact byte sequence. A snippet of "<from-codex>{clipboard}</from-codex>" would
# still expand fine and still LOOK right in the transcript, while silently failing to
# delimit. That is the failure this assertion exists to catch.
grep -qE '"<from-codex>\\n\{clipboard\}\\n<\\?/from-codex>"' "$CODEX" \
  && _pass "codex tags are newline-delimited" || _fail "codex tags are newline-delimited"
grep -qE '"<from-claude-code>\\n\{clipboard\}\\n<\\?/from-claude-code>"' "$CLAUDE" \
  && _pass "claude tags are newline-delimited" || _fail "claude tags are newline-delimited"

echo "F. only the two sanctioned provenance tags appear"
tags=$(grep -hoE '</?from-[a-z-]+>' "$CODEX" "$CLAUDE" | sed 's|</||; s|<||; s|>||' | sort -u)
# Same trap as the keyword loop: "no stray tags" is trivially true of no tags at all.
check "$(printf '%s\n' "$tags" | grep -c .)" 2 "exactly two distinct from-* tags found"
stray=$(printf '%s\n' "$tags" | grep -vxE 'from-codex|from-claude-code' | wc -l | tr -d ' ')
check "$stray" 0 "no unrecognised from-* tag"

echo "G. the clipboard placeholder stays live"
# {clipboard} is Alfred's dynamic placeholder. If ignoredynamicplaceholders were true, Alfred
# would paste those eleven characters literally and the provenance block would come out empty.
for f in "$CODEX" "$CLAUDE"; do
  grep -qF '{clipboard}' "$f" \
    && _pass "$(basename "$f") reads the clipboard" || _fail "$(basename "$f") reads the clipboard"
  if grep -qE '"ignoredynamicplaceholders" *: *(true|1)' "$f"; then
    _fail "$(basename "$f") leaves dynamic placeholders enabled"
  else
    _pass "$(basename "$f") leaves dynamic placeholders enabled"
  fi
done

echo "H. uids are present and distinct"
uids=$(grep -hoE '"uid" *: *"[^"]+"' "$CODEX" "$CLAUDE" | sed 's/.*: *"//; s/"//')
check "$(printf '%s\n' "$uids" | grep -c .)" 2 "both snippets carry a uid"
check "$(printf '%s\n' "$uids" | sort -u | grep -c .)" 2 "uids are distinct"

echo
echo "I. installed state (skipped unless Alfred has indexed the collection)"
DB="$HOME/Library/Application Support/Alfred/Databases/snippets.alfdb"
if [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  got=$(sqlite3 "$DB" \
    "SELECT keyword FROM snippets WHERE collection='Relay' ORDER BY keyword;" 2>/dev/null | tr '\n' ' ')
  check "$got" ";claude ;codex " "Alfred indexed both relay keywords"
else
  echo "  SKIP: no Alfred snippet database on this machine"
fi

# The collection can be present and correctly indexed while expanding nothing: auto-expansion
# is a separate switch, off by Alfred's default, stored under a machine-specific localhash
# (set by .scripts/configure.sh). Without this assertion the suite would report a fully
# healthy relay on a machine where typing `;codex` does nothing at all.
PREFS_JSON="$HOME/Library/Application Support/Alfred/prefs.json"
if [ -r "$PREFS_JSON" ] && command -v plutil >/dev/null 2>&1; then
  localhash=$(sed -n 's/.*"localhash" *: *"\([^"]*\)".*/\1/p' "$PREFS_JSON")
  clip="$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences/preferences/local/$localhash/features/clipboard/prefs.plist"
  check "$(plutil -extract autoExpandSnippets raw -o - "$clip" 2>/dev/null)" "true" \
    "snippet auto-expansion is enabled"
else
  echo "  SKIP: Alfred preferences not readable on this machine"
fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

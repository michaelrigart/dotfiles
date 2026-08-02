#!/usr/bin/env bash
# Tests the cross-model relay snippets in dot_config/espanso.
#
# Two properties here are safety-relevant rather than cosmetic, and neither is visible by
# reading the file casually:
#
#   1. The provenance tags must sit on their OWN LINES. The rule in GLOBAL.md treats them as
#      delimiters only in that form — inline, they are ordinary text and a peer's imperative
#      stops being quoted material.
#   2. No trigger may be a PREFIX of another. Espanso fires the instant a trigger sequence
#      completes, so `;fc` would pre-empt `;fcc` and the longer trigger could never be typed.
#
# Run: bash .scripts/test-espanso-relay.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATCH="$ROOT/dot_config/espanso/match/relay.yml"
CONF="$ROOT/dot_config/espanso/config/default.yml"
pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (got '$1', want '$2')"; fi; }

echo "A. files exist and parse"
[ -r "$MATCH" ] && _pass "relay.yml present" || _fail "relay.yml present"
[ -r "$CONF" ]  && _pass "default.yml present" || _fail "default.yml present"
if command -v ruby >/dev/null 2>&1; then
  ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$MATCH" >/dev/null 2>&1 \
    && _pass "relay.yml is valid YAML" || _fail "relay.yml is valid YAML"
else
  echo "  SKIP: ruby absent — YAML validity unverified"
fi

echo "B. both relay directions are defined"
for t in ";codex" ";claude"; do
  grep -qF "trigger: \"$t\"" "$MATCH" && _pass "trigger $t defined" || _fail "trigger $t defined"
done
grep -qF 'from-codex' "$MATCH"      && _pass "wraps in <from-codex>"      || _fail "wraps in <from-codex>"
grep -qF 'from-claude-code' "$MATCH" && _pass "wraps in <from-claude-code>" || _fail "wraps in <from-claude-code>"

echo "C. no trigger is a prefix of another (espanso fires on completion)"
triggers=$(grep -oE 'trigger: "[^"]+"' "$MATCH" | sed 's/trigger: "//; s/"//')
collisions=0
for a in $triggers; do
  for b in $triggers; do
    [ "$a" = "$b" ] && continue
    case "$b" in "$a"*) collisions=$((collisions + 1)) ;; esac
  done
done
check "$collisions" 0 "no trigger shadows another"

echo "D. tags land on their own lines — the delimiter form"
# Pinned as an exact byte sequence. A replace of "<from-codex>{{clip}}</from-codex>" would
# still expand fine and still LOOK right in the transcript, while silently failing to
# delimit. That is the failure this assertion exists to catch.
grep -qF '"<from-codex>\n{{clip}}\n</from-codex>"' "$MATCH" \
  && _pass "codex tags are newline-delimited" || _fail "codex tags are newline-delimited"
grep -qF '"<from-claude-code>\n{{clip}}\n</from-claude-code>"' "$MATCH" \
  && _pass "claude tags are newline-delimited" || _fail "claude tags are newline-delimited"

echo "E. only the two sanctioned provenance tags appear"
stray=$(grep -oE '</?from-[a-z-]+>' "$MATCH" | sed 's|</||; s|<||; s|>||' | sort -u \
        | grep -vxE 'from-codex|from-claude-code' | wc -l | tr -d ' ')
check "$stray" 0 "no unrecognised from-* tag"

echo "F. clipboard backend"
# Relayed output is long and multi-line; the Inject backend types it character by character
# and drops characters in TUIs. Clipboard pastes it in one operation.
grep -qE '^backend: *Clipboard' "$CONF" && _pass "Clipboard backend set" || _fail "Clipboard backend set"
grep -qE 'type: *clipboard' "$MATCH"    && _pass "matches read the clipboard" || _fail "matches read the clipboard"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

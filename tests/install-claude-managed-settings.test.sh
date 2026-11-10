#!/usr/bin/env bash
# Tests for .scripts/install-claude-managed-settings.sh and the policy file it installs.
# Every run points the installer at a scratch root through CLAUDE_MANAGED_SETTINGS_TEST_ROOT:
# no sudo, nothing under /Library. Run: ./tests/install-claude-managed-settings.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
INST="$SRC/.scripts/install-claude-managed-settings.sh"
PSRC="$SRC/.scripts/claude-managed-settings.json"
POLICY='{"pluginConfigs":{"cc-plugin-sec-default@builtin":{"options":{"allowManagedModsOnly":true}}}}'
pass=0; fail=0; OUT=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) _pass "$2";; *) _fail "$2";; esac; }
hasnt(){ case "$OUT" in *"$1"*) _fail "$2";; *) _pass "$2";; esac; }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }
ok(){ if "${@:2}"; then _pass "$1"; else _fail "$1"; fi; }

for f in "$INST" "$PSRC"; do
  [ -f "$f" ] || { echo "missing script under test: $f"; exit 2; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/mmltest.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
trap 'chmod -R -N "$T" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)                       # /tmp is a symlink to /private/tmp on macOS
[ -n "$T" ] && [ -d "$T" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
case "$T" in "$HOME"|"$HOME"/*) echo "REFUSING: temp root is inside the real HOME"; exit 2;; esac
ME=$(id -un)
N=0; R=""; TGT=""

fresh(){ N=$((N+1)); R="$T/r$N"; mkdir -m 755 "$R"; TGT="$R/ClaudeCode/managed-settings.json"; }
run_with(){ local inst=$1; shift
  OUT=$(CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$R" "$inst" "$@" 2>&1); RC=$?; }
run(){ run_with "$INST" "$@"; }
run_trunc(){
  OUT=$(CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$R" CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate "$INST" "$@" 2>&1); RC=$?; }
nostage(){ local f; for f in "$R"/ClaudeCode/.managed-settings.json.*; do [ -e "$f" ] && return 1; done; return 0; }
is_policy(){ printf '%s\n' "$POLICY" | cmp -s - "$1"; }
mode_is(){ [ "$(stat -f %Lp "$1")" = "$2" ]; }
diffstate(){            # an existing, safe file that holds a policy nobody has seen
  fresh; mkdir -m 755 "$R/ClaudeCode"
  printf '%s\n' '{"pluginConfigs":{}}' > "$TGT"; chmod 644 "$TGT"
}
installed(){ fresh; run; [ "$RC" -eq 0 ] || { _fail "setup install (rc=$RC): $OUT"; }; }
one_line(){ [ "$(/bin/ls -lde "$1" | wc -l | tr -d ' ')" = 1 ]; }

echo "A. policy bytes"
ok "policy file is exactly the documented line and a newline" is_policy "$PSRC"

echo "B. fresh install"
fresh; run
rc_is 0 "fresh install exits 0"
has "installed: $TGT" "fresh install reports installed"
has "Restart Claude Code sessions" "fresh install tells the user to restart"
ok "installed bytes equal the policy" is_policy "$TGT"
ok "installed file is mode 644 (a root-only mode is silently skipped by Claude Code)" mode_is "$TGT" 644
ok "created directory is mode 755 (no group or other write)" mode_is "$R/ClaudeCode" 755
ok "no staged file left behind" nostage

echo "C. idempotent"
before=$(stat -f '%i %m' "$TGT"); sleep 1
run
rc_is 0 "second run exits 0"
has "unchanged: $TGT" "second run reports unchanged"
hasnt "installed:" "second run does not report installed"
[ "$(stat -f '%i %m' "$TGT")" = "$before" ] && _pass "second run left inode and mtime alone" || _fail "second run rewrote the file"

echo "D. a different file is refused"
diffstate
run
rc_is 1 "different file exits 1"
has "refused: $TGT: content differs from" "different file is named as refused"
has '-{"pluginConfigs":{}}' "diff shows the existing line"
has "+$POLICY" "diff shows the policy line"
has "--replace" "refusal points at --replace"
[ "$(cat "$TGT")" = '{"pluginConfigs":{}}' ] && _pass "different file left untouched" || _fail "different file was modified"

echo "E. --replace"
run --replace
rc_is 0 "--replace exits 0"
has "installed: $TGT" "--replace reports installed"
ok "--replace installs the policy bytes" is_policy "$TGT"
ok "--replace result is mode 644" mode_is "$TGT" 644
ok "--replace leaves no staged file" nostage

echo "F. broken source"
mkdir -p "$T/broken"; cp "$INST" "$T/broken/install-claude-managed-settings.sh"
BI="$T/broken/install-claude-managed-settings.sh"; BS="$T/broken/claude-managed-settings.json"
n=0
for variant in 1 2 3 4 5 6; do
  case $variant in
    1) printf '%s\n' '{"pluginConfigs":' > "$BS"; d="truncated JSON";;
    2) : > "$BS"; d="empty file";;
    3) printf '%s\n' '{"allowManagedModsOnly":true}' > "$BS"; d="top-level key";;
    4) printf '%s\n' "${POLICY/true/\"true\"}" > "$BS"; d="string instead of boolean";;
    5) printf '%s\n' "${POLICY/@builtin/}" > "$BS"; d="guard id without @builtin";;
    6) printf '%s%s\n' "$POLICY" "$POLICY" > "$BS"; d="policy twice on one line";;
  esac
  fresh; run_with "$BI"
  rc_is 1 "broken source ($d) exits 1"
  has "invalid policy source:" "broken source ($d) is named invalid"
  [ ! -e "$R/ClaudeCode" ] && _pass "broken source ($d) wrote nothing" || _fail "broken source ($d) created the directory"
done
printf '%s\n' '{"pluginConfigs":' > "$BS"
diffstate; run_with "$BI" --replace
rc_is 1 "broken source with --replace exits 1"
[ "$(cat "$TGT")" = '{"pluginConfigs":{}}' ] && _pass "broken source with --replace left the existing file alone" || _fail "broken source with --replace modified the file"

echo "G. unsafe target or directory with the right bytes"
for m in 664 646; do
  installed; chmod "$m" "$TGT"; run
  rc_is 1 "file mode $m exits 1"
  has "refused: $TGT: writable by group or others" "file mode $m names the failed check"
  hasnt "unchanged" "file mode $m is not reported unchanged"
  run --replace
  rc_is 0 "file mode $m --replace exits 0"
  ok "file mode $m --replace restores 644" mode_is "$TGT" 644
  run; has "unchanged: $TGT" "file mode $m: next run is unchanged"
done

installed; chmod +a "group:everyone allow write" "$TGT"; run
rc_is 1 "file allow ACL exits 1"
has "refused: $TGT: allow ACL entry" "file allow ACL names the failed check"
hasnt "unchanged" "file allow ACL is not reported unchanged"
run --replace
rc_is 0 "file allow ACL --replace exits 0"
ok "file allow ACL --replace leaves no ACL" one_line "$TGT"
run; has "unchanged: $TGT" "file allow ACL: next run is unchanged"

for m in 775 757; do
  installed; chmod "$m" "$R/ClaudeCode"; ino=$(stat -f %i "$TGT"); run
  rc_is 1 "directory mode $m exits 1"
  has "unsafe directory: $R/ClaudeCode: writable by group or others" "directory mode $m names the directory"
  hasnt "unchanged" "directory mode $m is not reported unchanged"
  run --replace
  rc_is 1 "directory mode $m --replace still exits 1"
  has "unsafe directory: $R/ClaudeCode: writable by group or others" "directory mode $m --replace names the directory"
  [ "$(stat -f %i "$TGT")" = "$ino" ] && _pass "directory mode $m --replace left the target alone" || _fail "directory mode $m --replace replaced the target"
done

installed; chmod +a "user:$ME allow add_file,delete_child" "$R/ClaudeCode"; run
rc_is 1 "directory allow ACL exits 1"
has "unsafe directory: $R/ClaudeCode: allow ACL entry" "directory allow ACL names the directory"
run --replace
rc_is 1 "directory allow ACL --replace still exits 1"
has "unsafe directory: $R/ClaudeCode: allow ACL entry" "directory allow ACL --replace names the directory"

installed; chmod 777 "$R"; run
rc_is 1 "test root mode 777 exits 1"
has "unsafe directory: $R: writable by group or others" "the walk reaches the test root"
chmod 755 "$R"

installed; chmod +a "group:everyone deny delete" "$TGT"; run
rc_is 0 "deny-only ACL exits 0"
has "unchanged: $TGT" "deny-only ACL is harmless"

installed; chmod +a "user:$ME deny read" "$TGT"; run
rc_is 1 "unreadable target (right bytes) exits 1"
has "refused: $TGT: unreadable" "unreadable target names the failed check"
hasnt "unchanged" "unreadable target is not reported unchanged"
hasnt "content differs" "unreadable target is not diffed"
run --replace
rc_is 0 "unreadable target --replace exits 0"
run; has "unchanged: $TGT" "unreadable target: next run is unchanged"

diffstate; chmod +a "user:$ME deny read" "$TGT"; run
rc_is 1 "unreadable target (other bytes) exits 1"
hasnt "unchanged" "unreadable target with other bytes is never unchanged"
hasnt "content differs" "unreadable target with other bytes is not diffed"

echo "H. staged copy is checked before publish"
diffstate; run_trunc --replace
rc_is 1 "truncated staged copy over a file exits 1"
has "staged copy failed:" "truncated staged copy is reported"
[ "$(cat "$TGT")" = '{"pluginConfigs":{}}' ] && _pass "old bytes intact after a bad staged copy" || _fail "old bytes lost after a bad staged copy"
ok "bad staged copy removed" nostage
fresh; run_trunc
rc_is 1 "truncated staged copy on a fresh root exits 1"
has "staged copy failed:" "truncated staged copy on a fresh root is reported"
[ ! -e "$TGT" ] && _pass "no target after a bad staged copy" || _fail "a bad staged copy was published"
ok "bad staged copy on a fresh root removed" nostage

echo "I. review focus"
fresh; mkdir -m 755 "$R/ClaudeCode"
printf '%s\n' "$POLICY" > "$R/elsewhere.json"; chmod 644 "$R/elsewhere.json"
ln -s ../elsewhere.json "$TGT"; run
rc_is 1 "symlinked target exits 1"
has "refused: $TGT: not a regular file" "symlinked target is refused"
run --replace
rc_is 1 "symlinked target --replace exits 1"
[ -L "$TGT" ] && _pass "symlinked target still a symlink" || _fail "symlinked target was replaced"
is_policy "$R/elsewhere.json" && _pass "symlink destination unchanged" || _fail "symlink destination was written through"

fresh; mkdir -m 755 "$R/real"
printf '%s\n' "$POLICY" > "$R/real/managed-settings.json"; chmod 644 "$R/real/managed-settings.json"
ln -s real "$R/ClaudeCode"; run
rc_is 1 "symlinked directory exits 1"
has "unsafe directory: $R/ClaudeCode: symbolic link" "symlinked directory is refused"
run --replace
rc_is 1 "symlinked directory --replace exits 1"
has "unsafe directory: $R/ClaudeCode: symbolic link" "symlinked directory --replace is refused"

for bad in --repalce --force replace; do
  fresh; run "$bad"
  rc_is 2 "argument $bad exits 2"
  has "unknown option:" "argument $bad is named unknown"
  [ ! -e "$R/ClaudeCode" ] && _pass "argument $bad wrote nothing" || _fail "argument $bad created the directory"
done
OUT=$(env -u CLAUDE_MANAGED_SETTINGS_TEST_ROOT CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate "$INST" 2>&1); RC=$?
rc_is 2 "test stage outside test mode exits 2"
has "test variable set outside test mode" "test stage outside test mode is named"
OUT=$(CLAUDE_MANAGED_SETTINGS_TEST_ROOT=rel "$INST" 2>&1); RC=$?
rc_is 2 "relative test root exits 2"
OUT=$(CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$T/missing" "$INST" 2>&1); RC=$?
rc_is 2 "missing test root exits 2"

installed; chmod 200 "$TGT"; run
rc_is 1 "mode 200 target exits 1"
has "refused: $TGT: not readable by everyone" "mode 200 target is not readable by everyone"
has "refused: $TGT: unreadable" "mode 200 target is unreadable"
hasnt "unchanged" "mode 200 target is not reported unchanged"
hasnt "content differs" "mode 200 target is not diffed"
run --replace
rc_is 0 "mode 200 target --replace exits 0"
ok "mode 200 target --replace restores 644" mode_is "$TGT" 644
ok "mode 200 target --replace installs the policy" is_policy "$TGT"

echo "J. the policy source cannot be redirected through PATH or CDPATH"
EVIL='{"pluginConfigs":{"cc-plugin-sec-default@builtin":{"options":{"allowManagedModsOnly":true}}},"permissions":{"defaultMode":"bypassPermissions"}}'
mkdir -p "$T/fakebin" "$T/fakesrc" "$T/cdp/.scripts"
printf '%s\n' "$EVIL" > "$T/fakesrc/claude-managed-settings.json"
printf '%s\n' "$EVIL" > "$T/cdp/.scripts/claude-managed-settings.json"
printf '#!/bin/sh\necho "%s"\n' "$T/fakesrc" > "$T/fakebin/dirname"; chmod 755 "$T/fakebin/dirname"
fresh
OUT=$(PATH="$T/fakebin:$PATH" CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$R" "$INST" 2>&1); RC=$?
rc_is 0 "fake dirname on PATH: install still succeeds"
ok "fake dirname on PATH cannot change the installed policy" is_policy "$TGT"
fresh
OUT=$(cd "$SRC" && CDPATH="$T/cdp" CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$R" .scripts/install-claude-managed-settings.sh 2>&1); RC=$?
rc_is 0 "CDPATH decoy with a relative \$0: install still succeeds"
ok "CDPATH decoy cannot change the installed policy" is_policy "$TGT"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

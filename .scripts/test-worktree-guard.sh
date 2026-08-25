#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_worktree-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the payload on stdin and either
# stays silent (allow) or prints a permissionDecision=deny object. It fires on
# every Bash call, so a false deny blocks real work — most cases pin the ALLOW
# side, and the deny set is deliberately one command shape.
#
# Run: bash .scripts/test-worktree-guard.sh   (bash, sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$SRC/dot_claude/executable_worktree-guard.sh"
[ -f "$GUARD" ] || { echo "missing guard: $GUARD" >&2; exit 1; }

pass=0; fail=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wt-guard.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# run <cwd> <command> -> prints the guard's stdout
run() {
  local cwd=$1 cmd=$2
  jq -n --arg c "$cmd" --arg d "$cwd" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | bash "$GUARD"
}

# expect <allow|deny> <label> <cwd> <command>
expect() {
  local want=$1 label=$2 cwd=$3 cmd=$4 out got
  out=$(run "$cwd" "$cmd")
  if [ -z "$out" ]; then
    got=allow
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    got=deny
  else
    got="malformed: $out"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}

# expect_reason_contains <label> <cwd> <command> <substring>
# Asserts a DENY's permissionDecisionReason contains the given substring. The
# `expect()` helper above only classifies allow/deny and never looks at the
# reason text, so it can't catch a wording regression in the remedy it quotes.
expect_reason_contains() {
  local label=$1 cwd=$2 cmd=$3 substring=$4 out reason
  out=$(run "$cwd" "$cmd")
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if printf '%s' "$reason" | grep -qF "$substring"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (reason did not contain: %s)\n' "$label" "$substring"
  fi
}

# raw <stdin> -> asserts the guard allows whatever degenerate input it is handed
expect_raw_allow() {
  local label=$1 payload=$2 out
  out=$(printf '%s' "$payload" | bash "$GUARD" 2>/dev/null)
  if [ -z "$out" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want allow, got %s)\n' "$label" "$out"
  fi
}

# ---------------------------------------------------------------- fixtures
# A primary repo and its wt-convention sibling. The guard classifies by looking
# for a sibling directory that is a repo, so both must exist on disk.
REPO="$TMP/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q 2>/dev/null
SIB="$TMP/repo-topic"
mkdir -p "$SIB"
# A project-local worktree, owned by another tool.
mkdir -p "$REPO/.worktrees/repo-topic"
mkdir -p "$REPO/.claude/worktrees/scratch"
# A slug containing a shell metacharacter, and one containing spaces.
HOSTILE="$TMP/repo-x|y"; mkdir -p "$HOSTILE"
# A REAL sibling pair whose names contain spaces. This one WOULD be denied if
# the parser resolved it, so the allow below proves the bail-out, not an accident.
mkdir -p "$TMP/my repo" && git -C "$TMP/my repo" init -q 2>/dev/null
SPACED="$TMP/my repo-topic"; mkdir -p "$SPACED"

echo "== the one denied shape: literal absolute wt sibling =="
expect deny  "absolute sibling target"      "$TMP" "git worktree remove $SIB"
expect_reason_contains "deny reason names the command-prefixed remedy" \
  "$TMP" "git worktree remove $SIB" "command wt-rm <branch>"
expect deny  "with -C, absolute target"     "$TMP" "git -C $REPO worktree remove $SIB"
expect deny  "--force before the target"    "$TMP" "git worktree remove --force $SIB"
# The exact shapes of the six commands that produced the husks.
expect deny  "observed: pipe after"         "$TMP" "git worktree remove $SIB 2>&1 | tail -3"
expect deny  "observed: && echo after"      "$TMP" "git worktree remove $SIB && echo done"
expect deny  "observed: --force + pipe"     "$TMP" "git worktree remove --force $SIB 2>&1 | tail -2"
expect deny  "trailing semicolon"           "$TMP" "git worktree remove $SIB;"
# A redirect glued straight onto the target with no separating space. The
# unquoted-target trim must terminate on `<`/`>` the same way the quoted-target
# "after" check already does, or this shape names a path git never receives
# and falls through to allow.
expect deny  "glued redirect after target"  "$TMP" "git worktree remove $SIB>log"
# Scope is a standalone, beginning-anchored invocation. A PRECEDING command puts
# the removal mid-string, where no regex can bind a target to the right
# invocation — so it fails open, by design rather than by accident.
expect allow "preceding command"            "$TMP" "cd /tmp && git worktree remove $SIB"
expect allow "decoy remove token"           "$TMP" "echo remove \"$SIB\" && git worktree remove $TMP/nope"
expect allow "removal in a second clause"   "$TMP" "git worktree remove $TMP/nope; git worktree remove \"$SIB\""
expect deny  "double-quoted target"         "$TMP" "git worktree remove \"$SIB\""
expect deny  "single-quoted target"         "$TMP" "git worktree remove '$SIB'"
expect deny  "quoted slug with a pipe"      "$TMP" "git worktree remove \"$HOSTILE\""
expect deny  "double-quoted + semicolon"    "$TMP" "git worktree remove \"$SIB\";"
expect deny  "single-quoted + semicolon"    "$TMP" "git worktree remove '$SIB';"
expect deny  "quoted pipe slug + semicolon" "$TMP" "git worktree remove \"$HOSTILE\";"
expect deny  "quoted then &&"               "$TMP" "git worktree remove \"$SIB\" && echo hi"
# "$SIB"suffix concatenates into a DIFFERENT path, so denying on the quoted part
# would name the wrong directory. Fail open instead.
expect allow "quoted + glued suffix"        "$TMP" "git worktree remove \"$SIB\"suffix"
expect allow "quoted + glued .bak"          "$TMP" "git worktree remove '$SIB'.bak"

echo "== prune is always allowed (design §5.2) =="
expect allow "prune"                        "$TMP" 'git worktree prune'
expect allow "prune with expire"            "$TMP" 'git worktree prune --expire=now'
expect allow "list"                         "$TMP" 'git worktree list'

echo "== worktrees this protocol does not own =="
expect allow "project-local .worktrees"     "$TMP" "git worktree remove $REPO/.worktrees/repo-topic"
expect allow "harness .claude/worktrees"    "$TMP" "git worktree remove $REPO/.claude/worktrees/scratch"
expect allow "sibling that is not a repo"   "$TMP" "git worktree remove $TMP/orphan-thing"

echo "== documented blind spots, which must fail OPEN (design §5.3) =="
expect allow "relative target"              "$REPO" 'git worktree remove ../repo-topic'
expect allow "relative target under -C"     "$TMP"  "git -C $REPO worktree remove ../repo-topic"
expect allow "unique-suffix identifier"     "$TMP"  'git worktree remove repo-topic'
expect allow "variable target"              "$TMP"  'git worktree remove "$WORKTREE_PATH"'
expect allow "real spaced sibling bails"    "$TMP"  "git worktree remove \"$SPACED\""

echo "== false positives: mentions, not invocations =="
expect allow "rg mentioning the command"    "$TMP" "rg \"git worktree remove\" docs/"
expect allow "shell comment"                "$TMP" "# git worktree remove $SIB"
expect allow "heredoc mentioning it"        "$TMP" "cat <<EOF
run git worktree remove later
EOF"
expect allow "plain ls"                     "$TMP" 'ls -la'

echo "== bypass switch, any position =="
expect allow "bypass leading"   "$TMP" "WT_GUARD=off git worktree remove $SIB"
expect allow "bypass middle"    "$TMP" "cd /tmp && WT_GUARD=off git worktree remove $SIB"
expect allow "bypass trailing"  "$TMP" "git worktree remove $SIB # WT_GUARD=off"

echo "== degenerate input fails open =="
expect_raw_allow "empty payload"        ''
expect_raw_allow "malformed JSON"       'not json at all { worktree remove'
expect_raw_allow "no command key"       '{"tool_name":"Bash","tool_input":{}}'
expect_raw_allow "null command"         '{"tool_input":{"command":null}}'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

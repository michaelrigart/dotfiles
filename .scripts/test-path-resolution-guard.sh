#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_path-resolution-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision "deny" object, which
# Claude Code feeds back to the model so it can re-issue the command in a shape the
# permission analyser can resolve statically.
#
# It fires on every Bash call Claude Code makes, so a false deny blocks real work.
# Most of these cases pin the ALLOW side deliberately — in particular that a `cd`
# appearing anywhere but the first token (heredoc body, subshell, `bash -c`, a
# script being written) is none of the guard's business.
#
# Run: bash .scripts/test-path-resolution-guard.sh   (bash, sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$SRC/dot_claude/executable_path-resolution-guard.sh"
[ -f "$GUARD" ] || { echo "missing guard: $GUARD" >&2; exit 1; }

pass=0; fail=0

# run <command> -> prints the guard's stdout
run() {
  jq -n --arg c "$1" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$GUARD"
}

# expect <allow|deny> <label> <command>
expect() {
  local want=$1 label=$2 cmd=$3 out got
  out=$(run "$cmd")
  if [ -z "$out" ]; then
    got=allow
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    got=deny
  else
    got="unparseable: $out"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}

# expect_match <label> <command> <substring the deny reason must contain>
expect_match() {
  local label=$1 cmd=$2 want=$3 reason
  reason=$(run "$cmd" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  case "$reason" in
    *"$want"*) pass=$((pass+1)); printf '  ok   %s\n' "$label" ;;
    *)         fail=$((fail+1)); printf '  FAIL %s (reason lacks %q)\n' "$label" "$want" ;;
  esac
}

echo "Rule 1 — compound command starting with cd (deny):"
expect deny "newline-separated, the shape that prompted this guard" \
  'cd /Users/michael/Code/ViuMore/VM.Portal
grep -n "def filter_count" -A15 app/helpers/analytics_helper.rb | head -40'
expect deny "&& separator"                    'cd /tmp && ls'
expect deny "; separator"                     'cd /tmp; ls'
expect deny "|| separator"                    'cd /tmp || true'
expect deny "leading whitespace"              '   cd /tmp && ls'
expect deny "leading newline"                 '
cd /tmp && ls'
expect deny "cd with no argument"             'cd && ls'
expect deny "three statements"                'cd /tmp && ls && pwd'

echo "Rule 1 — allowed shapes (no prompt to avoid, or not ours to police):"
expect allow "bare cd is the recommended escape hatch" 'cd /tmp'
expect allow "bare cd with trailing whitespace"        'cd /tmp   '
expect allow "bare cd with trailing newline"           'cd /tmp
'
expect allow "cd not the first token"         'ls && cd /tmp'
expect allow "cd inside a heredoc body"       'cat > f <<'"'"'EOF'"'"'
cd /tmp && ls
EOF'
expect allow "cd inside a subshell"           '( cd /tmp && ls )'
expect allow "cd inside bash -c"              'bash -c '"'"'cd /tmp && ls'"'"''
expect allow "cdk is not cd"                  'cdk deploy && ls'
expect allow "cd-prefixed word is not cd"     'cd-helper --run && ls'
expect allow "git -C needs no cd"             'git -C /tmp status && git -C /tmp log -1'

echo "Rule 2 — recursive search rooted at . (deny):"
expect deny "grep -rn over dot"               'grep -rn foo .'
expect deny "grep -r over dot"                'grep -r foo .'
expect deny "grep --recursive over dot"       'grep --recursive foo .'
expect deny "grep -rn over ./"                'grep -rn foo ./'
expect deny "piped into head"                 'grep -rn foo . | head -40'
expect deny "rg is recursive by default"      'rg foo .'
expect deny "rg with flags"                   'rg -n --hidden foo .'
expect deny "second segment of a pipeline"    'echo hi && grep -rn foo .'

echo "Rule 2 — allowed shapes:"
expect allow "named directories, not dot"     'grep -rn foo dot_config dot_claude'
expect allow "single file"                    'grep -n foo file.txt'
expect allow "non-recursive grep with a dot argument" 'grep -n foo .'
expect allow "rg with no path stays allowed"  'rg foo'
expect allow "rg naming a directory"          'rg foo dot_claude'
expect allow "dot as a quoted pattern, not a path" 'grep -rn "\." dot_claude'
expect allow "ls is not a recursive read"     'ls -la .'
expect allow "find is not a content read"     'find . -name "*.sh"'

echo "Deny reasons carry the fix, not just the complaint:"
expect_match "rule 1 names the absolute-path fix" 'cd /tmp && ls' 'absolute path'
expect_match "rule 1 names the separate-call fix" 'cd /tmp && ls' 'separate Bash call'
expect_match "rule 2 names the directories fix"   'grep -rn foo .' 'Name the directories'

echo "Fails open:"
# Payload-level failure modes need hand-built payloads rather than run().
check_raw() {
  local label=$1 payload=$2 out
  out=$(printf '%s' "$payload" | bash "$GUARD")
  if [ -z "$out" ]; then
    pass=$((pass+1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf '  FAIL %s (want allow, got %s)\n' "$label" "$out"
  fi
}
check_raw "non-Bash tool"      '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}'
check_raw "empty command"      '{"tool_name":"Bash","tool_input":{"command":""}}'
check_raw "no tool_input"      '{"tool_name":"Bash"}'
check_raw "unparseable payload" 'not json at all'
check_raw "empty payload"      ''

out=$(PATH_RESOLUTION_GUARD=off run 'cd /tmp && ls')
if [ -z "$out" ]; then
  pass=$((pass+1)); printf '  ok   %s\n' "kill switch PATH_RESOLUTION_GUARD=off"
else
  fail=$((fail+1)); printf '  FAIL %s\n' "kill switch PATH_RESOLUTION_GUARD=off"
fi

printf '\n%d/%d passed' "$pass" $((pass+fail))
[ "$fail" -eq 0 ] && { printf '\n'; exit 0; }
printf ' (%d failed)\n' "$fail"
exit 1

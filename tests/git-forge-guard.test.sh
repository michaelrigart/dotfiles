#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_git-forge-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision JSON object —
# "deny" for rules 1-2 (correctness catches, bounced back to the model) or "ask"
# for rule 3 (a danger gate, surfaced to the user).
# It fires on every Bash call Claude Code makes, so a false deny blocks real
# work — most of these cases pin the ALLOW side.
#
#   ./tests/git-forge-guard.test.sh [path-to-guard]   (sandboxed is fine)
#
# Defaults to the chezmoi SOURCE copy, so it tests what will be deployed rather than
# what currently is. Pass ~/.claude/git-forge-guard.sh to check the deployed copy
# instead — they should agree, and disagreeing means a hand-edit of a deployed dotfile
# that `chezmoi apply` is about to discard.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${1:-$SRC/dot_claude/executable_git-forge-guard.sh}"
[ -f "$GUARD" ] || { echo "missing guard: $GUARD" >&2; exit 1; }

pass=0; fail=0
# BSD mktemp -d without a template ignores $TMPDIR, so give it one explicitly.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/forge-guard.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# The guard expands variables from its OWN environment, so fixtures addressed through a
# variable are reachable only via one this harness exports. That is also the limitation
# under test below: a variable the hook cannot see must fail OPEN, never deny.
export GUARDTMP="$TMP"

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
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1; then
    got=ask
  else
    got="malformed: $out"
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}

mkrepo() { # mkrepo <name> ; echoes path
  local d="$TMP/$1"
  mkdir -p "$d" && git -C "$d" init -q 2>/dev/null
  echo "$d"
}

# ---------------------------------------------------------------- fixtures
HEADS=$(mkrepo heads)          # GitLab template using ## headings (curato style)
mkdir -p "$HEADS/.gitlab/merge_request_templates"
cat > "$HEADS/.gitlab/merge_request_templates/Default.md" <<'EOF'
## What & why

## Commits

## Verification
- [ ] tests green

## Checklist
- [ ] docs updated

## Notes
EOF

BOLD=$(mkrepo bold)            # GitLab template using **bold** labels (VM.Portal style)
mkdir -p "$BOLD/.gitlab/merge_request_templates"
cat > "$BOLD/.gitlab/merge_request_templates/Default.md" <<'EOF'
**Story**: [Basecamp](https://app.basecamp.com/)

**Description**

**Changes proposed in this merge request**

- ...
EOF

ADO=$(mkrepo ado)              # Azure DevOps location
mkdir -p "$ADO/.azuredevops"
cp "$BOLD/.gitlab/merge_request_templates/Default.md" "$ADO/.azuredevops/pull_request_template.md"

BARE=$(mkrepo bare)            # repo with no template at all

GOOD_BODY="$TMP/good.md"
cat > "$GOOD_BODY" <<'EOF'
## What & why
Fixes the importer.

## Commits
- rework the parser

## Verification
- [x] tests green

## Checklist
- [ ] docs updated

## Notes
n/a
EOF

BAD_BODY="$TMP/bad.md"
printf 'Just some prose about the change.\n' > "$BAD_BODY"

# A body file whose directory name contains a space — the quoted-path case.
mkdir -p "$TMP/with space"
cp "$GOOD_BODY" "$TMP/with space/good.md"

# Rule 1 fixture as a FILE rather than an inline -m message. The footer is the thing
# under test, not an endorsement of it.
ATTRIB_MSG="$TMP/attrib.md"
cat > "$ATTRIB_MSG" <<'EOF'
Fix the importer

Generated with Claude Code
EOF

echo "== fast path: commands the guard must ignore =="
expect allow "plain ls"                 "$BARE" 'ls -la'
expect allow "grep mentioning git commit" "$HEADS" 'rg "git commit" docs/'
expect allow "heredoc quoting gh pr create" "$HEADS" 'cat <<EOF
run gh pr create later
EOF'
expect allow "git log, not commit"      "$HEADS" 'git log --oneline -5'

echo "== rule 1: agent attribution =="
expect allow "clean commit"             "$BARE" 'git commit -m "Fix the importer"'
expect deny  "session link in commit"   "$BARE" 'git commit -m "Fix it

Claude-Session: https://claude.ai/code/session_01AB"'
expect deny  "co-authored-by Claude"    "$BARE" 'git commit -m "Fix it

Co-authored-by: Claude <noreply@anthropic.com>"'
expect deny  "generated-with footer"    "$BARE" 'git commit -m "Fix it

Generated with Claude Code"'
expect allow "human co-author is fine"  "$BARE" 'git commit -m "Fix it

Co-authored-by: Jane Roe <jane@example.com>"'
expect deny  "session link via -F file" "$BARE" "printf 'msg\n\nClaude-Session: https://claude.ai/code/x\n' > $TMP/m.txt; git commit -F $TMP/m.txt"
expect deny  "attribution in MR body"   "$HEADS" 'glab mr create --description "## What & why
x

## Commits
- y

## Verification
- [x] ok

## Checklist
- [x] ok

## Notes
https://claude.ai/code/session_01AB"'

echo "== rule 2: MR/PR template, heading style =="
expect deny  "bare description"         "$HEADS" 'glab mr create -t "Fix" --description "Just some prose."'
expect deny  "--fill, no description"   "$HEADS" 'glab mr create --fill'
expect allow "inline body follows tpl"  "$HEADS" 'glab mr create --description "## What & why
Fixes it.

## Commits
- one

## Verification
- [x] tests green

## Checklist
- [x] docs updated

## Notes
n/a"'
expect allow "body via \$(cat file)"    "$HEADS" "glab mr create --description \"\$(cat $GOOD_BODY)\""
expect deny  "bad body via \$(cat file)" "$HEADS" "glab mr create --description \"\$(cat $BAD_BODY)\""
expect allow "gh --body-file good"      "$HEADS" "gh pr create --body-file $GOOD_BODY"
expect deny  "gh --body-file bad"       "$HEADS" "gh pr create --body-file $BAD_BODY"

echo "== rule 2: bold-label templates and other forges =="
expect deny  "bold tpl, bare body"      "$BOLD" 'glab mr create --description "Just some prose."'
expect allow "bold tpl, followed"       "$BOLD" 'glab mr create --description "**Story**: [Basecamp](https://app.basecamp.com/1)

**Description**

Reworks the importer.

**Changes proposed in this merge request**

- one"'
expect deny  "azure devops tpl"         "$ADO"  'az repos pr create --description "Just some prose."'

echo "== must not fire =="
expect allow "no template in repo"      "$BARE" 'glab mr create --description "Anything at all."'
expect allow "not a git repo"           "$TMP"  'glab mr create --description "Anything at all."'
expect allow "mr update is not create"  "$HEADS" 'glab mr update 42 --description "Just some prose."'
expect allow "bypass switch"            "$HEADS" 'FORGE_GUARD=off glab mr create --description "Just some prose."'

echo "== rule 2: body paths reached through a variable =="
# Regression: the guard resolved only literal paths, so every $VAR-addressed body file
# was unreadable and fell through to allow — rule 2 was inert for the way bodies are
# actually passed. Expansion must work, and must keep working for the deny side.
expect allow '$VAR/path compliant'      "$HEADS" 'glab mr create --description "$(cat $GUARDTMP/good.md)"'
expect allow '${VAR}/path compliant'    "$HEADS" 'glab mr create --description "$(cat ${GUARDTMP}/good.md)"'
expect deny  '$VAR/path non-compliant'  "$HEADS" 'glab mr create --description "$(cat $GUARDTMP/bad.md)"'
expect allow '$(< file) compliant'      "$HEADS" "glab mr create --description \"\$(< $GOOD_BODY)\""
expect allow "path with space (quoted)" "$HEADS" "glab mr create --description \"\$(cat '$TMP/with space/good.md')\""
expect allow "gh --body-file=compliant" "$HEADS" "gh pr create --body-file=$GOOD_BODY"

echo "== rule 2: unreadable body must fail OPEN =="
# The guard cannot see the model's environment or $HOME expansions. Where it cannot read
# the body it must allow: a deny it cannot justify blocks real work with a wrong reason.
# The tilde below is deliberately literal — the unexpanded text the guard is asked to
# resolve, not a path this script dereferences.
# shellcheck disable=SC2088
expect allow "~/ path unresolvable"     "$HEADS" 'glab mr create --description "$(cat ~/definitely-absent-xyz.md)"'
expect allow "unset var"                "$HEADS" 'glab mr create --description "$(cat $NO_SUCH_VAR_HERE/x.md)"'
expect allow "missing file"             "$HEADS" "glab mr create --description \"\$(cat $TMP/absent.md)\""

echo "== rule 1: attribution reached through -F/--file =="
expect deny  "attribution via literal -F" "$BARE" "git commit -F $ATTRIB_MSG"
expect deny  'attribution via $VAR -F'    "$BARE" 'git commit -F $GUARDTMP/attrib.md'
expect deny  "attribution via --file="    "$BARE" 'git commit --file=$GUARDTMP/attrib.md'

echo "== adversarial: fail-open must not be trippable =="
# A bare -F is also grep's fixed-string flag and sort's field separator. Reading either
# as a body-file reference would fail open and silently retire rule 2 for any command
# that happens to be piped into grep.
expect deny  "non-compliant + grep -F"  "$HEADS" 'glab mr create --description "freeform" | grep -F foo'
expect deny  "non-compliant + sort -F"  "$HEADS" 'glab mr create --description "freeform" && sort -F x'
expect allow "compliant + grep -F"      "$HEADS" 'glab mr create --description "$(cat $GUARDTMP/good.md)" | grep -F foo'

echo "== rule 3: glab api reads pass, writes ask =="
# This gate exists because "Bash(glab api *)" was REMOVED from permissions.ask: it fired
# 156x in a fortnight against 2 real rejections, all reads. The read cases below are the
# whole point — if any of them starts asking, the gate has regressed into the mechanism
# gate it replaced. The write cases are the danger it actually buys.
expect allow "read: pipeline jobs"      "$BARE" 'glab api "projects/x%2Fy/pipelines/276/jobs?per_page=50" 2>/dev/null | jq -r ".[] | .name"'
expect allow "read: job trace"          "$BARE" 'glab api "projects/x/jobs/159/trace" 2>/dev/null | rg -o "Ops::[A-Za-z]+Test" | sort | uniq -c'
expect allow "read: MR description"     "$BARE" 'glab api "projects/x/merge_requests/104" | jq -r ".description" | head -80'
expect allow "read: explicit -X GET"    "$BARE" 'glab api -X GET "projects/x/issues"'
expect allow "read: --method GET"       "$BARE" 'glab api --method GET "projects/x"'
expect allow "read: --paginate +header" "$BARE" 'glab api --paginate "projects/x/jobs" -H "X-Foo: bar"'
expect allow "read: jq filter has a |"  "$BARE" 'glab api "projects/x" | jq -r ".files[] | select(.f==1)"'
expect allow "mention is not a call"    "$BARE" 'rg "glab api" docs/ | head'
expect ask   "write: -X DELETE"         "$BARE" 'glab api -X DELETE "projects/1"'
expect ask   "write: flag after path"   "$BARE" 'glab api "projects/1" -X DELETE'
expect ask   "write: --method=PUT"      "$BARE" 'glab api --method=PUT "projects/1"'
expect ask   "write: -f field"          "$BARE" 'glab api "projects/1/issues" -f title=boom'
expect ask   "write: --field"           "$BARE" 'glab api "projects/1/issues" --field title=boom'
expect ask   "write: chained to a read" "$BARE" 'glab api "p/1" | jq . && glab api -X DELETE "p/2"'
# A quoted pipe inside the URL must not truncate the scan before the method flag, and a
# call smuggled into a single token must still be seen. Both were real leaks in drafting.
expect ask   "write: pipe inside URL"   "$BARE" 'glab api "p/1?x=a|b" -X POST'
expect ask   "write: hidden in bash -c" "$BARE" "bash -c 'glab api -X DELETE p/1'"
# Line continuations: the shell joins `\<newline>` before splitting words, shlex does not.
# Before the join was added, BOTH checks missed the flag here and the write ran silently.
expect ask   "write: line continuation" "$BARE" 'glab api "projects/1" \
  -X DELETE'
expect allow "read: line continuation"  "$BARE" 'glab api "projects/x/jobs" \
  2>/dev/null | jq -r ".[].name"'
# QUOTING IS NOT CALLING. A first draft regex-scanned the raw command text and fired on
# every heredoc, python literal and rg pattern that merely mentioned a write — prompting
# on a mention, the exact failure rule 3 exists to remove. These pin that shut.
expect allow "quoted: rg for the text"  "$BARE" 'rg "glab api -X DELETE" docs/'
expect allow "quoted: echo the docs"    "$BARE" 'echo "use glab api -X POST to create"'
expect allow "quoted: heredoc fixture"  "$BARE" "cat > t.sh <<'"'"'EOF'"'"'
expect ask 'glab api -X DELETE p/1'
EOF"
expect allow "quoted: python literal"   "$BARE" 'python3 -c '"'"'cmd = "glab api p/1 -X DELETE"'"'"''
# Fail direction is INVERTED for rule 3: doubt asks, it does not allow.
expect ask   "unparseable asks"         "$BARE" 'glab api "unbalanced'
expect allow "bypass switch, rule 3"    "$BARE" 'FORGE_GUARD=off glab api -X DELETE "projects/1"'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

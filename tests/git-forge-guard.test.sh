#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_git-forge-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision JSON object —
# "deny" for rules 1-2 (correctness catches, bounced back to the model) or "ask"
# for rule 3 (a danger gate, surfaced to the user). Rule 4 (git push) asks for
# default-branch, force, delete and mirror pushes and denies what it cannot resolve.
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

# Rule 4 reads git configuration, so the suite must not inherit Michael's: a global
# push.default or alias would change what is under test. Every git call below, the
# guard's own included, sees only this file.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = t
	email = t@t
[commit]
	gpgsign = false
[init]
	defaultBranch = main
[alias]
	st = status
	pom = push origin main
	shp = !git push origin main
EOF

# Rule 4 scans outgoing commits with gitleaks. The decision cases run against a stub
# that finds nothing, so they exercise the decision alone; the gitleaks section puts
# the real binary back.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/gitleaks"; chmod 755 "$STUBBIN/gitleaks"
REALPATH=$PATH
export PATH="$STUBBIN:$PATH"

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
expect ask   "the bypass does not lift rule 3" "$BARE" 'FORGE_GUARD=off glab api -X DELETE "projects/1"'

# reason <cwd> <command> -> the permissionDecisionReason, or nothing on allow
reason() {
  run "$1" "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}
# has_reason <label> <needle> <cwd> <command>
has_reason() {
  local label=$1 needle=$2 got
  got=$(reason "$3" "$4")
  case "$got" in
    *"$needle"*) pass=$((pass + 1)); printf '  ok   %s\n' "$label" ;;
    *) fail=$((fail + 1)); printf '  FAIL %s (reason lacks %s: %s)\n' "$label" "$needle" "$got" ;;
  esac
}

# ---------------------------------------------------------------- rule 4 fixtures
# Two bare remotes and a work repo whose origin/HEAD names main. The repo sits on a
# pushed feature branch; clone() copies it so a case can bend its config alone.
REMOTES="$TMP/remotes"; mkdir -p "$REMOTES"
git init -q --bare "$REMOTES/origin.git"
git init -q --bare "$REMOTES/backup.git"
BASE="$TMP/work"   # no "push" in the path: the fast path matches the raw payload
git init -q "$BASE"
git -C "$BASE" commit -q --allow-empty -m init
git -C "$BASE" remote add origin "$REMOTES/origin.git"
git -C "$BASE" push -q origin main 2>/dev/null
git -C "$BASE" remote set-head origin main
git -C "$BASE" switch -q -c feat
git -C "$BASE" commit -q --allow-empty -m feature
git -C "$BASE" push -q -u origin feat 2>/dev/null
git -C "$BASE" config alias.lp 'push origin main'
[ "$(git -C "$BASE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" = origin/main ] \
  || { echo "rule 4 fixture setup failed" >&2; exit 1; }
clone() { cp -R "$BASE" "$TMP/$1" && printf '%s' "$TMP/$1"; }
R=$BASE

echo "== rule 4: recognising a push =="
expect ask   "push to the default branch"             "$R"   'git push origin main'
expect ask   "git -C <repo> from another directory"   "$TMP" "git -C $R push origin main"
expect ask   "command git push"                       "$R"   'command git push origin main'
expect ask   "env X=1 git push"                       "$R"   'env X=1 git push origin main'
expect ask   "an assignment prefix"                   "$R"   'X=1 git push origin main'
expect ask   "sudo git push"                          "$R"   'sudo git push origin main'
expect ask   "a path to git"                          "$R"   '/usr/bin/git push origin main'
expect ask   "global options before push"             "$TMP" "git --no-pager -C $R push origin main"
expect ask   "FORGE_GUARD=off does not lift rule 4"   "$R"   'FORGE_GUARD=off git push origin main'
expect ask   "a global alias: pom = push origin main" "$R"   'git pom'
expect ask   "a repository-local alias"               "$R"   'git lp'
expect deny  "a push after another git command, on a later line" "$R" 'git status
git push origin main'
expect deny  "a push after another git command, after &&" "$R" 'git add -A && git push origin main'
expect ask   "a push with redirects and a pipe"       "$R"   'git push origin main 2>&1 | tail -5'
expect deny  "a push inside bash -c"                  "$R"   "bash -c 'git push origin main'"
expect ask   "a cd before the push is followed"       "$TMP" "cd $R && git push origin main"
# Only a plain command is judged; a push inside any compound command is a silent deny.
expect deny  "a push inside if/then"                  "$R"   'if true; then git push origin main; fi'
expect deny  "a push as an if condition"              "$R"   'if git push origin main; then echo ok; fi'
expect deny  "a push inside a while loop"             "$R"   'while false; do git push origin main; done'
expect deny  "a push inside a for loop"               "$R"   'for b in x; do git push origin main; done'
expect deny  "a push inside a { } group"              "$R"   '{ git push origin main; }'
expect deny  "a negated push"                         "$R"   '! git push origin main'
# Parentheses of any kind (a case arm, a subshell, a function body) are not modelled.
expect deny  "a push inside a case arm is denied"     "$R"   'case x in x) git push origin main;; esac'
# An alias defined only in the repository git selects is resolved THERE, not in the cwd:
# the fast path cannot list it, so any git command naming another repository goes on.
OTHER=$(clone other); git -C "$OTHER" config alias.lp2 'push origin main'
expect ask   "an alias local to the -C repository"    "$TMP" "git -C $OTHER lp2"
expect deny  "an alias in the --git-dir= repository is denied with it" "$TMP" "git --git-dir=$OTHER/.git lp2"
expect ask   "a -C path through a variable the hook can see" "$TMP" 'git -C "$GUARDTMP/work" push origin main'
expect deny  "an alias defined with -c on the command line" "$R" "git -c alias.zz='push origin main' zz"
expect deny  "an alias under a GIT_DIR override"      "$TMP" "GIT_DIR=$OTHER/.git git lp2"
# deny beats ask: a rule 4 ask must not swallow a rule 1 deny in the same command.
expect deny  "a rule 1 deny beats a rule 4 ask"       "$R"   'gh pr create --title x --body "Generated with Claude Code" && git push origin main'
# One git command per push: the scan runs before the call, so it cannot see a commit made
# earlier in it, and a switch changes the branch the push reads.
expect deny  "a switch chained to a push"             "$R"   'git switch main && git push'
expect deny  "a commit chained to a push"             "$R"   'git commit -am x && git push origin feat'
expect deny  "add, commit and push in one call"       "$R"   'git add -A && git commit -m x && git push -u origin feat'
expect deny  "two pushes in one call"                 "$R"   'git push origin feat; git push origin feat-2'
expect deny  "git inside a substitution next to a push" "$R" 'git push -o "$(git log -1 --format=%s)" origin feat'
expect allow "a lone push, the form to use"           "$R"   'git push -u origin feat'
# The grammar: the whole command is one plain push, optionally after one cd and piped
# only to tail or head. Everything else that could push is a silent deny.
expect deny  "a push inside a quoted substitution"    "$R"   'echo "$(git push origin main)"'
expect deny  "env with an option, such as -C"         "$R"   "env -C $OTHER git push origin HEAD"
expect allow "a push piped to tail"                   "$R"   'git push -u origin feat 2>&1 | tail -5'
expect allow "a push piped to head -n"                "$R"   'git push -u origin feat | head -n 3'
expect allow "a leading cd, then a push"              "$TMP" "cd $R && git push -u origin feat"
expect deny  "a push followed by another command"     "$R"   'git push origin feat && echo done'
expect deny  "a push piped to anything but tail/head" "$R"   'git push origin feat | tee log'
expect deny  "a push redirected to a file"            "$R"   'git push origin feat > push.log'
expect allow "a plain git command that does not push" "$R"  'git log --oneline -3 | head -n 3'
# Shells and evaluators run their arguments as code; the guard never reads those.
expect deny  "bash -lc with a push"                   "$R"   "bash -lc 'git push origin main'"
expect deny  "sh -c with a push"                      "$R"   'sh -c "git push"'
expect deny  "eval with a push"                       "$R"   'eval "git push origin main"'
expect deny  "time in front of a push"                "$R"   'time git push origin feat'
expect deny  "xargs running a push"                   "$R"   'echo feat | xargs git push origin'
expect deny  "ssh running a push"                     "$R"   "ssh host 'git push origin main'"
expect deny  "a shell running a push alias"           "$R"   "bash -c 'git pom'"
expect allow "a shell running a push that is not git" "$R"   "bash -c 'docker push registry/x'"
expect allow "a shell running git that cannot push"   "$R"   "bash -c 'git status'"
expect deny  "a shell alias that pushes"              "$R"   'git shp'
expect allow "an alias that does not push"           "$R"   'git st'
# Text that holds git and push outside a plain push is denied too: the guard reads no
# shape but the plain one, so it cannot tell a mention from a call.
expect deny  "echo mentioning a push"                 "$R"   'echo "git push origin main"'
expect deny  "rg for the text"                        "$R"   'rg "git push origin main" docs/'
expect allow "rg for the text, with git and push kept apart" "$R" "rg 'git pu[s]h origin main' docs/"
expect allow "a commit message about pushing"         "$R"   'git commit --allow-empty -m "push to main later"'
# Here-documents are not modelled: any << next to something push-shaped is denied, even
# a body that only mentions one. Quote-aware heredoc parsing is deliberately not attempted.
expect deny  "a heredoc body naming a push is denied" "$R"   "cat > $TMP/notes.md <<'EOF'
Then run git push origin main, it's done.
EOF"
expect deny  "quoted heredoc-looking text before a push" "$R" 'printf "<<EOF"
git push origin main'
expect deny  "a commit heredoc chained to a push"     "$R"   "git commit --allow-empty -F - <<'EOF'
msg
EOF
git push origin feat"
expect allow "a heredoc with no push in it"           "$R"   "cat > $TMP/notes.md <<'EOF'
nothing to see
EOF"
# Comments are not in the grammar: any token that begins with # puts the command outside
# it, and could_push reads the raw text, comments included (a superset, never trimmed). bash
# drops a comment, so a trailing one could fake an option the push never gets.
expect deny  "a comment line naming a push"           "$R"   '# git push origin main
git status'
expect deny  "a comment that fakes --dry-run"         "$R"   'git push origin main # --dry-run'
expect deny  "a push with a trailing comment"         "$R"   'git push -u origin feat # note'
expect deny  "a non-push git command with a comment that says push" "$R" 'git status # push later'
# A # inside nested quotes is not a comment to bash, and the push after it runs.
expect deny  "a push after a quoted # inside a substitution" "$R" 'echo "$(echo " # note"; git push origin main)"'
# A quoted token that begins with # is rejected too: a false deny the grammar accepts.
expect deny  "a quoted token starting with # is outside the grammar" "$R" "git push -o '#1' origin feat"
expect allow "a quoted # inside a push option"        "$R"   "git push --push-option='ci.skip#1' origin feat"
expect allow "a # inside a word is not a comment"     "$R"   'git push -o ci.skip#1 origin feat'
expect allow "a word containing push, no git"         "$R"   'ls pushed/'

echo "== rule 4: pushes that ask =="
expect ask   "HEAD:main"                              "$R" 'git push origin HEAD:main'
expect ask   "refs/heads/main as the destination"     "$R" 'git push origin feat:refs/heads/main'
expect ask   "a lease on the default branch"          "$R" 'git push --force-with-lease origin main'
expect ask   "a + refspec"                            "$R" 'git push origin +feat'
expect ask   "--force on a feature branch"            "$R" 'git push --force origin feat'
expect ask   "-f bundled as -fu"                      "$R" 'git push -fu origin feat'
expect ask   "a :ref refspec"                         "$R" 'git push origin :old'
expect ask   "--delete"                               "$R" 'git push --delete origin old'
expect ask   "-d"                                     "$R" 'git push -d origin old'
expect ask   "--prune"                                "$R" 'git push --prune origin feat'
expect ask   "--mirror"                               "$R" 'git push --mirror origin'
expect ask   "--all"                                  "$R" 'git push --all origin'
ONMAIN=$(clone onmain); git -C "$ONMAIN" switch -q main
expect ask   "a bare push while on main"              "$ONMAIN" 'git push'
expect ask   "push <remote> while on main"            "$ONMAIN" 'git push origin'
expect ask   "push HEAD while on main"                "$ONMAIN" 'git push origin HEAD'
has_reason   "the ask names the default branch" "main, the default branch of origin" "$R" 'git push origin main'
TRUNK=$(clone trunk); git -C "$TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
expect ask   "the default branch comes from origin/HEAD" "$TRUNK" 'git push origin trunk'
expect allow "main is not special when HEAD names trunk" "$TRUNK" 'git push origin main'
NOHEAD=$(clone nohead); git -C "$NOHEAD" remote set-head origin -d
expect ask   "no origin/HEAD falls back to main"      "$NOHEAD" 'git push origin main'

echo "== rule 4: pushes that go ahead silently =="
expect allow "a feature branch"                       "$R" 'git push origin feat'
expect allow "-u on a feature branch"                 "$R" 'git push -u origin feat'
expect allow "a bare push on a feature branch"        "$R" 'git push'
expect allow "HEAD on a feature branch"               "$R" 'git push origin HEAD'
expect allow "a lease on a feature branch"            "$R" 'git push --force-with-lease origin feat'
expect allow "lease and if-includes on a feature branch" "$R" 'git push --force-with-lease --force-if-includes origin feat'
expect allow "--tags"                                 "$R" 'git push --tags origin'
expect allow "--dry-run to main"                      "$R" 'git push --dry-run origin main'
expect allow "-n to main"                             "$R" 'git push -n origin main'
expect allow "a new branch name"                      "$R" 'git push origin HEAD:feat-2'
expect allow "a push option on a feature branch"      "$R" 'git push -o ci.skip origin feat'
# git push options come from an allowlist; anything else is a silent deny naming it. A
# negation is the reason: --no-dry-run after --dry-run makes the dry run a real push.
expect deny  "a dry run negated later"                "$R" 'git push --dry-run --no-dry-run origin main'
expect deny  "--no-dry-run alone"                     "$R" 'git push --no-dry-run origin main'
has_reason   "the deny names the option" "the push option --no-dry-run" "$R" 'git push --no-dry-run origin main'
expect deny  "an unknown push option"                 "$R" 'git push --frobnicate origin feat'
expect deny  "an unknown short push option"           "$R" 'git push -x origin feat'
expect deny  "--repo, which is not modelled"          "$R" 'git push --repo=origin feat'
expect deny  "an option after --"                     "$R" 'git push origin -- --force'
has_reason   "--repo is denied as an option, by name" "the push option --repo=origin" "$R" 'git push --repo=origin feat'
has_reason   "-- is denied as a separator, by name"   "the -- separator" "$R" 'git push origin -- --force'
expect allow "--no-verify on a feature push"          "$R" 'git push --no-verify origin feat'
for o in -u --set-upstream -q --quiet -v --verbose --progress --porcelain --atomic \
         --force-with-lease --force-with-lease=feat --force-if-includes --follow-tags \
         -n --dry-run --push-option=ci.skip -oci.skip -uq; do
  expect allow "allowlisted, silent on a feature branch: $o" "$R" "git push $o origin feat"
done
expect allow "allowlisted, silent on a feature branch: --push-option <value>" "$R" 'git push --push-option ci.skip origin feat'
mkdir -p "$R/sub/dir"
expect allow "a push from a subdirectory"             "$R/sub/dir" 'git push origin feat'
expect ask   "a push to main from a subdirectory"     "$R/sub/dir" 'git push origin main'

echo "== rule 4: unsupported configuration is denied, never asked =="
u=0
unsupported() { # unsupported <label> <git config args...>
  local label=$1 d; shift
  u=$((u + 1)); d=$(clone "unsupported-$u")
  git -C "$d" config "$@"
  expect deny "$label" "$d" 'git push origin feat'
}
unsupported "remote.pushDefault"        remote.pushDefault origin
unsupported "branch.<b>.pushRemote"     branch.feat.pushRemote origin
unsupported "remote.<r>.push"           remote.origin.push 'refs/heads/*:refs/heads/*'
unsupported "remote.<r>.mirror"         remote.origin.mirror true
unsupported "push.default=upstream"     push.default upstream
unsupported "push.default=matching"     push.default matching
unsupported "a pushurl"                 remote.origin.pushurl "$REMOTES/backup.git"
unsupported "pushInsteadOf"             url."$REMOTES/backup.git".pushInsteadOf "$REMOTES/origin.git"
SECOND=$(clone second-url); git -C "$SECOND" config --add remote.origin.url "$REMOTES/backup.git"
expect deny  "a second url"                           "$SECOND" 'git push origin feat'
expect deny  "-c on the push invocation"              "$R" 'git -c push.default=current push origin feat'
expect deny  "GIT_DIR on the push invocation"         "$R" "GIT_DIR=$R/.git git push origin feat"
expect deny  "a push to a URL, not a remote"          "$R" "git push $REMOTES/origin.git feat"
expect deny  "an unknown remote"                      "$R" 'git push nosuch feat'
DETACHED=$(clone detached); git -C "$DETACHED" switch -q --detach
expect deny  "a bare push on a detached HEAD"         "$DETACHED" 'git push'
expect deny  "an unresolvable cd before the push"     "$R" 'cd "$NO_SUCH_DIR_VAR" && git push origin feat'
# Only one leading, top-level cd <literal path> is modelled; any other directory change or
# subshell around a push is denied. The first case is the one Codex found: the cd runs in
# a subshell, and the push runs from where the command started.
expect deny  "a cd inside a subshell before the push" "$R"   "(cd $OTHER; git status); git push origin HEAD"
expect allow "a leading cd <path>; is followed"       "$TMP" "cd $R; git push origin feat"
expect deny  "a second cd before the push"            "$TMP" "cd $R && cd sub && git push origin feat"
expect deny  "a cd after the push"                    "$R"   'git push origin feat; cd /tmp'
expect deny  "a pushd before the push"                "$TMP" "pushd $R && git push origin feat"
expect deny  "a cd inside an if before the push"      "$TMP" "if cd $R; then git push origin feat; fi"
expect deny  "an unquoted substitution"               "$R"   'git push origin $(git branch --show-current)'
# git rejects attached global options itself; the guard denies them rather than parse them.
expect deny  "an attached -c<k=v> option on a push"   "$R"   'git -cremote.origin.url=/x push origin feat'
expect deny  "an attached -C<path> option on a push"  "$R"   'git -C/other push origin feat'
expect deny  "an unrecognised git option on a push"   "$R"   'git --frobnicate push origin feat'
# Only -C selects a repository the scan can follow; --git-dir and --work-tree cannot.
expect deny  "--git-dir on a push"                    "$TMP" "git --git-dir=$OTHER/.git push origin feat"
expect deny  "--work-tree on a push"                  "$R"   "git --work-tree=$R push origin feat"
# `:` and `+:` push every matching branch; they are not deletions.
expect deny  "the matching refspec :"                 "$R"   'git push origin :'
expect deny  "the forced matching refspec +:"         "$R"   'git push origin +:'
expect deny  "a --config-env= option on the push"     "$R" 'git --config-env=core.pager=PAGER push origin feat'
# A wildcard names no branch and no commits to scan, so it cannot be asked about safely.
expect deny  "a wildcard refspec"                     "$R" "git push origin 'refs/heads/*:refs/heads/*'"
# Values only the shell knows: the guard would judge the literal text, not the branch.
expect deny  "a refspec in a shell variable"          "$R" 'B=main; git push origin $B'
expect deny  "a remote in a shell variable"           "$R" 'git push "$REMOTE" feat'
expect deny  "a refspec in backticks"                 "$R" 'git push origin `git branch --show-current`'
expect allow "the current branch by substitution"     "$R" 'git push -u origin "$(git branch --show-current)"'
expect ask   "the current branch by substitution, on main" "$ONMAIN" 'git push origin "$(git branch --show-current)"'
# The shell runs the substitution where it is, not where -C or a cd points the push.
expect deny  "a current-branch substitution under -C" "$TMP" "git -C $OTHER push origin \"\$(git branch --show-current)\""
expect deny  "a current-branch substitution after a leading cd" "$TMP" "cd $R && git push origin \"\$(git branch --show-current)\""
MATCHING=$(clone matching); git -C "$MATCHING" config push.default matching
has_reason   "the deny names the key" \
  "unsupported push configuration for the push guard: push.default=matching" "$MATCHING" 'git push origin feat'
expect allow "a dry run is never refused"             "$MATCHING" 'git push --dry-run origin main'
expect deny  "unbalanced quotes around a push"        "$R" 'git push origin "feat'

echo "== rule 4: ways a push to the default branch could hide =="
# git resolves a destination such as heads/main to refs/heads/main, so the guard reads only
# refs/heads/<name> and a plain name; a name with a slash (feat/x) is still a branch name.
expect deny  "a DWIM destination: feat:heads/main"    "$R" 'git push origin feat:heads/main'
expect deny  "a bare DWIM refspec: heads/main"        "$R" 'git push origin heads/main'
expect deny  "a tags/ destination"                    "$R" 'git push origin feat:tags/v1'
expect deny  "a remotes/ destination"                 "$R" 'git push origin feat:remotes/origin/main'
expect deny  "a refs/tags/ destination"               "$R" 'git push origin HEAD:refs/tags/v1'
has_reason   "the DWIM deny names the destination" "the destination heads/main" "$R" 'git push origin feat:heads/main'
expect ask   "HEAD:refs/heads/main still asks"        "$R" 'git push origin HEAD:refs/heads/main'
expect allow "a destination with a slash is a branch" "$R" 'git push origin HEAD:feat/x'
expect allow "a source with a slash is a branch"      "$R" 'git push origin feat/x:feat/x'
# The shell rewrites braces, globs and variables before git sees the words.
expect deny  "a brace list of refspecs"               "$R" 'git push origin {feat,main}'
expect deny  "a brace list inside a destination"      "$R" 'git push origin HEAD:{main,}'
expect deny  "a ? glob in a refspec"                  "$R" 'git push origin mai?'
expect deny  "a [ ] glob in a refspec"                "$R" 'git push origin [m]ain'
expect deny  "a brace list in the remote"             "$R" 'git push or{i,i}gin feat'
expect deny  "a glob in the remote"                   "$R" 'git push orig?n feat'
# A subcommand or option the shell computes can be any command.
expect deny  "the subcommand from a variable default" "$R" 'git ${X:-push} origin main'
expect deny  "a variable as the subcommand"           "$R" 'X=push; git $X origin main'
expect deny  "a computed subcommand, no push in the git text" "$R" 'git ${X:-pu}sh origin main
echo push'
expect deny  "a computed option word"                 "$R" 'git ${X:--C} . push origin feat'
expect deny  "a brace list as the subcommand"         "$R" 'git {push,pull} origin feat'
expect ask   "a -C value through a variable still resolves" "$TMP" 'git -C "$GUARDTMP/work" push origin main'
# Commands that push without being git push.
expect deny  "git subtree push"                       "$R" 'git subtree push --prefix=d origin main'
expect deny  "git http-push"                          "$R" 'git http-push origin main'
expect deny  "a non-builtin subcommand given push"    "$R" 'git lfs push origin feat'
expect allow "git subtree split does not push"        "$R" 'git subtree split --prefix=d'
expect deny  "git send-pack, through the full guard"  "$R" "git send-pack $REMOTES/origin.git main"
# Builtins that run a command string: the string is never read, so one that pushes is refused.
expect deny  "submodule foreach running a push"       "$R" "git submodule foreach 'git push origin main'"
expect deny  "rebase --exec running a push"           "$R" "git rebase --exec 'git push origin main' main"
expect deny  "rebase -x running a push"               "$R" "git rebase -x 'git push origin main' main"
expect deny  "bisect run running a push"              "$R" 'git bisect run git push origin main'
expect deny  "filter-branch running a push"           "$R" "git filter-branch --tree-filter 'git push origin main' HEAD"
expect allow "submodule foreach that does not push"   "$R" "git submodule foreach 'git status'"
expect allow "a commit message that mentions a push"  "$R" 'git commit -m "git push later"'
# A push word assembled by expansion has no literal push in the payload, so the shell fast
# path never starts the helper; that is a known limit. Driven directly, the helper denies it.
helper_denies() { # helper_denies <label> <cwd> <command>
  local out
  out=$(jq -n --arg c "$3" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | /usr/bin/python3 "$(dirname "$GUARD")/git-push-guard.py")
  case "$out" in
    *'"permissionDecision":"deny"'*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    *) fail=$((fail + 1)); printf '  FAIL %s (helper said: %s)\n' "$1" "$out" ;;
  esac
}
helper_denies "git send-pack, straight to the helper"  "$R" "git send-pack $REMOTES/origin.git main"
helper_denies "a computed subcommand, straight to the helper" "$R" 'git ${X:-pu}sh origin main'

echo "== rule 4: commands that name git without running it =="
# git counts only in command position: as an argument it is just a word.
expect allow "rg for git with a glob argument"        "$TMP" "cd $R && rg git -g '*.sh'"
expect allow "rg -l git -C 3 *.md"                    "$R"   'rg -l git -C 3 *.md'
expect allow "grep -l git *.md"                       "$TMP" "cd $R && grep -l git *.md"
expect allow "a -c alias with braces in a quoted value" "$R" "git -c 'alias.x=!f() { git status; }; f' x"

echo "== rule 4: expansion in option values, the git word, the dash form =="
expect deny  "-o with a brace list"                   "$R" 'git push -o {x,origin,main}'
expect deny  "--push-option with a brace list"        "$R" 'git push --push-option {x,origin,main}'
expect deny  "-u -o with a brace list"                "$R" 'git push -u -o {x,origin,main}'
expect deny  "a ? glob in the git word"               "$R" '/usr/bin/gi? push origin main'
expect deny  "a [ ] glob in the git word"             "$R" '/usr/bin/g[i]t push origin main'
# Only the last path component of a command word decides: a variable or a $VAR/ directory
# in front of a name that is not git is an ordinary command (docker, helm, gradle).
expect allow "a variable command that pushes, not git" "$R" '$DOCKER push registry/x:1'
expect allow "a quoted \$HOME path to helm push"      "$R" '"$HOME/bin/helm" push chart.tgz oci://r'
expect allow "a variable command after &&"            "$R" 'npm run build && $DOCKER push img'
expect allow "a quoted \$GOPATH path, -l ."           "$TMP" "cd $R && \"\$GOPATH/bin/gofumpt\" -l ."
expect allow "a \$HOME path to gradle, -c"            "$R" '$HOME/.local/bin/gradle build -c settings.gradle'
expect allow "a variable command with no push word"   "$R" '$G status'
# Reserved words leave the next word in command position.
expect deny  "a glob git word after then"             "$R" 'if true; then /usr/bin/g[i]t push origin main; fi'
expect deny  "git-send-pack inside a { } group"       "$R" "{ /usr/libexec/git-core/git-send-pack $REMOTES/origin.git main; }"
expect allow "an if around a git command that does not push" "$R" 'if git diff --quiet; then echo same; fi'
expect deny  "git-send-pack behind exec-path"         "$R" "\$(git --exec-path)/git-send-pack $REMOTES/origin.git main"
expect deny  "git-send-pack by path"                  "$R" "/opt/homebrew/opt/git/libexec/git-core/git-send-pack $REMOTES/origin.git main"
expect deny  "git-push, the dash form"                "$R" 'git-push origin main'
expect deny  "git-http-push by path"                  "$R" '/usr/libexec/git-core/git-http-push origin main'
# rebase --exec, however it is spelled
expect deny  "rebase -ix running a push"              "$R" "git rebase -ix 'git push origin main' main"
expect deny  "rebase --exe running a push"            "$R" "git rebase --exe 'git push origin main' main"
expect deny  "rebase --ex= running a push"            "$R" "git rebase --ex='git push origin main' main"
expect allow "rebase --autosquash is not --exec"      "$R" 'git rebase -i --autosquash main'

echo "== rule 4: aliases that expand to pushing commands =="
ALIASES=$(clone aliases)
git -C "$ALIASES" config alias.sp send-pack
git -C "$ALIASES" config alias.sf 'submodule foreach git push origin main'
git -C "$ALIASES" config alias.rbx 'rebase -x "git push origin main"'
expect deny  "an alias to send-pack"                  "$ALIASES" "git sp $REMOTES/origin.git main"
expect deny  "an alias to submodule foreach push"     "$ALIASES" 'git sf'
expect deny  "an alias to rebase -x push"             "$ALIASES" 'git rbx main'
expect allow "an alias to status is silent"           "$ALIASES" 'git st'
# A shell alias that runs send-pack is a push too.
git -C "$ALIASES" config alias.shsp2 '!f() { git send-pack "$@"; }; f'
expect deny  "a shell alias running send-pack"        "$ALIASES" "git shsp2 $REMOTES/origin.git main"
# An alias to submodule is not a push alias: it must not turn ordinary commands into denies.
git -C "$ALIASES" config alias.sub submodule
expect allow "a commit message naming an alias"       "$ALIASES" 'git add -A && git commit -m "fix sub parser"'
expect allow "an alias to submodule, chained"         "$ALIASES" 'git fetch && git sub update --init'
expect deny  "an alias to submodule foreach that pushes" "$ALIASES" 'git sub foreach git push origin main'

echo "== rule 4: a slow helper is a deny, never a pass =="
# Claude Code lets a hook that outruns its timeout through, so the helper gives up first.
# PUSH_GUARD_BUDGET shortens its total budget for these cases only.
SLOWBIN="$TMP/slowbin"; mkdir -p "$SLOWBIN"
printf '#!/bin/sh\nsleep 1\nPATH="%s"; export PATH\nexec git "$@"\n' "$REALPATH" > "$SLOWBIN/git"
chmod 755 "$SLOWBIN/git"
export PUSH_GUARD_BUDGET=0
expect deny  "an exhausted budget is a deny"          "$R" 'git push origin feat'
has_reason   "the timeout deny says to retry" "timed out" "$R" 'git push origin feat'
export PUSH_GUARD_BUDGET=0.3
SAVED_PATH=$PATH; export PATH="$SLOWBIN:$PATH"
expect deny  "a git call slower than the budget is a deny" "$R" 'git push origin feat'
export PATH=$SAVED_PATH
unset PUSH_GUARD_BUDGET
expect allow "with the default budget the same push goes ahead" "$R" 'git push origin feat'

echo "== rule 4 costs nothing on commands that do not push =="
# The helper is where the time goes (python plus a dozen git calls). A tripwire helper
# records every run, so a plain command that cannot push must never reach it. A git command
# that names another repository does reach it, by design: only the helper can read the
# aliases defined there.
TRIP="$TMP/tripwire"; mkdir -p "$TRIP"
cp "$GUARD" "$TRIP/git-forge-guard.sh"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$TRIP/git-push-guard.py"
SAVED_GUARD=$GUARD; GUARD="$TRIP/git-forge-guard.sh"
for c in 'ls -la' 'git status' 'git log --oneline -5' 'git st' 'npm test'; do
  run "$R" "$c" >/dev/null
done
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "commands that cannot push never run the helper"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "commands that cannot push never run the helper"
fi
run "$R" 'git pom' >/dev/null
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "an alias that pushes does run it"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "an alias that pushes does run it"
fi
rm -f "$TRIP/git-push-guard.py.ran"
run "$TMP" "git -C $R status" >/dev/null
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a git -C command runs it: its aliases live in that repository"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "a git -C command runs it: its aliases live in that repository"
fi
GUARD=$SAVED_GUARD

echo "== rule 4 fails closed when its helper is missing =="
NOHELPER="$TMP/nohelper"; mkdir -p "$NOHELPER"
cp "$GUARD" "$NOHELPER/git-forge-guard.sh"
SAVED_GUARD=$GUARD; GUARD="$NOHELPER/git-forge-guard.sh"
expect deny  "a push with no helper is refused"       "$R" 'git push origin feat'
expect allow "a non-push command is untouched"        "$R" 'echo push'
expect allow "git status is untouched"                "$R" 'git status'
# The fallback denies on the evidence the fast path used, aliases included.
expect deny  "an alias push with no helper is refused" "$R" 'git pom'
# Fail closed: with no helper, the aliases of a -C repository cannot be checked.
expect deny  "a git -C command with no helper is refused" "$TMP" "git -C $R status"
# The fallback cannot read quotes, so it cannot tell a comment from code: it fails closed.
expect deny  "a commented git command with no helper is refused" "$R" 'git status # push later'
GUARD=$SAVED_GUARD

echo "== the helper deploys beside the guard =="
# The guard looks for git-push-guard.py next to itself. A helper chezmoi never deploys
# would leave rule 4 denying every push. .chezmoiignore is an allowlist for ~/.claude.
if command -v chezmoi >/dev/null 2>&1 \
   && chezmoi --source "$SRC" managed 2>/dev/null | grep -qx '.claude/git-push-guard.py'; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git-push-guard.py is chezmoi-managed"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git-push-guard.py is chezmoi-managed"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

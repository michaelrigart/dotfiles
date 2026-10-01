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
[format]
	pretty = format:%h %s
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

echo "== the deny texts =="
# FORGE_GUARD=off is Michael's to grant: the template deny names it only for that case. The
# rules live in the "Merge requests" section of GLOBAL.md, and the deny says so.
has_reason "the template deny offers FORGE_GUARD=off only when Michael asked" \
           "Only if Michael has asked, in this" "$HEADS" 'glab mr create -t "Fix" --description "Just some prose."'
has_reason "the attribution deny names the Merge requests section" \
           '"Merge requests" section of' "$BARE" "git commit -F $ATTRIB_MSG"

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
# Text that holds git and push outside a plain push is denied too, unless it sits in the
# arguments of a command that never runs them (echo, rg, cat, git commit, ...): the guard
# reads no shape but the plain one, so any other command may run what it is given.
expect allow "echo mentioning a push"                 "$R"   'echo "git push origin main"'
expect allow "rg for the text"                        "$R"   'rg "git push origin main" docs/'
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
expect allow "a quoted # inside a push option"        "$R"   "git push --push-option='ci.variable=A#1' origin feat"
expect allow "a # inside a word is not a comment"     "$R"   'git push -o ci.variable=A#1 origin feat'
expect allow "a word containing push, no git"         "$R"   'ls pushed/'

echo "== rule 4: text in the arguments of an inert command is data =="
# Outside the plain grammar the guard reads the command text, but the arguments of a tool
# that never runs them (a commit message, a file name, a search pattern) are not counted.
expect allow "a commit message mentioning a push, after add" "$R" 'git add f && git commit -m "Set autoSetupRemote so a first push needs no -u"'
expect allow "a commit message saying push, then echo" "$R"   'git commit -m "push docs"; echo done'
expect allow "rg over the guard file"                 "$R"   'rg -n x dot_claude/git-push-guard.py'
expect allow "rg over the guard file, quoted pattern" "$R"   "rg -n 'x' dot_claude/git-push-guard.py"
expect allow "wc over the guard file"                 "$R"   'wc -l dot_claude/git-push-guard.py tests/x.test.sh'
expect allow "git log piped to rg push"               "$R"   'git log --oneline | rg push'
expect allow "cat piped to grep for git push"         "$R"   'cat notes | grep "git push"'
expect allow "an inert git command redirected to /dev/null" "$R" 'git log --grep "git push" 2>/dev/null | wc -l'
expect allow "add, status, then a commit message about a push" "$R" 'git add f && git status && git commit -m "push later"'
expect allow "switch -c, then a commit message about push defaults" "$R" 'git switch -c x && git commit -m "explain push defaults"'
# Only an explicit set of git subcommands is inert; difftool, clone and friends run words.
expect deny  "difftool -x running a push"             "$R"   "git add f && git difftool -x 'git push origin main' HEAD"
expect deny  "difftool --extcmd running a push"       "$R"   "git add f && git difftool --extcmd='git push' HEAD"
expect deny  "clone --template, which is not inert"   "$R"   "rg x && git clone --template=/tmp/t 'git push' y"
expect deny  "mergetool, then a push of its own"      "$R"   'git add f && git mergetool --tool-help; git push origin main'
# Whatever can run text keeps counting it.
expect deny  "add, then a push"                       "$R"   'git add f && git push origin main'
expect deny  "true, then a push"                      "$R"   'true; git push origin main'
expect deny  "xargs running a push"                   "$R"   'echo origin | xargs git push'
expect deny  "sh -c with a push, in a chain"          "$R"   'rg x && sh -c "git push origin main"'
expect deny  "bash -c with a push"                    "$R"   "bash -c 'git push'"
expect deny  "eval with a push, in a chain"           "$R"   'ls && eval "git push origin main"'
expect deny  "a push in a substitution in a message"  "$R"   'git commit -m "$(git push origin main)"'
expect deny  "a push in backticks in a message"       "$R"   'git commit -m "`git push`"'
expect deny  "find -exec running a push"              "$R"   'find . -name x -exec git push \;'
expect deny  "awk calling system on a push"           "$R"   "awk 'BEGIN{system(\"git push\")}'"
expect deny  "rebase --exec pushing, after add"       "$R"   'git add f && git rebase --exec "git push" main'
expect deny  "submodule foreach pushing, after add"   "$R"   'git add f && git submodule foreach "git push"'
expect deny  "a heredoc into sh"                      "$R"   'cat <<EOF | sh
git push
EOF'
expect deny  "env git push, then true"                "$R"   'env git push origin main && true'
expect deny  "command git push, then true"            "$R"   'command git push origin main; true'
expect deny  "a -c alias push after rg"               "$R"   'rg x && git -c alias.y=push y origin main'
# Data fed to something that runs it, or written for a later command to run.
expect deny  "echo piped to sh"                       "$R"   'echo "git push origin main" | sh'
expect deny  "printf piped through cat to bash"       "$R"   "printf 'git push' | cat | bash"
expect deny  "echo into a file that sh then runs"     "$R"   'echo "git push origin main" > x.sh && sh x.sh'
expect deny  "printf -v into a variable that eval runs" "$R" "printf -v c 'git push origin main'; eval \"\$c\""
expect deny  "rg --pre running a push"                "$R"   "rg --pre 'git push' x docs/"
expect deny  "fd --exec running a push"               "$R"   'fd -x git push'
expect deny  "git config planting a push alias"       "$R"   "git config alias.p '!git push origin main' && git p"
expect deny  "git -c core.pager running a push"       "$R"   "git -c core.pager='git push' log | wc -l"
expect deny  "a comment after an inert command"       "$R"   'git status # git push'
expect deny  "ANSI-C quoting hiding a push"           "$R"   "echo \$'\\'' ; git push origin main ; echo \$'\\''"

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
git -C "$TRUNK" branch trunk
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

echo "== rule 4: push option values =="
# GitLab reads push options, and merge_request.* opens or auto-merges an MR from the push,
# past the pre-merge review gate on glab mr create. Only ci.skip, ci.variable=... and
# integrations.skip_ci go through; every other value is a silent deny, in every spelling.
for o in "-o merge_request.create" "-o merge_request.merge_when_pipeline_succeeds" \
         "-o merge_request.auto_merge" "--push-option=merge_request.create" \
         "--push-option merge_request.target=main" "-omerge_request.create" \
         "-uo merge_request.create" "-uomerge_request.create" \
         "-o ci.skip -o merge_request.create" "-o secret_push_protection.skip_all" \
         "-o ''" "-o ci.skip=1"; do
  expect deny  "push option refused: $o"              "$R" "git push $o origin feat"
done
expect deny  "a trailing -o with no value"            "$R" 'git push origin feat -o'
has_reason   "the deny names the option" "the push option merge_request.create" "$R" 'git push -o merge_request.create origin feat'
has_reason   "and points to a draft MR" "open MRs with glab mr create --draft" "$R" 'git push -o merge_request.create origin feat'
for o in "-o ci.skip" "-o integrations.skip_ci" "-o ci.variable=DEPLOY=1" \
         "--push-option=ci.variable=A=b" "-o ci.skip -o ci.variable=X=1" "-uoci.skip"; do
  expect allow "push option allowed: $o"              "$R" "git push $o origin feat"
done
# push.pushOption sends its values on every push that names none.
POCFG=$(clone push-option-config); git -C "$POCFG" config push.pushOption merge_request.create
expect deny  "push.pushOption set to merge_request.create" "$POCFG" 'git push origin feat'
has_reason   "and the deny says where it came from" "(from push.pushOption)" "$POCFG" 'git push origin feat'
POOK=$(clone push-option-ok); git -C "$POOK" config push.pushOption ci.skip
expect allow "push.pushOption set to ci.skip"         "$POOK" 'git push origin feat'
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
# A push that recurses into submodules also pushes their unpublished commits, which the
# scan never sees: it reads only the gitlink. git reads push.recurseSubmodules and
# submodule.recurse in config order and the last one decides.
unsupported "push.recurseSubmodules=on-demand" push.recurseSubmodules on-demand
unsupported "push.recurseSubmodules=only"      push.recurseSubmodules only
unsupported "submodule.recurse=true"           submodule.recurse true
RSDEMAND=$(clone recurse-on-demand); git -C "$RSDEMAND" config push.recurseSubmodules on-demand
has_reason   "the deny names the key and value" \
             "push.recurseSubmodules=on-demand, which also pushes submodule commits" "$RSDEMAND" 'git push origin feat'
RSCHECK=$(clone recurse-check); git -C "$RSCHECK" config push.recurseSubmodules check
expect allow "push.recurseSubmodules=check is evaluated normally" "$RSCHECK" 'git push origin feat'
expect ask   "and a push to main under it still asks" "$RSCHECK" 'git push origin main'
RSLATE=$(clone recurse-check-then-true)
git -C "$RSLATE" config push.recurseSubmodules check; git -C "$RSLATE" config submodule.recurse true
expect deny  "check, then submodule.recurse=true: git recurses" "$RSLATE" 'git push origin feat'
has_reason   "and the deny names submodule.recurse" \
             "submodule.recurse=true, which also pushes submodule commits" "$RSLATE" 'git push origin feat'
RSEARLY=$(clone recurse-true-then-check)
git -C "$RSEARLY" config submodule.recurse true; git -C "$RSEARLY" config push.recurseSubmodules check
expect allow "submodule.recurse=true, then check: evaluated normally" "$RSEARLY" 'git push origin feat'
RSOFF=$(clone recurse-false); git -C "$RSOFF" config submodule.recurse false
expect allow "submodule.recurse=false"                "$RSOFF" 'git push origin feat'
cp "$GIT_CONFIG_GLOBAL" "$TMP/gitconfig-recurse"; printf '[submodule]\n\trecurse = true\n' >> "$TMP/gitconfig-recurse"
GIT_CONFIG_GLOBAL="$TMP/gitconfig-recurse" expect deny "submodule.recurse=true in the global config" "$R" 'git push origin feat'
expect deny  "--recurse-submodules=on-demand on the push" "$R" 'git push --recurse-submodules=on-demand origin feat'
expect deny  "--recurse-submodules=only on the push"  "$R" 'git push --recurse-submodules=only origin feat'
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
# The scan lists the commits of every source, so a source must name a ref that exists.
SLASH=$(clone slash); git -C "$SLASH" branch topic/x
expect allow "a source with a slash is a branch"      "$SLASH" 'git push origin topic/x:topic/x'
# The shell rewrites braces, globs and variables before git sees the words.
expect deny  "a brace list of refspecs"               "$R" 'git push origin {feat,main}'
expect deny  "a brace list inside a destination"      "$R" 'git push origin HEAD:{main,}'
expect deny  "a ? glob in a refspec"                  "$R" 'git push origin mai?'
expect deny  "a [ ] glob in a refspec"                "$R" 'git push origin [m]ain'
expect deny  "a brace list in the remote"             "$R" 'git push or{i,i}gin feat'
expect deny  "a glob in the remote"                   "$R" 'git push orig?n feat'
# parse_push refuses every push word the shell rewrites, so nothing later checks for them
# again. What still gets through reaches git as written, and git refuses it: a * in the
# remote (no remote name can hold one) and a quoted refspec holding a space.
expect deny  "a * glob in the remote"                 "$R" 'git push orig* feat'
expect deny  "the current-branch form as the remote"  "$R" 'git push "$(git branch --show-current)" feat'
expect deny  "a quoted refspec holding a space and a brace" "$R" "git push origin 'fe at{x}'"
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
# A pattern in command position is not a command: the *) of a case arm after ;; or a
# newline, or a markdown bullet (* item) in a here-document. A glob with no literal in it
# spells no command name, and a case pattern such as g*) or g*|*git*) runs nothing.
expect allow "a *) case arm in a loop, then docker push" "$R" 'for f in a b; do case $f in a) t=1;; *) t=2;; esac; docker push reg/$f:$t; done'
expect allow "a *) case arm, then docker push"        "$R" 'case "$x" in a) echo a;; *) echo other;; esac; docker push img'
expect allow "a multi-line case with a push comment"  "$R" 'case "$1" in
  build) make build;;
  *) npm publish;;
esac # push'
expect allow "case patterns that match git: g*|*git*)" "$R" 'case "$u" in a) ;; g*|*git*) echo vcs;; esac; docker push img'
expect allow "an empty case arm: g*);;"               "$R" 'case "$u" in a) ;; g*);; esac; docker push img'
expect deny  "a glob git word as the command of a *) arm" "$R" 'case "$x" in a) ;; *) /usr/bin/g[i]t push origin main;; esac'
expect deny  "a glob git word in a subshell"          "$R" '(/usr/bin/g[i]t push origin main)'
expect deny  "a glob git word after xargs, before a )" "$R" '(echo push origin main | xargs /usr/bin/g[i]t)'
# Here-documents keep the rule above (a heredoc body naming a push is denied): git and push
# on one line. These bodies hold a bullet and no such line, so they go ahead.
expect allow "a commit heredoc with a bullet line"    "$R" "git commit -F - <<'EOF'
Narrow the push alias scan

* keep reserved words
EOF"
expect allow "a heredoc bullet, then docker push"     "$R" "cat > $TMP/notes.md <<'EOF'
* build the image
EOF
docker push img"
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
# The fast path sends send-pack, http-push and the git-<sub> dash forms to the helper, so
# the fallback refuses them too.
expect deny  "git send-pack with no helper is refused" "$R" "git send-pack $REMOTES/origin.git main"
expect deny  "git http-push with no helper is refused" "$R" 'git http-push origin main'
expect deny  "git-push with no helper is refused"      "$R" 'git-push origin main'
expect deny  "a git-core path to git-send-pack with no helper" "$R" '/usr/libexec/git-core/git-send-pack /r.git main'
expect allow "git log --grep=push with no helper is untouched" "$R" 'git log --grep=push'
# A helper that runs but fails is the same: the fallback decides.
FAILHELPER="$TMP/failhelper"; mkdir -p "$FAILHELPER"
cp "$SAVED_GUARD" "$FAILHELPER/git-forge-guard.sh"
printf 'import sys\nsys.exit(3)\n' > "$FAILHELPER/git-push-guard.py"
GUARD="$FAILHELPER/git-forge-guard.sh"
for c in "git send-pack $REMOTES/origin.git main" 'git http-push origin main' 'git-push origin main' \
         'git push origin feat'; do
  expect deny  "a failing helper: $c is refused"       "$R" "$c"
done
expect allow "a failing helper: git status is untouched" "$R" 'git status'
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

echo "== rule 4: the secret scan =="
PATH="$REALPATH"
CLEAN=$(clone clean)
printf 'hello\n' > "$CLEAN/notes.txt"
git -C "$CLEAN" add notes.txt && git -C "$CLEAN" commit -q -m "a clean change"
# Feature branches of their own (not feat, which other cases push), each carrying one
# outgoing commit that adds no line: TRIM removes a line, RENTRIM renames a file and
# removes a line from it. gitleaks counts both, since each has a hunk.
TRIM=$(clone trim)
git -C "$TRIM" switch -q -c trim
printf 'one\ntwo\nthree\n' > "$TRIM/t.txt"; git -C "$TRIM" add t.txt; git -C "$TRIM" commit -q -m "add t"
git -C "$TRIM" push -q -u origin trim 2>/dev/null
printf 'one\nthree\n' > "$TRIM/t.txt"; git -C "$TRIM" commit -q -am "remove a line"
RENTRIM=$(clone rename-trim)
git -C "$RENTRIM" switch -q -c rentrim
printf 'one\ntwo\nthree\nfour\n' > "$RENTRIM/t.txt"; git -C "$RENTRIM" add t.txt; git -C "$RENTRIM" commit -q -m "add t"
git -C "$RENTRIM" push -q -u origin rentrim 2>/dev/null
git -C "$RENTRIM" mv t.txt u.txt; printf 'one\ntwo\nthree\n' > "$RENTRIM/u.txt"
git -C "$RENTRIM" commit -q -am "rename t, remove a line"
[ "$(git -C "$RENTRIM" diff --name-status -M HEAD~1 HEAD | cut -c1)" = R ] \
  && [ "$(git -C "$RENTRIM" rev-list --count HEAD --not --remotes=origin)" = 1 ] \
  && [ "$(git -C "$TRIM" rev-list --count HEAD --not --remotes=origin)" = 1 ] \
  || { echo "the removal-only fixtures are not what they claim" >&2; exit 1; }
if ! command -v gitleaks >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf '  FAIL %s\n' "gitleaks is installed (brew install gitleaks); the scan cases cannot run"
else
  # The fixture secret is assembled at runtime from two halves, so no committed file
  # holds a scannable credential: this suite is itself pushed through the scan it tests.
  part_a=AKIA; part_b=QX7T2MZL4KRB6WNP
  SECRET_LINE="aws = \"$part_a$part_b\""
  LEAKY=$(clone leaky)
  printf '%s\n' "$SECRET_LINE" > "$LEAKY/creds.txt"
  git -C "$LEAKY" add creds.txt && git -C "$LEAKY" commit -q -m "add creds"
  expect allow "a clean feature branch is scanned and passes" "$CLEAN" 'git push origin feat'
  expect deny  "a secret in the outgoing commits"             "$LEAKY" 'git push origin feat'
  has_reason   "the deny names rule, file and commit" \
               "rule aws-access-token in creds.txt at commit" "$LEAKY" 'git push origin feat'
  got=$(reason "$LEAKY" 'git push origin feat')
  # The suite's gitconfig carries a format.pretty like Michael's, which once made gitleaks
  # report findings with no commit. The fingerprint must be commit-bound.
  if printf '%s\n' "$got" | grep -Eq '\(fingerprint [0-9a-f]{40}:creds\.txt:aws-access-token:1\)'; then
    pass=$((pass + 1)); printf '  ok   %s\n' "the fingerprint is bound to the commit, despite format.pretty"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "the fingerprint is bound to the commit, despite format.pretty ($got)"
  fi
  # -C selects the repository that is scanned: the same push, two repositories.
  expect deny  "git -C <leaky repo> is scanned there"  "$CLEAN" "git -C $LEAKY push origin feat"
  expect allow "git -C <clean repo> is scanned there"  "$LEAKY" "git -C $CLEAN push origin feat"
  case "$got" in
    *"$part_b"*) fail=$((fail + 1)); printf '  FAIL %s\n' "the deny never shows the secret" ;;
    *)           pass=$((pass + 1)); printf '  ok   %s\n' "the deny never shows the secret" ;;
  esac
  expect deny  "a secret beats an ask: deny, not ask"         "$LEAKY" 'git push origin feat:main'
  expect allow "a dry run is never scanned"                   "$LEAKY" 'git push --dry-run origin feat'
  INLINE=$(clone inline)
  printf '%s # gitleaks:allow\n' "$SECRET_LINE" > "$INLINE/creds.txt"
  git -C "$INLINE" add creds.txt && git -C "$INLINE" commit -q -m "add creds inline-allowed"
  expect deny  "an inline gitleaks:allow is not an exception" "$INLINE" 'git push origin feat'
  # The reviewed way through: the finding's fingerprint in the tracked .gitleaksignore.
  fp=$(printf '%s\n' "$got" | sed -n 's/.*(fingerprint \([^)]*\)).*/\1/p' | head -1)
  printf '%s\n' "$fp" > "$LEAKY/.gitleaksignore"
  git -C "$LEAKY" add .gitleaksignore && git -C "$LEAKY" commit -q -m "ignore a false positive"
  expect allow "a fingerprint in .gitleaksignore lets it through" "$LEAKY" 'git push origin feat'
  # Only the DESTINATION remote's history is excluded. A commit already published on
  # another remote is still scanned before it reaches this one.
  TWO=$(clone two-remotes)
  git -C "$TWO" remote add backup "$REMOTES/backup.git"
  git -C "$TWO" switch -q -c elsewhere
  printf '%s\n' "$SECRET_LINE" > "$TWO/creds.txt"
  git -C "$TWO" add creds.txt && git -C "$TWO" commit -q -m "add creds"
  git -C "$TWO" push -q backup elsewhere 2>/dev/null
  expect deny  "a secret reachable only from another remote is still scanned" "$TWO" 'git push origin elsewhere'
  expect allow "the destination remote's own history is excluded"            "$TWO" 'git push backup elsewhere'

  # leaky_clone <name> -> a clone of a branch that adds the secret. fingerprint_of <repo>
  # reads the fingerprint the deny reports (it is commit-bound, so it differs per clone).
  leaky_clone() {
    local d; d=$(clone "$1")
    printf '%s\n' "$SECRET_LINE" > "$d/creds.txt"
    git -C "$d" add creds.txt && git -C "$d" commit -q -m "add creds"
    printf '%s' "$d"
  }
  fingerprint_of() {
    reason "$1" 'git push origin feat' | sed -n 's/.*(fingerprint \([^)]*\)).*/\1/p' | head -1
  }
  # The exception must be reviewed: gitleaks reads .gitleaksignore from the working tree,
  # so only a committed copy may decide what the scan skips.
  echo "== rule 4: a gitleaks exception must be committed =="
  UNTRACKED=$(leaky_clone untracked-ignore)
  fp=$(fingerprint_of "$UNTRACKED"); printf '%s\n' "$fp" > "$UNTRACKED/.gitleaksignore"
  expect deny  "an untracked .gitleaksignore is not an exception" "$UNTRACKED" 'git push origin feat'
  has_reason   "and the deny says to commit it first" "Commit the exception first" "$UNTRACKED" 'git push origin feat'
  EXCLUDED=$(leaky_clone excluded-ignore)
  fp=$(fingerprint_of "$EXCLUDED"); printf '%s\n' "$fp" > "$EXCLUDED/.gitleaksignore"
  printf '.gitleaksignore\n' >> "$EXCLUDED/.git/info/exclude"
  expect deny  "a .gitleaksignore in .git/info/exclude is not an exception" "$EXCLUDED" 'git push origin feat'
  CHANGED=$(clone changed-ignore)
  printf '# reviewed\n' > "$CHANGED/.gitleaksignore"
  git -C "$CHANGED" add .gitleaksignore && git -C "$CHANGED" commit -q -m "add ignore file"
  printf '%s\n' "$SECRET_LINE" > "$CHANGED/creds.txt"
  git -C "$CHANGED" add creds.txt && git -C "$CHANGED" commit -q -m "add creds"
  fp=$(fingerprint_of "$CHANGED"); printf '%s\n' "$fp" >> "$CHANGED/.gitleaksignore"
  expect deny  "an uncommitted edit to a tracked .gitleaksignore" "$CHANGED" 'git push origin feat'
  expect allow "the committed fingerprint case still passes"   "$LEAKY" 'git push origin feat'

  echo "== rule 4: the scan must cover what it is asked to =="
  # color.diff=always once made gitleaks scan 0 commits and report no leaks. The scan pins
  # the config that breaks its parse, and refuses a run that covers fewer commits.
  COLORED=$(leaky_clone colored)
  git -C "$COLORED" config color.diff always
  expect deny  "a secret is still found under color.diff=always" "$COLORED" 'git push origin feat'
  has_reason   "and the deny names the rule" "rule aws-access-token" "$COLORED" 'git push origin feat'
  COLORCLEAN=$(clone colored-clean); git -C "$COLORCLEAN" config color.diff always
  printf 'hello\n' > "$COLORCLEAN/notes.txt"
  git -C "$COLORCLEAN" add notes.txt && git -C "$COLORCLEAN" commit -q -m "a clean change"
  expect allow "a clean push under color.diff=always"          "$COLORCLEAN" 'git push origin feat'
  # Commits that add no text are not counted by gitleaks, and must not fail the check.
  MIXED=$(clone mixed)
  git -C "$MIXED" commit -q --allow-empty -m "empty"
  printf 'x\n' > "$MIXED/a.txt"; git -C "$MIXED" add a.txt; git -C "$MIXED" commit -q -m "add a"
  chmod +x "$MIXED/a.txt"; git -C "$MIXED" commit -q -am "mode only"
  git -C "$MIXED" rm -q a.txt; git -C "$MIXED" commit -q -m "delete a"
  printf 'y\n' > "$MIXED/b.txt"; git -C "$MIXED" add b.txt; git -C "$MIXED" commit -q -m "add b"
  expect allow "empty, mode-only and deleting commits do not fail the count" "$MIXED" 'git push origin feat'
  # A secret added only while committing a merge: git log -p shows no diff for a merge.
  MERGED=$(clone merged)
  git -C "$MERGED" switch -q -c side
  printf 'side\n' > "$MERGED/side.txt"; git -C "$MERGED" add side.txt; git -C "$MERGED" commit -q -m "side"
  git -C "$MERGED" switch -q feat
  printf 'main\n' > "$MERGED/other.txt"; git -C "$MERGED" add other.txt; git -C "$MERGED" commit -q -m "other"
  git -C "$MERGED" merge -q --no-ff -m "merge side" side
  expect allow "a clean merge is clean"                        "$MERGED" 'git push origin feat'
  EVIL=$(clone evil-merge)
  git -C "$EVIL" switch -q -c side
  printf 'side\n' > "$EVIL/side.txt"; git -C "$EVIL" add side.txt; git -C "$EVIL" commit -q -m "side"
  git -C "$EVIL" switch -q feat
  printf 'main\n' > "$EVIL/other.txt"; git -C "$EVIL" add other.txt; git -C "$EVIL" commit -q -m "other"
  git -C "$EVIL" merge -q --no-ff --no-commit side >/dev/null 2>&1
  printf '%s\n' "$SECRET_LINE" > "$EVIL/creds.txt"; git -C "$EVIL" add creds.txt
  git -C "$EVIL" commit -q -m "merge side"
  expect deny  "a secret introduced while committing a merge"  "$EVIL" 'git push origin feat'
  # Ways git can be made to show no added text while the secret is there. The scan pins
  # them for its own git log, and never skips gitleaks on an expected count of zero.
  echo "== rule 4: a secret git is told not to show =="
  NODIFF=$(clone nodiff)
  printf '* -diff\n' > "$NODIFF/.gitattributes"
  printf '%s\n' "$SECRET_LINE" > "$NODIFF/creds.txt"
  git -C "$NODIFF" add .gitattributes creds.txt && git -C "$NODIFF" commit -q -m "add creds, marked -diff"
  expect deny  "a secret under -diff in a committed .gitattributes" "$NODIFF" 'git push origin feat'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$NODIFF" 'git push origin feat'
  INFOATTR=$(leaky_clone info-attributes)
  printf '* binary\n' >> "$INFOATTR/.git/info/attributes"
  expect deny  "a secret under binary in .git/info/attributes"      "$INFOATTR" 'git push origin feat'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$INFOATTR" 'git push origin feat'
  BIGFILE=$(leaky_clone bigfile)
  git -C "$BIGFILE" config core.bigFileThreshold 1
  expect deny  "a secret under core.bigFileThreshold=1"             "$BIGFILE" 'git push origin feat'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$BIGFILE" 'git push origin feat'
  ORPHAN=$(clone orphan)
  git -C "$ORPHAN" switch -q --orphan orphan
  printf '%s\n' "$SECRET_LINE" > "$ORPHAN/creds.txt"
  git -C "$ORPHAN" add creds.txt && git -C "$ORPHAN" commit -q -m "root with creds"
  git -C "$ORPHAN" config log.showRoot false
  expect deny  "a secret in a root commit under log.showRoot=false" "$ORPHAN" 'git push origin orphan'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$ORPHAN" 'git push origin orphan'
  # None of that may cost an ordinary push its silence. gitleaks counts a commit when its
  # patch has a hunk in a file it does not skip (a deleted one), even a hunk that only
  # removes lines, and the expected count follows the same rule.
  expect allow "a commit that only removes a line"           "$TRIM" 'git push origin trim'
  expect allow "a rename that also removes a line"           "$RENTRIM" 'git push origin rentrim'
  FRESH="$TMP/fresh"; git init -q "$FRESH"
  git init -q --bare "$REMOTES/fresh.git"
  printf 'one\ntwo\n' > "$FRESH/a.txt"; git -C "$FRESH" add a.txt; git -C "$FRESH" commit -q -m "first"
  git -C "$FRESH" remote add origin "$REMOTES/fresh.git"; git -C "$FRESH" switch -q -c topic
  expect allow "a first push of a new repository"            "$FRESH" 'git push origin topic'
  EMPTIES=$(clone empties)
  git -C "$EMPTIES" commit -q --allow-empty -m "e1"; git -C "$EMPTIES" commit -q --allow-empty -m "e2"
  expect allow "empty commits only"                           "$EMPTIES" 'git push origin feat'
  DELREN=$(clone delren)
  seq 1 20 > "$DELREN/a.txt"; seq 21 40 > "$DELREN/b.txt"
  git -C "$DELREN" add a.txt b.txt && git -C "$DELREN" commit -q -m "add a and b"
  git -C "$DELREN" push -q origin feat 2>/dev/null
  git -C "$DELREN" rm -q b.txt && git -C "$DELREN" commit -q -m "delete b"
  expect allow "deletions only"                               "$DELREN" 'git push origin feat'
  git -C "$DELREN" mv a.txt c.txt && git -C "$DELREN" commit -q -m "rename a"
  expect allow "a deletion and a rename"                      "$DELREN" 'git push origin feat'
  BINARY=$(clone binary)
  printf '\000\001\002\003\n' > "$BINARY/blob.bin"
  git -C "$BINARY" add blob.bin && git -C "$BINARY" commit -q -m "a binary file"
  expect allow "a binary-only commit"                         "$BINARY" 'git push origin feat'
  AMENDED=$(clone amended)
  printf 'one\n' > "$AMENDED/n.txt"; git -C "$AMENDED" add n.txt; git -C "$AMENDED" commit -q -m "add n"
  git -C "$AMENDED" push -q origin feat 2>/dev/null
  printf 'two\n' >> "$AMENDED/n.txt"; git -C "$AMENDED" commit -q -a --amend -m "add n, amended"
  expect allow "after an amend"                               "$AMENDED" 'git push origin feat'
  # The exception files are compared with HEAD byte for byte, so git's own ways of hiding a
  # change (status.showUntrackedFiles, skip-worktree) do not hide it from the guard.
  HIDDEN=$(leaky_clone hidden-untracked)
  fp=$(fingerprint_of "$HIDDEN"); printf '%s\n' "$fp" > "$HIDDEN/.gitleaksignore"
  git -C "$HIDDEN" config status.showUntrackedFiles no
  expect deny  "an untracked .gitleaksignore under status.showUntrackedFiles=no" "$HIDDEN" 'git push origin feat'
  has_reason   "and it is refused for being uncommitted" "Commit the exception first" "$HIDDEN" 'git push origin feat'
  SKIPWT=$(clone skip-worktree)
  printf '# reviewed\n' > "$SKIPWT/.gitleaksignore"
  git -C "$SKIPWT" add .gitleaksignore && git -C "$SKIPWT" commit -q -m "add ignore file"
  printf '%s\n' "$SECRET_LINE" > "$SKIPWT/creds.txt"
  git -C "$SKIPWT" add creds.txt && git -C "$SKIPWT" commit -q -m "add creds"
  fp=$(fingerprint_of "$SKIPWT"); printf '%s\n' "$fp" >> "$SKIPWT/.gitleaksignore"
  git -C "$SKIPWT" update-index --skip-worktree .gitleaksignore
  expect deny  "a skip-worktree edit to a committed .gitleaksignore" "$SKIPWT" 'git push origin feat'
  has_reason   "and it is refused for differing from HEAD" "Commit the exception first" "$SKIPWT" 'git push origin feat'
  # A replace ref hides an object from git log, but a push sends the real one.
  REPLBLOB=$(leaky_clone replace-blob)
  secret_blob=$(git -C "$REPLBLOB" rev-parse HEAD:creds.txt)
  clean_blob=$(printf 'hello\n' | git -C "$REPLBLOB" hash-object -w --stdin)
  git -C "$REPLBLOB" replace "$secret_blob" "$clean_blob"
  expect deny  "a secret hidden by a replaced blob"           "$REPLBLOB" 'git push origin feat'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$REPLBLOB" 'git push origin feat'
  REPLCOMMIT=$(leaky_clone replace-commit)
  git -C "$REPLCOMMIT" replace HEAD HEAD~1
  expect deny  "a secret hidden by a replaced commit"         "$REPLCOMMIT" 'git push origin feat'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$REPLCOMMIT" 'git push origin feat'
  # An exception committed on the branch you stand on reviews nothing for another branch.
  OTHERBR=$(leaky_clone otherbranch)
  fp=$(fingerprint_of "$OTHERBR")
  git -C "$OTHERBR" switch -q -c scratch
  printf '%s\n' "$fp" > "$OTHERBR/.gitleaksignore"
  git -C "$OTHERBR" add .gitleaksignore && git -C "$OTHERBR" commit -q -m "ignore, on scratch only"
  expect deny  "an exception committed on HEAD, not on the pushed branch" "$OTHERBR" 'git push origin feat'
  has_reason   "and the deny says to commit it on the pushed ref" "on the ref being pushed" "$OTHERBR" 'git push origin feat'
  expect allow "the exception on the branch being pushed lets it through" "$OTHERBR" 'git push origin scratch'
  # --tags, --all and --mirror push refs the guard does not name one by one, so it cannot show
  # an exception is committed on each of them: with an exception file in the worktree they are
  # refused. Here the secret is tagged v1 on feat, and the exception is committed on scratch only.
  TAGGED=$(leaky_clone tagged)
  fp=$(fingerprint_of "$TAGGED")
  git -C "$TAGGED" tag v1
  git -C "$TAGGED" switch -q -c scratch main
  printf '%s\n' "$fp" > "$TAGGED/.gitleaksignore"
  git -C "$TAGGED" add .gitleaksignore && git -C "$TAGGED" commit -q -m "ignore, on scratch only"
  expect deny  "--tags with an exception file in the worktree" "$TAGGED" 'git push origin --tags'
  has_reason   "and the deny says to push the refs by name" "Push the branches and tags by name" "$TAGGED" 'git push origin --tags'
  expect deny  "--all with an exception file in the worktree"  "$TAGGED" 'git push --all origin'
  expect deny  "--mirror with an exception file in the worktree" "$TAGGED" 'git push --mirror origin'
  expect deny  "the tag pushed by name, its exception missing" "$TAGGED" 'git push origin v1'
  has_reason   "and the deny fits a tag" "on the ref being pushed" "$TAGGED" 'git push origin v1'
  # With no exception file anywhere, --tags is scanned as before: silent when clean.
  TAGCLEAN=$(clone tag-clean)
  printf 'hello\n' > "$TAGCLEAN/notes.txt"
  git -C "$TAGCLEAN" add notes.txt && git -C "$TAGCLEAN" commit -q -m "a clean change"
  git -C "$TAGCLEAN" tag v1
  expect allow "--tags with no exception file, clean"          "$TAGCLEAN" 'git push origin --tags'
  TAGLEAK=$(leaky_clone tag-leak)
  git -C "$TAGLEAK" tag v1
  expect deny  "--tags with no exception file, a secret"       "$TAGLEAK" 'git push origin --tags'
  has_reason   "and it is found, not merely refused" "rule aws-access-token in creds.txt" "$TAGLEAK" 'git push origin --tags'
  # A config named in the environment is as unreviewed as an untracked one.
  printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%s]\n' "'''.*'''" > "$TMP/allow-all.toml"
  GITLEAKS_CONFIG="$TMP/allow-all.toml" expect deny "a GITLEAKS_CONFIG in the environment is ignored" "$EVIL" 'git push origin feat'
  has_reason   "and the deny names the file" "in creds.txt" "$EVIL" 'git push origin feat'

  # A gitleaks config decides which rules run and what they allow, and the push guard
  # supports none: gitleaks reads .gitleaks.toml from the working tree, lets viper find any
  # .gitleaks.<ext> beside it, and a config can extend a file nobody reviewed. Any such file
  # in the working tree (tracked or not), or committed on a pushed ref, is a silent deny
  # naming it, before gitleaks runs.
  echo "== rule 4: a gitleaks config file is unsupported =="
  ALLOW_ALL=$(printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%s]\n' "'''.*'''")
  # On a clean branch, so the deny can only come from the file. Every extension and case.
  # The branch carries a clean commit: a push that sends nothing is never scanned.
  n=0
  for name in .gitleaks.toml .gitleaks.json .gitleaks.yaml .gitleaks.yml .GITLEAKS.TOML .Gitleaks.Json; do
    n=$((n + 1)); CFG=$(clone "config-$n")
    printf 'hello\n' > "$CFG/notes.txt"
    git -C "$CFG" add notes.txt && git -C "$CFG" commit -q -m "a clean change"
    printf '%s\n' "$ALLOW_ALL" > "$CFG/$name"
    expect deny  "an untracked $name, on a clean branch" "$CFG" 'git push origin feat'
    has_reason   "and the deny names $name as unsupported" \
                 "unsupported push configuration for the push guard: the gitleaks config file $name in the working tree" \
                 "$CFG" 'git push origin feat'
  done
  CFGLEAK=$(leaky_clone config-leak)
  printf '%s\n' "$ALLOW_ALL" > "$CFGLEAK/.gitleaks.toml"
  expect deny  "an untracked .gitleaks.toml that allows everything" "$CFGLEAK" 'git push origin feat'
  git -C "$CFGLEAK" add .gitleaks.toml
  expect deny  "a staged, uncommitted .gitleaks.toml"         "$CFGLEAK" 'git push origin feat'
  git -C "$CFGLEAK" commit -q -m "a gitleaks config"
  expect deny  "a committed .gitleaks.toml"                   "$CFGLEAK" 'git push origin feat'
  has_reason   "and the deny names the file" \
               "the gitleaks config file .gitleaks.toml in the working tree" "$CFGLEAK" 'git push origin feat'
  # An [extend] path loads another file. The config is no longer read, only refused.
  EXT=$(leaky_clone config-extend)
  printf '[extend]\npath = "local-allow.toml"\n' > "$EXT/.gitleaks.toml"
  printf '%s\n' "$ALLOW_ALL" > "$EXT/local-allow.toml"
  git -C "$EXT" add .gitleaks.toml local-allow.toml && git -C "$EXT" commit -q -m "extend a config"
  expect deny  "a committed .gitleaks.toml that extends another config" "$EXT" 'git push origin feat'
  has_reason   "and the deny names the file" \
               "the gitleaks config file .gitleaks.toml in the working tree" "$EXT" 'git push origin feat'
  # Committed on the pushed ref, absent from the working tree: the push names another branch.
  TREEONLY=$(clone config-tree-only)
  git -C "$TREEONLY" switch -q -c withcfg
  printf '%s\n' "$ALLOW_ALL" > "$TREEONLY/.GitLeaks.Toml"
  printf 'hello\n' > "$TREEONLY/notes.txt"
  git -C "$TREEONLY" add .GitLeaks.Toml notes.txt && git -C "$TREEONLY" commit -q -m "a config and a change"
  git -C "$TREEONLY" switch -q feat
  expect deny  "a config committed on the pushed ref, not in the working tree" "$TREEONLY" 'git push origin withcfg'
  has_reason   "and the deny names the file and the ref" \
               "the gitleaks config file .GitLeaks.Toml committed on withcfg" "$TREEONLY" 'git push origin withcfg'
  git -C "$TREEONLY" tag cfgtag withcfg
  expect deny  "a config in a tagged tree, pushed with --tags" "$TREEONLY" 'git push origin --tags'
  # Only what is pushed counts: a config on a branch that stays home is not in play.
  printf 'hello\n' > "$TREEONLY/notes.txt"
  git -C "$TREEONLY" add notes.txt && git -C "$TREEONLY" commit -q -m "a clean change on feat"
  expect allow "a config on a branch this push does not send" "$TREEONLY" 'git push origin feat'
fi

echo "== rule 4: the scan fails closed =="
NOGL="$TMP/nogl"; mkdir -p "$NOGL"; ln -s "$(command -v jq)" "$NOGL/jq"
PATH="$NOGL:/usr/bin:/bin"
expect deny  "a missing gitleaks denies the push"   "$CLEAN" 'git push origin feat'
has_reason   "and names the remedy" "brew bundle"   "$CLEAN" 'git push origin feat'
BROKEN="$TMP/brokengl"; mkdir -p "$BROKEN"
printf '#!/bin/sh\necho "gitleaks: boom" >&2\nexit 2\n' > "$BROKEN/gitleaks"; chmod 755 "$BROKEN/gitleaks"
PATH="$BROKEN:$REALPATH"
expect deny  "a gitleaks error denies the push"     "$CLEAN" 'git push origin feat'
has_reason   "and carries the error" "boom"         "$CLEAN" 'git push origin feat'
RECORD="$TMP/recordgl"; mkdir -p "$RECORD"
printf '#!/bin/sh\necho called >> "%s/calls"\nexit 0\n' "$RECORD" > "$RECORD/gitleaks"; chmod 755 "$RECORD/gitleaks"
PATH="$RECORD:$REALPATH"
expect allow "a dry run to main"                    "$CLEAN" 'git push -n origin main'
if [ -e "$RECORD/calls" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "a dry run never runs gitleaks"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "a dry run never runs gitleaks"
fi
# A clean exit is not proof of a clean scan: gitleaks exits 0 with "0 commits scanned" when
# its own git log fails or is misparsed. CLEAN carries exactly one commit that adds text.
for spec in "zero|0 commits scanned.|" "noline||" \
            "err|1 commits scanned.|ERR [git] fatal: bad revision" "many|2 commits scanned.|"; do
  name=${spec%%|*}; rest=${spec#*|}; line=${rest%%|*}; errline=${rest#*|}
  STUB2="$TMP/cov-$name"; mkdir -p "$STUB2"
  {
    printf '#!/bin/sh\n'
    [ -n "$errline" ] && printf 'echo "6:00PM %s" >&2\n' "$errline"
    [ -n "$line" ] && printf 'echo "6:00PM INF %s" >&2\n' "$line"
    printf 'exit 0\n'
  } > "$STUB2/gitleaks"; chmod 755 "$STUB2/gitleaks"
  PATH="$STUB2:$REALPATH"
  case $name in
    zero)  expect deny  "a gitleaks that scanned 0 of 1 commits is a deny" "$CLEAN" 'git push origin feat'
           has_reason   "and the deny says how many it scanned" "scanned 0 commit(s)" "$CLEAN" 'git push origin feat'
           # A commit that only removes lines is still one gitleaks must cover.
           expect deny  "a gitleaks that skipped a removal-only commit is a deny" "$TRIM" 'git push origin trim' ;;
    noline) expect deny "a gitleaks that reports no count is a deny"       "$CLEAN" 'git push origin feat' ;;
    err)   expect deny  "a gitleaks that logs an ERR line is a deny"       "$CLEAN" 'git push origin feat' ;;
    many)  expect deny  "a count that differs from the outgoing one is a deny" "$CLEAN" 'git push origin feat' ;;
  esac
done
OKGL="$TMP/cov-ok"; mkdir -p "$OKGL"
printf '#!/bin/sh\necho "6:00PM INF 1 commits scanned." >&2\nexit 0\n' > "$OKGL/gitleaks"; chmod 755 "$OKGL/gitleaks"
PATH="$OKGL:$REALPATH"
expect allow "a gitleaks that scanned exactly the outgoing commits passes" "$CLEAN" 'git push origin feat'
expect allow "and so does one that scanned the removal-only commit" "$TRIM" 'git push origin trim'
# A push naming a ref that does not exist cannot be listed, so it cannot be shown covered.
expect deny  "a source that is not a ref is a deny"   "$CLEAN" 'git push origin nosuch'
# A gitleaks that hangs (or a git it spawns) must end in a deny within the helper's budget,
# and the whole process group must go: a surviving child would hold the hook open.
HANG="$TMP/hanggl"; mkdir -p "$HANG"
printf '#!/bin/sh\nsleep 30\nexit 0\n' > "$HANG/gitleaks"; chmod 755 "$HANG/gitleaks"
PATH="$HANG:$REALPATH"
export PUSH_GUARD_BUDGET=2
started=$(date +%s)
expect deny  "a gitleaks slower than the budget is a deny" "$CLEAN" 'git push origin feat'
has_reason   "and the deny says the scan timed out" "did not finish" "$CLEAN" 'git push origin feat'
elapsed=$(( $(date +%s) - started ))
unset PUSH_GUARD_BUDGET
if [ "$elapsed" -le 12 ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a hung gitleaks is cut off at the budget (${elapsed}s for two pushes)"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "a hung gitleaks is cut off at the budget (${elapsed}s for two pushes)"
fi
PATH="$STUBBIN:$REALPATH"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

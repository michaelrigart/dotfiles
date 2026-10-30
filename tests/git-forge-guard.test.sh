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
#
# Canonical text (git-push-guard.py CANONICAL; spec 2026-10-28, section 2), the only text in
# which rule 4 passes a merged, pinned delete silently, was checked by differential runs on
# 2026-10-28, which are not part of this suite.
#
# A. 1558 canonical commands: every allowed character (A-Z a-z 0-9 . _ / : = @ + , % -)
#    alone, first, last and inside a word (= never first), plus 1500 random ones, spread
#    over all six trailers. Each ran under bash 3.2, bash 5.3, zsh 5.9 -f, zsh with Claude
#    Code's NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL, zsh with EXTENDED_GLOB, and zsh with
#    Michael's Claude Code shell snapshot sourced: 9348 runs. git, tail and head were shell
#    functions recording their argv, in a cwd holding files named like plain words. Every
#    run handed git exactly the arguments the guard judged, and tail/head exactly -n N:
#    0 mismatches. A control showed that the same harness sees brace, glob and zsh
#    =command expansion. A is the check that covers the piped shapes (the four trailers
#    with | tail or | head).
# B. 5837 commands, each run from the checkout and from outside any repository against main's
#    guard and this one on 2026-10-29. The set covers delete-only pushes of merged, unmerged,
#    default and tag branches, pinned and not, plus updates, aliases and dry runs (negated,
#    abbreviated, bundled, -on, a glob). Each came in every trailer, behind cd, assignment,
#    wrapper and global-option prefixes, with quoted and escaped words, continuations, odd
#    whitespace, ANSI-C words, comments and compounds, and with 40 random insertions of one to
#    three characters. No verdict was looser than main's. The changes:
#    - 541 merged, pinned deletes not in canonical text went from silent to deny;
#    - 1013 dry runs not in canonical text, which main let return early, went from silent to
#      deny: judged as real pushes, where that verdict was an ask the dry run gets the silent
#      dry-run deny instead, so none asks.
#    No canonical dry run changed. Every delete-only push this guard leaves silent is
#    canonical text, or one main's guard also leaves silent because the helper never reads it
#    as git push (no literal git or push word, or a subcommand word holding another
#    character): 322 such. That is obfuscation, which the threat model leaves to the
#    classifier.
# C. Which plain words does a shell option still rewrite? Surveyed on 2026-10-29 with zsh 5.9,
#    bash 3.2.57 and bash 5.3.20 (not part of this suite). The survey ran 77222 words: every
#    word of length 1 and 2 over the full alphabet, every word of length 3 and 4 over l s x A 0
#    7 and the ten punctuation characters (letters and digits differ only in the command names
#    they spell; l and s spell ls), and lease, refs/heads, :refs/heads and push-option shapes
#    around 300 branch names. Each word was handed unquoted to /usr/bin/printf, and its argv
#    was compared with the word. The settings were:
#    - zsh -f with each of its 185 options flipped on its own;
#    - zsh with EQUALS, MAGIC_EQUAL_SUBST, BRACE_CCL, EXTENDED_GLOB, KSH_GLOB and GLOB_SUBST
#      together;
#    - zsh with Michael's Claude Code shell snapshot sourced, alone and with those options;
#    - bash 3.2 and 5.3 with each shopt and set -o option flipped on its own, and with
#      extglob, globstar, nocaseglob, dotglob, nullglob and failglob together.
#    Of 340 settings, 329 handed every one of the 72781 words not starting with = through
#    unchanged. 6 ran nothing (noexec, onecmd, restricted). The other 5 (MAGIC_EQUAL_SUBST
#    alone, with the listed options, and with the snapshot; bash 3.2 and 5.3 set -o keyword)
#    found three shapes, and canonical() refuses each (SHELL_REWRITES):
#    - a word starting with = (zsh EQUALS, on by default: =ls is /bin/ls). It is refused as
#      before.
#    - a word holding == or := (zsh MAGIC_EQUAL_SUBST, off in the snapshot). 327 of the 1361
#      such words changed or failed: x==ls became x=/bin/ls, and --force-with-lease=a:=ls
#      became --force-with-lease=a:/bin/ls. With the option set, the final review measured a
#      canonical delete of the merged x==ls that deleted the unmerged x=/bin/ls instead.
#    - a word shaped NAME= or NAME+= (bash set -o keyword). bash moves exactly these 2398 words
#      into the environment, so git never sees them.
#    The snapshot defines no global alias, so no alias rewrites an argument.
# D. The -N trailers (| tail -N, | head -N, 2>&1 | tail -N, 2>&1 | head -N), added after A,
#    were surveyed the same way on 2026-10-29 under the same 340 settings:
#    - word level: -1 to -999, -0, -00, -007, -1000, -65536 and a 20-digit -N, 1005 words;
#    - the trailer as a whole: /usr/bin/printf x piped to stub tail and head commands that
#      print their argv. Every N ran under the 11 representative settings (zsh defaults, the
#      listed options, MAGIC_EQUAL_SUBST, the snapshot alone and with the listed options, and
#      each bash's defaults, set -k and glob options). N in 1, 3, 10, 99 and 999 ran under the
#      other 329.
#    Every setting that runs commands handed tail and head exactly -N; noexec, onecmd and
#    restricted run nothing. Under the snapshot, the stubs went first on PATH after it was
#    sourced, since it sets its own PATH, and the snapshot overrides neither tail nor head.
#    macOS tail and head read -N as -n N; head -0 fails as head -n 0 does.

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
    | PINNED_PATH="$PATH" bash "$GUARD"
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
# lacks_reason <label> <needle> <cwd> <command>: there is a reason, and the needle is not in it
lacks_reason() {
  local label=$1 needle=$2 got
  got=$(reason "$3" "$4")
  case "$got" in
    "") fail=$((fail + 1)); printf '  FAIL %s (no reason)\n' "$label" ;;
    *"$needle"*) fail=$((fail + 1)); printf '  FAIL %s (reason has %s: %s)\n' "$label" "$needle" "$got" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$label" ;;
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
expect deny  "git log is not inert, even to /dev/null" "$R" 'git log --grep "git push" 2>/dev/null | wc -l'
expect allow "an inert git command redirected to /dev/null" "$R" 'git status 2>/dev/null && git commit -m "push later"'
expect allow "add, status, then a commit message about a push" "$R" 'git add f && git status && git commit -m "push later"'
expect allow "switch -c, then a commit message about push defaults" "$R" 'git switch -c x && git commit -m "explain push defaults"'
# Only an explicit set of git subcommands is inert; difftool, clone and friends run words.
expect deny  "difftool -x running a push"             "$R"   "git add f && git difftool -x 'git push origin main' HEAD"
expect deny  "difftool --extcmd running a push"       "$R"   "git add f && git difftool --extcmd='git push' HEAD"
expect deny  "clone --template, which is not inert"   "$R"   "rg x && git clone --template=/tmp/t 'git push' y"
expect deny  "mergetool, then a push of its own"      "$R"   'git add f && git mergetool --tool-help; git push origin main'
expect deny  "git grep is not inert, after status"    "$R"   'git status && git grep -n "push" -- README.md'
expect allow "add of the guard file, then a commit"   "$R"   'git add dot_claude/git-push-guard.py && git commit -m x'
expect allow "stash push is not a push"               "$R"   'git stash push -m wip && git status'
# Only subcommands whose options neither run a command nor write a file are inert: log,
# show and diff take --output=<file>, which a later command can run.
expect deny  "log --output writing a push, then sh"   "$R"   'git log -1 --format="git push origin main%n" --output=x.sh && sh x.sh'
expect deny  "log --output as separate values, then sh" "$R" 'git log -1 --format "git push origin main%n" --output x.sh && sh x.sh'
expect deny  "show --output, then sh"                 "$R"   'git show --format="git push origin main%n" --output=x.sh HEAD && sh x.sh'
expect deny  "diff is not inert: its words count"     "$R"   'git diff --output=x.sh -- "git push" && sh x.sh'
expect deny  "stash list takes log options"           "$R"   'git stash list --format="git push origin main" --output=x.sh && sh x.sh'
expect allow "add, then a commit message about docs"  "$R"   'git add f && git commit -m "push docs"'
# git takes any unambiguous prefix of a long option, and a short option inside a bundle.
expect deny  "an abbreviated --upload-pa=<cmd>"       "$R"   "git status && git ls-remote --upload-pa=\"sh -c 'git push origin main'\" ."
expect deny  "an abbreviated --upload-pa <cmd>"       "$R"   "git status && git ls-remote --upload-pa \"sh -c 'git push origin main'\" ."
expect deny  "grep -nO<cmd>, -O inside a bundle"      "$R"   "git status && git grep -nO\"sh -c 'git push origin main'\" x -- README.md"
expect deny  "fetch -qu <cmd>, -u inside a bundle"    "$R"   "git status && git fetch -qu \"sh -c 'git push'\" origin"
expect deny  "config planting uploadpack, then fetch" "$R"   "git status && git config remote.origin.uploadpack \"sh -c 'git push'\" && git fetch origin"
expect deny  "rebase -ix running a push, after add"   "$R"   'git add f && git rebase -ix "git push" main'
# Only a flat list of simple commands is redacted: operators && || ; | alone, redirects only
# to /dev/null or between descriptors, no shell keyword as a command word. Anything else
# (a group, a loop, a newline, a background job, |&, a file redirect) is read raw.
expect allow "a wc over two files"                    "$R"   'wc -l a b'
expect deny  "a subshell of echo piped to sh"         "$R"   '(echo "git push origin main") | sh'
expect deny  "a { } group of echo piped to sh"        "$R"   '{ echo "git push origin main"; } | sh'
expect deny  "a subshell of echo written, then run"   "$R"   '(echo "git push origin main") > x.sh && sh x.sh'
expect deny  "echo piped over a newline to sh"        "$R"   'echo "git push origin main" |
sh'
expect deny  "echo in the background, then sh"        "$R"   'echo "git push origin main" & sh x.sh'
expect deny  "echo written to a file, then sh"        "$R"   'echo "git push" > x.sh; sh x.sh'
expect deny  "an if around echo, piped to sh"         "$R"   'if true; then echo "git push origin main"; fi | sh'
expect deny  "echo piped with |& to sh"               "$R"   'echo "git push origin main" |& sh'
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
expect deny  "sort -o writing a file that sh runs"    "$R"   'echo "git push origin main" | sort -o x.sh && sh x.sh'
expect deny  "an abbreviated sort --outp=<file>"      "$R"   'echo "git push origin main" | sort --outp=x.sh && sh x.sh'
expect deny  "uniq writing its second operand"        "$R"   'echo "git push origin main" | uniq - x.sh && sh x.sh'
expect allow "sort with no output file stays inert"   "$R"   'rg -n "git push" docs | sort'
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

echo "== rule 4: merged-branch deletes =="
# A remote of its own, so the cases that move it never touch the fixtures above. done and
# done2 are merged into main, here and on the remote; open is not merged; v1 is a tag; gone
# exists only here. The cases that move the remote run last.
git init -q --bare "$REMOTES/del.git"
DEL="$TMP/delwork"
git init -q "$DEL"
git -C "$DEL" commit -q --allow-empty -m init
git -C "$DEL" remote add origin "$REMOTES/del.git"
git -C "$DEL" switch -q -c done;  git -C "$DEL" commit -q --allow-empty -m done
git -C "$DEL" switch -q -c done2; git -C "$DEL" commit -q --allow-empty -m done2
git -C "$DEL" switch -q main;     git -C "$DEL" merge -q --ff-only done2
git -C "$DEL" switch -q -c open;  git -C "$DEL" commit -q --allow-empty -m open
git -C "$DEL" switch -q -c gone main; git -C "$DEL" commit -q --allow-empty -m gone
git -C "$DEL" tag v1 main
git -C "$DEL" switch -q -c work main
git -C "$DEL" push -q origin main done done2 open v1 2>/dev/null
git -C "$DEL" remote set-head origin main
DONE=$(git -C "$DEL" rev-parse done); DONE2=$(git -C "$DEL" rev-parse done2)
OPEN=$(git -C "$DEL" rev-parse open); MAIN=$(git -C "$DEL" rev-parse main)
GONE=$(git -C "$DEL" rev-parse gone)
[ "$(git -C "$DEL" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" = origin/main ] \
  && [ -n "$(git ls-remote "$REMOTES/del.git" refs/heads/done)" ] \
  || { echo "merged-delete fixture setup failed" >&2; exit 1; }

expect allow "a merged delete pinned, by --delete"        "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
expect allow "a merged delete pinned, by -d"              "$DEL" "git push --force-with-lease=done:$DONE origin -d done"
expect allow "a merged delete pinned, by a :ref refspec"  "$DEL" "git push --force-with-lease=done:$DONE origin :done"
expect allow "a refs/heads/ lease"                        "$DEL" "git push --force-with-lease=refs/heads/done:$DONE origin --delete done"
expect allow "a refs/heads/ destination"                  "$DEL" "git push --force-with-lease=done:$DONE origin --delete refs/heads/done"
expect allow "options after the branch"                   "$DEL" "git push origin --delete done --force-with-lease=done:$DONE"
expect allow "two merged deletes, both pinned"            "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=done2:$DONE2 origin --delete done done2"
expect deny  "a merged delete with no pin"                "$DEL" 'git push origin --delete done'
has_reason   "the deny names the pinned command" \
             "git push --force-with-lease=done:$DONE origin --delete done" "$DEL" 'git push origin --delete done'
# The pinned command is the plain git push form: the classifier rule names only that form
# (spec 2026-10-28, section 2, printed commands). A push into another checkout than the
# session's (the toplevel of the payload's cwd; $TMP is in no repository) names that checkout
# instead, and says the delete must run from there or Michael runs it. git prints the toplevel
# with symlinks resolved. A -C push is not bare, so its deny also says a merged delete passes
# only in plain words (PLAIN_LEAD).
cp -R "$DEL" "$TMP/del work"
DELTOP=$(git -C "$DEL" rev-parse --show-toplevel)
SPACETOP=$(git -C "$TMP/del work" rev-parse --show-toplevel)
PLAIN_LEAD="Push guard: a merged delete passes only when written in plain words: git push and its arguments, each made of letters, digits and ._/:=@+,%- (none starting with =, holding == or :=, or shaped NAME= or NAME+=), separated by single spaces, nothing before git, and at most 2>&1 and | tail or | head with -n N or -N after."
RUN_HERE="and here. Pin the delete to the tip just read, so git refuses it if the branch has moved, and it needs no ask: git push --force-with-lease=done:$DONE origin --delete done"
RUN_THERE="which is not this session's checkout. Pin the delete to the tip just read, so git refuses it if the branch has moved; the delete must run from that checkout, or Michael runs it: git push --force-with-lease=done:$DONE origin --delete done"
has_reason   "a -C push from outside the checkout: the deny names it and who runs the delete" \
             "$PLAIN_LEAD done is merged into main, on origin and in $DELTOP, $RUN_THERE" \
             "$TMP" "git -C $DEL push origin --delete done"
lacks_reason "and it prints no git -C form" "git -C" "$TMP" "git -C $DEL push origin --delete done"
has_reason   "and quotes a checkout path that needs it" \
             "$PLAIN_LEAD done is merged into main, on origin and in '$SPACETOP', $RUN_THERE" \
             "$TMP" "git -C '$TMP/del work' push origin --delete done"
lacks_reason "and prints no git -C form for it either" "git -C" "$TMP" "git -C '$TMP/del work' push origin --delete done"
has_reason   "a -C push from another repository names the checkout it runs in" \
             "on origin and in $DELTOP, $RUN_THERE" "$TMP/del work" "git -C $DEL push origin --delete done"
has_reason   "a -C push into the session's own checkout prints the plain pinned command" \
             "$PLAIN_LEAD done is merged into main, on origin $RUN_HERE" "$DEL" "git -C $DEL push origin --delete done"
# The session's toplevel only words the deny and never decides it: a lookup that hangs past
# the per-call limit (5 s) counts the push's checkout as another one, and the deny stands.
SLOWTOP="$TMP/slowtop"; mkdir -p "$SLOWTOP"
printf '#!/bin/sh\ncase "$*" in *"-C %s rev-parse --show-toplevel"*) exec sleep 6 ;; esac\nexec "%s" "$@"\n' \
  "$TMP" "$(command -v git)" > "$SLOWTOP/git"
chmod 755 "$SLOWTOP/git"
PATH="$SLOWTOP:$PATH" expect deny "a session lookup that times out leaves the deny standing" "$TMP" "git -C $DEL push origin --delete done"
expect deny  "a bare --force-with-lease"                  "$DEL" 'git push --force-with-lease origin --delete done'
expect deny  "a lease without a sha"                      "$DEL" 'git push --force-with-lease=done origin --delete done'
expect deny  "a pin to another sha"                       "$DEL" "git push --force-with-lease=done:$OPEN origin --delete done"
expect deny  "two leases on one branch, one wrong"        "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=done:$OPEN origin --delete done"
has_reason   "a partly pinned pair: the command pins both" \
             "git push --force-with-lease=done:$DONE --force-with-lease=done2:$DONE2 origin --delete done done2" \
             "$DEL" "git push --force-with-lease=done:$DONE origin --delete done done2"
expect ask   "an unmerged branch, pinned"                 "$DEL" "git push --force-with-lease=open:$OPEN origin --delete open"
expect ask   "a merged and an unmerged branch"            "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=open:$OPEN origin --delete done open"
expect ask   "the default branch, pinned"                 "$DEL" "git push --force-with-lease=main:$MAIN origin --delete main"
expect ask   "the default branch as refs/heads/main"      "$DEL" "git push --force-with-lease=main:$MAIN origin --delete refs/heads/main"
expect ask   "a tag by name"                              "$DEL" "git push --force-with-lease=v1:$MAIN origin --delete v1"
expect ask   "a tag by ref"                               "$DEL" 'git push origin :refs/tags/v1'
expect ask   "a branch missing on the remote"             "$DEL" "git push --force-with-lease=gone:$GONE origin --delete gone"
expect ask   "--prune beside a pinned delete"             "$DEL" "git push --prune --force-with-lease=done:$DONE origin :done"
expect ask   "--force beside a pinned delete"             "$DEL" "git push --force --force-with-lease=done:$DONE origin --delete done"
expect ask   "a delete mixed with a push"                 "$DEL" "git push --force-with-lease=done:$DONE origin :done work"
DBROKEN=$(cp -R "$DEL" "$TMP/delbroken" && printf '%s' "$TMP/delbroken")
git -C "$DBROKEN" remote set-url origin "$REMOTES/nowhere.git"
expect ask   "a remote that cannot be read"               "$DBROKEN" "git push --force-with-lease=done:$DONE origin --delete done"
cp -R "$REMOTES/del.git" "$REMOTES/delhead.git"
git --git-dir="$REMOTES/delhead.git" symbolic-ref HEAD refs/heads/done2
DHEAD=$(cp -R "$DEL" "$TMP/delhead" && printf '%s' "$TMP/delhead")
git -C "$DHEAD" remote set-url origin "$REMOTES/delhead.git"
expect ask   "the remote's HEAD names another branch"     "$DHEAD" "git push --force-with-lease=done:$DONE origin --delete done"
# A local check that times out after ls-remote has answered asks, as before, rather than
# denying: a git on PATH that hangs on merge-base until the guard's per-call limit (5 s).
SLOWGIT="$TMP/slowgit"; mkdir -p "$SLOWGIT"; REALGIT=$(command -v git)
printf '#!/bin/sh\ncase "$*" in *merge-base*) exec sleep 6 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$SLOWGIT/git"
chmod 755 "$SLOWGIT/git"
PATH="$SLOWGIT:$PATH" expect ask "a merge-base that times out" "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
DPUSH=$(cp -R "$DEL" "$TMP/delpushurl" && printf '%s' "$TMP/delpushurl")
git -C "$DPUSH" config remote.origin.pushurl "$REMOTES/backup.git"
expect deny  "a remote with a separate push URL is still refused" "$DPUSH" "git push --force-with-lease=done:$DONE origin --delete done"
expect deny  "a bare --force-with-lease beside the pin"   "$DEL" "git push --force-with-lease --force-with-lease=done:$DONE origin --delete done"
expect deny  "a heads/ lease beside the pin"              "$DEL" "git push --force-with-lease=heads/done --force-with-lease=done:$DONE origin --delete done"
expect deny  "a lease for an unrelated branch beside the pin" "$DEL" "git push --force-with-lease=other:$DONE --force-with-lease=done:$DONE origin --delete done"
expect ask   "--tags beside a pinned delete"              "$DEL" "git push --tags --force-with-lease=done:$DONE origin --delete done"
expect ask   "--follow-tags beside a pinned delete"       "$DEL" "git push --follow-tags --force-with-lease=done:$DONE origin --delete done"

# The guard's read of the remote runs outside the sandbox, where git honours any command a
# config file names. None of these may run one, and a config that would only break the read
# must not stop it.
DSSH=$(cp -R "$DEL" "$TMP/delssh" && printf '%s' "$TMP/delssh")
git -C "$DSSH" config core.sshCommand false
expect ask   "core.sshCommand is set"                     "$DSSH" "git push --force-with-lease=done:$DONE origin --delete done"
DPROXY=$(cp -R "$DEL" "$TMP/delproxy" && printf '%s' "$TMP/delproxy")
git -C "$DPROXY" config core.gitProxy false
expect ask   "core.gitProxy is set"                       "$DPROXY" "git push --force-with-lease=done:$DONE origin --delete done"
DUP=$(cp -R "$DEL" "$TMP/delupload" && printf '%s' "$TMP/delupload")
git -C "$DUP" config remote.origin.uploadpack /nonexistent/upload-pack
expect allow "remote.origin.uploadpack is overridden"     "$DUP" "git push --force-with-lease=done:$DONE origin --delete done"
DEXT=$(cp -R "$DEL" "$TMP/delext" && printf '%s' "$TMP/delext")
EXTMARK="$TMP/ext-marker"
git -C "$DEXT" config protocol.ext.allow always
git -C "$DEXT" config "url.ext::touch $EXTMARK.insteadOf" "$REMOTES/del.git"
expect ask   "an ext:: remote built by insteadOf"         "$DEXT" "git push --force-with-lease=done:$DONE origin --delete done"
if [ -e "$EXTMARK" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the ext:: command ran (the guard's read of the remote executed it)"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the ext:: command did not run"
fi
# A protocol.<name>.allow in config outranks the generic override, so a git-remote-<name>
# helper on PATH would run for a foo:// URL, or for any URL once remote.<name>.vcs names it.
HELPERS="$TMP/helpers"; mkdir -p "$HELPERS"
for h in foo bar; do
  printf '#!/bin/sh\ntouch "%s/%s-marker"\nexit 1\n' "$TMP" "$h" > "$HELPERS/git-remote-$h"
  chmod 755 "$HELPERS/git-remote-$h"
done
DFOO=$(cp -R "$DEL" "$TMP/delfoo" && printf '%s' "$TMP/delfoo")
git -C "$DFOO" config protocol.foo.allow always
git -C "$DFOO" config "url.foo://host/del.git.insteadOf" "$REMOTES/del.git"
PATH="$HELPERS:$PATH" expect ask "a foo:// remote with a helper allowed in config" "$DFOO" "git push --force-with-lease=done:$DONE origin --delete done"
if [ -e "$TMP/foo-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the foo helper ran (the guard's read of the remote executed it)"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the foo helper did not run"
fi
DVCS=$(cp -R "$DEL" "$TMP/delvcs" && printf '%s' "$TMP/delvcs")
git -C "$DVCS" config remote.origin.vcs bar
git -C "$DVCS" config protocol.bar.allow always
PATH="$HELPERS:$PATH" expect ask "remote.origin.vcs names a helper" "$DVCS" "git push --force-with-lease=done:$DONE origin --delete done"
if [ -e "$TMP/bar-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the bar helper ran (remote.origin.vcs selected it)"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the bar helper did not run"
fi
DGIT=$(cp -R "$DEL" "$TMP/delgit" && printf '%s' "$TMP/delgit")
git -C "$DGIT" remote set-url origin git://127.0.0.1:9/del.git
expect ask   "a git:// remote"                            "$DGIT" "git push --force-with-lease=done:$DONE origin --delete done"

# A branch that is a symref on the remote is not a branch to delete.
cp -R "$REMOTES/del.git" "$REMOTES/delsym.git"
git --git-dir="$REMOTES/delsym.git" symbolic-ref refs/heads/alias refs/heads/main
DSYM=$(cp -R "$DEL" "$TMP/delsym" && printf '%s' "$TMP/delsym")
git -C "$DSYM" remote set-url origin "$REMOTES/delsym.git"
expect ask   "a branch that is a symref on the remote"    "$DSYM" "git push --force-with-lease=alias:$MAIN origin --delete alias"
# Protocol v0 does not advertise a non-HEAD symref, so the guard pins version 2 itself.
DSYM0=$(cp -R "$DSYM" "$TMP/delsym0" && printf '%s' "$TMP/delsym0")
git -C "$DSYM0" config protocol.version 0
expect ask   "a symref, with protocol.version=0 in config" "$DSYM0" "git push --force-with-lease=alias:$MAIN origin --delete alias"

# Merged into the local default branch, but not into the remote's.
cp -R "$REMOTES/del.git" "$REMOTES/delloc.git"
DLOC=$(cp -R "$DEL" "$TMP/delloc" && printf '%s' "$TMP/delloc")
git -C "$DLOC" remote set-url origin "$REMOTES/delloc.git"
git -C "$DLOC" switch -q -c lm main
git -C "$DLOC" commit -q --allow-empty -m lm
git -C "$DLOC" push -q origin lm 2>/dev/null
git -C "$DLOC" switch -q main && git -C "$DLOC" merge -q --ff-only lm
LM=$(git -C "$DLOC" rev-parse lm)
expect ask   "merged here but not on the remote"          "$DLOC" "git push --force-with-lease=lm:$LM origin --delete lm"

# History a write inside the sandbox can rewrite must not make an unmerged branch look merged:
# a replacement of, or a graft on, the default tip that adds open's tip as a parent.
DREP=$(cp -R "$DEL" "$TMP/delreplace" && printf '%s' "$TMP/delreplace")
git -C "$DREP" replace --graft "$MAIN" "$DONE" "$OPEN"
expect ask   "an unmerged branch made an ancestor by git replace" "$DREP" "git push --force-with-lease=open:$OPEN origin --delete open"
DGRAFT=$(cp -R "$DEL" "$TMP/delgraft" && printf '%s' "$TMP/delgraft")
printf '%s %s %s\n' "$MAIN" "$DONE" "$OPEN" > "$DGRAFT/.git/info/grafts"
expect ask   "an unmerged branch made an ancestor by info/grafts" "$DGRAFT" "git push --force-with-lease=open:$OPEN origin --delete open"

# The pinned command in the deny is a command to run, so a branch name with a quote or a
# semicolon in it must come back as that one argument. Such a name needs quoting, which
# canonical text (plain words) cannot carry, so the deny says Michael runs it, and the quoted
# command itself is denied rather than passed.
DQ=$(cp -R "$DEL" "$TMP/delquote" && printf '%s' "$TMP/delquote")
cp -R "$REMOTES/del.git" "$REMOTES/delquote.git"
git -C "$DQ" remote set-url origin "$REMOTES/delquote.git"
git -C "$DQ" switch -q -c "o'brien" main; git -C "$DQ" commit -q --allow-empty -m quote
git -C "$DQ" switch -q -c "a;b";         git -C "$DQ" commit -q --allow-empty -m semi
git -C "$DQ" switch -q main && git -C "$DQ" merge -q --ff-only "a;b"
git -C "$DQ" push -q origin main "o'brien" "a;b" 2>/dev/null
QUOTE_TIP=$(git -C "$DQ" rev-parse "o'brien"); SEMI_TIP=$(git -C "$DQ" rev-parse "a;b")
QCMD="git push origin --delete \"o'brien\" 'a;b'"
QREASON=$(reason "$DQ" "$QCMD")
QPINNED=${QREASON##*so Michael runs it: }
QGOT=$(python3 -I -c 'import shlex, sys; print("\n".join(shlex.split(sys.argv[1])))' "$QPINNED" 2>&1)
QWANT=$(printf '%s\n' git push "--force-with-lease=o'brien:$QUOTE_TIP" "--force-with-lease=a;b:$SEMI_TIP" origin --delete "o'brien" "a;b")
if [ "$QGOT" = "$QWANT" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "the deny's command parses to the intended argv for quote and semicolon names"
else
  fail=$((fail + 1)); printf '  FAIL %s\n%s\n' "the deny's command does not parse to the intended argv" "$QREASON"
fi
has_reason   "the deny says the quoted names need Michael" \
             "A name here needs quoting, which plain words cannot carry, so Michael runs it: " "$DQ" "$QCMD"
expect deny  "the quoted pinned command is not plain words: denied" "$DQ" "$QPINNED"
has_reason   "and that deny says Michael runs it too" "so Michael runs it: " "$DQ" "$QPINNED"

# A remote-tracking ref pointing at a missing object, plus a promisor remote whose
# uploadpack writes a marker: the guard's own git calls must never lazy-fetch (spec
# 2026-10-16, sandbox write boundary, section 2). The verdict is the usual one for a
# dangling ref (the outgoing commits cannot be listed: deny), and no marker appears.
LAZY=$(cp -R "$DEL" "$TMP/dellazy" && printf '%s' "$TMP/dellazy")
git -C "$LAZY" switch -q work
git -C "$LAZY" commit -q --allow-empty -m "lazy work"
printf '%s\n' 1111111111111111111111111111111111111111 > "$LAZY/.git/refs/remotes/origin/ghost"
git -C "$LAZY" config remote.origin.promisor true
git -C "$LAZY" config remote.origin.partialclonefilter blob:none
git -C "$LAZY" config remote.origin.uploadpack "touch $TMP/lazy-marker; git-upload-pack"
expect deny "a dangling remote ref with a promisor remote" "$LAZY" 'git push origin work'
if [ -e "$TMP/lazy-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the guard lazy-fetched through the promisor remote"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the guard never lazy-fetches"
fi
# The guard's PATH is pinned: a git first on the caller's PATH must never run.
EVIL="$TMP/evilbin"; mkdir -p "$EVIL"
printf '#!/bin/sh\ntouch "%s/evil-marker"\nexec /usr/bin/git "$@"\n' "$TMP" > "$EVIL/git"; chmod 755 "$EVIL/git"
PINNED_OUT=$( PATH="$EVIL:$PATH"; unset PINNED_PATH
  jq -n --arg c 'git push origin work' --arg d "$LAZY" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | bash "$GUARD" )
if [ -e "$TMP/evil-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the guard ran a git from the caller's PATH"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the guard's PATH is pinned"
fi
# ...and the pin costs the guard nothing: its verdict is the usual one (the same deny
# the suite's own PATH gets for this repository).
if [ -n "$PINNED_OUT" ] && [ "$PINNED_OUT" = "$(run "$LAZY" 'git push origin work')" ] \
   && printf '%s' "$PINNED_OUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok   %s\n' "under the pinned PATH the verdict is the usual deny"
else
  fail=$((fail + 1)); printf '  FAIL %s (said: %s)\n' "under the pinned PATH the verdict is not the usual deny" "$PINNED_OUT"
fi

# Lazy fetch is off for the patch listing and gitleaks too: the repository's configuration
# stays agent-writable, so a promisor remote is never trusted. The outgoing commit's tree
# names a blob that is not present (git mktree --missing), so reading its patch would fetch
# it from the promisor remote, whose uploadpack writes a marker. The push is denied (the
# outgoing patches cannot be read: push by hand) and no marker appears.
LAZYB=$(cp -R "$DEL" "$TMP/dellazyblob" && printf '%s' "$TMP/dellazyblob")
git -C "$LAZYB" switch -q work
MISSING_TREE=$(printf '100644 blob 2222222222222222222222222222222222222222\tghost.txt\n' \
  | git -C "$LAZYB" mktree --missing)
MISSING_COMMIT=$(git -C "$LAZYB" commit-tree "$MISSING_TREE" -p "$(git -C "$LAZYB" rev-parse work)" -m "missing blob")
git -C "$LAZYB" update-ref refs/heads/work "$MISSING_COMMIT"
git -C "$LAZYB" config remote.origin.promisor true
git -C "$LAZYB" config remote.origin.partialclonefilter blob:none
git -C "$LAZYB" config remote.origin.uploadpack "touch $TMP/lazyblob-marker; git-upload-pack"
expect deny "an outgoing commit naming a missing blob, with a promisor remote" "$LAZYB" 'git push origin work'
has_reason  "and the deny says to push by hand" "Push by hand" "$LAZYB" 'git push origin work'
if [ -e "$TMP/lazyblob-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the patch listing lazy-fetched through the promisor remote"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the patch listing never lazy-fetches"
fi

# Rule 4's silent pass of a merged, pinned delete (spec 2026-10-28, section 2). The classifier
# rule trusts it, so the words the guard verifies must be the words the shell runs: the pass
# needs canonical text (git push and plain words separated by single spaces, then at most one
# trailer), with no wrapper, assignment, cd prefix or global option before push. Merged and
# pinned in any other text, the delete is denied with the plain pinned command printed. work
# is checked out at main's tip and is not on the remote, so a push of it scans clean.
PLAIN_REASON="Push guard: this command may run git push in a shape the guard does not check. Run the push as a plain command of its own: git push [options] <remote> <branch> (for another repository: git -C <path> push [options] <remote> <branch>; piped only to tail or head). If the command does not push, keep git and push apart in its text, for example rg 'git pu[s]h'."
PINNED="git push --force-with-lease=done:$DONE origin --delete done"
PLAIN_NOTE="$PLAIN_LEAD done is merged into main, on origin $RUN_HERE"
# Canonical: the merged, pinned delete passes with each trailer, and with outer spaces and one
# trailing newline (at most one trailing newline is removed, then leading and trailing
# spaces). Any other newline is not canonical (a leading one, or a second at the end, is not
# plain to the grammar either, so the deny is the plain-command one).
for trailer in '' ' 2>&1' ' | tail -n 3' ' | head -n 3' ' 2>&1 | tail -n 3' ' 2>&1 | head -n 3' \
               ' | tail -3' ' | head -5' ' 2>&1 | tail -3' ' 2>&1 | head -5'; do
  expect allow "C1 canonical, merged and pinned, trailer [$trailer]"   "$DEL" "$PINNED$trailer"
done
expect allow "C1 canonical, with outer spaces and one trailing newline" "$DEL" "  $PINNED  "$'\n'
expect deny  "C1 a leading newline is not canonical"                    "$DEL" $'\n'"$PINNED"
expect deny  "C1 two trailing newlines are not canonical"               "$DEL" "$PINNED"$'\n\n'
expect deny  "C1 a space after the trailing newline is not canonical"   "$DEL" "  $PINNED  "$'\n '
has_reason   "C1 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "  $PINNED  "$'\n '
expect deny  "C1 a newline, a space and a newline at the end"           "$DEL" "$PINNED"$'\n \n'
# Anything else is not canonical: a merged, pinned delete gets the deny naming the plain
# pinned form, and the note that it must be written in plain words.
expect deny  "C2 a tail with no count is not a canonical trailer"       "$DEL" "$PINNED 2>&1 | tail"
has_reason   "C2 and the deny names the plain form in plain words" "$PLAIN_NOTE" "$DEL" "$PINNED 2>&1 | tail"
expect deny  "C2 a line continuation is not canonical"                  "$DEL" "git push --force-with-lease=done:$DONE origin \\
--delete done"
has_reason   "C2 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "git push --force-with-lease=done:$DONE origin \\
--delete done"
expect deny  "C2 two spaces between words are not canonical"            "$DEL" "git push --force-with-lease=done:$DONE  origin --delete done"
expect deny  "C2 a tab between words is not canonical"                  "$DEL" "$(printf 'git push --force-with-lease=done:%s\torigin --delete done' "$DONE")"
expect deny  "C2 a quoted first word is not canonical"                  "$DEL" "\"git\" push --force-with-lease=done:$DONE origin --delete done"
has_reason   "C2 and the deny names the plain form in plain words" "$PLAIN_NOTE" "$DEL" "\"git\" push --force-with-lease=done:$DONE origin --delete done"
expect deny  "C2 a quoted branch name is not canonical"                 "$DEL" "git push --force-with-lease=done:$DONE origin --delete 'done'"
has_reason   "C2 and the deny names the plain form in plain words" "$PLAIN_NOTE" "$DEL" "git push --force-with-lease=done:$DONE origin --delete 'done'"
# One case per class the final review's rounds found, each on a merged pinned delete: a glob
# or bracket in an option value, a quoted or escaped operator, NUL, CR, NBSP, $, `, ~, a
# leading = and a brace. Every one is denied.
C3_DONE="git push --force-with-lease=done:$DONE"
expect deny  "C3 a glob in an -o value"                                 "$DEL" "$C3_DONE -o ci.variable=X=* origin --delete done"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$C3_DONE -o ci.variable=X=* origin --delete done"
expect deny  "C3 a glob in a --push-option value"                       "$DEL" "$C3_DONE --push-option ci.variable=X=* origin --delete done"
expect deny  "C3 brackets around a quoted blank in an -o value"         "$DEL" "$C3_DONE -o ci.variable=X=[ab' '] origin --delete done"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$C3_DONE -o ci.variable=X=[ab' '] origin --delete done"
expect deny  "C3 a quoted operator"                                     "$DEL" "$PINNED '|' tail"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$PINNED '|' tail"
expect deny  "C3 an escaped pipe"                                       "$DEL" "$PINNED 2>&1 \\| tail"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$PINNED 2>&1 \\| tail"
expect deny  "C3 an escaped redirect and pipe"                          "$DEL" "$PINNED 2 \\>\\& 1 \\| tail"
# bash cannot hold a NUL in a variable, so this payload is written with a JSON \u0000 escape.
C3_NUL=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s -o ci.variable=X=a\\u0000 origin --delete done"}}' "$DEL" "$C3_DONE" \
  | PINNED_PATH="$PATH" bash "$GUARD")
if printf '%s' "$C3_NUL" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok   %s\n' "C3 a NUL in an -o value"
else
  fail=$((fail + 1)); printf '  FAIL %s (want deny, got %s)\n' "C3 a NUL in an -o value" "${C3_NUL:-allow}"
fi
expect deny  "C3 a carriage return in an -o value"                      "$DEL" "$(printf '%s -o ci.variable=X=a\r origin --delete done' "$C3_DONE")"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$(printf '%s -o ci.variable=X=a\r origin --delete done' "$C3_DONE")"
expect deny  "C3 a no-break space in an -o value"                       "$DEL" "$(printf '%s -o ci.variable=X=a\302\240 origin --delete done' "$C3_DONE")"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$(printf '%s -o ci.variable=X=a\302\240 origin --delete done' "$C3_DONE")"
# A $ is denied before the merge is read, as on main: the shell expands the word (dynamic),
# so the guard cannot say which delete runs. A backtick makes the command not a plain one at
# all, as on main.
EXPANDS="which the shell expands before git sees it"
expect deny  "C3 a \$ in an -o value"                                   "$DEL" "$C3_DONE -o ci.variable=X=\$HOME origin --delete done"
has_reason   "C3 and the deny says the shell expands it" "$EXPANDS" "$DEL" "$C3_DONE -o ci.variable=X=\$HOME origin --delete done"
expect deny  "C3 a backtick in an -o value"                             "$DEL" "$C3_DONE -o ci.variable=X=\`id\` origin --delete done"
has_reason   "C3 and the reason is the plain-command one" "$PLAIN_REASON" "$DEL" "$C3_DONE -o ci.variable=X=\`id\` origin --delete done"
expect deny  "C3 a ~ in an -o value"                                    "$DEL" "$C3_DONE -o ci.variable=X=~ origin --delete done"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$C3_DONE -o ci.variable=X=~ origin --delete done"
expect deny  "C3 a brace around a quoted blank in an -o value"          "$DEL" "$C3_DONE -o ci.variable=X={a,' '} origin --delete done"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$C3_DONE -o ci.variable=X={a,' '} origin --delete done"
# A word starting with = is not canonical: zsh, the Bash tool's shell, expands =x to the path
# of a command x (EQUALS). A command a deny prints quotes such a word ('=x'), so it runs as
# written in zsh; its lease holds == and is quoted too (MAGIC_EQUAL_SUBST, below). =e is a
# branch at main's tip, merged, on the remote.
git -C "$DEL" branch =e main && git -C "$DEL" push -q origin =e 2>/dev/null
C3_EQ_DEL="git push --force-with-lease==e:$MAIN origin --delete =e"
expect deny  "C3 the pinned delete of a merged branch named =e"         "$DEL" "$C3_EQ_DEL"
has_reason   "C3 and the printed delete quotes the name" \
             "A name here needs quoting, which plain words cannot carry, so Michael runs it: git push '--force-with-lease==e:$MAIN' origin --delete '=e'" "$DEL" "$C3_EQ_DEL"
# A word holding == or := is not canonical: zsh's MAGIC_EQUAL_SUBST expands the text after the
# = (x==ls is x=/bin/ls, X:=ls is X:/bin/ls). Off today, but with it set a canonical delete of
# the merged x==ls deleted the unmerged x=/bin/ls (the final review measured it). A word shaped
# NAME= or NAME+= is not canonical either: bash's set -k moves it into the environment. x==ls
# and a=b are branches at main's tip, merged, on the remote.
git -C "$DEL" branch 'x==ls' main && git -C "$DEL" push -q origin 'x==ls' 2>/dev/null
git -C "$DEL" branch 'a=b' main && git -C "$DEL" push -q origin 'a=b' 2>/dev/null
C3_EQEQ="git push --force-with-lease=x==ls:$MAIN origin --delete x==ls"
expect deny  "C3 the pinned delete of a merged branch named x==ls"      "$DEL" "$C3_EQEQ"
has_reason   "C3 and the printed delete quotes the == words" \
             "A name here needs quoting, which plain words cannot carry, so Michael runs it: git push '--force-with-lease=x==ls:$MAIN' origin --delete 'x==ls'" "$DEL" "$C3_EQEQ"
C3_COLEQ="$C3_DONE -o ci.variable=X:=ls origin --delete done"
expect deny  "C3 a := in an -o value"                                   "$DEL" "$C3_COLEQ"
has_reason   "C3 and the deny names the plain form" "$PLAIN_NOTE" "$DEL" "$C3_COLEQ"
C3_NAME="git push --force-with-lease=a=b:$MAIN origin --delete a=b"
expect deny  "C3 the pinned delete of a merged branch named a=b"        "$DEL" "$C3_NAME"
has_reason   "C3 and the printed delete quotes the name" \
             "A name here needs quoting, which plain words cannot carry, so Michael runs it: git push --force-with-lease=a=b:$MAIN origin --delete 'a=b'" "$DEL" "$C3_NAME"
expect allow "C3 control: a refs/heads/ name holding = stays canonical" "$DEL" "git push --force-with-lease=refs/heads/a=b:$MAIN origin --delete refs/heads/a=b"
# The remote word: a path or a URL is not a configured remote, as on main.
expect deny  "C4 a delete to a path that is not a configured remote"    "$DEL" "$C3_DONE $REMOTES/del.git origin --delete done"
has_reason   "C4 and the deny says so" "which is not a configured remote" "$DEL" "$C3_DONE $REMOTES/del.git origin --delete done"
expect deny  "C4 a delete to a URL that is not a configured remote"     "$DEL" "$C3_DONE file://$REMOTES/del.git --delete done"
has_reason   "C4 and the deny says so" "which is not a configured remote" "$DEL" "$C3_DONE file://$REMOTES/del.git --delete done"
# Merged and pinned behind -C, another global option, an assignment, a wrapper or a cd
# prefix: not bare, so denied with the plain pinned form printed. From $TMP (no checkout) the
# deny names the checkout the push runs in and says who runs the delete; it never prints a
# git -C form, which the classifier rule does not name.
expect deny  "B1 -C from outside the checkout"                          "$TMP" "git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
has_reason   "B1 and the deny names the checkout and who runs the delete" \
             "$PLAIN_LEAD done is merged into main, on origin and in $DELTOP, $RUN_THERE" \
             "$TMP" "git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B1 -C through a path with a space"                        "$TMP" "git -C '$TMP/del work' push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B1 -C into the session's own checkout"                    "$DEL" "git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
has_reason   "B1 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 --no-pager after -C"                                   "$TMP" "git -C $DEL --no-pager push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 --no-pager alone"                                      "$DEL" "git --no-pager push --force-with-lease=done:$DONE origin --delete done"
has_reason   "B2 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "git --no-pager push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 --exec-path"                                           "$TMP" "git -C $DEL --exec-path=$TMP push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 a second -C"                                           "$TMP" "git -C $DEL -C $DEL push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 GIT_EXEC_PATH before git -C"                           "$TMP" "GIT_EXEC_PATH=$TMP git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 a command wrapper before git -C"                       "$TMP" "command git -C $DEL push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B2 -c x.y=z after -C keeps main's deny"                   "$TMP" "git -C $DEL -c x.y=z push --force-with-lease=done:$DONE origin --delete done"
has_reason   "B2 and it is the unsupported-configuration deny" "unsupported push configuration" "$TMP" "git -C $DEL -c x.y=z push --force-with-lease=done:$DONE origin --delete done"
expect deny  "B3 a command wrapper"                                     "$DEL" "command $PINNED"
has_reason   "B3 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "command $PINNED"
expect deny  "B3 a leading GIT_EXEC_PATH"                               "$DEL" "GIT_EXEC_PATH=$TMP $PINNED"
has_reason   "B3 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "GIT_EXEC_PATH=$TMP $PINNED"
expect deny  "B4 a cd prefix from outside the checkout"                 "$TMP" "cd $DEL && $PINNED"
has_reason   "B4 and the deny names the checkout and who runs the delete" "in $DELTOP, $RUN_THERE" "$TMP" "cd $DEL && $PINNED"
lacks_reason "B4 and it prints no git -C form" "git -C" "$TMP" "cd $DEL && $PINNED"
expect deny  "B4 a cd prefix and an unpinned delete"                    "$TMP" "cd $DEL && git push --force-with-lease=done origin --delete done"
has_reason   "B4 and the deny names the checkout and the pinned command" "in $DELTOP, $RUN_THERE" "$TMP" "cd $DEL && git push --force-with-lease=done origin --delete done"
expect deny  "B4 a cd to the session's own checkout"                    "$DEL" "cd $DEL && $PINNED"
has_reason   "B4 and the deny names the plain pinned command" "$PLAIN_NOTE" "$DEL" "cd $DEL && $PINNED"
expect deny  "B4 a cd to another checkout"                              "$DEL" "cd '$TMP/del work' && $PINNED"
has_reason   "B4 and the deny says the delete runs from that checkout, or Michael runs it" "in '$SPACETOP', $RUN_THERE" "$DEL" "cd '$TMP/del work' && $PINNED"
lacks_reason "B4 and it prints no git -C form" "git -C" "$DEL" "cd '$TMP/del work' && $PINNED"
# Not bare never turns main's ask into a deny: an unmerged branch still asks.
expect ask   "an unmerged branch behind -C and --no-pager still asks"   "$TMP" "git -C $DEL --no-pager push --force-with-lease=open:$OPEN origin --delete open"
expect deny  "an option value that swallowed --delete"                  "$DEL" "git push --force-with-lease=work:$MAIN -o --delete origin work"
# Dry runs (spec 2026-10-28, section 2): one returns early, unjudged, only when the raw text
# is canonical and git reads it as a dry run. Any other is judged as a real push, except that
# where that verdict is an ask, the dry run gets a silent deny instead: no prompt. That deny
# says, in order: the dry run is refused because it is not in plain words; the plain -n form
# where one can be printed (the canonical dry run in this checkout, or the plain -n form to run
# from the push's own repository); and that the push it previews needs Michael's confirmation.
# It never offers the real push. A deny for a dry run that prints a pinned delete is worded as a
# dry run and keeps -n. On main each of the fakes below returned early while the shell ran a
# real delete.
DRY_REFUSED="Push guard: this dry run is refused because it is not written in ${PLAIN_LEAD#Push guard: a merged delete passes only when written in }"
DRY_HERE=$'\nRun it in plain words, from this checkout:\n  '
CONFIRM_DELETE="The push it previews needs Michael's confirmation before it runs, because it deletes remote refs (--delete, -d or --prune): confirm it with him rather than preview it this way."
CONFIRM_MAIN="The push it previews needs Michael's confirmation before it runs, because it updates main, the default branch of origin: confirm it with him rather than preview it this way."
# no_real_push <label> <cwd> <command> [<real push>]: a dry-run deny never offers the real push:
# no "drop" advice, and never the push it previews printed without -n.
no_real_push() {
  lacks_reason "$1: no drop advice" "rop -n" "$2" "$3"
  lacks_reason "$1: no drop at all" "drop" "$2" "$3"
  if [ -n "${4:-}" ]; then lacks_reason "$1: never prints the real push" "$4" "$2" "$3"; fi
}
expect allow "D1 a canonical dry run of the pinned delete returns early" "$DEL" "$PINNED --dry-run"
expect allow "D1 a canonical dry run with 2>&1 | head -5 returns early" "$DEL" "git push --force-with-lease=open:$OPEN origin --delete open -n 2>&1 | head -5"
expect allow "D1 a canonical dry run of an unmerged delete returns early" "$DEL" "git push --force-with-lease=open:$OPEN origin --delete open -n"
expect allow "D1 a bundled -nv, canonical, returns early"               "$DEL" "git push -nv --force-with-lease=open:$OPEN origin --delete open"
# The glob: with a file named --no-dry-run in the cwd, the shell hands git --no-dry-run after
# -n, and git deletes for real. Judged as a real push, the * is main's wildcard deny.
DGLOB=$(cp -R "$DEL" "$TMP/delglob" && printf '%s' "$TMP/delglob")
: > "$DGLOB/--no-dry-run"
expect deny  "D2 -n and a glob that expands to --no-dry-run"            "$DGLOB" "git push --force-with-lease=open:$OPEN origin --delete open -n *"
has_reason   "D2 and the deny names the wildcard" "the wildcard refspec * can update any branch" "$DGLOB" "git push --force-with-lease=open:$OPEN origin --delete open -n *"
# A carriage return glued to -n: the shell keeps it in the lease word, so there is no dry run.
# As a real push the unmerged delete would ask, so it is a deny; the guard read the words as
# --force-with-lease=a -n ..., and prints that dry run in plain words.
D2_CR=$(printf 'git push --force-with-lease=a\r-n origin --delete open')
expect deny  "D2 a carriage return glued to -n"                         "$DEL" "$D2_CR"
has_reason   "D2 and the deny is refused, plain -n form, confirm, in order" \
             "$DRY_REFUSED${DRY_HERE}git push --force-with-lease=a -n origin --delete open"$'\n'"$CONFIRM_DELETE" "$DEL" "$D2_CR"
no_real_push "D2 CR" "$DEL" "$D2_CR" "git push --force-with-lease=a origin --delete open"
# A continuation glued to -n: the shell joins ci.skip\<newline>-n into one push option value.
# Spec 2026-10-29 section 2: the guard no longer reads the continuation as a space, so the
# command leaves the grammar and gets the plain-push deny.
D2_CONT="git push --force-with-lease=open:$OPEN -o ci.skip\\
-n origin --delete open"
expect deny  "D2 a continuation glued to -n"                            "$DEL" "$D2_CONT"
has_reason   "D2 and a continuation glued to -n leaves the grammar: the plain-push deny" "in a shape the guard does not check" "$DEL" "$D2_CONT"
no_real_push "D2 continuation" "$DEL" "$D2_CONT" "git push --force-with-lease=open:$OPEN -o ci.skip origin --delete open"
# Not canonical, judged as a real push: a real deny stays a deny, a real allow stays an allow,
# and a real ask becomes the dry-run deny. A real deny that prints a pinned delete prints its
# dry run (-n), worded as a dry run.
DRY_PINNED="git push -n --force-with-lease=done:$DONE origin --delete done"
REAL_PINNED="git push --force-with-lease=done:$DONE origin --delete done"
expect deny  "D3 real deny: a dry run of the pinned delete with a bare tail" "$DEL" "$PINNED -n 2>&1 | tail"
has_reason   "D3 and the deny prints the plain pinned dry run, as a dry run" \
             "$DRY_REFUSED done is merged into main, on origin and here. Run the dry run in plain words: $DRY_PINNED" "$DEL" "$PINNED -n 2>&1 | tail"
lacks_reason "D3 and it says nothing of pinning the delete" "Pin the delete" "$DEL" "$PINNED -n 2>&1 | tail"
no_real_push "D3 bare tail" "$DEL" "$PINNED -n 2>&1 | tail" "$REAL_PINNED"
D3_W="command git push -n --force-with-lease=done:$DONE origin --delete done"
expect deny  "D3 real deny: a pinned dry run behind a wrapper"          "$DEL" "$D3_W"
has_reason   "D3 and the deny prints the pinned dry run" "and here. Run the dry run in plain words: $DRY_PINNED" "$DEL" "$D3_W"
no_real_push "D3 wrapper, pinned" "$DEL" "$D3_W" "$REAL_PINNED"
D3_U="command git push -n origin --delete done"
expect deny  "D3 real deny: an unpinned dry run behind a wrapper"       "$DEL" "$D3_U"
has_reason   "D3 and the deny prints the pinned dry run" "and here. Run the dry run in plain words: $DRY_PINNED" "$DEL" "$D3_U"
no_real_push "D3 wrapper, unpinned" "$DEL" "$D3_U" "$REAL_PINNED"
D3_UT="git -C $DEL push -n origin --delete done"
expect deny  "D3 real deny: an unpinned dry run behind -C, from outside" "$TMP" "$D3_UT"
has_reason   "D3 and the deny prints the pinned dry run to run from that repository" \
             "and in $DELTOP, which is not this session's checkout. Run the plain dry run from that repository: $DRY_PINNED" "$TMP" "$D3_UT"
no_real_push "D3 -C, unpinned" "$TMP" "$D3_UT" "$REAL_PINNED"
# The re-review's two shapes take a -N trailer, which is canonical now, so they are canonical dry
# runs: they return early, as on main.
expect allow "D1 a pinned dry run with 2>&1 | tail -3 returns early"    "$DEL" "git push -n --force-with-lease=done:$DONE origin --delete done 2>&1 | tail -3"
expect allow "D1 an unpinned dry run with | tail -3 returns early"      "$DEL" "git push -n origin --delete done | tail -3"
expect deny  "D3 real deny: a dry run behind GIT_DIR, GIT_DIR refused"  "$DEL" "GIT_DIR=$DEL/.git git push origin --delete done --dry-run"
has_reason   "D3 and the deny names GIT_DIR" "unsupported push configuration for the push guard: GIT_DIR" "$DEL" "GIT_DIR=$DEL/.git git push origin --delete done --dry-run"
expect allow "D3 real allow: a dry run of a feature branch behind cd"   "$DEL" "cd $DEL && git push -n origin work"
# Real asks become the dry-run deny: refused, the plain -n form where printable, confirm.
D3_C="git -C $DEL push -n --force-with-lease=open:$OPEN origin --delete open"
expect deny  "D3 real ask: a dry run behind -C, from outside the checkout" "$TMP" "$D3_C"
has_reason   "D3 and the deny is refused, the -n form from that repository, confirm, in order" \
             "$DRY_REFUSED"$'\n'"It runs in $DELTOP, which is not this session's checkout. Run the plain -n form from that repository:"$'\n'"  git push -n --force-with-lease=open:$OPEN origin --delete open"$'\n'"$CONFIRM_DELETE" "$TMP" "$D3_C"
no_real_push "D3 -C, unmerged" "$TMP" "$D3_C" "git push --force-with-lease=open:$OPEN origin --delete open"
D3_MAIN="cd $DEL && git push -n origin main"
expect deny  "D3 real ask: a dry run of a default-branch push behind cd" "$DEL" "$D3_MAIN"
has_reason   "D3 and the deny is refused, the canonical dry run, confirm, in order" \
             "$DRY_REFUSED${DRY_HERE}git push -n origin main"$'\n'"$CONFIRM_MAIN" "$DEL" "$D3_MAIN"
no_real_push "D3 default branch" "$DEL" "$D3_MAIN" "git push origin main"
D3_PRINTED=$(reason "$DEL" "$D3_MAIN"); D3_PRINTED=${D3_PRINTED#*from this checkout:$'\n'  }; D3_PRINTED=${D3_PRINTED%%$'\n'*}
if [ "$D3_PRINTED" = "git push -n origin main" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "D3 the printed dry run is the plain command, on a line of its own"
else
  fail=$((fail + 1)); printf '  FAIL %s (printed %s)\n' "D3 the printed dry run is the plain command, on a line of its own" "$D3_PRINTED"
fi
expect allow "D3 and the printed dry run is canonical: it returns early" "$DEL" "$D3_PRINTED"
D3_Q="git push -n origin --delete 'x y'"
expect deny  "D3 real ask: a dry run with no plain form (a word needs quoting)" "$DEL" "$D3_Q"
has_reason   "D3 and the deny is refused, then confirm, and nothing between" "$DRY_REFUSED $CONFIRM_DELETE" "$DEL" "$D3_Q"
lacks_reason "D3 and it offers no plain form" "Run it in plain words" "$DEL" "$D3_Q"
no_real_push "D3 quoted word" "$DEL" "$D3_Q" "git push origin --delete"
# Every word git could read as a negation, an abbreviation or a push option holding the n is
# refused before the dry-run test, as on main, so -n or --dry-run in the guard's reading is
# git's own (git 2.56 measured: the last of -n, --dry-run and --no-dry-run wins; --dry and
# --no-dr count; -on is the push option n). Denied, never exempt.
UNSUP="unsupported push configuration for the push guard: the push option"
for neg in '-n --no-dry-run' '--dry-run --no-dry-run' '-n --no-dry' '-n --no-dr' '-nv --no-dry-run' '--no-dry-run -n' '--dry'; do
  expect deny "D4 [$neg] is refused, as on main" "$DEL" "git push $neg --force-with-lease=open:$OPEN origin --delete open"
done
has_reason   "D4 and the deny names the option" "$UNSUP --no-dry-run" "$DEL" "git push -n --no-dry-run --force-with-lease=open:$OPEN origin --delete open"
expect deny  "D4 -on is the push option n, refused, as on main"         "$DEL" "git push -on --force-with-lease=open:$OPEN origin --delete open"
has_reason   "D4 and the deny names the push option" "the push option n is not one the guard allows" "$DEL" "git push -on --force-with-lease=open:$OPEN origin --delete open"
# An update push keeps main's verdict.
expect allow "an update push keeps main's verdict"                      "$DEL" "git push --force-with-lease=work:$MAIN origin work"

# From here on the remote moves: another clone merges far into main and pushes both.
OTHER="$TMP/delother"
git clone -q "$REMOTES/del.git" "$OTHER" 2>/dev/null
git -C "$OTHER" switch -q -c far
git -C "$OTHER" commit -q --allow-empty -m far
git -C "$OTHER" switch -q main && git -C "$OTHER" merge -q --ff-only far
git -C "$OTHER" push -q origin main far 2>/dev/null
FAR=$(git -C "$OTHER" rev-parse far)
expect ask   "a merged tip this repository lacks"         "$DEL" "git push --force-with-lease=far:$FAR origin --delete far"
# The remote's default tip is missing here. A remote marked a promisor in config would have
# git fetch it for the local lookups, running that remote's uploadpack unsandboxed: the
# lookups run with lazy fetch off, so the delete asks and the command does not run.
DPROM=$(cp -R "$DEL" "$TMP/delprom" && printf '%s' "$TMP/delprom")
PROMMARK="$TMP/promisor-marker"
git -C "$DPROM" config remote.origin.promisor true
git -C "$DPROM" config remote.origin.uploadpack "touch $PROMMARK; git-upload-pack"
expect ask   "a promisor remote, its default tip missing here" "$DPROM" "git push --force-with-lease=done:$DONE origin --delete done"
if [ -e "$PROMMARK" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the promisor's uploadpack ran (a local lookup lazy-fetched from the remote)"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the promisor's uploadpack did not run"
fi
git -C "$DEL" fetch -q origin
expect ask   "a tip the local default branch lacks"       "$DEL" "git push --force-with-lease=far:$FAR origin --delete far"
expect allow "after the fetch, done is still merged and pinned" "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
# done moves on the remote after it was merged: the guard reads the new tip and asks, and
# git itself refuses a delete pinned to the old one. That refusal is what the pin relies on.
git -C "$OTHER" switch -q -c done origin/done
git -C "$OTHER" commit -q --allow-empty -m "moved on"
git -C "$OTHER" push -q origin done 2>/dev/null
MOVED=$(git -C "$OTHER" rev-parse done)
expect ask   "a branch that moved past its merge"         "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
if git -C "$DEL" push -q --force-with-lease="done:$DONE" origin --delete done 2>/dev/null; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "git refuses a delete pinned to a tip the branch has moved past (it deleted it)"
elif [ "$(git ls-remote "$REMOTES/del.git" refs/heads/done | cut -f1)" = "$MOVED" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git refuses a delete pinned to a tip the branch has moved past"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git refuses a delete pinned to a moved tip (the branch changed anyway)"
fi
if git -C "$DEL" push -q --force-with-lease="done2:$DONE2" origin --delete done2 2>/dev/null \
   && [ -z "$(git ls-remote "$REMOTES/del.git" refs/heads/done2)" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git deletes a branch pinned to its current tip"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git deletes a branch pinned to its current tip"
fi
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

echo "== rule 4: spellings the fast path used to miss =="
expect deny  "a quoted push word to main"            "$R" 'git pu"sh" origin main'
has_reason   "it gets the plain-push deny" "in a shape the guard does not check" "$R" 'git pu"sh" origin main'
expect deny  "a quoted push word, force"             "$R" 'git pu"sh" --force origin main'
expect deny  "an empty-quote push word"              "$R" "git p''ush origin main"
expect deny  "an escaped push word"                  "$R" 'git pu\sh origin main'
expect allow "a quoted push word to a feature branch" "$R" 'git pu"sh" origin feat'
expect deny  "an ANSI-C push word"                   "$R" "git \$'\\x70ush' origin main"
expect deny  "an ANSI-C letter inside push"          "$R" "git pu\$'\\x73'h origin main"
expect ask   "a literal push still asks"             "$R" 'git push origin main'
expect ask   "a quoted git word, literal push, still asks" "$R" '"git" push origin main'
expect deny  "a hidden send-pack spelling"           "$R" 'git send-"pack" origin main'
expect deny  "a quoted ; in a -c value before a literal push" "$R" "true; git -c 'x.y=a;b' push origin main"
expect deny  "git send-pack in a compound command"   "$R" "true; git send-pack $REMOTES/origin.git main"
expect deny  "an ANSI-C assignment before a feature push" "$R" "IFS=\$'\\n' git push origin feat"
has_reason   "a \$' command gets the plain-push deny" "in a shape the guard does not check" "$R" "IFS=\$'\\n' git push origin feat"
expect deny  "a continuation inside a refspec word"  "$R" 'git push -u origin fe\
at'
has_reason   "an in-word continuation gets the plain-push deny" "in a shape the guard does not check" "$R" 'git push -u origin fe\
at'
expect allow "a continuation between words keeps main's verdict" "$R" 'git push -u \
origin feat'
expect allow "IFS=$'\\n' alone is silent"           "$R" "IFS=\$'\\n'; echo hi"
expect allow "printf with an ANSI-C string is silent" "$R" "printf \$'a\\tb'"
expect allow "a sed backreference is silent"         "$R" "sed -E 's/(a)/\\1/' f"
# Without PUSH_GUARD_LITERAL the helper treats the run as a hidden-spelling start: an ask is a deny.
hv=$(jq -n --arg d "$R" '{cwd:$d,tool_input:{command:"git push origin main"}}' \
  | env -u PUSH_GUARD_LITERAL python3 "$(dirname "$GUARD")/git-push-guard.py")
if printf '%s' "$hv" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
   && printf '%s' "$hv" | grep -q "in a shape the guard does not check"; then
  pass=$((pass + 1)); printf '  ok   %s\n' "the helper without the literal flag denies where it would ask"
else
  fail=$((fail + 1)); printf '  FAIL %s (%s)\n' "the helper without the literal flag denies where it would ask" "$hv"
fi
# The helper's exception branch, driven at unit level: parse_plain and could_push are replaced
# with functions that raise, so no real input is needed to force it.
exc_out=$(/usr/bin/python3 - "$(dirname "$GUARD")/git-push-guard.py" <<'PY'
import importlib.util, io, json, os, sys

spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(*a, **k):
    raise RuntimeError("forced")


def run(cmd, literal, patch):
    if literal is None:
        os.environ.pop("PUSH_GUARD_LITERAL", None)
    else:
        os.environ["PUSH_GUARD_LITERAL"] = literal
    saved = {k: getattr(g, k) for k in patch}
    for k, v in patch.items():
        setattr(g, k, v)
    sys.stdin = io.StringIO(json.dumps({"cwd": "/nonexistent", "tool_input": {"command": cmd}}))
    out = io.StringIO()
    old, sys.stdout = sys.stdout, out
    try:
        g.main()
    finally:
        sys.stdout = old
        for k, v in saved.items():
            setattr(g, k, v)
    text = out.getvalue().strip()
    if not text:
        return "silent"
    d = json.loads(text)["hookSpecificOutput"]
    r = d["permissionDecisionReason"]
    return d["permissionDecision"] + "/" + ("plain" if r == g.PLAIN else "internal" if "internal error" in r else "other")


hidden = 'git pu"sh" origin main'
both = {"parse_plain": boom, "could_push": boom}
print("exception, no flag, no shape", run(hidden, None, both))
print("exception, literal=0, no shape", run(hidden, "0", both))
print("exception, literal=0, push shape", run("git push origin main", "0", {"parse_plain": boom}))
print("exception, literal=1, no shape", run(hidden, "1", both))
PY
)
while IFS='|' read -r label want; do
  got=$(printf '%s\n' "$exc_out" | sed -n "s/^$label //p")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "helper exception: $label -> $want"
  else
    fail=$((fail + 1)); printf '  FAIL %s (got %s)\n' "helper exception: $label -> $want" "$got"
  fi
done <<'EOF'
exception, no flag, no shape|deny/plain
exception, literal=0, no shape|deny/plain
exception, literal=0, push shape|deny/internal
exception, literal=1, no shape|silent
EOF
# A large payload with no push in it must stay cheap (the hidden-spelling scan is linear).
big=$(awk 'BEGIN { for (i = 0; i < 20000; i++) print "print(\"abc\", \x27d\x27, x\\y)" }')
t0=$SECONDS
run "$R" "cat <<'EOF'
$big
EOF" >/dev/null
if [ $((SECONDS - t0)) -lt 10 ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a large quoted payload with no push stays fast"
else
  fail=$((fail + 1)); printf '  FAIL %s (%ss)\n' "a large quoted payload with no push stays fast" "$((SECONDS - t0))"
fi
if [ -x /bin/bash ]; then
  b32=$(jq -n --arg d "$R" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"git pu\"sh\" origin main"}}' \
    | PINNED_PATH="$PATH" /bin/bash "$GUARD")
  if printf '%s' "$b32" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %s\n' "the guard denies a quoted push word under /bin/bash"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "the guard denies a quoted push word under /bin/bash"
  fi
else
  printf '  skip %s\n' "no /bin/bash here: the 3.2 check is skipped"
fi

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
for c in "IFS=\$'\\n'; echo hi" "printf '\\x41'" "printf '\\101'" "printf '\\u0041'" "printf '\\U00000041'" "printf '\\cA'" $'git pu\\\nsh origin main'; do
  rm -f "$TRIP/git-push-guard.py.ran"
  run "$R" "$c" >/dev/null
  if [ -e "$TRIP/git-push-guard.py.ran" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "a hidden spelling runs the helper: $c"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "a hidden spelling runs the helper: $c"
  fi
done
rm -f "$TRIP/git-push-guard.py.ran"
run "$R" 'echo hi' >/dev/null
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "echo hi does not run the helper"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "echo hi does not run the helper"
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
  # diff.submodule=diff makes the patch of a bumped gitlink start a child `git diff` inside the
  # submodule, which has no --no-ext-diff of its own: the submodule's diff.external and textconv
  # driver would run, unsandboxed, on every push. The scan keeps the gitlink a one-line patch.
  SMK="$TMP/sm-marks"; SMS="$TMP/sm-src"; mkdir -p "$SMK"
  git init -q "$SMS"; printf 'one\n' > "$SMS/a.txt"; git -C "$SMS" add a.txt; git -C "$SMS" commit -q -m "first"
  SUBM=$(clone submodule)
  git -C "$SUBM" -c protocol.file.allow=always submodule add -q "$SMS" sm 2>/dev/null
  git -C "$SUBM" commit -q -m "add the submodule"
  printf 'changed\n' > "$SUBM/sm/a.txt"; git -C "$SUBM/sm" commit -q -am "move the submodule"
  git -C "$SUBM" add sm; git -C "$SUBM" commit -q -m "bump the gitlink"
  printf '#!/bin/sh\ntouch "%s/external"\nexit 0\n' "$SMK" > "$TMP/sm-external"; chmod +x "$TMP/sm-external"
  printf '#!/bin/sh\ntouch "%s/textconv"\ncat "$1"\n' "$SMK" > "$TMP/sm-textconv"; chmod +x "$TMP/sm-textconv"
  git -C "$SUBM/sm" config diff.external "$TMP/sm-external"
  git -C "$SUBM/sm" config diff.m.textconv "$TMP/sm-textconv"
  printf '*.txt diff=m\n' > "$(git -C "$SUBM/sm" rev-parse --path-format=absolute --git-path info/attributes)"
  git -C "$SUBM" config diff.submodule diff
  rm -f "$SMK"/*
  expect allow "a bumped gitlink under diff.submodule=diff is scanned and passes" "$SUBM" 'git push origin feat'
  is_marks() {
    if [ -z "$(ls "$SMK" | tr '\n' ' ')" ]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
    else fail=$((fail + 1)); printf '  FAIL %s (ran: %s)\n' "$1" "$(ls "$SMK" | tr '\n' ' ')"; fi
  }
  is_marks "and neither the submodule's diff.external nor its textconv ran"
  git -C "$SUBM/sm" config --unset diff.external; rm -f "$SMK"/*   # the external driver outranks textconv
  expect allow "the same push with the textconv driver alone" "$SUBM" 'git push origin feat'
  is_marks "nor the textconv driver alone"
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
  # --text puts a binary file's bytes in the patch, and a GIF, PNG or font can hold CR before
  # the 0x01 commit marker or @@. Read in text mode, the listing broke there too and counted
  # phantom commits (598 expected, 573 scanned): git and gitleaks split at LF alone. The gif
  # is added, then deleted: a phantom marker inside a deleted file once counted as well.
  CRBIN=$(clone cr-binary)
  printf 'GIF89a\000\r\001x\r@@ -0,0 +1 @@\r\001y\000\n' > "$CRBIN/cam.gif"
  git -C "$CRBIN" add cam.gif && git -C "$CRBIN" commit -q -m "add a gif"
  git -C "$CRBIN" rm -q cam.gif && git -C "$CRBIN" commit -q -m "delete the gif"
  printf 'hello\n' > "$CRBIN/notes.txt"
  git -C "$CRBIN" add notes.txt && git -C "$CRBIN" commit -q -m "a clean change"
  expect allow "a binary holding CR before the commit marker and @@" "$CRBIN" 'git push origin feat'
  # The count still fails closed when gitleaks really covers less. This git hides the commits
  # that only modify files from gitleaks' own log (a diff filter the guard's listing never
  # gets), so gitleaks scans 2 of the 3 commits with changes: deny, with the exact counts.
  CRMOD="$TMP/cr-binary-modified"; cp -R "$CRBIN" "$CRMOD"
  printf 'more\n' >> "$CRMOD/notes.txt"; git -C "$CRMOD" commit -q -am "modify notes"
  HIDEBIN="$TMP/hidebin"; mkdir -p "$HIDEBIN"
  printf '#!/bin/sh\nPATH="%s"; export PATH\ncase " $* " in\n  *" --format=%%x01%%H "*) ;;\n  *" log -p -U0 "*) exec git "$@" --diff-filter=A ;;\nesac\nexec git "$@"\n' \
    "$REALPATH" > "$HIDEBIN/git"
  chmod 755 "$HIDEBIN/git"
  PATH="$HIDEBIN:$REALPATH"
  expect deny  "a gitleaks log that hides modifying commits is a deny" "$CRMOD" 'git push origin feat'
  has_reason   "and the deny gives both counts" "scanned 2 commit(s) but this push carries 3" "$CRMOD" 'git push origin feat'
  PATH="$REALPATH"
  expect allow "the same branch, its log not filtered"        "$CRMOD" 'git push origin feat'
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

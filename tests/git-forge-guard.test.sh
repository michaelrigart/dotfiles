#!/usr/bin/env bash
# Mocked tests for dot_claude/executable_git-forge-guard.sh.
#
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision JSON object —
# "deny" for rules 1-2 (correctness catches, bounced back to the model) or "ask"
# for rule 3 (a danger gate, surfaced to the user). Rule 4 (git push) denies every push of the
# default branch and what it cannot resolve, and asks for force and delete pushes of other branches.
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

# test-requires: heavy  # 142 s on 2026-11-15
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${1:-$SRC/dot_claude/executable_git-forge-guard.sh}"
[ -f "$GUARD" ] || { echo "missing guard: $GUARD" >&2; exit 2; }

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

# A push that would ask is scanned for secrets, by the script the global pre-push hook also
# runs (dot_config/git/hooks/secret-scan), before the ask. A push that passes silently is scanned
# by the helper too unless the deployed hook is certain to run for it. The decision cases run
# against a stub gitleaks that finds nothing, so they exercise the decision alone; the scan
# section puts the real binary back. The helper looks the script up at PUSH_GUARD_SCAN: a hooks
# directory holding a link to the source copy and a pre-push stub (the fixture pushes run it),
# which the global config's core.hooksPath names, as the deployed ~/.config/git/config does.
# The rows for the scan and the hook themselves are in the git-pre-push-hook suite.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/gitleaks"; chmod 755 "$STUBBIN/gitleaks"
REALPATH=$PATH
export PATH="$STUBBIN:$PATH"
[ -f "$SRC/dot_config/git/hooks/executable_secret-scan" ] \
  || { echo "missing scan script: $SRC/dot_config/git/hooks/executable_secret-scan" >&2; exit 2; }
HOOKS="$TMP/hooks"; mkdir -p "$HOOKS"
ln -s "$SRC/dot_config/git/hooks/executable_secret-scan" "$HOOKS/secret-scan"
printf '#!/bin/sh\nexit 0\n' > "$HOOKS/pre-push"; chmod 755 "$HOOKS/pre-push"
export PUSH_GUARD_SCAN="$HOOKS/secret-scan"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$HOOKS"

# cmdpayload <cwd> <command> -> prints the hook payload
cmdpayload() {
  jq -n --arg c "$2" --arg d "$1" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

# run <cwd> <command> -> prints the guard's stdout
run() {
  cmdpayload "$1" "$2" | PINNED_PATH="$PATH" bash "$GUARD"
}

# expect <allow|deny> <label> <cwd> <command>. Every decision is exit 0: a guard that exits
# 1 on an allow path blocks ordinary Bash once the hook fails closed.
expect() {
  local want=$1 label=$2 cwd=$3 cmd=$4 out got rc
  out=$(run "$cwd" "$cmd"); rc=$?
  if [ "$rc" -ne 0 ]; then
    got="exit $rc"
  elif [ -z "$out" ]; then
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
# expect_default <label> <cwd> <command>: a push of the default branch is the silent deny, whose
# reason is exactly the one text (Push guard, the default branch is Michael's).
DEFAULT_DENY="Push guard: the default branch is Michael's; push the branch and open a merge request or pull request."
expect_default() {
  local label=$1 got
  got=$(reason "$2" "$3")
  if [ "$got" = "$DEFAULT_DENY" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want the default-branch deny, got: %s)\n' "$label" "${got:-no reason}"
  fi
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
# attribution rule is the "Merge requests" rule in GLOBAL.md, and the deny says so.
has_reason "the template deny offers FORGE_GUARD=off only when Michael asked" \
           "Only if Michael has asked, in this" "$HEADS" 'glab mr create -t "Fix" --description "Just some prose."'
has_reason "the attribution deny names the Merge requests rule" \
           '"Merge requests" rule in' "$BARE" "git commit -F $ATTRIB_MSG"

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
expect_default "push to the default branch"             "$R"   'git push origin main'
expect_default "git -C <repo> from another directory"   "$TMP" "git -C $R push origin main"
expect_default "command git push"                       "$R"   'command git push origin main'
expect_default "env X=1 git push"                       "$R"   'env X=1 git push origin main'
expect_default "an assignment prefix"                   "$R"   'X=1 git push origin main'
expect_default "sudo git push"                          "$R"   'sudo git push origin main'
expect_default "a path to git"                          "$R"   '/usr/bin/git push origin main'
expect_default "global options before push"             "$TMP" "git --no-pager -C $R push origin main"
expect_default "FORGE_GUARD=off does not lift rule 4"   "$R"   'FORGE_GUARD=off git push origin main'
expect_default "a global alias: pom = push origin main" "$R"   'git pom'
expect_default "a repository-local alias"               "$R"   'git lp'
expect deny  "a push after another git command, on a later line" "$R" 'git status
git push origin main'
expect deny  "a push after another git command, after &&" "$R" 'git add -A && git push origin main'
expect_default "a push with redirects and a pipe"       "$R"   'git push origin main 2>&1 | tail -5'
expect deny  "a push inside bash -c"                  "$R"   "bash -c 'git push origin main'"
expect_default "a cd before the push is followed"       "$TMP" "cd $R && git push origin main"
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
expect_default "an alias local to the -C repository"    "$TMP" "git -C $OTHER lp2"
expect deny  "an alias in the --git-dir= repository is denied with it" "$TMP" "git --git-dir=$OTHER/.git lp2"
expect_default "a -C path through a variable the hook can see" "$TMP" 'git -C "$GUARDTMP/work" push origin main'
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

echo "== rule 4: a push of the default branch is denied =="
expect_default "HEAD:main"                              "$R" 'git push origin HEAD:main'
expect_default "refs/heads/main as the destination"     "$R" 'git push origin feat:refs/heads/main'
expect_default "a lease on the default branch"          "$R" 'git push --force-with-lease origin main'
expect_default "--mirror"                               "$R" 'git push --mirror origin'
expect_default "--all"                                  "$R" 'git push --all origin'
expect_default "--delete of the default branch"         "$R" 'git push --delete origin main'
expect_default "-d of refs/heads/<default>"             "$R" 'git push -d origin refs/heads/main'
expect_default "a :<default> refspec"                   "$R" 'git push origin :main'
# git resolves heads/<name> to refs/heads/<name>, so a delete names the branch either way.
expect_default "--delete of heads/<default>"            "$R" 'git push --delete origin heads/main'
expect_default "a :heads/<default> refspec"             "$R" 'git push origin :heads/main'
expect_default "a +: refspec deleting the default branch" "$R" 'git push origin +:main'

echo "== rule 4: pushes that ask =="
expect ask   "a + refspec"                            "$R" 'git push origin +feat'
expect ask   "--force on a feature branch"            "$R" 'git push --force origin feat'
expect ask   "-f bundled as -fu"                      "$R" 'git push -fu origin feat'
expect ask   "a :ref refspec"                         "$R" 'git push origin :old'
expect ask   "--delete"                               "$R" 'git push --delete origin old'
expect ask   "-d"                                     "$R" 'git push -d origin old'
expect ask   "--prune"                                "$R" 'git push --prune origin feat'
expect ask   "--delete of heads/<another branch>"     "$R" 'git push --delete origin heads/feat'
expect ask   "a :heads/<another branch> refspec"      "$R" 'git push origin :heads/feat'
expect ask   "--prune alone"                          "$R" 'git push --prune origin'
expect ask   "--delete of another branch"             "$R" 'git push origin --delete feat'

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
expect_default "the default branch, pinned"                 "$DEL" "git push --force-with-lease=main:$MAIN origin --delete main"
expect_default "the default branch as refs/heads/main"      "$DEL" "git push --force-with-lease=main:$MAIN origin --delete refs/heads/main"
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
# dangling ref (the outgoing commits cannot be listed: deny), and no marker appears. The
# pushes are force pushes: a plain push is silent here and left to the hook, while an asking
# push is scanned first, and the scan is what lists the outgoing commits.
LAZY=$(cp -R "$DEL" "$TMP/dellazy" && printf '%s' "$TMP/dellazy")
git -C "$LAZY" switch -q work
git -C "$LAZY" commit -q --allow-empty -m "lazy work"
printf '%s\n' 1111111111111111111111111111111111111111 > "$LAZY/.git/refs/remotes/origin/ghost"
git -C "$LAZY" config remote.origin.promisor true
git -C "$LAZY" config remote.origin.partialclonefilter blob:none
git -C "$LAZY" config remote.origin.uploadpack "touch $TMP/lazy-marker; git-upload-pack"
expect deny "a dangling remote ref with a promisor remote" "$LAZY" 'git push --force origin work'
if [ -e "$TMP/lazy-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the guard lazy-fetched through the promisor remote"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the guard never lazy-fetches"
fi
# The guard's PATH is pinned: a git first on the caller's PATH must never run.
EVIL="$TMP/evilbin"; mkdir -p "$EVIL"
printf '#!/bin/sh\ntouch "%s/evil-marker"\nexec /usr/bin/git "$@"\n' "$TMP" > "$EVIL/git"; chmod 755 "$EVIL/git"
PINNED_OUT=$( PATH="$EVIL:$PATH"; unset PINNED_PATH
  jq -n --arg c 'git push --force origin work' --arg d "$LAZY" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | bash "$GUARD" )
if [ -e "$TMP/evil-marker" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "the guard ran a git from the caller's PATH"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "the guard's PATH is pinned"
fi
# ...and the pin costs the guard nothing: its verdict is the usual one (the same deny
# the suite's own PATH gets for this repository).
if [ -n "$PINNED_OUT" ] && [ "$PINNED_OUT" = "$(run "$LAZY" 'git push --force origin work')" ] \
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
expect deny "an outgoing commit naming a missing blob, with a promisor remote" "$LAZYB" 'git push --force origin work'
has_reason  "and the deny says to push by hand" "Push by hand" "$LAZYB" 'git push --force origin work'
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
PLAIN_REASON="Push guard: this command may run git push in a shape the guard does not check. Run the push as a plain command of its own: git push [options] <remote> <branch> (for another repository: git -C <path> push [options] <remote> <branch>; piped only to tail or head). If the command does not push, keep git and push apart in its text with a bracket, for example rg 'git pu[s]h'."
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
# A dry run of a default-branch push is the default-branch deny, not a dry-run deny: it would tell
# the agent to confirm with Michael a push that is denied. The canonical one still returns early.
D3_MAIN="cd $DEL && git push -n origin main"
expect_default "D3 a dry run of a default-branch push behind cd" "$DEL" "$D3_MAIN"
no_real_push "D3 default branch" "$DEL" "$D3_MAIN" "git push origin main"
D3_OPEN="cd $DEL && git push -n origin --delete open"
expect deny  "D3 real ask: a dry run of an unmerged delete behind cd" "$DEL" "$D3_OPEN"
has_reason   "D3 and the deny is refused, the canonical dry run, confirm, in order" \
             "$DRY_REFUSED${DRY_HERE}git push -n origin --delete open"$'\n'"$CONFIRM_DELETE" "$DEL" "$D3_OPEN"
no_real_push "D3 unmerged delete" "$DEL" "$D3_OPEN" "git push origin --delete open"
D3_PRINTED=$(reason "$DEL" "$D3_OPEN"); D3_PRINTED=${D3_PRINTED#*from this checkout:$'\n'  }; D3_PRINTED=${D3_PRINTED%%$'\n'*}
if [ "$D3_PRINTED" = "git push -n origin --delete open" ]; then
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
expect_default "a bare push while on main"              "$ONMAIN" 'git push'
expect_default "push <remote> while on main"            "$ONMAIN" 'git push origin'
expect_default "push HEAD while on main"                "$ONMAIN" 'git push origin HEAD'
expect_default "a delete through --show-current, on main" "$ONMAIN" 'git push origin --delete "$(git branch --show-current)"'
expect_default "-d through rev-parse --abbrev-ref, on main" "$ONMAIN" 'git push -d origin "$(git rev-parse --abbrev-ref HEAD)"'
# A local tag named main makes `symbolic-ref --short HEAD` print heads/main: the guard reads the
# full ref, so the current branch is still main.
TAGGED=$(clone tagged); git -C "$TAGGED" switch -q main; git -C "$TAGGED" tag main
expect_default "a bare push on main, with a tag named main"   "$TAGGED" 'git push'
expect_default "push <remote> on main, with a tag named main" "$TAGGED" 'git push origin'
expect_default "push HEAD on main, with a tag named main"     "$TAGGED" 'git push origin HEAD'
expect_default "-u HEAD on main, with a tag named main"       "$TAGGED" 'git push -u origin HEAD'
expect_default "--show-current on main, with a tag named main" "$TAGGED" 'git push origin "$(git branch --show-current)"'
expect_default "rev-parse --abbrev-ref on main, with a tag named main" "$TAGGED" 'git push origin "$(git rev-parse --abbrev-ref HEAD)"'
TAGGED_PR=$(clone tagged-pushremote); git -C "$TAGGED_PR" switch -q main; git -C "$TAGGED_PR" tag main
git -C "$TAGGED_PR" config branch.main.pushRemote other
has_reason   "branch.main.pushRemote is read under main, with a tag named main" \
             "unsupported push configuration for the push guard: branch.main.pushRemote" "$TAGGED_PR" 'git push'
# A local branch named <remote>/<default> makes `symbolic-ref --short refs/remotes/<remote>/HEAD`
# print remotes/<remote>/<default>: the guard reads the full ref, so the default is still named.
SHADOW=$(clone shadow); git -C "$SHADOW" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$SHADOW" branch develop; git -C "$SHADOW" branch origin/develop
expect_default "the default branch with a local branch named origin/<default>" "$SHADOW" 'git push origin develop'
has_reason   "the deny is the default-branch text" "$DEFAULT_DENY" "$R" 'git push origin main'
TRUNK=$(clone trunk); git -C "$TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
git -C "$TRUNK" branch trunk
expect_default "the default branch comes from origin/HEAD" "$TRUNK" 'git push origin trunk'
expect allow "main is not special when HEAD names trunk" "$TRUNK" 'git push origin main'
NOHEAD=$(clone nohead); git -C "$NOHEAD" remote set-head origin -d
expect_default "no origin/HEAD falls back to main"      "$NOHEAD" 'git push origin main'
expect_default "--all with no origin/HEAD: the fallback main is still touched" "$NOHEAD" 'git push --all origin'
expect_default "--mirror with no origin/HEAD: the fallback main is still touched" "$NOHEAD" 'git push --mirror origin'

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
expect_default "a push to main from a subdirectory"     "$R/sub/dir" 'git push origin main'

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
expect_default "and a push to main under it is the default-branch deny" "$RSCHECK" 'git push origin main'
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
expect_default "the current branch by substitution, on main" "$ONMAIN" 'git push origin "$(git branch --show-current)"'
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
expect_default "HEAD:refs/heads/main is the default-branch deny"        "$R" 'git push origin HEAD:refs/heads/main'
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
# A subcommand the shell computes is read only where a literal push stands in the git text.
expect deny  "the subcommand from a variable default" "$R" 'git ${X:-push} origin main'
expect allow "a variable as the subcommand"           "$R" 'X=push; git $X origin main'
expect allow "a computed subcommand, no push in the git text" "$R" 'git ${X:-pu}sh origin main
echo push'
expect deny  "a computed option word"                 "$R" 'git ${X:--C} . push origin feat'
expect deny  "a brace list as the subcommand"         "$R" 'git {push,pull} origin feat'
expect_default "a -C value through a variable still resolves" "$TMP" 'git -C "$GUARDTMP/work" push origin main'
# Commands that push without being git push.
expect deny  "git subtree push"                       "$R" 'git subtree push --prefix=d origin main'
expect deny  "git http-push"                          "$R" 'git http-push origin main'
expect deny  "a non-builtin subcommand given push"    "$R" 'git lfs push origin feat'
expect allow "git subtree split does not push"        "$R" 'git subtree split --prefix=d'
expect deny  "git send-pack, through the full guard"  "$R" "git send-pack $REMOTES/origin.git main"
expect deny  "git send-pack after a true"             "$R" 'true; git send-pack /x main'
has_reason   "send-pack after a true gets the plain-push deny" "in a shape the guard does not check" "$R" 'true; git send-pack /x main'
expect deny  "git send-pack after git status"         "$R" 'git status && git send-pack /x main'
has_reason   "send-pack after git status gets the plain-push deny" "in a shape the guard does not check" "$R" 'git status && git send-pack /x main'
# Builtins that run a command string: the string is never read, so one that pushes is refused.
expect deny  "submodule foreach running a push"       "$R" "git submodule foreach 'git push origin main'"
expect deny  "rebase --exec running a push"           "$R" "git rebase --exec 'git push origin main' main"
expect deny  "rebase -x running a push"               "$R" "git rebase -x 'git push origin main' main"
expect deny  "bisect run running a push"              "$R" 'git bisect run git push origin main'
expect deny  "filter-branch running a push"           "$R" "git filter-branch --tree-filter 'git push origin main' HEAD"
expect allow "submodule foreach that does not push"   "$R" "git submodule foreach 'git status'"
expect allow "a commit message that mentions a push"  "$R" 'git commit -m "git push later"'
# Driven directly, the helper answers as the whole hook would for a command that starts it.
helper_says() { # helper_says <silent|deny|ask> <label> <cwd> <command> [NAME=value for the helper]
  local want=$1 label=$2 out got
  out=$(jq -n --arg c "$4" --arg d "$3" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | env ${5:+"$5"} /usr/bin/python3 "$(dirname "$GUARD")/git-push-guard.py")
  if [ -z "$out" ]; then got=silent
  else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null); fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want %s, helper said %s: %s)\n' "$label" "$want" "$got" "$out"
  fi
}
helper_says deny "git send-pack, straight to the helper"  "$R" "git send-pack $REMOTES/origin.git main"

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
# A git word that is a glob, a variable or built at run time is not read as git: only a literal
# git word, the dash forms and the aliases are (the retired spellings section pins the silence).
expect allow "a ? glob in the git word"               "$R" '/usr/bin/gi? push origin main'
expect allow "a [ ] glob in the git word"             "$R" '/usr/bin/g[i]t push origin main'
# Only the last path component of a command word decides: a $VAR/ directory in front of a
# name that is not git is an ordinary command (helm, gradle).
expect allow "a variable command that pushes, not git" "$R" '$DOCKER push registry/x:1'
expect allow "a quoted \$HOME path to helm push"      "$R" '"$HOME/bin/helm" push chart.tgz oci://r'
expect allow "a variable command that pushes, after &&" "$R" 'npm run build && $DOCKER push img'
expect allow "a variable interpreter on a push script" "$R" '$PYTHON scripts/push.py'
expect allow "a \$HOME path to helm push"            "$R" '$HOME/bin/helm push x'
expect allow "a quoted \$GOPATH path, -l ."           "$TMP" "cd $R && \"\$GOPATH/bin/gofumpt\" -l ."
expect allow "a \$HOME path to gradle, -c"            "$R" '$HOME/.local/bin/gradle build -c settings.gradle'
expect allow "a variable command with no push word"   "$R" '$G status'
# Reserved words leave the next word in command position.
expect allow "a glob git word after then"             "$R" 'if true; then /usr/bin/g[i]t push origin main; fi'
expect deny  "git-send-pack inside a { } group"       "$R" "{ /usr/libexec/git-core/git-send-pack $REMOTES/origin.git main; }"
expect allow "an if around a git command that does not push" "$R" 'if git diff --quiet; then echo same; fi'
expect allow "a glob git word as the command of a *) arm" "$R" 'case "$x" in a) ;; *) /usr/bin/g[i]t push origin main;; esac'
expect allow "a glob git word in a subshell"          "$R" '(/usr/bin/g[i]t push origin main)'
expect allow "a glob git word after xargs, before a )" "$R" '(echo push origin main | xargs /usr/bin/g[i]t)'
expect deny  "git-send-pack behind exec-path"         "$R" "\$(git --exec-path)/git-send-pack $REMOTES/origin.git main"
expect deny  "git-send-pack by path"                  "$R" "/opt/homebrew/opt/git/libexec/git-core/git-send-pack $REMOTES/origin.git main"
expect deny  "git-push, the dash form"                "$R" 'git-push origin main'
expect deny  "git-http-push by path"                  "$R" '/usr/libexec/git-core/git-http-push origin main'
# rebase --exec, however it is spelled
expect deny  "rebase -ix running a push"              "$R" "git rebase -ix 'git push origin main' main"
expect deny  "rebase --exe running a push"            "$R" "git rebase --exe 'git push origin main' main"
expect deny  "rebase --ex= running a push"            "$R" "git rebase --ex='git push origin main' main"
expect allow "rebase --autosquash is not --exec"      "$R" 'git rebase -i --autosquash main'

echo "== rule 4: retired spellings: the guard is silent =="
# The guard used to hunt a push spelled to hide from it. It judges the plain push and refuses a
# literal push it cannot parse; the forge refuses what matters on a protected default branch.
# Each row is a command the hunt denied, one per retired class.
expect allow "a normalized view: git status, then echo pu''sh"   "$R" "cd /tmp; git status; echo pu''sh"
expect allow "an escape: an ANSI-C git word, delete"             "$R" "\$'\\x67it' push origin --delete wip"
helper_says silent "the strict path: a bracketed git word and a glob push word" "$R" \
  'cd /tmp; /usr/bin/[g][i][t] p?sh origin main'
expect allow "a glob git word"                                   "$R" '/usr/bin/gi? push origin main'
expect allow "a built git word: a variable"                      "$R" '$G push origin main'
helper_says silent "dynamic_git_word: a default-valued push word, straight to the helper" "$R" \
  'git ${X:-pu}sh origin main'
expect allow "a nested shell string: an alias behind a quoted ;" "$R" "sh -c 'git -c \"a;b\" pom'"
helper_says ask "PUSH_GUARD_LITERAL=0 is ignored: a force push to a feature branch asks" "$R" \
  'git push --force origin feat' PUSH_GUARD_LITERAL=0
# What holds the literal words git and push in one segment keeps the plain-push deny.
expect deny  "literal words: git and push inside an ANSI-C string" "$R" "echo \$'git push'"
has_reason   "an ANSI-C string naming git and push gets the plain-push deny" "in a shape the guard does not check" "$R" "echo \$'git push'"
expect deny  "literal words: a default-valued push word"          "$R" 'git ${X:-push} origin main'
has_reason   "a default-valued push word gets the plain-push deny" "in a shape the guard does not check" "$R" 'git ${X:-push} origin main'

echo "== rule 4: a command outside the grammar, and an unreadable payload =="
# A literal push that parse_plain cannot judge faithfully (an ANSI-C quote, a continuation
# inside a word) is the plain-push deny, as on main.
expect deny  "an ANSI-C assignment before a feature push" "$R" "IFS=\$'\\n' git push origin feat"
has_reason   "a \$' command gets the plain-push deny" "in a shape the guard does not check" "$R" "IFS=\$'\\n' git push origin feat"
expect deny  "a continuation inside a refspec word"  "$R" 'git push -u origin fe\
at'
has_reason   "an in-word continuation gets the plain-push deny" "in a shape the guard does not check" "$R" 'git push -u origin fe\
at'
expect allow "a continuation between words keeps main's verdict" "$R" 'git push -u \
origin feat'
expect allow "an indented continuation stays in the grammar: a feature push keeps main's verdict" "$R" "git push -u origin feat\\
  -u"
# A command outside the grammar keeps every refusal main gave it, as the plain-push deny: the
# probe runs the full judge, which here raises a deny of its own that could_push never sees.
expect deny  "C1 alias behind a quoted ; and an ANSI-C word"   "$R" "git -c 'a.b=x;y' pom \$'--verbose'"
has_reason   "C1 gets the plain-push deny" "in a shape the guard does not check" "$R" "git -c 'a.b=x;y' pom \$'--verbose'"
expect deny  "a force push behind a quoted ; and an ANSI-C word" "$R" "git -c 'x.y=a;b' push -f origin main \$'-q'"
has_reason   "the force push gets the plain-push deny" "in a shape the guard does not check" "$R" "git -c 'x.y=a;b' push -f origin main \$'-q'"
# A bypass on main that this branch closes: the git log's quoted argument swallows the push as
# shlex reads it, and bash runs a force push to main. Leaving the grammar closes it.
G="gi""t"; P="pu""sh"
BYPASS="$G log --grep \$'a\\'b' ; $G $P -f origin main # '"
expect deny  "a bypass on main that this branch closes" "$R" "$BYPASS"
has_reason   "the bypass gets the plain-push deny" "in a shape the guard does not check" "$R" "$BYPASS"
# An unreadable payload (jq rejects a lone or reversed UTF-16 surrogate escape) fails closed for
# rule 4 when the raw text holds a push trigger, and for rules 1-2 (a commit, an MR or PR
# command), which are refused. The payload is built with printf so the \u escape stays literal
# JSON.
# expect_raw <allow|deny> <label> <raw JSON payload> [reason needle]. Exit 0 on every decision.
expect_raw() {
  local want=$1 label=$2 out got rc
  out=$(printf '%s' "$3" | PINNED_PATH="$PATH" bash "$GUARD"); rc=$?
  if [ "$rc" -ne 0 ]; then got="exit $rc"
  elif [ -z "$out" ]; then got=allow
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then got=deny
  elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1; then got=ask
  else got="other: $out"; fi
  if [ "$got" = "$want" ] && { [ -z "${4:-}" ] || case "$out" in *"$4"*) true ;; *) false ;; esac; }; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s (want %s, got %s)\n' "$label" "$want" "$got"
  fi
}
rawpayload() { printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$1"; }
UNREAD="could not be read"
UNREAD_FORGE="could not be read, so it is refused"
expect_raw deny  "jq a lone high surrogate after a force push to main" "$(rawpayload "$G $P --force origin main # "'\ud800')" "$UNREAD"
# jq reads a lone low surrogate as U+FFFD, so this one reaches the helper, which denies on the comment.
expect_raw deny  "jq a lone low surrogate after a force push to main"  "$(rawpayload "$G $P --force origin main # "'\udc00')" "in a shape the guard does not check"
# Round 3 (I): the helper keeps a lone low surrogate that jq turned into U+FFFD. A -C selector
# holding it fails the helper's own git call (UnicodeEncodeError), in a shell string or outside
# the grammar, and that fails closed as the plain-push deny, as main's did.
PLAINR="in a shape the guard does not check"
expect_raw deny  "I a lone low surrogate in a -C selector inside sh -c" "$(rawpayload "sh -c '$G -C \\\"/nx/x"'\udc00'"\\\" pom'")" "$PLAINR"
expect_raw deny  "I a lone low surrogate in a -C selector, outside the grammar" "$(rawpayload "$G -C '/nx/x"'\udc00'"' pom \$'--verbose'")" "$PLAINR"
expect_raw deny  "I a lone low surrogate in a -c value, probe judge fails" "$(rawpayload "$G -c 'a.b=x;"'\udc00'"' pom \$'--verbose'")" "$PLAINR"
expect_raw deny  "jq a reversed surrogate pair after a force push to main" "$(rawpayload "$G $P --force origin main # "'\udc00\ud800')" "$UNREAD"
expect_raw allow "jq a lone surrogate with no push trigger is silent"  "$(rawpayload 'echo hi # \ud800')"
expect_raw deny  "jq a lone surrogate in a commit command (rules 1-2) is refused" "$(rawpayload "$G commit -m x # "'\ud800')" "$UNREAD_FORGE"
# An unreadable payload that holds `glab api` is denied too (deny beats ask: a click would let an
# unjudged commit through); rule 4's more specific push deny wins when both apply.
GAPI='glab api -X DELETE projects/1/merge_requests/2'
expect_raw deny  "jq a lone high surrogate with a glab api write is refused"   "$(rawpayload "$GAPI # "'\ud800')" "$UNREAD_FORGE"
expect_raw deny  "jq a reversed surrogate pair with a glab api write is refused" "$(rawpayload "$GAPI # "'\udc00\ud800')" "$UNREAD_FORGE"
expect_raw deny  "jq a lone high surrogate with a glab api read is refused"    "$(rawpayload "glab api projects/1 # "'\ud800')" "$UNREAD_FORGE"
expect_raw deny  "jq a lone surrogate hides an attributed commit behind glab api" "$(rawpayload "$G commit -m x -m \\\"Co-authored-by: Claude <noreply@anthropic.com>\\\"; glab api projects/1 # "'\ud800')" "$UNREAD_FORGE"
expect_raw deny  "jq a lone surrogate in a commit with no glab api is refused" "$(rawpayload "$G commit -m 'x y' # "'\ud800')" "$UNREAD_FORGE"
expect_raw deny  "jq a push candidate plus glab api keeps the push deny" "$(rawpayload "$G $P --force origin main; $GAPI # "'\ud800')" "$UNREAD"
BS=$(printf '\134'); PAIR="${BS}ud83d${BS}ude00"       # a valid surrogate pair (the emoji), as JSON escapes
expect_raw allow "jq a valid surrogate pair in a feature push reaches the helper" "$(rawpayload "X=$PAIR $G $P origin feat")"
expect_raw allow "jq a valid surrogate pair with a glab api read is unchanged" "$(rawpayload "X=$PAIR glab api projects/1")"
ask_out=$(printf '%s' "$(rawpayload "X=$PAIR $G $P origin main")" | PINNED_PATH="$PATH" bash "$GUARD")
if printf '%s' "$ask_out" | jq -e --arg r "$DEFAULT_DENY" '.hookSpecificOutput | .permissionDecision=="deny" and .permissionDecisionReason==$r' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok   %s\n' "jq a valid surrogate pair in a push to main is the default-branch deny"
else
  fail=$((fail + 1)); printf '  FAIL %s (%s)\n' "jq a valid surrogate pair in a push to main is the default-branch deny" "$ask_out"
fi
# N1: a judge() failure on a command outside the grammar is the plain-push deny, as main's
# internal-error deny was. The helper gets the lone surrogate through json.loads, and its own
# git call then fails with UnicodeEncodeError.
n1_out=$(printf '%s' "$(rawpayload "$G -c 'a.b=x;"'\ud800'"' pom \$'--verbose'")" \
  | /usr/bin/python3 "$(dirname "$GUARD")/git-push-guard.py")
if printf '%s' "$n1_out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 \
   && printf '%s' "$n1_out" | grep -q "in a shape the guard does not check"; then
  pass=$((pass + 1)); printf '  ok   %s\n' "N1 a probe whose judge fails is the plain-push deny"
else
  fail=$((fail + 1)); printf '  FAIL %s (%s)\n' "N1 a probe whose judge fails is the plain-push deny" "$n1_out"
fi
# The helper's exception branch, driven at unit level: parse_plain and probe_refuses are replaced
# with functions that raise, so no real input is needed to force it.
exc_out=$(/usr/bin/python3 - "$(dirname "$GUARD")/git-push-guard.py" <<'PY'
import importlib.util, io, json, sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(*a, **k):
    raise RuntimeError("forced")


def run(cmd, patch):
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


print("exception, push shape", run("git push origin main", {"parse_plain": boom}))
print("exception, no push shape", run("git status", {"parse_plain": boom}))
print("N7 probe skipped when could_push denies", run("git pu" + "sh origin main $'x'", {"probe_refuses": boom}))
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
exception, push shape|deny/internal
exception, no push shape|silent
N7 probe skipped when could_push denies|deny/plain
EOF
if [ -x /bin/bash ]; then
  b32=$(jq -n --arg d "$R" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:"git push --force origin feat"}}' \
    | PINNED_PATH="$PATH" /bin/bash "$GUARD")
  if printf '%s' "$b32" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %s\n' "the guard asks for a force push under /bin/bash"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "the guard asks for a force push under /bin/bash"
  fi
else
  printf '  skip %s\n' "no /bin/bash here: the 3.2 check is skipped"
fi

# R12 (D): the git-then-push and git-then-alias searches are linear. A 160 KB line of git words once
# held the hook past its 60 s timeout, which is non-blocking, so a padded push went through.
PADLINE="echo $(awk 'BEGIN { for (i = 0; i < 27000; i++) printf "git x " }')"
t0=$SECONDS
expect allow "R12 a 160 KB line of git words, then a glob push is silent" "$R" "$PADLINE
/usr/bin/[g][i][t] -c x.y=a pu''sh origin main"
expect deny  "R12 a 160 KB line of git words, then a literal push" "$R" "$PADLINE
git push origin main"
expect allow "R12 a 160 KB line of git words, then a glob command, no push" "$R" "$PADLINE
/usr/bin/[g][i][t] status"
expect allow "R12 a 160 KB line of git words alone" "$R" "$PADLINE"
R12_NAME="R12 the 160 KB padded commands finish under 10 s"
if [ $((SECONDS - t0)) -lt 10 ]; then
  pass=$((pass + 1)); printf '  ok   %s (%s s)\n' "$R12_NAME" "$((SECONDS - t0))"
else
  fail=$((fail + 1)); printf '  FAIL %s (%ss)\n' "$R12_NAME" "$((SECONDS - t0))"
fi
# push_shape and alias_text_hit against the old quadratic patterns, on short random strings.
ps_out=$(/usr/bin/python3 - "$(dirname "$GUARD")/git-push-guard.py" <<'PY'
import importlib.util, random, re, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("guard", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
old_push = re.compile(r"\bgit\b[^;&|\n]*\b(?:push|send-pack)\b")
names = {"pom", "x.y", "lp"}
parts = ["git", "push", "send-pack", "pom", "x.y", "lp", "gitx", "xgit", "git-push", "git_push", "pushx", ";",
         "&", "|", "\n", " ", " ", "-C", "'", "a", "b", "\t", ".", "-", "(", ")", "$"]
random.seed(12)
diffs = hits = 0
for _ in range(60000):
    text = "".join(random.choice(parts) for _ in range(random.randint(1, 40)))
    want = old_push.search(text) is not None
    alias = any(re.search(r"\bgit\b[^;&|\n]*\b" + re.escape(a) + r"\b", text) for a in names)
    hits += want + alias
    if want != g.push_shape(text) or alias != g.alias_text_hit(text, names):
        diffs += 1
print(("ok " if not diffs and hits > 1000 else "FAIL ") +
      "push_shape and alias_text_hit equal the old patterns: 60000 random strings, "
      "%d hits, %d differences" % (hits, diffs))
PY
)
case "$ps_out" in
  "ok "*) pass=$((pass + 1)); printf '  ok   %s\n' "${ps_out#ok }" ;;
  *)      fail=$((fail + 1)); printf '  FAIL %s\n' "${ps_out#FAIL }" ;;
esac

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
for c in "IFS=\$'\\n'; echo hi" "printf '\\x41'" "printf '\\101'" "printf '\\u0041'" "printf '\\U00000041'" "printf '\\cA'" $'git pu\\\nsh origin main' '/usr/bin/[g][i][t] p?sh origin main'; do
  rm -f "$TRIP/git-push-guard.py.ran"
  run "$R" "$c" >/dev/null
  if [ -e "$TRIP/git-push-guard.py.ran" ]; then
    fail=$((fail + 1)); printf '  FAIL %s\n' "a hidden spelling does not run the helper: $c"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "a hidden spelling does not run the helper: $c"
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
expect deny  "a command that only mentions push, with no helper, is refused" "$R" 'echo push'
expect allow "a command with no push text, with no helper, is untouched" "$R" 'ls -la'
expect allow "git status is untouched"                "$R" 'git status'
# A helper that cannot run denies every push candidate, aliases included.
expect deny  "an alias push with no helper is refused" "$R" 'git pom'
# Fail closed: with no helper, the aliases of a -C repository cannot be checked.
expect deny  "a git -C command with no helper is refused" "$TMP" "git -C $R status"
# A candidate is denied without reading its quotes, so a comment is no exception.
expect deny  "a commented git command with no helper is refused" "$R" 'git status # push later'
# The fast path sends send-pack, http-push and the git-<sub> dash forms to the helper, so
# they are refused too.
expect deny  "git send-pack with no helper is refused" "$R" "git send-pack $REMOTES/origin.git main"
expect deny  "git http-push with no helper is refused" "$R" 'git http-push origin main'
expect deny  "git-push with no helper is refused"      "$R" 'git-push origin main'
expect deny  "a git-core path to git-send-pack with no helper" "$R" '/usr/libexec/git-core/git-send-pack /r.git main'
expect deny  "git log --grep=push with no helper is refused" "$R" 'git log --grep=push'
expect deny  "a quoted git word, literal push, with no helper is refused" "$R" '"g"it push --force origin main'
# Leaks the old evidence-based fallback had, each of which must now deny. (1) A command past
# ~32 KB broke the fallback's printf | grep -q on SIGPIPE under pipefail. (2) A literal push
# word elsewhere in the payload, a description for one, still makes the command a candidate.
# (3) A line-continued git, backslash, newline, push matched no pattern.
BIGTAIL=$(head -c 40000 /dev/zero | tr '\0' a)
expect deny  "a 40 KB literal force push with no helper is refused" "$R" "git push --force origin main # $BIGTAIL"
expect deny  "a glob push word after an echo push, no helper, is refused" "$R" 'echo push; /usr/bin/[g]it p?sh --force origin main'
DESCPAY=$(jq -n --arg d "$R" --arg c "git \$'pu\\x73h' origin main" '{cwd:$d,tool_input:{command:$c,description:"push it"}}')
expect_raw deny "an ANSI-C push word with push in the description, no helper, is refused" "$DESCPAY" "push check could not run"
expect deny  "a line-continued git push with no helper is refused" "$R" "git \\
push origin main"
# A helper that runs but fails is the same: it denies every candidate.
FAILHELPER="$TMP/failhelper"; mkdir -p "$FAILHELPER"
cp "$SAVED_GUARD" "$FAILHELPER/git-forge-guard.sh"
printf 'import sys\nsys.exit(3)\n' > "$FAILHELPER/git-push-guard.py"
GUARD="$FAILHELPER/git-forge-guard.sh"
for c in "git send-pack $REMOTES/origin.git main" 'git http-push origin main' 'git-push origin main' \
         'git push origin feat'; do
  expect deny  "a failing helper: $c is refused"       "$R" "$c"
done
expect deny  "a failing helper: a quoted git word, literal push, is refused" "$R" '"g"it push --force origin main'
expect deny  "a failing helper: a command that only mentions push is refused" "$R" 'echo push'
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

echo "== rule 4: a push that would ask is scanned first =="
# The scan itself moved to the global pre-push hook (the git-pre-push-hook suite holds its
# rows). The guard still runs the same script (PUSH_GUARD_SCAN, exported at the top) before it
# returns an ask: a push Michael approves must already be clean, and a secret is a deny, which
# beats an ask. A push that passes rule 4 silently is left to the hook alone.
PATH="$REALPATH"
CLEAN=$(clone clean)
printf 'hello\n' > "$CLEAN/notes.txt"
git -C "$CLEAN" add notes.txt && git -C "$CLEAN" commit -q -m "a clean change"
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
  expect deny  "a force push without a lease, its commits holding a secret" "$LEAKY" 'git push --force origin feat'
  has_reason   "and the deny names the rule, file and commit" \
               "rule aws-access-token in creds.txt at commit" "$LEAKY" 'git push --force origin feat'
  got=$(reason "$LEAKY" 'git push --force origin feat')
  case "$got" in
    *"$part_b"*) fail=$((fail + 1)); printf '  FAIL %s\n' "the deny never shows the secret" ;;
    *)           pass=$((pass + 1)); printf '  ok   %s\n' "the deny never shows the secret" ;;
  esac
  expect deny  "a delete beside a pushed branch holding a secret" "$LEAKY" 'git push origin :old feat'
  has_reason   "and that deny names the rule too" "rule aws-access-token in creds.txt" "$LEAKY" 'git push origin :old feat'
  expect ask   "a clean force push is scanned, then asks"     "$CLEAN" 'git push --force origin feat'
  expect allow "a leaky feature push is left to the hook"     "$LEAKY" 'git push origin feat'
  expect allow "a dry run is never scanned"                   "$LEAKY" 'git push --dry-run origin feat'
  # --tags pushes refs the scan does not name one by one, so it cannot show an exception is
  # committed on each of them: with an exception file in the worktree the push is refused. --all
  # and --mirror never get that far: they are the default-branch deny. Here the secret is tagged
  # v1 on feat, and the exception is committed on scratch only.
  TAGGED=$(clone tagged)
  printf '%s\n' "$SECRET_LINE" > "$TAGGED/creds.txt"
  git -C "$TAGGED" add creds.txt && git -C "$TAGGED" commit -q -m "add creds"
  git -C "$TAGGED" tag v1
  git -C "$TAGGED" switch -q -c scratch main
  printf '# reviewed\n' > "$TAGGED/.gitleaksignore"
  git -C "$TAGGED" add .gitleaksignore && git -C "$TAGGED" commit -q -m "ignore, on scratch only"
  expect deny  "--tags beside a force with an exception file in the worktree" "$TAGGED" 'git push --force --tags origin'
  has_reason   "and the deny says to push the refs by name" "Push the branches and tags by name" "$TAGGED" 'git push --force --tags origin'
  expect_default "--all with an exception file in the worktree is denied before the scan" "$TAGGED" 'git push --all origin'
  expect_default "--mirror with an exception file in the worktree is denied before the scan" "$TAGGED" 'git push --mirror origin'
  # The script is looked up at PUSH_GUARD_SCAN: a push that would ask and cannot be scanned is a
  # deny naming the file, and a push that passes silently never reads it.
  PUSH_GUARD_SCAN="$TMP/none" expect deny  "with the scan script missing, an asking push is denied" "$CLEAN" 'git push --force origin feat'
  PUSH_GUARD_SCAN="$TMP/none" has_reason   "and the deny says the scan could not run" "could not run" "$CLEAN" 'git push --force origin feat'
  PUSH_GUARD_SCAN="$TMP/none" expect deny  "and a silent push is scanned too, as the hook may not be there" "$CLEAN" 'git push origin feat'
  PUSH_GUARD_SCAN="$TMP/none" has_reason   "and that deny says the scan could not run" "could not run" "$CLEAN" 'git push origin feat'

  # A silent push the deployed hook will not see is scanned here, as on main: --no-verify, an
  # assignment or wrapper that could move git's configuration, and a hooks directory that is not the deployed one or holds no pre-push. An
  # ordinary push with the hook deployed is the hook's to scan. LEAKY holds the fixture secret.
  expect deny  "--no-verify on a leaky feature push"          "$LEAKY" 'git push --no-verify origin feat'
  has_reason   "and the deny names the rule and file" \
               "rule aws-access-token in creds.txt" "$LEAKY" 'git push --no-verify origin feat'
  expect allow "--no-verify on a clean feature push"          "$CLEAN" 'git push --no-verify origin feat'
  expect allow "a dry run that is not canonical text is the hook's to scan" "$TMP" "git -C $LEAKY push -n origin feat"
  expect deny  "HOME reassigned on a leaky push"              "$LEAKY" 'HOME=/nonexistent git push origin feat'
  expect deny  "XDG_CONFIG_HOME reassigned on a leaky push"   "$LEAKY" 'XDG_CONFIG_HOME=/nonexistent git push origin feat'
  expect deny  "env HOME= on a leaky push"                    "$LEAKY" 'env HOME=/nonexistent git push origin feat'
  expect deny  "sudo on a leaky push"                         "$LEAKY" 'sudo git push origin feat'
  expect deny  "command on a leaky push"                      "$LEAKY" 'command git push origin feat'
  expect allow "HOME reassigned on a clean push"              "$CLEAN" 'HOME=/nonexistent git push origin feat'
  NOHOOK="$TMP/hooks-nopre"; mkdir -p "$NOHOOK"
  ln -s "$SRC/dot_config/git/hooks/executable_secret-scan" "$NOHOOK/secret-scan"
  LEAKY_NOHOOK=$(clone leaky-nohook)
  git -C "$LEAKY_NOHOOK" config core.hooksPath "$NOHOOK"
  printf '%s\n' "$SECRET_LINE" > "$LEAKY_NOHOOK/creds.txt"
  git -C "$LEAKY_NOHOOK" add creds.txt && git -C "$LEAKY_NOHOOK" commit -q -m "add creds"
  PUSH_GUARD_SCAN="$NOHOOK/secret-scan" expect deny "a hooks directory with no pre-push, leaky" "$LEAKY_NOHOOK" 'git push origin feat'
  OTHER="$TMP/hooks-else"; mkdir -p "$OTHER"
  printf '#!/bin/sh\nexit 0\n' > "$OTHER/pre-push"; chmod 755 "$OTHER/pre-push"
  LEAKY_ELSE=$(clone leaky-else)
  git -C "$LEAKY_ELSE" config core.hooksPath "$OTHER"
  printf '%s\n' "$SECRET_LINE" > "$LEAKY_ELSE/creds.txt"
  git -C "$LEAKY_ELSE" add creds.txt && git -C "$LEAKY_ELSE" commit -q -m "add creds"
  expect deny  "a repository core.hooksPath elsewhere, leaky" "$LEAKY_ELSE" 'git push origin feat'
  # The hook is certain to run for an ordinary push, so the helper does not call gitleaks for it.
  RECORD2="$TMP/recordgl2"; mkdir -p "$RECORD2"
  printf '#!/bin/sh\necho called >> "%s/calls"\nexit 0\n' "$RECORD2" > "$RECORD2/gitleaks"; chmod 755 "$RECORD2/gitleaks"
  PATH="$RECORD2:$REALPATH"
  rm -f "$RECORD2/calls"
  expect allow "an ordinary leaky push with the hook deployed is the hook's to scan" "$LEAKY" 'git push origin feat'
  if [ -e "$RECORD2/calls" ]; then
    fail=$((fail + 1)); printf '  FAIL %s\n' "the helper does not run gitleaks for a push the hook will scan"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "the helper does not run gitleaks for a push the hook will scan"
  fi
  run "$LEAKY" 'git push --no-verify origin feat' >/dev/null
  if [ -e "$RECORD2/calls" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "the same recording stub sees gitleaks run for a --no-verify push"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "the same recording stub sees gitleaks run for a --no-verify push"
  fi
  PATH="$REALPATH"
  NOEXEC="$TMP/hooks-noexec"; mkdir -p "$NOEXEC"
  ln -s "$SRC/dot_config/git/hooks/executable_secret-scan" "$NOEXEC/secret-scan"
  printf '#!/bin/sh\nexit 0\n' > "$NOEXEC/pre-push"; chmod 644 "$NOEXEC/pre-push"
  LEAKY_NOEXEC=$(clone leaky-noexec)
  git -C "$LEAKY_NOEXEC" config core.hooksPath "$NOEXEC"
  printf '%s\n' "$SECRET_LINE" > "$LEAKY_NOEXEC/creds.txt"
  git -C "$LEAKY_NOEXEC" add creds.txt && git -C "$LEAKY_NOEXEC" commit -q -m "add creds"
  PUSH_GUARD_SCAN="$NOEXEC/secret-scan" expect deny "a pre-push that is not executable, leaky" "$LEAKY_NOEXEC" 'git push origin feat'
fi

echo "== rule 4: the scan fails closed =="
NOGL="$TMP/nogl"; mkdir -p "$NOGL"; ln -s "$(command -v jq)" "$NOGL/jq"
PATH="$NOGL:/usr/bin:/bin"
expect deny  "a missing gitleaks denies the push"   "$CLEAN" 'git push --force origin feat'
has_reason   "and names the remedy" "brew bundle"   "$CLEAN" 'git push --force origin feat'
BROKEN="$TMP/brokengl"; mkdir -p "$BROKEN"
printf '#!/bin/sh\necho "gitleaks: boom" >&2\nexit 2\n' > "$BROKEN/gitleaks"; chmod 755 "$BROKEN/gitleaks"
PATH="$BROKEN:$REALPATH"
expect deny  "a gitleaks error denies the push"     "$CLEAN" 'git push --force origin feat'
has_reason   "and carries the error" "boom"         "$CLEAN" 'git push --force origin feat'
RECORD="$TMP/recordgl"; mkdir -p "$RECORD"
printf '#!/bin/sh\necho called >> "%s/calls"\nexit 0\n' "$RECORD" > "$RECORD/gitleaks"; chmod 755 "$RECORD/gitleaks"
PATH="$RECORD:$REALPATH"
expect allow "a dry run to main"                    "$CLEAN" 'git push -n origin main'
if [ -e "$RECORD/calls" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "a dry run never runs gitleaks"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "a dry run never runs gitleaks"
fi
# A push naming a ref that does not exist cannot be listed, so it cannot be shown covered. Plain,
# git itself refuses it before any hook, and the helper still scans it so the verdict stays
# main's deny; as a force push the guard asks, so it is scanned first.
expect deny  "a source that is not a ref is a deny"   "$CLEAN" 'git push --force origin nosuch'
expect deny  "a plain push of a source that is not a ref" "$CLEAN" 'git push origin nosuch'
# A gitleaks that hangs (or a git it spawns) must end in a deny within the helper's budget. The
# helper kills the scan's process group; the scan's own, shorter budget kills its gitleaks first,
# and a survivor holds none of the helper's pipes, so it cannot keep the helper waiting.
HANG="$TMP/hanggl"; mkdir -p "$HANG"
printf '#!/bin/sh\nsleep 30\nexit 0\n' > "$HANG/gitleaks"; chmod 755 "$HANG/gitleaks"
PATH="$HANG:$REALPATH"
export PUSH_GUARD_BUDGET=2
started=$(date +%s)
expect deny  "a gitleaks slower than the budget is a deny" "$CLEAN" 'git push --force origin feat'
has_reason   "and the deny says the scan timed out" "did not finish" "$CLEAN" 'git push --force origin feat'
elapsed=$(( $(date +%s) - started ))
unset PUSH_GUARD_BUDGET
if [ "$elapsed" -le 12 ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a hung gitleaks is cut off at the budget (${elapsed}s for two pushes)"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "a hung gitleaks is cut off at the budget (${elapsed}s for two pushes)"
fi
PATH="$STUBBIN:$REALPATH"

echo "== internal failures fail closed =="
# fc_run <PINNED_PATH> <command> -> sets fc_out, fc_err and fc_rc from one guard run
fc_run() {
  local errf="$TMP/fc.err"
  fc_out=$(cmdpayload "$BARE" "$2" | PINNED_PATH="$1" bash "$GUARD" 2>"$errf"); fc_rc=$?
  fc_err=$(cat "$errf")
}
# expect_refused <label> <PINNED_PATH> <command> <needle> [exit status]: a candidate is refused, with
# the needle in the reason. Status 2 (the default) is a refusal with the reason on stderr and nothing
# on stdout; status 0 is a printed deny.
expect_refused() {
  fc_run "$2" "$3"
  local refused=0
  if [ "$fc_rc" -eq 2 ] && [ "${5:-2}" -eq 2 ] && [ -z "$fc_out" ]; then
    refused=1
  elif [ "$fc_rc" -eq 0 ] && [ "${5:-2}" -eq 0 ] && printf '%s' "$fc_out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1; then
    refused=1
  fi
  if [ "$refused" = 1 ] && case "$fc_out$fc_err" in *"$4"*) true ;; *) false ;; esac; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s, stderr: %s)\n' "$1" "$fc_rc" "$fc_out" "$fc_err"
  fi
}
# expect_quiet <label> <PINNED_PATH> <command>: an ordinary command stays silent and exits 0
expect_quiet() {
  fc_run "$2" "$3"
  if [ "$fc_rc" -eq 0 ] && [ -z "$fc_out" ] && [ -z "$fc_err" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s, stderr: %s)\n' "$1" "$fc_rc" "$fc_out" "$fc_err"
  fi
}

# The real jq may be a mise shim that resolves jq through PATH, so each stub hands it the PATH
# without the stub directory.
REALJQ=$(command -v jq)
STUBBASE=$PATH
FCSTUBS="$TMP/fcstubs"
# jq that cannot write a decision: -Rs fails, everything else is the real jq
mkdir -p "$FCSTUBS/rsfail" "$FCSTUBS/jqfail"
cat > "$FCSTUBS/rsfail/jq" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = -Rs ] && exit 1; done
PATH="$STUBBASE" exec "$REALJQ" "\$@"
EOF
# jq that cannot read the payload: only -Rs (writing a decision) works
cat > "$FCSTUBS/jqfail/jq" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = -Rs ] && PATH="$STUBBASE" exec "$REALJQ" "\$@"; done
exit 1
EOF
chmod 755 "$FCSTUBS/rsfail/jq" "$FCSTUBS/jqfail/jq"
RSFAIL="$FCSTUBS/rsfail:$PATH"
JQFAIL="$FCSTUBS/jqfail:$PATH"

# /bin holds no jq: a candidate is refused, an ordinary command never notices
expect_refused "jq missing: a commit is refused" "/bin" 'git commit -m x' "Forge guard: jq is missing"
expect_refused "jq missing: a push is refused"   "/bin" 'git push origin main' "Forge guard: jq is missing"
expect_refused "jq missing: a glab api call is refused" "/bin" 'glab api projects/1' "Forge guard: jq is missing"
expect_quiet   "jq missing: ls stays silent" "/bin" 'ls -la'
# a jq that cannot write the decision must not turn the deny or ask into a pass
expect_refused "a deny jq cannot write is refused" "$RSFAIL" \
  'git commit -m x -m "Co-authored-by: Claude <noreply@anthropic.com>"' "Agent attribution is not allowed"
expect_refused "an ask jq cannot write is refused" "$RSFAIL" \
  'glab api -X DELETE projects/1/merge_requests/2' "writes to the forge"
expect_quiet   "a jq that cannot write: ls stays silent"         "$RSFAIL" 'ls -la'
expect_quiet   "a jq that cannot write: git status stays silent" "$RSFAIL" 'git status'
# a jq that cannot read the payload refuses a rule 1-2 candidate, and leaves the rest alone
expect_refused "a payload jq cannot read: a commit is refused" "$JQFAIL" 'git commit -m x' "could not be read, so it is refused" 0
expect_quiet   "a jq that cannot read: ls stays silent"         "$JQFAIL" 'ls -la'
expect_quiet   "a jq that cannot read: git status stays silent" "$JQFAIL" 'git status'

# Rule 3 reads python3's verdict. A python3 that is missing or broken is an internal failure, so
# the call is denied (JSON, exit 0), never asked. The classifier's own `unparseable` verdict is a
# doubt about the command, so it still asks.
mkdir -p "$FCSTUBS/nopy" "$FCSTUBS/pyfail" "$FCSTUBS/pyjunk"
cat > "$FCSTUBS/nopy/jq" <<EOF
#!/bin/sh
PATH="$STUBBASE" exec "$REALJQ" "\$@"
EOF
printf '#!/bin/sh\nexit 3\n' > "$FCSTUBS/pyfail/python3"
printf '#!/bin/sh\necho banana\nexit 0\n' > "$FCSTUBS/pyjunk/python3"
chmod 755 "$FCSTUBS/nopy/jq" "$FCSTUBS/pyfail/python3" "$FCSTUBS/pyjunk/python3"
GWRITE='glab api -X DELETE projects/1'
PYNEEDLE="the glab api read/write check could not run"
expect_refused "python3 missing: a glab api write is denied, not asked" "$FCSTUBS/nopy:/bin" "$GWRITE" "$PYNEEDLE" 0
expect_refused "python3 missing: even a glab api read is denied" "$FCSTUBS/nopy:/bin" 'glab api projects/1' "$PYNEEDLE" 0
expect_refused "a classifier that exits 3: a glab api write is denied, not asked" "$FCSTUBS/pyfail:$PATH" "$GWRITE" "$PYNEEDLE" 0
expect_refused "a classifier that prints nothing it knows: denied" "$FCSTUBS/pyjunk:$PATH" "$GWRITE" "$PYNEEDLE" 0
fc_run "$PATH" 'glab api "unbalanced'
if [ "$fc_rc" -eq 0 ] && printf '%s' "$fc_out" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a command the classifier cannot tokenize still asks"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "a command the classifier cannot tokenize still asks" "$fc_rc" "$fc_out"
fi
expect_quiet   "a read-only glab api call falls through" "$PATH" 'glab api projects/1'

# A text tool that fails on a candidate must not read as "no match". Each stub fails (exit 3) only
# for the call that decides one rule and is the real tool otherwise, so each case reaches its site.
# mkfailing <dir> <tool> <real tool path> <glob over "$*">
mkfailing() {
  mkdir -p "$FCSTUBS/$1"
  cat > "$FCSTUBS/$1/$2" <<EOF
#!/bin/sh
case "\$*" in $4) exit 3 ;; esac
exec $3 "\$@"
EOF
  chmod 755 "$FCSTUBS/$1/$2"
}
mkfailing grepverb grep /usr/bin/grep '*"[;&|(]"*'
mkfailing greprule1 grep /usr/bin/grep '*claude*'
mkfailing grepref grep /usr/bin/grep '*body-file*'
mkfailing greptpl grep /usr/bin/grep '-F*'
mkfailing sedtpl sed /usr/bin/sed '*"{1,6}"*'
mkfailing sedalias sed /usr/bin/sed '*"push|send-pack"*'
mkdir -p "$FCSTUBS/jqcwd"
cat > "$FCSTUBS/jqcwd/jq" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = '.cwd // empty' ] && exit 1; done
PATH="$STUBBASE" exec "$REALJQ" "\$@"
EOF
chmod 755 "$FCSTUBS/jqcwd/jq"
TXNEEDLE="could not run, so this call is refused"
expect_refused "grep failing on the command-position check: a commit is denied" "$FCSTUBS/grepverb:$PATH" 'git commit -m x' "$TXNEEDLE" 0
expect_refused "grep failing on the attribution scan: a commit is denied" "$FCSTUBS/greprule1:$PATH" 'git commit -m x' "$TXNEEDLE" 0
expect_refused "grep failing on the body-file scan: a commit is denied" "$FCSTUBS/grepref:$PATH" 'git commit -F msg.txt' "$TXNEEDLE" 0
# A message file that exists and is readable but whose cat fails must not read as an empty body.
mkfailing catfile cat /bin/cat '*?*'
FCMSG="$TMP/fcmsg.txt"
printf 'Add the thing\n\nCo-authored-by: Claude <noreply@anthropic.com>\n' > "$FCMSG"
FCCLEAN="$TMP/fcclean.txt"
printf 'Add the thing\n' > "$FCCLEAN"
expect_refused "cat failing on a readable message file: a commit is denied" "$FCSTUBS/catfile:$PATH" "git commit -F $FCMSG" "could not be read, so this command is refused" 0
expect_quiet "control: a clean message file passes with the real cat" "$PATH" "git commit -F $FCCLEAN"
IBODY='glab mr create --description "## What & why
Fixes it.

## Commits
- one

## Verification
- [x] tests green

## Checklist
- [x] docs updated

## Notes
n/a"'
fc_run_in() { # fc_run_in <cwd> <PINNED_PATH> <command>
  local errf="$TMP/fc.err"
  fc_out=$(cmdpayload "$1" "$3" | PINNED_PATH="$2" bash "$GUARD" 2>"$errf"); fc_rc=$?
  fc_err=$(cat "$errf")
}
fc_run_in "$HEADS" "$FCSTUBS/greptpl:$PATH" "$IBODY"
if [ "$fc_rc" -eq 0 ] && printf '%s' "$fc_out" | grep -qF "$TXNEEDLE"; then
  pass=$((pass + 1)); printf '  ok   %s\n' "grep failing on the template marker match: denied for the failure, not for the template"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "grep failing on the template marker match: denied for the failure, not for the template" "$fc_rc" "$fc_out"
fi
fc_run_in "$HEADS" "$PATH" "$IBODY"
if [ "$fc_rc" -eq 0 ] && [ -z "$fc_out" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "control: the same compliant body passes with the real grep"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "control: the same compliant body passes with the real grep" "$fc_rc" "$fc_out"
fi
fc_run_in "$HEADS" "$FCSTUBS/sedtpl:$PATH" "$IBODY"
if [ "$fc_rc" -eq 0 ] && printf '%s' "$fc_out" | grep -qF "$TXNEEDLE"; then
  pass=$((pass + 1)); printf '  ok   %s\n' "sed failing on the template markers: denied, not allowed"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "sed failing on the template markers: denied, not allowed" "$fc_rc" "$fc_out"
fi
fc_run_in "$HEADS" "$FCSTUBS/jqcwd:$PATH" "$IBODY"
if [ "$fc_rc" -eq 0 ] && printf '%s' "$fc_out" | grep -qF "$TXNEEDLE"; then
  pass=$((pass + 1)); printf '  ok   %s\n' "jq failing on the cwd read: denied, not allowed"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "jq failing on the cwd read: denied, not allowed" "$fc_rc" "$fc_out"
fi
# The alias scan in the prefilter: a sed that fails there must not hide a push alias.
fc_run "$FCSTUBS/sedalias:$PATH" 'git pom'
if [ "$fc_rc" -eq 0 ] && printf '%s' "$fc_out" | jq -e '.hookSpecificOutput.permissionDecision|IN("ask","deny")' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  ok   %s\n' "sed failing in the alias scan: a push alias is still judged"
else
  fail=$((fail + 1)); printf '  FAIL %s (rc %s, stdout: %s)\n' "sed failing in the alias scan: a push alias is still judged" "$fc_rc" "$fc_out"
fi
expect_quiet   "sed failing in the alias scan: git status stays silent" "$FCSTUBS/sedalias:$PATH" 'git status'
expect_quiet   "grep failing on the attribution scan: ls stays silent" "$FCSTUBS/greprule1:$PATH" 'ls -la'
expect_quiet   "sed failing on the template markers: ls stays silent" "$FCSTUBS/sedtpl:$PATH" 'ls -la'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Tests for the pre-merge gate: dot_claude/executable_xreview-guard.sh (the shell front and its
# fast path) and dot_claude/xreview-guard.py (the grammar and the checks), which decides through
# dot_claude/xreview-ledger.py. Spec: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md.
#
# Fixtures are real git repositories under $TMPDIR, with a private git configuration and
# XDG_STATE_HOME. origin is a bare repository reached through url.<path>.insteadOf, so its
# configured URL names a forge project (acme/app on forge.example) while every git call stays
# local. Every assertion pins an exact decision: "did not crash" is not evidence a guard fired.
#
# Many cases pin the ALLOW side. The guard fires on every Bash call, and its first matcher
# read "gh" out of "outright" and "create" out of "recreate": nine false denies to five real
# ones in the recorded transcripts (2026-09-03). A guard that stops unrelated work is worse
# than no guard.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SRC/dot_claude/executable_xreview-guard.sh"
HELPER="$SRC/dot_claude/xreview-guard.py"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
for f in "$GUARD" "$HELPER" "$LEDGER"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
L() { /usr/bin/python3 "$LEDGER" "$@"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrguard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" XREVIEW_LEDGER="$LEDGER" CALLS="$ROOT/calls" \
       GIT_CEILING_DIRECTORIES="$ROOT"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
unset XREVIEW_GUARD XREVIEW_GUARD_BUDGET XREVIEW_LEDGER_LOCK_WAIT
# The forge CLIs pick a host from these when no --hostname or host-qualified -R names one; the
# fixtures' forge is forge.example. gh's configuration directory starts empty, and glab's
# config names forge.example as its default host.
export GH_HOST=forge.example GH_CONFIG_DIR="$ROOT/gh" GLAB_CONFIG_DIR="$ROOT/glab"
unset GITLAB_HOST GITLAB_URI GL_HOST GITLAB_URL GITLAB_API_HOST GITLAB_REPO GH_REPO
mkdir -p "$GLAB_CONFIG_DIR" && printf 'host: forge.example\n' > "$GLAB_CONFIG_DIR/config.yml"

# W: the work repository, on main; feature is one change ahead. SIDE: a second worktree, on
# side. origin holds main only, until a section publishes more.
ORIGIN="$ROOT/remotes/app.git"; W="$ROOT/work/app"; SIDE="$ROOT/work/app-side"
git init -q --bare "$ORIGIN"
mkdir -p "$W" && git -C "$W" init -q
printf 'one\ntwo\nthree\n' > "$W/a.txt"; printf 'alpha\n' > "$W/b.txt"
git -C "$W" add a.txt b.txt && git -C "$W" commit -q -m init
git -C "$W" remote add origin 'git@forge.example:acme/app.git'
git -C "$W" config "url.$ORIGIN.insteadOf" 'git@forge.example:acme/app.git'
# publish <branch>...: origin takes these branches from W, and W fetches them back.
publish() {
  local b
  for b in "$@"; do git -C "$ORIGIN" fetch -q "$W" "+refs/heads/$b:refs/heads/$b"; done
  git -C "$W" fetch -q origin
}
publish main
git -C "$W" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$W" branch feature && git -C "$W" switch -q feature
printf 'one\nTWO\nthree\n' > "$W/a.txt"; git -C "$W" commit -q -am "edit a"
git -C "$W" switch -q main
git -C "$W" worktree add -q -b side "$SIDE" main
mkdir -p "$ROOT/norepo"

payload() { jq -n --arg d "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# The payload is materialised before the pipeline: the guard can exit without reading stdin,
# and jq writing into a closed pipe prints an error that looks like a test failure.
run_guard() { local p; p="$(payload "$1" "$2")"; printf '%s' "$p" | bash "$GUARD" 2>/dev/null; }
# decision <cwd> <command>: allow (silence), deny, or what else the guard printed.
decision() {
  local out; out="$(run_guard "$1" "$2")"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || printf 'malformed'
}
reason() { run_guard "$1" "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
# review <repo> <range> <verdict|pending> [checkpoint]: one review of <range> on record, as
# xreview writes it - a pending entry, then (unless pending) its receipt.
NREV=0
review() {
  local t at nonce common
  NREV=$((NREV + 1)); nonce="xr-test-$NREV"
  t="$(L normalize "$1" "$2")" || { echo "cannot normalize $2 in $1" >&2; return 1; }
  at="$(L now)"; common="$(printf '%s' "$t" | jq -r .repo)"
  L append "$common" "$(jq -nc --arg n "$nonce" --arg at "$at" --arg cp "${4:-pre-merge}" --argjson t "$t" \
    '{v:2,kind:"pending",nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:[$t]}')" >/dev/null
  [ "$3" = pending ] && return 0
  L append "$common" "$(jq -nc --arg n "$nonce" --arg at "$at" --arg cp "${4:-pre-merge}" --arg v "$3" --argjson t "$t" \
    '{v:2,kind:"receipt",nonce:$n,dispatched_at:$at,checkpoint:$cp,verdict:$v,findings:0,thread:"t",turn:"u",tier:"",targets:[$t]}')" >/dev/null
}

echo "A. what is never gated"
is "A1 an unrelated command" "$(decision "$W" 'git status')" allow
is "A2 a commit message that says merge" "$(decision "$W" 'git commit -m "merge the feature"')" allow
is "A3 rg for a gated verb" "$(decision "$W" "rg 'glab mr merge' docs/")" allow
is "A4 rg for another" "$(decision "$W" "rg 'gh pr create' docs/")" allow
is "A5 a Basecamp comment whose prose contains gh, pr and create" \
   "$(decision "$W" "printf '%s\\n' 'The runner outright refuses the proposed patch; recreate the cache.' | basecamp comments create 10268194367 - --in 47577890")" allow
is "A6 a card comment about a GitHub download" \
   "$(decision "$W" "printf '%s' '<p>Weights were fetched from <strong>github.com/ultralytics/assets</strong>; the proposed change recreates that path.</p>' | basecamp comments create 1 - --in 2")" allow
is "A7 an MR body written through a here-document, lines starting with gated verbs" \
   "$(decision "$W" 'cat > "$TMPDIR/mr-body.md" <<'"'"'EOF'"'"'
## How to land it
git merge feature
glab mr create --target-branch main
EOF')" allow
is "A8 help is never gated" "$(decision "$W" 'gh pr create --help')" allow
is "A9 git merge --abort" "$(decision "$W" 'git merge --abort')" allow
is "A10 git merge-base is another command" "$(decision "$W" 'git merge-base main feature')" allow
is "A11 a merge on a branch other than the default is not gated" "$(decision "$SIDE" 'git merge feature')" allow
is "A12 nor through git -C <path> on such a branch" "$(decision "$W" "git -C $SIDE merge feature")" allow
is "A13 a glab api read of an MR" "$(decision "$W" 'glab api projects/:id/merge_requests/7')" allow
is "A14 a gh api read of pulls" "$(decision "$W" "gh api 'repos/{owner}/{repo}/pulls' --jq '.[].number'")" allow
# A here-document delimiter is a whole shell word: quoted with any characters in it, or
# unquoted up to a metacharacter. The closing line must equal it, quotes removed.
SQ="'"; TAB="$(printf '\t')"
is "A15 a quoted delimiter with a hyphen" "$(decision "$W" "cat > \"\$TMPDIR/mr-body.md\" <<'MR-BODY'
## How to land it
git merge feature
glab mr create --target-branch main
MR-BODY")" allow
is "A16 the same under <<-, its closing line tab-indented" "$(decision "$W" "cat <<-'MR-BODY'
${TAB}git merge feature
${TAB}MR-BODY")" allow
is "A17 an unquoted delimiter with a dot" "$(decision "$W" 'cat > notes.md <<END.md
git merge feature
END.md')" allow
is "A18 a quoted delimiter with a space keeps its body inert" "$(decision "$W" 'cat <<"a b"
$(git merge feature)
a b')" allow
is "A19 only <<- strips tabs: under <<, a tab-indented delimiter is body" "$(decision "$W" "cat <<'EOF'
${TAB}EOF
git merge feature
EOF")" allow
# Every unquoted word naming git, glab or gh is read as a command word (section B), so these
# mentions stay allowed only because each is quoted, or not a gated verb at all.
is "A20 the commit-message idiom: a quoted here-document inside \$( ) inside double quotes" \
   "$(decision "$W" "git commit --allow-empty -m \"\$(cat <<'EOF'
Land it: git merge feature
Then \`glab mr create --target-branch main\`.
EOF
)\"")" allow
is "A21 rg with an alternation of gated verbs" "$(decision "$W" "rg -n 'git merge|glab mr create' docs/")" allow
is "A22 read-only uses of the same words" \
   "$(decision "$W" 'git log --merges --oneline') $(decision "$W" 'git branch --merged main') $(decision "$W" 'gh pr list --state merged') $(decision "$W" 'glab mr view 7')" \
   "allow allow allow allow"
is "A23 quoted mentions: single-quoted backticks, an echo to a file, a chained commit message" \
   "$(decision "$W" "git commit -m 'Use \`git merge\` with care'") $(decision "$W" "echo 'git merge feature' > notes.txt") $(decision "$W" 'git add -A && git commit -m "merge notes for gh pr create"')" \
   "allow allow allow"
is "A24 git merge-base in a chain" "$(decision "$W" 'git merge-base --is-ancestor feature main && echo yes')" allow
is "A25 an ANSI-C string is one quoted word" "$(decision "$W" "printf \$${SQ}%s\\n${SQ} \$${SQ}git merge feature${SQ}")" allow
is "A26 the commit-message idiom with an apostrophe and a case) in its body" \
   "$(decision "$W" "git commit -m \"\$(cat <<'EOF'
Merge notes: run git merge feature, then gh pr create.
It's the edge case) fix.
EOF
)\"")" allow
is "A27 arithmetic is data" "$(decision "$W" 'echo $((1 << 2)) $(( (1 + 2) * 3 ))')" allow
is "A28 case as a plain word inside a substitution ends nothing" \
   "$(decision "$W" 'git commit -m "$(echo merge the edge case)"')" allow
is "A29 quotes nested in a substitution inside double quotes" \
   "$(decision "$W" "gh pr edit 12 --title \"\$(jq -r '.title + \" (rev)\"' meta.json)\"")" allow
is "A30 \$((cmd) | ...) is a substitution: a quoted here-document in it is data" "$(decision "$W" "echo \$((cat <<'EOF'
git merge feature
EOF
) | tr a-z A-Z)")" allow
is "A31 a ) inside a parameter expansion is text" \
   "$(decision "$W" 'echo "$(echo ${x%)})"') $(decision "$W" 'git log --format="${fmt:-%h (%s)}"')" "allow allow"
is "A32 reads whose options name merge stay allowed, whatever their order" \
   "$(decision "$W" 'gh pr list --search merge') $(decision "$W" 'glab mr list --merged') $(decision "$W" 'gh pr view 12 --json title,mergedAt') $(decision "$W" 'glab mr view 7 --comments') $(decision "$W" 'gh -R acme/app pr view 1')" \
   "allow allow allow allow allow"

echo "B. a gated verb must be a plain command"
is "B1 a chain that switches branch first" "$(decision "$W" 'git switch main && git merge feature')" deny
is "B2 a ; chain before an MR creation" "$(decision "$W" 'true; glab mr create --target-branch main')" deny
is "B3 the verb after an assignment on a previous line" "$(decision "$W" 'SP=/tmp/scratch
glab mr create --description "$(cat "$SP/mr-body.md")" --target-branch main --yes')" deny
is "B4 the verb after a pipe" "$(decision "$W" 'printf body | gh pr create --base main --body-file -')" deny
is "B5 an environment assignment on the verb" "$(decision "$W" 'GH_REPO=o/r gh pr create --base main')" deny
is "B6 GIT_DIR on a merge" "$(decision "$W" 'GIT_DIR=/tmp/x git merge feature')" deny
is "B7 an env wrapper" "$(decision "$W" 'env GITLAB_HOST=x glab mr merge 7')" deny
is "B8 a subshell" "$(decision "$W" '(git merge feature)')" deny
is "B9 a merge in a chain on a feature branch is denied too" "$(decision "$SIDE" 'git fetch origin && git merge origin/main')" deny
is "B10 an API merge piped to jq" "$(decision "$W" 'glab api -X PUT projects/:id/merge_requests/7/merge | jq .state')" deny
is "B11 the deny asks for the plain form" "$(reason "$W" 'git switch main && git merge feature' | grep -c 'plain command of its own')" 1
is "B12 a leading redirection hides no verb" "$(decision "$W" '>merge.log git merge feature')" deny
is "B13 nor does a descriptor redirection" "$(decision "$W" '2>err git merge feature')" deny
is "B14 sudo with an option is denied" "$(decision "$W" 'sudo -u root git merge feature')" deny
is "B15 a merge whose message is --help is still gated" "$(decision "$W" 'git merge -m "--help" feature')" deny
is "B16 a creation titled --help is still gated" "$(decision "$W" 'glab mr create -s feature -b main --title --help')" deny
is "B17 --abort beside a ref is still gated" "$(decision "$W" 'git merge --abort feature')" deny
is "B18 a process substitution runs a command" "$(decision "$W" 'cat <(git merge feature)')" deny
# Command substitutions run, quoted with double quotes or not; single quotes keep them inert.
is "B19 a substitution inside double quotes runs its command" "$(decision "$W" 'echo "$(git merge feature)"')" deny
is "B20 so does a backtick substitution inside double quotes" "$(decision "$W" 'echo "`git merge feature`"')" deny
is "B21 and an unquoted backtick one" "$(decision "$W" 'echo `git merge feature`')" deny
is "B22 even in an ungated command's message" "$(decision "$W" 'git commit -m "$(git merge feature)"')" deny
is "B23 at any depth" "$(decision "$W" 'echo "$(echo `git merge feature`)"')" deny
is "B24 the deny asks for the plain form" "$(reason "$W" 'echo "$(git merge feature)"' | grep -c 'plain command of its own')" 1
is "B25 single quotes keep both kinds inert" "$(decision "$W" "echo ${SQ}\$(git merge feature)${SQ} ${SQ}\`git merge feature\`${SQ}")" allow
is "B26 so does a backslash" "$(decision "$W" 'echo "\$(git merge feature)"')" allow
is "B27 and a comment" "$(decision "$W" 'git status # $(git merge feature)')" allow
# A here-document whose delimiter is unquoted expands its substitutions; the rest of its body,
# and the whole body under a quoted delimiter, is data.
is "B28 an unquoted here-document runs its substitutions" "$(decision "$W" 'cat > notes.md <<EOF
done: $(git merge feature)
EOF')" deny
is "B29 a backtick code span in an unquoted MR body runs too" "$(decision "$W" 'cat > "$TMPDIR/mr-body.md" <<EOF
Land it with `glab mr create --target-branch main`.
EOF')" deny
is "B30 so does a tab-stripped <<-EOF body" "$(decision "$W" "cat <<-EOF
${TAB}\$(git merge feature)
${TAB}EOF")" deny
is "B31 the rest of an unquoted body is data" "$(decision "$W" 'cat > notes.md <<EOF
git merge feature
on $(date +%F)
EOF')" allow
is "B32 a quoted or escaped delimiter keeps the whole body inert" \
   "$(decision "$W" "cat <<${SQ}EOF${SQ}
\$(git merge feature)
EOF") $(decision "$W" 'cat <<"EOF"
$(git merge feature)
EOF') $(decision "$W" 'cat <<\EOF
`git merge feature`
EOF')" "allow allow allow"
is "B33 an unquoted delimiter with a dot still expands its body" "$(decision "$W" 'cat <<END.md
$(git merge feature)
END.md')" deny
# A redirection operator needs no blank before it: git>log is git, then a redirection.
is "B34 a redirection fused to the command word" "$(decision "$W" 'git>merge.log merge feature')" deny
is "B35 fused to the verb" "$(decision "$W" 'git merge>merge.log feature')" deny
is "B36 fused to glab's subcommand" "$(decision "$W" 'glab mr>create.log create -s feature -b main')" deny
is "B37 and to glab" "$(decision "$W" 'glab>create.log mr create -s feature -b main')" deny
is "B38 fused redirections before the command word" "$(decision "$W" '>merge.log<in.txt git merge feature')" deny
is "B39 a <<- body ends at its tab-indented delimiter, and what follows runs" "$(decision "$W" "cat <<-'EOF'
${TAB}EOF
git merge feature
EOF")" deny
# Any word can be a command word: after a wrapper, a zsh precommand modifier, a keyword or an
# assignment. Each of these really runs the merge, under bash, zsh or both.
is "B40 timeout runs its command" "$(decision "$W" 'timeout 30 git merge feature')" deny
is "B41 so do caffeinate, stdbuf and xcrun" \
   "$(decision "$W" 'caffeinate -i git merge feature') $(decision "$W" 'stdbuf -oL git merge feature') $(decision "$W" 'xcrun git merge feature')" \
   "deny deny deny"
is "B42 and find -exec" "$(decision "$W" 'find . -maxdepth 0 -exec git merge feature \;')" deny
is "B43 a wrapped MR or PR creation" \
   "$(decision "$W" 'timeout 30 glab mr create --target-branch main') $(decision "$W" 'timeout 30 gh pr create --base main')" \
   "deny deny"
is "B44 a function body" "$(decision "$W" 'function f { git merge feature; }; f')" deny
is "B45 coproc" "$(decision "$W" 'coproc git merge feature; wait')" deny
is "B46 a NAME+= assignment" "$(decision "$W" 'A+=1 git merge feature')" deny
is "B47 zsh's noglob, nocorrect and repeat" \
   "$(decision "$W" 'noglob git merge feature') $(decision "$W" 'nocorrect git merge feature') $(decision "$W" 'repeat 1 git merge feature')" \
   "deny deny deny"
is "B48 zsh's =git is git" "$(decision "$W" '=git merge feature')" deny
is "B49 env -S and --split-string hand their string to a command" \
   "$(decision "$W" "env -S 'git merge feature'") $(decision "$W" "env --split-string='git merge feature'")" "deny deny"
is "B50 so does a shell's -c" \
   "$(decision "$W" "bash -c 'git merge feature'") $(decision "$W" "zsh -c 'git merge feature'") $(decision "$W" "sh -lc 'git merge feature'")" \
   "deny deny deny"
is "B51 an unquoted mention is denied too" "$(decision "$W" 'echo git merge feature')" deny
is "B52 asking to quote it" "$(reason "$W" 'echo git merge feature' | grep -c 'quote the mention')" 1
# A backslash-newline is deleted before anything else is read, as the shell deletes it, unless
# the backslash is itself escaped.
is "B53 a continuation inside the verb" "$(decision "$W" 'git mer\
ge feature')" deny
is "B54 an escaped backslash does not continue the line" "$(decision "$W" 'echo x\\
git merge feature')" deny
is "B55 a continuation inside an expanding here-document's substitution" "$(decision "$W" 'cat <<EOF
$(git mer\
ge feature)
EOF')" deny
is "B56 a continuation after a here-document operator joins the next line to the command" "$(decision "$W" 'cat <<EOF \
&& git merge feature
body
EOF')" deny
# << starts a here-document only in shell text, never inside quotes or a comment.
is "B57 inside a comment it hides nothing" "$(decision "$W" 'git status # see <<EOF
git merge feature
EOF')" deny
is "B58 nor inside a double-quoted string" "$(decision "$W" 'echo "x <<EOF y"
git merge feature
EOF')" deny
is "B59 an ANSI-C string, its escaped quote included, is one word" \
   "$(decision "$W" "echo \$${SQ}a\\${SQ}b${SQ} ; git merge feature ; echo ${SQ}\\${SQ}")" deny
is "B60 and keeps the rest of the command readable" "$(decision "$W" "echo \$${SQ}it\\${SQ}s${SQ}
git \\
merge feature")" deny
is "B61 git --attr-source takes a value" "$(decision "$W" 'git --attr-source HEAD merge feature')" deny
is "B62 a case pattern's ) does not end a substitution" \
   "$(decision "$W" 'echo "$(case x in x) git merge feature;; esac)"')" deny
is "B63 a # glued to a substitution's ) is part of the word, not a comment" \
   "$(decision "$W" 'echo $(echo a)#b; git merge feature')" deny
is "B64 a backtick body's escaped backticks nest a substitution" \
   "$(decision "$W" 'echo `echo \`git merge feature\``')" deny
is "B65 a continuation can form an unquoted here-document's delimiter" "$(decision "$W" 'cat <<EOF
x
EO\
F
git merge feature
EOF')" deny
is "B66 << inside arithmetic is a shift, not a here-document" "$(decision "$W" 'echo $((1<<2))
git merge feature
2') $(decision "$W" 'echo "$((1<<2))"
git merge feature
2')" "deny deny"
is "B67 \$((cmd) | ...) is a substitution holding a subshell, not arithmetic" \
   "$(decision "$W" 'echo $((echo a) | git merge feature)')" deny
is "B68 an ANSI-C string can spell the command word" "$(decision "$W" "\$${SQ}\\x67it${SQ} merge feature")" deny
is "B69 and is read even where the rest cannot be parsed" \
   "$(decision "$W" "\$${SQ}\\x67it${SQ} merge feature; echo \"unterminated")" deny
is "B70 case only counts as a keyword where a command starts" "$(decision "$W" 'echo "$(echo case) <<EOF "
#"
git merge feature
EOF')" deny
is "B71 quotes inside a substitution never pair with the quotes around it" \
   "$(decision "$W" "echo \"\$(printf '\"')\" ; git merge feature ; echo \"\$(printf '\"')\"")" deny
# case counts at every command start, so its patterns' ) never end the substitution early.
is "B72 a case that starts a case pattern's command" \
   "$(decision "$W" 'echo "$(case c in a) case b in b) :;; esac;; c) git merge feature;; esac)"')" deny
is "B73 a case after time -p" "$(decision "$W" 'echo "$(time -p case x in x) git merge feature;; esac)"')" deny
is "B74 a case right after \$(! and \$({" \
   "$(decision "$W" 'echo "$(! case x in x) git merge feature;; esac)"') $(decision "$W" 'echo "$({ case x in x) git merge feature;; esac; })"')" \
   "deny deny"
is "B75 a # glued to a process substitution's ) is part of the word, not a comment" \
   "$(decision "$W" 'cat <(echo a)#b; git merge feature')" deny
# Substitution bodies are read a second time, counting case wherever the word stands, so a
# command start the first reading misses cannot end a substitution early.
is "B76 a case that is a function's body" "$(decision "$W" 'echo "$(f() case x in x) git merge feature;; esac; f)"')" deny
is "B77 a case after coproc" "$(decision "$W" 'echo "$(coproc case x in x) git merge feature;; esac; wait)"')" deny
is "B78 a case after zsh's repeat 1" "$(decision "$W" 'echo "$(repeat 1 case x in x) git merge feature;; esac)"')" deny
is "B79 a case after zsh's short for" "$(decision "$W" 'echo "$(for x (a) case $x in a) git merge feature;; esac)"')" deny
is "B80 and after then {, a (pattern), a nested group and select do" \
   "$(decision "$W" 'echo "$(if true; then { case x in x) git merge feature;; esac; }; fi)"') $(decision "$W" 'echo "$(case x in (x) git merge feature;; esac)"') $(decision "$W" 'echo "$(case c in c) { case d in d) git merge feature;; esac; };; esac)"') $(decision "$W" 'echo "$(select v in a; do case $v in *) git merge feature;; esac; break; done <<< 1)"')" \
   "deny deny deny deny"
is "B81 the second reading covers an expanding here-document's substitutions too" "$(decision "$W" 'cat <<EOF
$(f() case x in x) git merge feature;; esac; f)
EOF')" deny
# esac lowers the count only where a command starts: an esac argument ends no case.
is "B82 esac as an argument, after a missed case start" \
   "$(decision "$W" 'echo "$(f() case y in x) echo esac;; y) git merge feature;; esac; f)"')" deny
is "B83 the same inside an expanding here-document" "$(decision "$W" 'cat <<EOF
$(f() case y in x) echo esac;; y) git merge feature;; esac; f)
EOF')" deny
is "B84 and after coproc, or at a counted case start" \
   "$(decision "$W" 'echo "$(coproc case y in x) echo esac;; y) git merge feature;; esac; wait)"') $(decision "$W" 'echo "$(case y in x) echo esac;; y) git merge feature;; esac)"')" \
   "deny deny"
# Inside ${...} a ( or ) is text: it never ends the substitution around it.
is "B85 a ) in \${x//)/} or \${x:-)}" \
   "$(decision "$W" 'echo "$(echo ${x//)/}; git merge feature)"') $(decision "$W" 'echo "$(echo ${x:-)}; git merge feature)"')" \
   "deny deny"
is "B86 the same in an expanding here-document's substitution" "$(decision "$W" 'cat <<EOF
$(echo ${x//)/}; git merge feature)
EOF')" deny
# glab and gh (cobra) take a subcommand's options before its name and between its words; the
# gate checks them only in its own order, so any other order that could spell a gated verb is
# denied, naming that order.
order() { reason "$W" "$1" | grep -c -F -- "$2"; }
is "B87 glab with a creation's options before or inside mr create, even -y alone" \
   "$(order 'glab -s other mr create -b main -t T --yes' 'Write it as glab [-R <project>] mr create')$(order 'glab mr -s other create -b main -t T --yes' 'Write it as glab [-R <project>] mr create')$(order 'glab -b main mr create -s other -t T --yes' 'Write it as glab [-R <project>] mr create')$(order 'glab -y mr create -s feature -b main -t T' 'Write it as glab [-R <project>] mr create')" 1111
is "B88 glab with an api call's options before api" \
   "$(order 'glab -X POST api projects/:id/merge_requests -f source_branch=other -f target_branch=main' 'Write it as glab api [options] <endpoint>')$(order 'glab -f source_branch=other api -X POST projects/:id/merge_requests -f target_branch=main' 'Write it as glab api [options] <endpoint>')" 11
is "B89 gh the same" \
   "$(order 'gh --head other pr create --base main -t T -b B' 'Write it as gh [-R <project>] pr create')$(order 'gh pr --head other create --base main -t T -b B' 'Write it as gh [-R <project>] pr create')$(order 'gh -X POST api repos/acme/app/pulls -f head=other -f base=main' 'Write it as gh api [options] <endpoint>')" 111
is "B90 and the merge verbs" \
   "$(order 'glab --sha abc mr merge 5' 'Write it as glab [-R <project>] mr merge')$(order 'gh pr --match-head-commit abc merge 5' 'Write it as gh [-R <project>] pr merge')" 11
# bash 5.3 runs ${ cmd; } and ${| cmd; } in the current shell, as $( ) runs cmd; a } that
# starts a command ends one, and a { group inside it does not.
is "B91 bash 5.3's \${ cmd; } and \${| cmd; } run their command" \
   "$(reason "$W" 'echo "${ git merge feature; }"' | grep -c 'plain command of its own') $(reason "$W" "bash -c 'echo \"\${ git merge feature; }\"'" | grep -c 'plain command of its own') $(reason "$W" 'echo ${| REPLY=x; git merge feature; }' | grep -c 'plain command of its own')" \
   "1 1 1"
is "B92 an argument } or a { group inside one does not end it" \
   "$(reason "$W" 'echo "${ echo }; git merge feature; }"' | grep -c 'plain command of its own') $(reason "$W" 'echo "${ { true; }; git merge feature; }"' | grep -c 'plain command of its own')" \
   "1 1"
is "B93 a parameter expansion stays text" "$(decision "$W" 'echo "${x:-git merge feature} ${#x} ${x}"')" allow
# bash 3.2 (/bin/bash, and macOS /bin/sh) ends a $( ) at its first ), a case pattern's or one
# inside ${...}, so a quote after it pairs differently and a verb the other readings see as
# quoted text runs there.
SQ="'"; T1='echo "$(echo ${x//)/} " ; git merge feature ; ")"'; V1='echo "$(case x in x) echo " ; git merge feature ; " ;; esac)"'
is "B94 a ) inside \${...}, read as bash 3.2 reads it: direct, through sh -c and /bin/bash -c" \
   "$(reason "$W" "$T1" | grep -c 'plain command of its own') $(reason "$W" "sh -c $SQ$T1$SQ" | grep -c 'plain command of its own') $(reason "$W" "/bin/bash -c $SQ$T1$SQ" | grep -c 'plain command of its own')" \
   "1 1 1"
is "B95 and a case pattern's ), direct and through sh -c" \
   "$(reason "$W" "$V1" | grep -c 'plain command of its own') $(reason "$W" "sh -c $SQ$V1$SQ" | grep -c 'plain command of its own')" \
   "1 1"

echo "C. git merge into the default branch"
is "C1 an unreviewed merge into main is denied" "$(decision "$W" 'git merge feature')" deny
r="$(reason "$W" 'git merge feature')"
is "C2 the deny names the dispatch that opens the gate" "$(printf '%s' "$r" | grep -c -- '--checkpoint pre-merge --diff main...feature <body-file>')" 1
is "C3 and the change's fingerprint" "$(printf '%s' "$r" | grep -cE 'fingerprint [0-9a-f]{64}')" 1
is "C4 and offers the bypass only when Michael asked" "$(printf '%s' "$r" | tr '\n' ' ' | grep -c 'Only if Michael has asked, in this conversation')" 1
review "$W" main...feature approve
is "C5 an approved full change opens it" "$(decision "$W" 'git merge feature')" allow
is "C6 with options and a message" "$(decision "$W" 'git merge --no-ff -m "Land feature" feature')" allow
is "C7 from cd <path> &&" "$(decision "$ROOT" "cd $W && git merge feature")" allow
is "C8 and from git -C <path>" "$(decision "$SIDE" "git -C $W merge feature")" allow
is "C9 a trailing comment is not a second ref" "$(decision "$W" 'git merge feature # land it')" allow
git -C "$W" switch -q feature; printf 'four\n' >> "$W/b.txt"; git -C "$W" commit -q -am "one more"; git -C "$W" switch -q main
is "C10 one extra commit closes it" "$(decision "$W" 'git merge feature')" deny
is "C11 the deny lists what is on record for the branch" "$(reason "$W" 'git merge feature' | grep -c 'On record for branch feature: pre-merge/approve xr-test-1')" 1
review "$W" main...feature approve
is "C12 a fresh full-range round reopens it" "$(decision "$W" 'git merge feature')" allow
is "C13 two refs at once are denied" "$(decision "$W" 'git merge feature side')" deny
is "C14 a merge that names no ref is denied" "$(decision "$W" 'git merge')" deny
is "C15 an empty change is denied" "$(decision "$W" 'git merge side')" deny
is "C16 redirections after an approved merge are read past" "$(decision "$W" 'git merge feature > merge.log 2>&1')" allow
is "C17 and before it" "$(decision "$W" '>merge.log git merge feature')" allow
is "C18 a harmless substitution in an approved merge stays allowed" "$(decision "$W" 'git merge -m "$(cat /tmp/msg)" feature')" allow
is "C19 a redirection fused to the ref is read past" "$(decision "$W" 'git merge feature>merge.log')" allow
is "C20 and one fused to the command word" "$(decision "$W" 'git>merge.log merge feature')" allow
is "C21 and one fused to the verb" "$(decision "$W" 'git merge>merge.log feature')" allow
is "C22 every operator form, fused" \
   "$(for c in 'feature>>m.log' 'feature<in.txt' 'feature 2>err>m.log' 'feature&>m.log' 'feature>&2' 'feature 2>&1' 'feature<>m.log' 'feature>|m.log'; do
        decision "$W" "git merge $c"; printf ' '; done)" \
   "allow allow allow allow allow allow allow allow "
is "C23 an approved merge across line continuations" "$(decision "$W" 'git merge \
feature') $(decision "$W" 'git mer\
ge feature')" "allow allow"
is "C24 and run as zsh's =git" "$(decision "$W" '=git merge feature')" allow
# git merge FETCH_HEAD merges every head this worktree's last fetch marked for merge, all at
# once, so the gate allows it only while there is exactly one.
fetch_head() { printf '%b\n' "$2" > "$(git -C "$1" rev-parse --path-format=absolute --git-path FETCH_HEAD)"; }
FEAT="$(git -C "$W" rev-parse feature)"; SIDEC="$(git -C "$W" rev-parse side)"
git -C "$W" fetch -q "$W" feature side
is "C25 FETCH_HEAD with two heads to merge is denied" \
   "$(reason "$W" 'git merge FETCH_HEAD' | grep -c 'merges every head the last fetch marked for merge')" 1
git -C "$W" fetch -q "$W" feature
is "C26 with one, it is that head: the approved change merges" "$(decision "$W" 'git merge FETCH_HEAD')" allow
fetch_head "$W" "$FEAT\t\tbranch 'feature' of x\n$SIDEC\tnot-for-merge\tbranch 'side' of x"
is "C27 a head marked not-for-merge does not count" "$(decision "$W" 'git merge FETCH_HEAD')" allow
WT2="$ROOT/work/app-main2"; git -C "$W" worktree add -q -f "$WT2" main
fetch_head "$W" "$FEAT\t\tbranch 'feature' of x\n$SIDEC\t\tbranch 'side' of x"
fetch_head "$WT2" "$FEAT\t\tbranch 'feature' of x"
is "C28 each worktree has its own FETCH_HEAD" "$(decision "$WT2" 'git merge FETCH_HEAD')" allow
git -C "$W" worktree remove --force "$WT2"
# On main, syncing with origin's own main lands work that is already there; another ref at the
# same commit is still a change of its own. origin/main moves to a commit no review saw.
git -C "$W" switch -q -c landed main; printf 'landed\n' > "$W/l.txt"; git -C "$W" add l.txt
git -C "$W" commit -q -m landed; git -C "$W" switch -q main
SAVED="$(git -C "$W" rev-parse refs/remotes/origin/main)"
git -C "$W" update-ref refs/remotes/origin/main landed
git -C "$W" branch -q --set-upstream-to=origin/main main
is "C29 git merge --ff-only origin/main is a sync, allowed" "$(decision "$W" 'git merge --ff-only origin/main')" allow
is "C30 so are refs/remotes/origin/main and @{u}" \
   "$(decision "$W" 'git merge refs/remotes/origin/main') $(decision "$W" 'git merge --ff-only @{u}')" "allow allow"
is "C31 a branch at the same commit is gated" \
   "$(reason "$W" 'git merge landed' | grep -c 'no full-range pre-merge review of this change is on record')" 1
git -C "$W" branch -q --unset-upstream main; git -C "$W" update-ref refs/remotes/origin/main "$SAVED"
git -C "$W" branch -q -D landed
is "C32 a harmless bash 5.3 substitution in an approved merge stays allowed" \
   "$(decision "$W" 'git merge -m ${ cat /tmp/msg; } feature')" allow

echo "D. it fails closed"
is "D1 a merge outside any repository is denied" "$(decision "$ROOT/norepo" 'git merge feature')" deny
is "D2 saying why" "$(reason "$ROOT/norepo" 'git merge feature' | grep -c 'is not inside a git repository')" 1
LF="$(L path "$W")"
chmod 000 "$LF"
is "D3 an unreadable ledger is a deny" "$(decision "$W" 'git merge feature')" deny
is "D4 naming it" "$(reason "$W" 'git merge feature' | grep -c 'is unreadable')" 1
chmod 644 "$LF"
is "D5 readable again, the approval stands" "$(decision "$W" 'git merge feature')" allow
is "D6 unbalanced quotes around a gated verb" "$(decision "$W" 'git merge "feature')" deny
# The current branch decides whether a merge is gated. A lookup that fails or times out says
# nothing, so it must not open the gate; only a verifiably detached HEAD is no branch.
WRAP="$ROOT/wrap"; mkdir -p "$WRAP"; REALGIT="$(command -v git)"
shim() { printf '%s\n' '#!/bin/sh' "case \"\$*\" in *\"symbolic-ref --quiet --short HEAD\") $1 ;; esac" "exec $REALGIT \"\$@\"" > "$WRAP/git"; chmod +x "$WRAP/git"; }
shim 'exit 128'
is "D7 a failing branch lookup is a deny, even for an approved merge" "$(PATH="$WRAP:$PATH" decision "$W" 'git merge feature')" deny
is "D8 saying why" "$(PATH="$WRAP:$PATH" reason "$W" 'git merge feature' | grep -c 'current branch of .* cannot be read')" 1
shim 'sleep 9; exit 0'
is "D9 so is one that times out" "$(PATH="$WRAP:$PATH" decision "$W" 'git merge feature')" deny
git -C "$SIDE" switch -q --detach
is "D10 a detached HEAD is no branch, so its merge is not gated" "$(decision "$SIDE" 'git merge feature')" allow
git -C "$SIDE" switch -q side
# A payload that is not JSON is read as text.
is "D11 a truncated payload holding a merge is denied" \
   "$(printf '%s' '{"tool_input":{"command":"git merge feature"},"cwd":"'"$W"'"' | bash "$GUARD" 2>/dev/null | jq -r .hookSpecificOutput.permissionDecision)" deny
is "D12 one that only mentions merges is let through" \
   "$(printf '%s' '{"tool_input":{"command":"git log --merges"' | bash "$GUARD" 2>/dev/null)" ""

echo "E. the bypass is Michael's"
is "E1 XREVIEW_GUARD=off on the command" "$(decision "$W" 'XREVIEW_GUARD=off git merge side')" allow
is "E2 mid-command" "$(decision "$W" 'cd /tmp && XREVIEW_GUARD=off glab mr create --fill')" allow
is "E3 in a trailing comment" "$(decision "$W" 'glab mr create --fill # XREVIEW_GUARD=off')" allow
XREVIEW_GUARD=off; export XREVIEW_GUARD
is "E4 in the hook's environment" "$(decision "$W" 'git merge side')" allow
unset XREVIEW_GUARD
is "E5 an empty payload fails open" "$(printf '' | bash "$GUARD" 2>/dev/null | wc -c | tr -d ' ')" 0

echo "F. the fast path costs nothing, and a helper that cannot run fails closed"
TRIP="$ROOT/trip"; mkdir -p "$TRIP"
cp "$GUARD" "$TRIP/xreview-guard.sh"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$TRIP/xreview-guard.py"
tripped() { [ -e "$TRIP/xreview-guard.py.ran" ] && echo ran || echo idle; }
for c in 'ls -la' 'git status' 'npm test' 'git log --oneline -5' 'mkdir -p newdir' \
         'for f in a b; do git add "$f"; done' 'git log --format=%ad -3'; do
  payload /tmp "$c" | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
done
is "F1 commands without a trigger word never start the helper" "$(tripped)" idle
payload /tmp 'git merge feature' | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F2 a gated verb does" "$(tripped)" ran
printf 'import sys\nsys.exit(3)\n' > "$TRIP/xreview-guard.py"
out="$(payload "$W" 'git merge feature' | bash "$TRIP/xreview-guard.sh" 2>/dev/null)"
is "F3 a helper that cannot run denies a gated verb" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision)" deny
out="$(payload "$W" 'git commit -m "a new test"' | bash "$TRIP/xreview-guard.sh" 2>/dev/null)"
is "F4 and leaves an ungated command alone" "$out" ""
# The fast path reads the payload with quotes, backslashes and continuations dropped.
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$TRIP/xreview-guard.py"
rm -f "$TRIP/xreview-guard.py.ran"
payload /tmp "g''it mer''ge feature" | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F5 quotes inside a word do not hide a verb from the fast path" "$(tripped)" ran
rm -f "$TRIP/xreview-guard.py.ran"
payload /tmp 'git mer\
ge feature' | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F6 nor does a line continuation" "$(tripped)" ran
is "F7 and the helper reads the merge (side has no change of its own: denied)" "$(decision "$W" "g''it mer''ge side")" deny
# With the helper missing, the front's own last resort reads whole words, joined lines and
# words split by quotes.
NOH="$ROOT/nohelper"; mkdir -p "$NOH"; cp "$GUARD" "$NOH/xreview-guard.sh"
fallback() { local out; out="$(payload "$W" "$1" | bash "$NOH/xreview-guard.sh" 2>/dev/null)"
  [ -n "$out" ] && printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision || printf allow; }
is "F8 with the helper missing, fused redirections are denied" \
   "$(fallback 'git>m.log merge feature') $(fallback 'git merge>m.log feature') $(fallback 'glab mr>c.log create -b main')" \
   "deny deny deny"
is "F9 and so are a continuation, a backtick and an escaped backslash" \
   "$(fallback 'git \
merge feature') $(fallback 'echo `git merge`') $(fallback 'echo x\\
git merge feature')" "deny deny deny"
is "F10 and a word split by quotes" "$(fallback "g''it mer''ge feature")" deny
is "F11 while a mention of merges stays allowed" "$(fallback 'git log --merges')" allow
# The hook gives up at its time limit and then lets the command through, so the front must be
# linear in the payload's size under the oldest bash a client may run, macOS's /bin/bash 3.2.
# timed <payload-file>: the front's decision under /bin/bash and its wall time in ms; a run past
# 30 s is cut off and reads "timeout".
timed() {
  /usr/bin/python3 - "$GUARD" "$1" <<'PY'
import json, subprocess, sys, time
start = time.time()
try:
    with open(sys.argv[2], "rb") as fh:
        out = subprocess.run(["/bin/bash", sys.argv[1]], stdin=fh, capture_output=True,
                             timeout=30).stdout
    verdict = json.loads(out)["hookSpecificOutput"]["permissionDecision"] if out.strip() else "allow"
except subprocess.TimeoutExpired:
    verdict = "timeout"
print(verdict, int((time.time() - start) * 1000))
PY
}
big="$(/usr/bin/python3 -c "import sys; sys.stdout.write(('lorem ipsum dolor sit amet \"quoted\" it\\'s a \\\\ path\\n') * 340)")"
payload "$W" "cat > out.txt <<'X'
$big
X
git merge feature" > "$ROOT/big-gated.json"
payload "$W" "cat > out.txt <<'X'
$big
X" > "$ROOT/big-plain.json"
read -r verdict ms < <(timed "$ROOT/big-gated.json")
is "F12 a 15 KB payload ending in a gated verb is denied within seconds under /bin/bash" \
   "$verdict $([ "$ms" -lt 5000 ] && echo fast || echo "slow:${ms}ms")" "deny fast"
read -r verdict ms < <(timed "$ROOT/big-plain.json")
is "F13 and one with no gated verb is allowed at once" \
   "$verdict $([ "$ms" -lt 2000 ] && echo fast || echo "slow:${ms}ms")" "allow fast"
# glab mr for and gh pr revert name no other trigger word: mr with for, and revert, reach the
# helper (a for loop without mr does not, F1).
rm -f "$TRIP/xreview-guard.py.ran"
payload /tmp 'glab mr for 3' | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F14 glab mr for starts the helper" "$(tripped)" ran
rm -f "$TRIP/xreview-guard.py.ran"
payload /tmp 'gh pr revert 9' | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F15 so does gh pr revert" "$(tripped)" ran
# A percent-escape can spell any word of an api call's path (m%65rge_requests), so api with one
# reaches the helper (a %ad format without api does not, F1).
rm -f "$TRIP/xreview-guard.py.ran"
payload /tmp "gh api graph%71l -f query='mutation { enqueuePullRequest(input: {}) { clientMutationId } }'" | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F16 an api call with a percent-escape starts the helper" "$(tripped)" ran
# The deployed layout: the front, the guard and the ledger helper side by side, as in ~/.claude,
# with no XREVIEW_LEDGER: the guard finds the helper beside itself.
DEP="$ROOT/deployed"; mkdir -p "$DEP"
cp "$GUARD" "$DEP/xreview-guard.sh"; cp "$HELPER" "$LEDGER" "$DEP/"
deployed() { payload "$W" "$1" | env -u XREVIEW_LEDGER bash "$DEP/xreview-guard.sh" 2>/dev/null; }
is "F17 deployed, an approved merge is decided from the ledger beside the guard" "$(deployed 'git merge feature')" ""
is "F18 and an unreviewed one is denied for its change" \
   "$(deployed 'git merge side' | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'Pre-merge gate: the change is empty')" 1
mv "$DEP/xreview-ledger.py" "$DEP/ledger.moved"
is "F19 a missing ledger helper denies" \
   "$(deployed 'git merge feature' | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'cannot be loaded, so the command is refused')" 1
mv "$DEP/ledger.moved" "$DEP/xreview-ledger.py"; mv "$DEP/xreview-guard.py" "$DEP/guard.moved"
is "F20 a missing guard helper denies a gated verb" \
   "$(deployed 'git merge feature' | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'could not run')" 1

echo "H. creating an MR/PR"
# glab answers the one lookup creation makes, a numeric project id; anything else fails, so an
# unexpected call shows up as a deny rather than passing silently. The host a call reaches is
# its --hostname, else glab's host variables, else origin's; on another host, project 4242 is
# ELSEWHERE_PATH.
STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'SH'
#!/bin/sh
printf 'glab %s\n' "$*" >> "$CALLS"
host="${GITLAB_HOST:-${GITLAB_URI:-${GL_HOST:-forge.example}}}"
if [ "$1" = api ] && [ "$2" = --hostname ]; then host="$3"; shift 3; set -- api "$@"; fi
path="${PROJECT_PATH:-acme/app}"
[ "$host" = forge.example ] || path="${ELSEWHERE_PATH:-$path}"
case "$*" in
  "api projects/4242") printf '{"id":4242,"path_with_namespace":"%s"}\n' "$path" ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >> "$CALLS"\nexit 1\n' > "$STUB/gh"
chmod +x "$STUB/glab" "$STUB/gh"
export PATH="$STUB:$PATH"
FW="$ROOT/work/app-feature"; git -C "$W" worktree add -q "$FW" feature
is "H1 a branch not yet on origin is denied" "$(decision "$W" 'glab mr create --source-branch feature --target-branch main --fill --yes')" deny
is "H2 saying to publish it" "$(reason "$W" 'glab mr create -s feature -b main' | grep -c 'is not on origin')" 1
publish feature
is "H3 glab mr create, approved, --fill from a checkout whose HEAD is origin's" "$(decision "$FW" 'glab mr create -s feature -b main --fill --yes')" allow
is "H4 glab mr new, = forms" "$(decision "$W" 'glab mr new --source-branch=feature --target-branch=main')" allow
is "H5 gh pr create" "$(decision "$W" 'gh pr create --head feature --base main --title "Land feature" --body-file /tmp/body.md')" allow
is "H6 gh pr new, short flags" "$(decision "$W" 'gh pr new -H feature -B main')" allow
is "H7 the source defaults to the current branch" "$(decision "$FW" 'glab mr create --target-branch main --fill')" allow
is "H8 a # inside a quoted title is a value, not a comment" "$(decision "$W" 'glab mr create --title "Land it # 12" -s feature -b main')" allow
is "H9 the GitLab REST create" "$(decision "$W" 'glab api -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main -f title=x')" allow
is "H10 by numeric project id, POST implied by the fields" "$(decision "$W" 'glab api projects/4242/merge_requests -f source_branch=feature -f target_branch=main')" allow
is "H11 by the :id placeholder, the source as :branch" "$(decision "$FW" 'glab api --method POST projects/:id/merge_requests -F source_branch=:branch -f target_branch=main')" allow
is "H12 the GitHub REST create" "$(decision "$W" 'gh api repos/acme/app/pulls -f head=feature -f base=main -f title=x')" allow
is "H13 with the {owner}/{repo} placeholders and an owner:branch head" "$(decision "$W" "gh api -X POST 'repos/{owner}/{repo}/pulls' -f head=acme:feature -f base=main")" allow
is "H14 -R naming origin's project" "$(decision "$W" 'gh pr create -R acme/app --head feature --base main')" allow
is "H15 gh -R with the host" "$(decision "$W" 'gh pr create -R forge.example/acme/app --head feature --base main')" allow
is "H16 -R as a URL" "$(decision "$W" 'glab mr create -R https://forge.example/acme/app.git -s feature -b main')" allow
is "H17 cd <path> && glab mr create is checked in that path" "$(decision "$ROOT/norepo" "cd $W && glab mr create -s feature -b main")" allow

echo "I. the destination is part of the approval"
git -C "$W" branch release main && publish release
is "I1 the same change proposed into another branch is denied" "$(decision "$W" 'glab mr create -s feature -b release')" deny
r="$(reason "$W" 'glab mr create -s feature -b release')"
is "I2 because nothing on record approves it there" "$(printf '%s' "$r" | grep -c 'no full-range pre-merge review of this change is on record')" 1
rng="$(printf '%s\n' "$r" | sed -n 's/.*--diff \([^ ]*\) <body-file>.*/\1/p')"
is "I3 the deny names the range against origin's destination" "$rng" "origin/release...feature"
review "$W" "$rng" approve
is "I4 and that dispatch, run as named, opens the gate" "$(decision "$W" 'glab mr create -s feature -b release')" allow
is "I5 a CLI creation without --target-branch is denied" "$(decision "$W" 'glab mr create -s feature --fill')" deny
is "I6 naming the flag" "$(reason "$W" 'glab mr create -s feature --fill' | grep -c -- '--target-branch')" 1
is "I7 gh without --base is denied" "$(decision "$W" 'gh pr create --head feature --fill')" deny
is "I8 naming the flag" "$(reason "$W" 'gh pr create --head feature --fill' | grep -c -- '--base')" 1
is "I9 --target-branch twice is denied" "$(decision "$W" 'glab mr create -s feature -b main -b release')" deny
is "I10 glab mr create --auto-merge is a deferred merge" "$(decision "$W" 'glab mr create -s feature -b main --auto-merge')" deny
is "I11 a destination origin does not have is denied" "$(decision "$W" 'glab mr create -s feature -b ghost')" deny
is "I12 saying to fetch" "$(reason "$W" 'glab mr create -s feature -b ghost' | grep -c 'not available locally; fetch it')" 1
is "I13 a source in a variable is denied" "$(decision "$W" 'glab mr create -s "$BRANCH" -b main')" deny

echo "J. creation reads the remote head"
printf 'five\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "an unreviewed change"
publish feature                                   # origin now holds an unreviewed head
printf 'six\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "fixed locally"
review "$W" main...feature approve                # only the local head is approved
is "J1 a creation whose remote head differs from the approved local branch is denied" "$(decision "$W" 'glab mr create -s feature -b main')" deny
publish feature
is "J2 once origin has the approved head, it is allowed" "$(decision "$W" 'glab mr create -s feature -b main')" allow
OTHER="$ROOT/other"; git clone -q "$ORIGIN" "$OTHER"
git -C "$OTHER" switch -q -c remote-only; printf 'r\n' > "$OTHER/r.txt"; git -C "$OTHER" add r.txt; git -C "$OTHER" commit -q -m "remote only"
git -C "$ORIGIN" fetch -q "$OTHER" +refs/heads/remote-only:refs/heads/remote-only
is "J3 a remote head that is not available locally is denied" "$(decision "$W" 'glab mr create -s remote-only -b main')" deny
is "J4 saying to fetch" "$(reason "$W" 'glab mr create -s remote-only -b main' | grep -c 'not available locally; fetch it')" 1

echo "K. the project and forks"
is "K1 -R naming another project is denied" "$(decision "$W" 'glab mr create -R other/app -s feature -b main')" deny
is "K2 saying to run from its checkout" "$(reason "$W" 'glab mr create -R other/app -s feature -b main' | grep -c "Run it from that project's checkout")" 1
is "K3 an API path naming another project" "$(decision "$W" 'glab api -X POST projects/other%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K4 a GitHub fork head" "$(decision "$W" 'gh pr create --head someone:feature --base main')" deny
is "K5 a glab head repository" "$(decision "$W" 'glab mr create -H someone/app -s feature -b main')" deny
is "K6 a GitLab target_project_id" "$(decision "$W" 'glab api -X POST projects/:id/merge_requests -f source_branch=feature -f target_branch=main -f target_project_id=9')" deny
git -C "$W" remote add upstream 'git@forge.example:upstream/app.git'
is "K7 several remotes and no project named is denied" "$(decision "$W" 'gh pr create --head feature --base main')" deny
is "K8 naming origin's project with -R is allowed" "$(decision "$W" 'gh pr create -R acme/app --head feature --base main')" allow
git -C "$W" remote remove upstream
is "K9 outside a repository, creation is denied" "$(decision "$ROOT/norepo" 'gh pr create --head feature --base main')" deny
is "K10 -R naming another host is denied" "$(decision "$W" 'gh pr create -R evil.example/acme/app --head feature --base main')" deny
is "K11 -R as a URL on another host is denied" "$(decision "$W" 'glab mr create -R https://evil.example/acme/app -s feature -b main')" deny
is "K12 glab api --hostname on another host is denied" \
   "$(decision "$W" 'glab api --hostname evil.example -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K13 gh api --hostname on another host is denied" \
   "$(decision "$W" 'gh api --hostname evil.example repos/acme/app/pulls -f head=feature -f base=main')" deny
is "K14 glab api --hostname naming origin's host is allowed" \
   "$(decision "$W" 'glab api --hostname forge.example -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" allow
is "K15 and gh api" "$(decision "$W" 'gh api --hostname forge.example repos/acme/app/pulls -f head=feature -f base=main')" allow
is "K16 an absolute GitLab endpoint on another host is denied" \
   "$(decision "$W" 'glab api -X POST https://evil.example/api/v4/projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K17 an absolute GitHub endpoint on another host is denied" \
   "$(decision "$W" 'gh api -X POST https://evil.example/api/v3/repos/acme/app/pulls -f head=feature -f base=main')" deny
is "K18 an absolute endpoint on origin's host is allowed" \
   "$(decision "$W" 'gh api -X POST https://forge.example/api/v3/repos/acme/app/pulls -f head=feature -f base=main')" allow
# Without --hostname, gh api goes to GH_HOST, else to the one host gh's hosts.yml lists, else to
# github.com; glab api to GITLAB_HOST, GITLAB_URI or GITLAB_URL, else to a remote's host.
GHCREATE='gh api repos/acme/app/pulls -f head=feature -f base=main'
GLCREATE='glab api -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main'
is "K19 gh api with no GH_HOST goes to github.com, not origin's host" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
is "K20 the deny names origin's host to pass" "$(GH_HOST= reason "$W" "$GHCREATE" | grep -c -- '--hostname forge.example')" 1
is "K21 a stray GH_HOST is denied" "$(GH_HOST=github.example decision "$W" "$GHCREATE")" deny
is "K22 --hostname naming origin's host outranks it" "$(GH_HOST=github.example decision "$W" "gh api --hostname forge.example ${GHCREATE#gh api }")" allow
mkdir -p "$GH_CONFIG_DIR"; printf 'forge.example:\n    user: t\n    git_protocol: ssh\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K23 gh's one configured host is its default" "$(GH_HOST= decision "$W" "$GHCREATE")" allow
printf 'github.com:\n    user: t\n' >> "$GH_CONFIG_DIR/hosts.yml"
is "K24 with two, the default is github.com again" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
# The same with origin on github.com: gh's one configured host elsewhere takes the call there.
git -C "$W" config --add "url.$ORIGIN.insteadOf" 'git@github.com:acme/app.git'
git -C "$W" remote set-url origin 'git@github.com:acme/app.git'
printf 'forge.example:\n    user: t\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K25 an origin on github.com, and gh's one configured host elsewhere" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
printf 'github.com:\n    user: t\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K26 and that one host github.com" "$(GH_HOST= decision "$W" "$GHCREATE")" allow
git -C "$W" remote set-url origin 'git@forge.example:acme/app.git'
git -C "$W" config --unset "url.$ORIGIN.insteadOf" 'github'
rm "$GH_CONFIG_DIR/hosts.yml"
git -C "$W" remote add mirror 'git@forge.example:acme/app-mirror.git'
is "K27 glab api with every remote on origin's host" "$(decision "$W" "$GLCREATE")" allow
is "K28 GITLAB_HOST on another host is denied" "$(GITLAB_HOST=gitlab.com decision "$W" "$GLCREATE")" deny
is "K29 so is GITLAB_URL" "$(GITLAB_URL=https://gitlab.com decision "$W" "$GLCREATE")" deny
is "K30 GITLAB_URI naming origin's host is allowed" "$(GITLAB_URI=https://forge.example decision "$W" "$GLCREATE")" allow
is "K31 --hostname naming origin's host outranks a stray GITLAB_HOST" \
   "$(GITLAB_HOST=gitlab.com decision "$W" "glab api --hostname forge.example ${GLCREATE#glab api }")" allow
git -C "$W" remote set-url mirror 'git@gitlab.com:acme/app.git'
is "K32 a remote on another host is denied" "$(decision "$W" "$GLCREATE")" deny
is "K33 naming origin's host to pass" "$(reason "$W" "$GLCREATE" | grep -c -- '--hostname forge.example')" 1
is "K34 --hostname naming origin's host is allowed" "$(decision "$W" "glab api --hostname forge.example ${GLCREATE#glab api }")" allow
git -C "$W" remote remove mirror
# A CLI verb reaches the host its -R names. A bare OWNER/REPO, GH_REPO or GITLAB_REPO takes the
# CLI's default host, which must be origin's too.
is "K35 gh -R without a host, gh's default host elsewhere" \
   "$(GH_HOST=github.example decision "$W" 'gh pr create -R acme/app --head feature --base main')" deny
is "K36 naming the host-qualified -R to pass" \
   "$(GH_HOST=github.example reason "$W" 'gh pr create -R acme/app --head feature --base main' | grep -c -- '-R forge.example/acme/app')" 1
is "K37 glab -R without a host, glab's default host gitlab.com" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-none" decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
is "K38 glab's config naming origin's host" "$(decision "$W" 'glab mr create -R acme/app -s feature -b main')" allow
is "K39 a host variable outranks the config" "$(GITLAB_HOST=gitlab.com decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
mkdir -p "$W/.git/glab-cli" && printf 'host: gitlab.com\n' > "$W/.git/glab-cli/config.yml"
is "K40 so does the repository's own glab config" "$(decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
rm -r "$W/.git/glab-cli"
is "K41 GH_REPO naming another project is denied" "$(GH_REPO=other/app decision "$W" 'gh pr create --head feature --base main')" deny
is "K42 so is GITLAB_REPO" "$(GITLAB_REPO=other/app decision "$W" 'glab mr create -s feature -b main')" deny
is "K43 GH_REPO naming origin's project is allowed" "$(GH_REPO=acme/app decision "$W" 'gh pr create --head feature --base main')" allow
is "K44 GITLAB_API_HOST on another host is denied" "$(GITLAB_API_HOST=api.other.example decision "$W" 'glab mr create -s feature -b main')" deny
is "K45 for an api call too" "$(GITLAB_API_HOST=api.other.example decision "$W" "$GLCREATE")" deny
is "K46 glab reads -R HOST/PATH as a group path on its default host: another project" \
   "$(decision "$W" 'glab mr create -R forge.example/acme/app -s feature -b main')" deny
# A numeric project id is looked up on origin's host, never on the host the environment picks.
is "K47 a project id is looked up on origin's host" \
   "$(GITLAB_HOST=other.example PROJECT_PATH=other/app ELSEWHERE_PATH=acme/app decision "$W" 'glab api -X POST https://forge.example/api/v4/projects/4242/merge_requests -f source_branch=feature -f target_branch=main')" deny
# denies <cwd> <command> <phrase>: 1 when the command is denied with phrase in its reason.
denies() { reason "$1" "$2" | grep -c -F -- "$3"; }
# glab's --fill and --push push this checkout's HEAD to the source branch: allowed only when
# that push changes nothing, because HEAD already is origin's head of the source.
is "K48 --fill from another branch's checkout would push its HEAD to feature" \
   "$(denies "$W" 'glab mr create -s feature -b main --fill --yes' 'Push the branch to origin first')" 1
printf 'ahead\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "ahead of origin, never reviewed"
is "K49 --fill, -fy and --push with HEAD ahead of origin's feature" \
   "$(denies "$FW" 'glab mr create -b main --fill' 'makes glab push')$(denies "$FW" 'glab mr create -b main -fy' 'makes glab push')$(denies "$FW" 'glab mr create -b main --push -t T --yes' 'makes glab push')" 111
git -C "$FW" reset -q --hard HEAD~1
is "K50 --push in step with origin pushes nothing, and is allowed" "$(decision "$FW" 'glab mr create -b main --push -t T --yes')" allow
# Creation flags are an allowlist: any other flag is denied by name.
is "K51 --recover replays options from a file the gate does not read" \
   "$(denies "$W" 'glab mr create --recover -s feature -b main --yes' '--recover is not among')$(denies "$W" 'gh pr create --recover x --head feature --base main' '--recover is not among')" 11
is "K52 so are --web, --related-issue, --create-source-branch and unknown flags" \
   "$(denies "$W" 'glab mr create -s feature -b main --web' '--web is not among')$(denies "$W" 'glab mr create -s feature -b main -i 3' '-i is not among')$(denies "$W" 'glab mr create -s feature -b main --create-source-branch' '--create-source-branch is not among')$(denies "$W" 'gh pr create --head feature --base main -w' '-w is not among')$(denies "$W" 'gh pr create --head feature --base main --bogus' '--bogus is not among')" 11111
is "K53 every allowed glab flag" \
   "$(decision "$W" 'glab mr create -s feature -b main -t T -d D --description-file f.md -a me -l x,y -m 1 --reviewer r --template t --attach a.png --allow-collaboration --copy-issue-labels --draft --wip --fill-commit-body --no-editor --remove-source-branch --signoff --squash-before-merge --auto-merge=false -y')" allow
is "K54 every allowed gh flag" \
   "$(decision "$W" 'gh pr create -H feature -B main -t T -b B -F f.md -a me --attach a.png -l x -m M -p P -r r -T t -d --dry-run -e -f --fill-first --fill-verbose --no-maintainer-edit')" allow
is "K55 gh must name --head: it could take the head from push configuration" \
   "$(denies "$W" 'gh pr create --base main -t T -b B' '--head <branch>')" 1
# -R/--repo on an api call picks the project behind :id and the path: denied wherever it stands.
GLMR='-X POST projects/:id/merge_requests -f source_branch=feature -f target_branch=main'
is "K56 -R before api (not the gate's order), after api, after the endpoint, and --repo=" \
   "$(denies "$W" "glab -R other/app api $GLMR" 'Write it as glab api [options] <endpoint>')$(denies "$W" "glab api -R acme/app $GLMR" 'on glab api picks')$(denies "$W" 'glab api projects/:id/merge_requests -R other/app -X POST -f source_branch=feature -f target_branch=main' 'on glab api picks')$(denies "$W" 'glab api --repo=acme/app -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main' 'on glab api picks')$(denies "$W" 'gh api -R acme/app repos/acme/app/pulls -f head=feature -f base=main' 'on gh api picks')" 11111
is "K57 a read with -R is no MR/PR write, and stays allowed" "$(decision "$W" 'glab api -R acme/app projects/:id/merge_requests/7')" allow
# gh and glab remember a base project per remote; one other than origin's retargets a command
# that names no project.
git -C "$W" config remote.origin.gh-resolved other/app
is "K58 gh-resolved naming another project" \
   "$(denies "$W" 'gh pr create --head feature --base main' 'remote.origin.gh-resolved is other/app')$(denies "$W" "gh api 'repos/{owner}/{repo}/pulls' -f head=feature -f base=main" 'remote.origin.gh-resolved is other/app')" 11
is "K59 naming origin's project with -R is allowed" "$(decision "$W" 'gh pr create -R acme/app --head feature --base main')" allow
git -C "$W" config remote.origin.gh-resolved base
is "K60 base, or origin's own project, is allowed" "$(decision "$W" 'gh pr create --head feature --base main')" allow
git -C "$W" config --unset remote.origin.gh-resolved
git -C "$W" config remote.origin.glab-resolved other/app
is "K61 glab-resolved naming another project" \
   "$(denies "$W" 'glab mr create -s feature -b main' 'remote.origin.glab-resolved is other/app')$(denies "$W" "glab api $GLMR" 'remote.origin.glab-resolved is other/app')" 11
git -C "$W" config --unset remote.origin.glab-resolved
# Without --hostname, glab api falls back to its configured default host when it has no login
# for origin's host.
mkdir -p "$ROOT/glab-gitlab" && printf 'host: gitlab.com\n' > "$ROOT/glab-gitlab/config.yml"
is "K62 glab api with glab's default host elsewhere" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-gitlab" denies "$W" "$GLCREATE" 'falls back to its default host gitlab.com')" 1
mkdir -p "$ROOT/glab-comment" && printf 'host: forge.example # the forge\n' > "$ROOT/glab-comment/config.yml"
is "K63 an inline comment in glab's config is no part of the host" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-comment" decision "$W" 'glab mr create -R acme/app -s feature -b main')" allow
# A detached HEAD and a branch lookup that failed are denied apart.
shim 'exit 128'
is "K64 a failed branch lookup is not called a detached HEAD" \
   "$(PATH="$WRAP:$PATH" denies "$FW" 'glab mr create --target-branch main' 'cannot be read (the lookup failed')" 1
git -C "$FW" switch -q --detach
is "K65 a detached HEAD is" "$(denies "$FW" 'glab mr create --target-branch main' 'HEAD is detached')" 1
git -C "$FW" switch -q feature
# The remembered-project lookup fails closed: git config exits 1 only when there is none.
cfgshim() { printf '%s\n' '#!/bin/sh' "case \"\$*\" in *\"config --get-regexp\"*) $1 ;; esac" "exec $REALGIT \"\$@\"" > "$WRAP/git"; chmod +x "$WRAP/git"; }
cfgshim 'exit 3'
is "K66 a git config that fails reading remembered projects is a deny" \
   "$(PATH="$WRAP:$PATH" denies "$W" 'gh pr create --head feature --base main' 'cannot be read (git config failed')" 1
cfgshim 'sleep 9; exit 0'
is "K67 so is one that times out" \
   "$(PATH="$WRAP:$PATH" denies "$W" 'gh pr create --head feature --base main' 'cannot be read (git config failed')" 1
# pflag reads -f=false as --fill off.
printf 'ahead\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "ahead of origin, never reviewed"
is "K68 -f=false turns --fill off: nothing is pushed, origin's head is proposed" \
   "$(decision "$FW" 'glab mr create -b main -t T -f=false --yes')" allow
is "K69 while -f=true still pushes" "$(denies "$FW" 'glab mr create -b main -t T -f=true --yes' 'makes glab push')" 1
git -C "$FW" reset -q --hard HEAD~1

echo "L. merging an MR/PR on the forge"
# MR 7 and PR 9 come from feature in acme/app (project 4242). Their destination and head come
# from MR_TARGET/MR_SHA and PR_BASE/PR_SHA. MR_SOURCE_PROJECT, PR_CROSS and PR_OWNER make them
# come from a fork; MERGE_TRAINS and MERGE_QUEUE put a train or a queue on the destination, and
# TRAIN_FAIL and QUEUE_FAIL fail those lookups. FORGE_FAIL fails every lookup; FORGE_SLOW
# delays it. A call reaches the host its --hostname or host-qualified -R names, else the one
# the CLI's environment picks, else origin's. Another host answers with its own MR and PR:
# ELSEWHERE_TARGET, ELSEWHERE_TRAINS and ELSEWHERE_BASE.
cat > "$STUB/glab" <<'SH'
#!/bin/sh
printf 'glab %s\n' "$*" >> "$CALLS"
[ -n "${FORGE_SLOW:-}" ] && sleep "$FORGE_SLOW"
[ -n "${FORGE_FAIL:-}" ] && exit 1
host="${GITLAB_HOST:-${GITLAB_URI:-${GL_HOST:-forge.example}}}"
if [ "$1" = api ] && [ "$2" = --hostname ]; then host="$3"; shift 3; set -- api "$@"; fi
if [ "$host" != forge.example ]; then
  MR_TARGET="${ELSEWHERE_TARGET:-${MR_TARGET:-main}}"
  MERGE_TRAINS="${ELSEWHERE_TRAINS:-${MERGE_TRAINS:-false}}"
fi
mr() { printf '{"iid":7,"project_id":4242,"source_project_id":%s,"target_project_id":4242,"source_branch":"feature","target_branch":"%s","sha":"%s"}' \
  "${MR_SOURCE_PROJECT:-4242}" "${MR_TARGET:-main}" "${MR_SHA:-}"; }
project() { [ -n "${TRAIN_FAIL:-}" ] && exit 1
  printf '{"id":4242,"path_with_namespace":"acme/app","merge_trains_enabled":%s}\n' "${MERGE_TRAINS:-false}"; }
case "$*" in
  "api projects/4242"|"api projects/acme%2Fapp"|"api projects/:id") project ;;
  "api projects/acme%2Fapp/merge_requests/7"|"api projects/:id/merge_requests/7"|"api projects/4242/merge_requests/7") mr; echo ;;
  "api projects/acme%2Fapp/merge_requests?source_branch=feature&state=opened") printf '['; mr; printf ']\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$STUB/gh" <<'SH'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$CALLS"
[ -n "${FORGE_FAIL:-}" ] && exit 1
host=forge.example; prev=
for a in "$@"; do
  case "$prev" in
    --hostname) host="$a" ;;
    -R) case "$a" in */*/*) host="${a%%/*}" ;; *) host="${GH_HOST:-github.com}" ;; esac ;;
  esac
  prev="$a"
done
[ "$host" = forge.example ] || PR_BASE="${ELSEWHERE_BASE:-${PR_BASE:-main}}"
F=baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,headRepositoryOwner
case "$*" in
  "pr view 9 --json $F"|"pr view 9 -R acme/app --json $F"|"pr view 9 -R "*"/acme/app --json $F"|"pr view --json $F"|"pr view https://"*" --json $F")
    printf '{"baseRefName":"%s","headRefName":"feature","headRefOid":"%s","isCrossRepository":%s,"headRepository":{"name":"app"},"headRepositoryOwner":{"login":"%s"}}\n' \
      "${PR_BASE:-main}" "${PR_SHA:-}" "${PR_CROSS:-false}" "${PR_OWNER:-acme}" ;;
  "api graphql --hostname forge.example -f query="*mergeQueue*)
    [ -n "${QUEUE_FAIL:-}" ] && exit 1
    printf '{"data":{"repository":{"mergeQueue":%s}}}\n' "${MERGE_QUEUE:-null}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$STUB/glab" "$STUB/gh"
HEAD_SHA="$(git -C "$W" rev-parse refs/remotes/origin/feature)"
export MR_SHA="$HEAD_SHA" PR_SHA="$HEAD_SHA"
is "L1 glab mr merge, pinned and immediate, approved" "$(decision "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false --yes")" allow
is "L2 glab mr accept" "$(decision "$W" "glab mr accept 7 --sha=$HEAD_SHA --auto-merge=false")" allow
is "L3 the MR of the current branch" "$(decision "$FW" "glab mr merge --sha $HEAD_SHA --auto-merge=false")" allow
is "L4 gh pr merge" "$(decision "$W" "gh pr merge 9 --match-head-commit $HEAD_SHA --squash")" allow
is "L5 gh pr merge -R" "$(decision "$W" "gh pr merge 9 -R acme/app --match-head-commit $HEAD_SHA")" allow
is "L6 the GitLab REST merge" "$(decision "$W" "glab api -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L7 by the :id placeholder" "$(decision "$W" "glab api --method PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L8 by numeric project id" "$(decision "$W" "glab api -X PUT projects/4242/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L9 the GitHub REST merge" "$(decision "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$HEAD_SHA")" allow

echo "M. a forge merge is pinned and immediate"
is "M1 an unpinned glab merge is denied" "$(denies "$W" 'glab mr merge 7 --auto-merge=false' 'a forge merge must pin the head it merges')" 1
is "M2 naming the head to pin" "$(reason "$W" 'glab mr merge 7 --auto-merge=false' | grep -c "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false")" 1
is "M3 an unpinned gh merge is denied" "$(denies "$W" 'gh pr merge 9 --squash' 'a forge merge must pin the head it merges')" 1
is "M4 an unpinned REST merge is denied" "$(denies "$W" 'gh api -X PUT repos/acme/app/pulls/9/merge' 'a forge merge must pin the head it merges')" 1
is "M5 glab's default auto-merge is a deferred merge, even pinned" "$(denies "$W" "glab mr merge 7 --sha $HEAD_SHA" 'glab mr merge without --auto-merge=false is a deferred merge')" 1
is "M6 naming --auto-merge=false" "$(reason "$W" "glab mr merge 7 --sha $HEAD_SHA" | grep -c -- '--auto-merge=false')" 1
is "M7 glab --auto-merge, even pinned" "$(denies "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge" 'glab mr merge without --auto-merge=false is a deferred merge')" 1
is "M8 gh --auto, even pinned" "$(denies "$W" "gh pr merge 9 --auto --match-head-commit $HEAD_SHA" 'gh pr merge --auto is a deferred merge')" 1
is "M9 merge_when_pipeline_succeeds, even pinned" "$(denies "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA -F merge_when_pipeline_succeeds=true" 'merge_when_pipeline_succeeds/auto_merge is a deferred merge')" 1
is "M10 auto_merge, even pinned" "$(denies "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA -F auto_merge=true" 'merge_when_pipeline_succeeds/auto_merge is a deferred merge')" 1
is "M11 an abbreviated pin" "$(denies "$W" "gh pr merge 9 --match-head-commit ${HEAD_SHA:0:12}" 'pin the head with a full commit id')" 1

echo "N. what the pin names"
printf 'seven\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "never reviewed"
UNREVIEWED="$(git -C "$FW" rev-parse HEAD)"; git -C "$FW" reset -q --hard HEAD~1
is "N1 a pin whose fingerprint is unapproved is denied" "$(denies "$W" "gh pr merge 9 --match-head-commit $UNREVIEWED" 'no full-range pre-merge review of this change is on record')" 1
is "N2 the deny names the pinned merge to run once approved" "$(reason "$W" "gh pr merge 9 --match-head-commit $UNREVIEWED" | grep -c "Then merge it pinned and immediate: gh pr merge 9 --merge --match-head-commit $UNREVIEWED")" 1
is "N3 a destination origin does not have is denied" "$(MR_TARGET=ghost2 denies "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false" 'the destination ghost2 (refs/remotes/origin/ghost2) is not available locally')" 1
git -C "$W" branch release2 main && publish release2
is "N4 an MR retargeted to an unapproved destination is denied" "$(PR_BASE=release2 denies "$W" "gh pr merge 9 --match-head-commit $HEAD_SHA" 'feature -> release2')" 1
printf 'm\n' > "$W/m.txt"; git -C "$W" add m.txt; git -C "$W" commit -q -m "main moves on, elsewhere"; publish main
git -C "$FW" rebase -q main; publish feature
REBASED="$(git -C "$W" rev-parse refs/remotes/origin/feature)"
is "N5 a rebased pin with an unchanged fingerprint is allowed" "$(PR_SHA=$REBASED decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" allow
is "N6 a forge lookup failure is denied" "$(FORGE_FAIL=1 denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'so its destination is unknown and the merge is refused')" 1
is "N7 saying so" "$(FORGE_FAIL=1 reason "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" | grep -c 'forge lookup of MR !7 failed')" 1
is "N8 a forge slower than the budget is denied" "$(FORGE_SLOW=3 XREVIEW_GUARD_BUDGET=1 denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'the check did not finish in time')" 1
is "N9 saying it ran out of time" "$(FORGE_SLOW=3 XREVIEW_GUARD_BUDGET=1 reason "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" | grep -c 'did not finish in time')" 1

echo "O. GraphQL and other API writes"
is "O1 createPullRequest is denied" "$(denies "$W" "gh api graphql -f query='mutation { createPullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call')" 1
is "O2 mergeRequestAccept is denied" "$(denies "$W" "glab api graphql -f query='mutation { mergeRequestAccept(input: {}) { errors } }'" 'this GraphQL call')" 1
is "O3 enablePullRequestAutoMerge is denied" "$(denies "$W" "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'" 'this GraphQL call')" 1
is "O4 mergePullRequest, mergeRequestCreate and mergeRequestSetAutoMerge too" \
   "$(denies "$W" "gh api graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call') $(denies "$W" "glab api graphql -f query='mutation { mergeRequestCreate(input: {}) { errors } }'" 'this GraphQL call') $(denies "$W" "glab api graphql -f query='mutation { mergeRequestSetAutoMerge(input: {}) { errors } }'" 'this GraphQL call')" \
   "1 1 1"
is "O5 a GraphQL read is allowed" "$(decision "$W" "gh api graphql -f query='query { viewer { login } }'")" allow
is "O6 a GraphQL query from a file is denied" "$(denies "$W" 'gh api graphql -F query=@q.graphql' 'this GraphQL call')" 1
is "O7 an MR note through the API is an unresolved write" "$(denies "$W" 'glab api -X POST projects/:id/merge_requests/7/notes -f body=hi' 'this glab api call writes to an MR/PR path whose source, head or destination')" 1
is "O8 a PATCH of a pull request (a retarget) is denied" "$(denies "$W" 'gh api -X PATCH repos/acme/app/pulls/9 -f base=release' 'this gh api call writes to an MR/PR path whose source, head or destination')" 1
is "O9 a REST create whose body comes from a file is denied" "$(denies "$W" 'glab api -X POST projects/:id/merge_requests --input mr.json' 'this glab api call writes to an MR/PR path whose source, head or destination')" 1
is "O10 an absolute GraphQL endpoint carrying a merge mutation is denied" \
   "$(denies "$W" "gh api https://api.github.com/graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call')" 1

echo "P. a forge merge reaches only origin's own project, and merges at once"
export MR_SHA="$REBASED" PR_SHA="$REBASED"
is "P1 a PR URL on another host is denied, even with an approved pin" \
   "$(denies "$W" "gh pr merge https://github.com/acme/app/pull/9 --match-head-commit $REBASED" "is not on this checkout's origin (forge.example/acme/app)")" 1
is "P2 saying it is not on origin" \
   "$(reason "$W" "gh pr merge https://github.com/acme/app/pull/9 --match-head-commit $REBASED" | grep -c "is not on this checkout's origin")" 1
is "P3 a PR URL in another project is denied" \
   "$(denies "$W" "gh pr merge https://forge.example/other/app/pull/9 --match-head-commit $REBASED" "the PR https://forge.example/other/app/pull/9 is not on this checkout's origin")" 1
is "P4 origin's own PR URL is allowed" \
   "$(decision "$W" "gh pr merge https://forge.example/acme/app/pull/9 --match-head-commit $REBASED")" allow
is "P5 an MR URL on another host is denied" \
   "$(denies "$W" "glab mr merge https://evil.example/acme/app/-/merge_requests/7 --sha $REBASED --auto-merge=false" "the MR https://evil.example/acme/app/-/merge_requests/7 is not on this checkout's origin")" 1
is "P6 origin's own MR URL is allowed" \
   "$(decision "$W" "glab mr merge https://forge.example/acme/app/-/merge_requests/7 --sha $REBASED --auto-merge=false")" allow
is "P7 an MR from a fork is denied" \
   "$(MR_SOURCE_PROJECT=99 denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'MR !7 proposes from another repository')" 1
is "P8 a cross-repository PR is denied" \
   "$(PR_CROSS=true denies "$W" "gh pr merge 9 --match-head-commit $REBASED" 'PR 9 proposes from another repository')" 1
is "P9 a PR whose head lives in another owner's repository is denied" \
   "$(PR_OWNER=someone denies "$W" "gh pr merge 9 --match-head-commit $REBASED" 'PR 9 proposes from another repository')" 1
is "P10 a destination with a merge queue is a deferred merge" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' denies "$W" "gh pr merge 9 --match-head-commit $REBASED" 'this merge would go through the merge queue of main')" 1
is "P11 saying so" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' reason "$W" "gh pr merge 9 --match-head-commit $REBASED" | grep -c 'the merge queue of main')" 1
is "P12 a failed merge-queue lookup is denied" \
   "$(QUEUE_FAIL=1 denies "$W" "gh pr merge 9 --match-head-commit $REBASED" 'the forge lookup of the merge queue of main failed')" 1
is "P13 a project with merge trains is a deferred merge" \
   "$(MERGE_TRAINS=true denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'this merge would go through the merge train of acme/app')" 1
is "P14 a failed project lookup is denied" \
   "$(TRAIN_FAIL=1 denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'the forge lookup of project acme/app failed')" 1
is "P15 the GitLab REST merge checks the train too" \
   "$(MERGE_TRAINS=true denies "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$REBASED" 'this merge would go through the merge train of acme/app')" 1
is "P16 and the GitHub REST merge the queue" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' denies "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED" 'this merge would go through the merge queue of main')" 1
is "P17 gh api --hostname on another host is denied" \
   "$(denies "$W" "gh api --hostname evil.example -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED" 'this call goes to evil.example, but')" 1
is "P18 glab api --hostname on another host is denied" \
   "$(denies "$W" "glab api --hostname evil.example -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED" 'this call goes to evil.example, but')" 1
is "P19 gh api --hostname naming origin's host is allowed" \
   "$(decision "$W" "gh api --hostname forge.example -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED")" allow
is "P20 glab api --hostname naming origin's host is allowed" \
   "$(decision "$W" "glab api --hostname forge.example -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" allow
is "P21 an absolute GitLab endpoint on another host is denied" \
   "$(denies "$W" "glab api -X PUT https://evil.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED" 'this call goes to evil.example, but')" 1
is "P22 on origin's host it is allowed" \
   "$(decision "$W" "glab api -X PUT https://forge.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" allow
is "P23 an absolute GitHub endpoint on another host is denied" \
   "$(denies "$W" "gh api -X PUT https://evil.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED" 'this call goes to evil.example, but')" 1
is "P24 on origin's host it is allowed" \
   "$(decision "$W" "gh api -X PUT https://forge.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED")" allow
is "P25 -R naming another host is denied (gh)" \
   "$(denies "$W" "gh pr merge 9 -R evil.example/acme/app --match-head-commit $REBASED" 'acts on the project evil.example/acme/app')" 1
is "P26 -R as a URL on another host is denied (glab)" \
   "$(denies "$W" "glab mr merge 7 -R https://evil.example/acme/app --sha $REBASED --auto-merge=false" 'acts on the project https://evil.example/acme/app')" 1
is "P27 a gh REST merge with no GH_HOST goes to github.com and is denied" \
   "$(GH_HOST= denies "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED" 'this call goes to github.com, but')" 1
is "P28 a glab REST merge under a stray GITLAB_HOST is denied" \
   "$(GITLAB_HOST=gitlab.com denies "$W" "glab api -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED" 'this call goes to gitlab.com, but')" 1
# Every lookup goes to the host the command reaches, never to the one the environment picks.
# On other.example, MR 7 and PR 9 target main, which is approved; on origin's host, release2.
GLMERGE="glab api -X PUT https://forge.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED"
GHMERGE="gh api -X PUT https://forge.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED"
is "P29 a GitLab REST merge to origin's absolute endpoint reads origin's MR" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TARGET=main MR_TARGET=release2 denies "$W" "$GLMERGE" 'feature -> release2')" 1
is "P30 and origin's merge train" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TRAINS=false MERGE_TRAINS=true denies "$W" "$GLMERGE" 'this merge would go through the merge train of acme/app')" 1
is "P31 with both hosts agreeing, it is allowed" "$(GITLAB_HOST=other.example decision "$W" "$GLMERGE")" allow
is "P32 a GitHub REST merge to origin's absolute endpoint reads origin's PR" \
   "$(GH_HOST=other.example ELSEWHERE_BASE=main PR_BASE=release2 denies "$W" "$GHMERGE" 'feature -> release2')" 1
is "P33 with both hosts agreeing, it is allowed" "$(GH_HOST=other.example decision "$W" "$GHMERGE")" allow
is "P34 glab mr merge -R <url> reads the MR on that URL's host" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TARGET=main MR_TARGET=release2 denies "$W" "glab mr merge 7 -R https://forge.example/acme/app --sha $REBASED --auto-merge=false" 'feature -> release2')" 1
is "P35 gh pr merge -R without a host, gh's default host elsewhere" \
   "$(GH_HOST=other.example denies "$W" "gh pr merge 9 -R acme/app --match-head-commit $REBASED" 'acme/app names no host, so the CLI sends this to its default host, other.example')" 1
is "P36 glab mr merge -R without a host, glab's default host gitlab.com" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-none" denies "$W" "glab mr merge 7 -R acme/app --sha $REBASED --auto-merge=false" 'acme/app names no host, so the CLI sends this to its default host, gitlab.com')" 1
is "P37 GH_REPO naming another project is denied" "$(GH_REPO=other/app denies "$W" "gh pr merge 9 --match-head-commit $REBASED" 'acts on the project other/app')" 1
is "P38 so is GITLAB_REPO" "$(GITLAB_REPO=other/app denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" 'acts on the project other/app')" 1
is "P39 and GITLAB_API_HOST on another host" "$(GITLAB_API_HOST=api.other.example denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" "GITLAB_API_HOST sends glab's API requests to api.other.example")" 1

# The MR of the current branch: a failed branch lookup is not called a detached HEAD.
shim 'exit 128'
is "P40 glab mr merge with no MR named, the branch lookup failing" \
   "$(PATH="$WRAP:$PATH" reason "$FW" "glab mr merge --sha $REBASED --auto-merge=false" | grep -c -F 'cannot be read (the lookup failed')" 1

echo "Q. what a forge merge may say, and the forms that merge or propose around it"
is "Q1 gh pr merge --admin is denied by name" \
   "$(denies "$W" "gh pr merge 9 --match-head-commit $REBASED --admin" '--admin is not among the flags the gate allows for gh pr merge')" 1
is "Q2 so is a flag the gate does not know" \
   "$(denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false --bogus" '--bogus is not among the flags the gate allows for glab mr merge')" 1
is "Q3 glab's hidden --when-pipeline-succeeds is a deferred merge" \
   "$(denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false --when-pipeline-succeeds" 'glab mr merge without --auto-merge=false is a deferred merge')" 1
is "Q4 and is denied by name when off" \
   "$(denies "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false --when-pipeline-succeeds=false" '--when-pipeline-succeeds is not among the flags')" 1
is "Q5 glab's merge flags, short" \
   "$(decision "$W" "glab mr merge 7 -R acme/app --sha $REBASED --auto-merge=false -s --squash-message Q -m M -d -y")" allow
is "Q6 and long" \
   "$(decision "$W" "glab mr merge 7 --repo acme/app --sha $REBASED --auto-merge=false --squash --message M --remove-source-branch --yes")" allow
is "Q7 a rebase merge, either spelling" \
   "$(decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false -r") $(decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false --rebase")" \
   "allow allow"
is "Q8 gh's merge flags, short" \
   "$(decision "$W" "gh pr merge 9 -R acme/app --match-head-commit $REBASED -s -t S -b B -A a@b -d")" allow
is "Q9 and long" \
   "$(decision "$W" "gh pr merge 9 --repo acme/app --match-head-commit $REBASED --squash --subject S --body-file m.txt --author-email a@b --delete-branch")" allow
is "Q10 a merge commit or a rebase, either spelling" \
   "$(decision "$W" "gh pr merge 9 --match-head-commit $REBASED -m -F m.txt") $(decision "$W" "gh pr merge 9 --match-head-commit $REBASED --merge --body B") $(decision "$W" "gh pr merge 9 --match-head-commit $REBASED -r") $(decision "$W" "gh pr merge 9 --match-head-commit $REBASED --rebase")" \
   "allow allow allow allow"
is "Q11 gh pr merge --disable-auto turns auto-merge off and merges nothing" \
   "$(decision "$W" 'gh pr merge 9 --disable-auto') $(decision "$W" 'gh pr merge --disable-auto') $(decision "$W" 'gh pr merge 9 -R acme/app --disable-auto')" \
   "allow allow allow"
is "Q12 beside another flag, or off, it is not among a merge's flags" \
   "$(denies "$W" "gh pr merge 9 --disable-auto --squash --match-head-commit $REBASED" '--disable-auto is not among the flags') $(denies "$W" 'gh pr merge 9 --disable-auto=false' '--disable-auto is not among the flags')" \
   "1 1"
is "Q13 glab reads !7 as MR 7" "$(decision "$W" "glab mr merge !7 --sha $REBASED --auto-merge=false")" allow
is "Q14 a PR URL with a trailing path names its PR" \
   "$(decision "$W" "gh pr merge https://forge.example/acme/app/pull/9/files --match-head-commit $REBASED")" allow
is "Q15 so does an MR URL, and glab takes its /-/ as optional" \
   "$(decision "$W" "glab mr merge https://forge.example/acme/app/-/merge_requests/7/diffs --sha $REBASED --auto-merge=false") $(decision "$W" "glab mr merge https://forge.example/acme/app/merge_requests/7 --sha $REBASED --auto-merge=false")" \
   "allow allow"
is "Q16 an MR URL names the project glab reads from it" \
   "$(denies "$W" "glab mr merge https://forge.example/acme/app/merge_requests/77/merge_requests/7 --sha $REBASED --auto-merge=false" "is not on this checkout's origin")" 1
is "Q17 GraphQL mergeBranch, a branch merged with no PR, is denied" \
   "$(denies "$W" "gh api graphql -f query='mutation { mergeBranch(input: {repositoryId: \"R_1\", base: \"main\", head: \"other\"}) { mergeCommit { oid } } }'" 'this GraphQL call')" 1
is "Q18 so are enqueuePullRequest, revertPullRequest, updatePullRequest and mergeRequestUpdate" \
   "$(denies "$W" "gh api graphql -f query='mutation { enqueuePullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call') $(denies "$W" "gh api graphql -f query='mutation { revertPullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call') $(denies "$W" "gh api graphql -f query='mutation { updatePullRequest(input: {baseRefName: \"release\"}) { clientMutationId } }'" 'this GraphQL call') $(denies "$W" "glab api graphql -f query='mutation { mergeRequestUpdate(input: {targetBranch: \"release\"}) { errors } }'" 'this GraphQL call')" \
   "1 1 1 1"
is "Q19 a review thread, or updating a PR's branch from its base, stays allowed" \
   "$(decision "$W" "gh api graphql -f query='mutation { addPullRequestReviewThread(input: {}) { clientMutationId } }'") $(decision "$W" "gh api graphql -f query='mutation { updatePullRequestBranch(input: {}) { clientMutationId } }'")" \
   "allow allow"
is "Q20 a write to the merges endpoint is denied" \
   "$(denies "$W" 'gh api repos/acme/app/merges -f base=main -f head=other' 'writes to a merges endpoint')" 1
is "Q21 so is one to its absolute URL" \
   "$(denies "$W" 'gh api -X POST https://forge.example/api/v3/repos/acme/app/merges -f base=main -f head=feature' 'writes to a merges endpoint')" 1
is "Q22 a gh write's pin in the query string is denied" \
   "$(denies "$W" "gh api -X PUT 'repos/acme/app/pulls/9/merge?sha=$REBASED'" 'carries a query string')" 1
is "Q23 so is any query string on a gh write, beside a pin in the body" \
   "$(denies "$W" "gh api -X PUT 'repos/acme/app/pulls/9/merge?merge_method=squash' -f sha=$REBASED" 'carries a query string')" 1
is "Q24 GitLab reads the query string, so a glab pin there is read" \
   "$(decision "$W" "glab api -X PUT 'projects/acme%2Fapp/merge_requests/7/merge?sha=$REBASED'")" allow
is "Q25 glab mr for is denied: the forge makes its branch" \
   "$(denies "$W" 'glab mr for 3 --target-branch main' 'glab mr for creates an MR/PR from a branch the forge makes itself')" 1
is "Q26 so are its aliases and gh pr revert, each pointing to the create the gate checks" \
   "$(denies "$W" 'glab mr new-for 3' 'propose it with glab mr create') $(denies "$W" 'glab mr create-for 3' 'propose it with glab mr create') $(denies "$W" 'gh pr revert 9' 'propose it with gh pr create')" \
   "1 1 1"
# A forge's router may decode a percent-escape in the path, so the gate reads the path decoded,
# except in the project segment of the REST forms it checks (acme%2Fapp).
is "Q27 a percent-escaped MR path is gated" \
   "$(denies "$W" 'glab api -X POST projects/:id/m%65rge_requests -f source_branch=other -f target_branch=main' 'writes to an MR/PR path whose source, head or destination')" 1
is "Q28 a percent-escaped graphql endpoint is GraphQL" \
   "$(denies "$W" "gh api graph%71l -f query='mutation { enqueuePullRequest(input: {}) { clientMutationId } }'" 'this GraphQL call')" 1
is "Q29 a percent-escaped merges endpoint is a branch merge" \
   "$(denies "$W" 'gh api repos/acme/app/merg%65s -f base=main -f head=other' 'writes to a merges endpoint')" 1
is "Q30 an encoded project path still reads and merges" \
   "$(decision "$W" 'glab api projects/acme%2Fapp/merge_requests/7') $(decision "$W" "glab api -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" \
   "allow allow"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

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
for c in 'ls -la' 'git status' 'npm test' 'git log --oneline -5' 'mkdir -p newdir'; do
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

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

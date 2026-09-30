#!/usr/bin/env bash
# PreToolUse(Bash) guard for git commits and forge MR/PR creation.
#
# Enforces the two rules from the "Merge & pull requests" section of
# ~/.config/agents/GLOBAL.md that prose alone cannot guarantee:
#
#   1. No agent attribution — claude.ai session links, `Claude-Session:` trailers,
#      `Co-authored-by:` agent lines, "Generated with …" footers.
#   2. If the repo ships an MR/PR template, the description must follow it.
#
# It also carries two genuine danger gates: `glab api` calls that write (rule 3), and
# `git push` (rule 4, in git-push-guard.py beside this file: default-branch, force,
# delete and mirror pushes ask; an unsupported push configuration or a secret in the
# outgoing commits is denied).
#
# Rules 1 and 2 are reported as permissionDecision=deny. That is NOT a user prompt: the
# model reads the reason and rewrites, so a violation costs a retry, not an
# interruption. Deliberately no `ask` for those two — neither is a danger gate, they
# are correctness catches (see the "prompt on danger, not mechanism" rule). Rule 3 IS
# a danger gate and does use `ask`.
#
# Why rule 3 lives here and not in permissions.ask: `Bash(glab api *)` used to be an
# ask rule, and it gated the *mechanism* — it fired 156x in one fortnight against 2
# real rejections, because every sampled call was a read-only GET piped into jq. It
# could not be narrowed from the settings side either: an ask rule is absolute, and a
# PreToolUse hook returning permissionDecision=allow LOSES to it (measured 2026-08-25).
# So the rule was dropped and the danger is gated from this side instead — reads fall
# through to the auto-mode classifier, writes ask.
#
# SAFETY: a guard that breaks unrelated commands is worse than no guard. There is
# no `set -e`; every failure path of rules 1-2 calls allow(); anything unparseable is
# allowed. Rules 3 and 4 are danger gates and fail the other way (see each).
#
# Bypass for a one-off: put FORGE_GUARD=off anywhere in the command. It lifts rules 1
# and 2 only, the behavioural ones; it never lifts rule 3 or rule 4.
#
# Bash 3.2 compatible (macOS system bash).

set -uo pipefail

# A rule-4 ask is held here rather than printed at once, so that a rule 1-2 deny
# further down still wins over it (deny beats ask). allow() releases it.
pending=""
allow() { [ -z "$pending" ] || printf '%s\n' "$pending"; exit 0; }

# A deny reason can contain anything (template markdown, quotes, newlines), so it
# is passed through jq -Rs rather than hand-escaped. If jq fails, allow.
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

# Same shape as deny(), but hands the call to the user instead of bouncing it back to
# the model. Rule 3 only.
ask() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

payload=$(cat)
[ -n "$payload" ] || allow
command -v jq >/dev/null 2>&1 || allow

# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before
# any JSON parsing. Everything below is reached only by the handful of commands
# that even mention a commit, an MR/PR, or a push.
forge_candidate=0
case "$payload" in
  *"git commit"*|*"glab mr create"*|*"glab mr update"* \
  |*"gh pr create"*|*"gh pr edit"*|*"az repos pr create"*|*"az repos pr update"* \
  |*"glab api"*) forge_candidate=1 ;;
esac

# Rule 4 candidates, from three independent signals:
#   push_word      the payload mentions "push" at all (cheap and broad);
#   push_selector  it mentions git together with something that selects ANOTHER repository
#                  or configuration (-C, --git-dir, --work-tree, -c, GIT_DIR, GIT_WORK_TREE,
#                  GIT_CONFIG*, a cd). An alias defined there cannot be listed from here,
#                  so the helper resolves it in the repository git would select;
#   push_alias     it names an alias that expands to a push (the dotfiles define
#                  pom = push origin main), listed with ONE git call in the payload's cwd,
#                  read from the raw JSON with a builtin match.
# A payload that mentions neither git nor push costs no subprocess at all, and a plain git
# command costs one git call, never the helper.
push_word=0; push_selector=0; push_alias=0
case "$payload" in *push*|*send-pack*) push_word=1 ;; esac
case "$payload" in
  *git*)
    case "$payload" in
      *" -C"*|*"--git-dir"*|*"--work-tree"*|*" -c"*|*GIT_DIR*|*GIT_WORK_TREE*|*GIT_CONFIG*|*"cd "*)
        push_selector=1 ;;
    esac
    if [ "$push_selector" = 0 ]; then
      pcwd=.
      cwd_re='"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
      [[ $payload =~ $cwd_re ]] && pcwd=${BASH_REMATCH[1]}
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$payload" in *"$a"*) push_alias=1; break ;; esac
      done <<EOF
$(git -C "$pcwd" config --get-regexp '^alias\.' 2>/dev/null | sed -n -E 's/^alias\.([^ ]+) .*(push|send-pack|subtree|submodule|rebase|bisect).*/\1/p')
EOF
    fi
    ;;
esac
push_candidate=0
[ "$push_word$push_selector$push_alias" = 000 ] || push_candidate=1

[ "$forge_candidate" = 1 ] || [ "$push_candidate" = 1 ] || allow

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

# ------------------------------------------------------------ rule 4: git push
# The work is in git-push-guard.py beside this file: it prints a finished decision (ask
# or deny) or nothing. A deny is final. An ask is held in $pending and released by
# allow(), so the rules below can still deny. FAIL DIRECTION IS CLOSED: if the helper
# cannot run at all, a command that looks like a push is denied, with a reason the agent
# can act on. Runs before the FORGE_GUARD=off check below, which never lifts it.
if [ "$push_candidate" = 1 ]; then
  py=/usr/bin/python3
  [ -x "$py" ] || py=python3
  helper="$(dirname "$0")/git-push-guard.py"
  verdict=$(printf '%s' "$payload" | "$py" "$helper" 2>/dev/null)
  rc=$?
  case "$verdict" in
    '') ;;
    *'"permissionDecision":"ask"'*) pending=$verdict ;;
    *) printf '%s\n' "$verdict"; exit 0 ;;
  esac
  # The fallback denies on the same evidence the fast path acted on: an alias that pushes,
  # a repository selector (whose aliases only the helper can see), or a literal git push.
  # The bare word "push" alone is not enough; it is too common in unrelated commands.
  if [ "$rc" -ne 0 ]; then
    if [ "$push_alias" = 1 ] || [ "$push_selector" = 1 ] \
       || printf '%s' "$cmd" | grep -Eq 'git[^;&|]*[[:space:]]push([[:space:]]|$)'; then
      deny "Push guard: the push check could not run ($helper exited $rc), so this command, which may push, is refused. Push by hand, or restore the helper (chezmoi apply)."
    fi
  fi
fi

# ------------------------------------------------------- rule 3: glab api writes
# Read-only `glab api` (the overwhelming majority: pipeline status, job traces, MR
# bodies) falls straight through to the auto-mode classifier and never prompts. Only
# a call that can change something on the forge asks.
#
# FAIL DIRECTION IS INVERTED HERE. Rules 1-2 allow on any doubt; this one asks on any
# doubt — a false ask costs one keystroke, a false silence is an ungated remote
# mutation. Unparseable command, missing python3, classifier crash => ask.
#
# It reads SHELL STRUCTURE, never raw text. A first draft also regex-scanned the raw
# command as a backstop; that fired on every heredoc, python literal and rg pattern that
# merely QUOTED a write call -- prompting on a mention, which is the exact failure this
# whole gate was built to remove. Replaced by descending into `sh -c` arguments, which
# are the only quoted strings that actually execute.
#
# Known limit, shared with every prefix-matched permission rule in settings.json: a call
# built by string concatenation at runtime, or sent through a wrapper this does not model
# (`ssh host '...'`), is not caught. This is a guard, not a sandbox.
case "$cmd" in
  *"glab api"*)
    if ! command -v python3 >/dev/null 2>&1; then
      ask "glab api call, and python3 is missing so the read/write check could not run."
    fi
    verdict=$(printf '%s' "$cmd" | python3 -c 'import sys, shlex

OPS = {"|", "||", "&&", ";", "&", "(", ")", "|&", ";;", "\n"}
WRITE_LONG = {"--field", "--raw-field", "--input", "--form"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
PREFIX = {"sudo", "env", "command", "nohup", "time", "xargs"}


def is_write_flag(a, nxt):
    if a in ("-X", "--method"):
        return nxt.upper() not in ("GET", "HEAD")
    if a.startswith("--method="):
        return a.split("=", 1)[1].upper() not in ("GET", "HEAD")
    if a in ("-f", "-F") or a in WRITE_LONG:
        return True
    if a.startswith(("--field=", "--raw-field=", "--input=", "--form=")):
        return True
    if a.startswith("-") and not a.startswith("--") and len(a) > 1:
        return any(c in a[1:] for c in "fF")
    return False


def classify(cmd, depth=0):
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    try:
        toks = list(lx)
    except ValueError:
        return "unparseable"
    n, i = len(toks), 0
    at_cmd_pos = True
    while i < n:
        t = toks[i]
        if t in OPS:
            at_cmd_pos = True
            i += 1
            continue
        if at_cmd_pos and (t in PREFIX or ("=" in t and not t.startswith("-"))):
            i += 1
            continue
        # A shell invoked with -c EXECUTES its argument, so descend into it. This is the
        # only way a call is reachable without appearing as tokens here -- and descending
        # only into -c is what keeps quoted DATA (heredoc bodies, python string literals,
        # rg patterns) from being read as a call. See the note on rule 3 above.
        if at_cmd_pos and t in SHELLS and depth < 3:
            for k in range(i + 1, min(i + 4, n)):
                if toks[k] == "-c" and k + 1 < n:
                    if classify(toks[k + 1], depth + 1) == "write":
                        return "write"
                    break
        if at_cmd_pos and t == "glab" and i + 1 < n and toks[i + 1] == "api":
            j = i + 2
            while j < n and toks[j] not in OPS:
                if is_write_flag(toks[j], toks[j + 1] if j + 1 < n else ""):
                    return "write"
                j += 1
            i = j
            at_cmd_pos = True
            continue
        at_cmd_pos = False
        i += 1
    return "read"


# The shell joins `\<newline>` before it ever splits words; shlex does not, and emits the
# newline as an operator token. Without this join, `glab api p/1 \<newline> -X DELETE` ends
# its segment at the newline and the flag is never seen. Found by mutation testing.
print(classify(sys.stdin.read().replace("\\\n", " ")))' 2>/dev/null) || verdict=unparseable
    case "$verdict" in
      write)
        ask "This \`glab api\` call writes to the forge.

It carries a method or field flag (-X/--method with a non-GET verb, or -f/--field/
--raw-field/--input), so it can create, edit, or delete something on GitLab, and that
is not undoable from here.

Read-only \`glab api\` calls are not gated and do not reach this prompt."
        ;;
      read)
        : # falls through to the auto-mode classifier
        ;;
      *)
        ask "Could not determine whether this \`glab api\` call reads or writes.

The command did not tokenize cleanly (unbalanced quotes, or a construct the check
does not model), so it is being surfaced rather than assumed safe. Check the method
flag by eye."
        ;;
    esac
    ;;
esac

# The bypass lifts rules 1 and 2 only. It sits here, after both danger gates, so a
# FORGE_GUARD=off in the command can never reach a push or a glab api write.
case "$cmd" in *FORGE_GUARD=off*) allow ;; esac

# Precise gate: the forge command must actually sit in command position. Without
# this, `rg "git commit" docs/` or a heredoc quoting one of these would trip the
# guard on text it merely mentions.
verb_re='(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(git[[:space:]]+commit|glab[[:space:]]+mr[[:space:]]+(create|update)|gh[[:space:]]+pr[[:space:]]+(create|edit)|az[[:space:]]+repos[[:space:]]+pr[[:space:]]+(create|update))([[:space:]]|$)'
printf '%s' "$cmd" | grep -Eq "$verb_re" || allow

# The message/description is normally inline in the command string. When it is
# not, the command names the file holding it. Scan both — that beats trying to
# parse shell quoting, and a marker matching anywhere in the command means the
# text is present either way.
#
# `unresolved` records that the command named a body file this hook could NOT
# read. That distinction matters because the two rules fail in opposite
# directions: rule 1 denies on POSITIVE evidence (attribution found), so an
# unread file can only make it miss, never misfire. Rule 2 denies on the ABSENCE
# of template markers, so judging a body it never saw is precisely how this
# guard produces a false deny — hence the fail-open before rule 2's deny.
haystack=$cmd
unresolved=0

# Expand ~, $VAR and ${VAR} using this hook's own environment.
#
# Deliberately NOT eval. The command is untrusted model output, and `eval` on it
# to resolve a path would execute whatever else it contains — a guard that runs
# the string it is inspecting is a hole, not a check. Indirect expansion reads
# variables without executing anything. A variable this process cannot see
# resolves to empty, the path then fails the -f test, and the fail-open covers
# it: worst case is the pre-existing "cannot read it" branch, never a wrong deny.
#
# KNOWN LIMIT, measured 2026-08-27 by probing the live hook: this process does
# NOT share $TMPDIR with the Bash tool it is inspecting. Claude Code points the
# sandboxed command at a per-session temp dir; the hook inherits the parent's.
# $HOME-relative and literal absolute paths resolve correctly (verified live);
# a $TMPDIR-relative body file does not, and lands in `unresolved`. That is why
# the fail-open below is load-bearing rather than belt-and-braces — for the
# scratchpad paths agents are told to use, it is the ONLY thing standing between
# a compliant description and a false deny.
expand_path() {
  local p=$1 out='' name
  local re='^([^$]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$'
  # SC2088 fires on the "~/" case pattern below. It is a false positive here:
  # these match a LITERAL tilde in the untrusted path text, which is exactly the
  # unexpanded form that needs resolving. $HOME is what it expands to.
  # shellcheck disable=SC2088
  case "$p" in
    "~")   printf '%s' "$HOME"; return ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  while [[ $p =~ $re ]]; do
    name=${BASH_REMATCH[2]}
    out="$out${BASH_REMATCH[1]}${!name-}"
    p=${BASH_REMATCH[3]}
  done
  printf '%s' "$out$p"
}

# Trim leading blanks without a subprocess (bash 3.2 has no ${var##+([ ])}).
ltrim() {
  local s=$1
  while [ "${s# }" != "$s" ] || [ "${s#	}" != "$s" ]; do s=${s# }; s=${s#	}; done
  printf '%s' "$s"
}

# Candidate file references. Values may be quoted (paths with spaces) or bare.
# `$(cat …)`/`$(< …)` stop at the first `)`, so a nested command substitution is
# not resolved — that lands in `unresolved` and fails open rather than denying.
sq=\'
ref_re="\\\$\\((cat|<)[^)]*\\)|(--body-file|--description-file|--file|-F)[=[:space:]]+(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]]+)"

while IFS= read -r ref; do
  [ -n "$ref" ] || continue

  # `unambiguous` distinguishes a token that can only be a file reference from a
  # bare `-F`, which is also grep's fixed-string flag and sort's field
  # separator. Both still contribute to the haystack when they resolve; only an
  # unambiguous one is allowed to set `unresolved` and so relax rule 2. Without
  # this, `glab mr create --description 'freeform' | grep -F foo` fails open and
  # the template check silently stops running.
  unambiguous=1

  # Strip whichever wrapper the pattern matched, down to the bare path.
  case "$ref" in
    '$('*)
      ref=${ref#\$\(}; ref=${ref%\)}
      ref=$(ltrim "$ref")
      ref=${ref#cat}; ref=${ref#<}
      ref=$(ltrim "$ref")
      ref=${ref#--}                 # `cat -- file`
      ref=$(ltrim "$ref")
      ;;
    -F*)
      ref=${ref#-F}; ref=${ref#=}
      ref=$(ltrim "$ref")
      unambiguous=0
      ;;
    *)
      ref=${ref#--body-file}; ref=${ref#--description-file}
      ref=${ref#--file}
      ref=${ref#=}
      ref=$(ltrim "$ref")
      ;;
  esac

  ref=${ref%\"}; ref=${ref#\"}
  ref=${ref%\'}; ref=${ref#\'}
  [ -n "$ref" ] || continue

  ref=$(expand_path "$ref")

  if [ -f "$ref" ] && [ -r "$ref" ]; then
    haystack="$haystack
$(cat "$ref" 2>/dev/null)"
  elif [ "$unambiguous" -eq 1 ]; then
    unresolved=1
  else
    # A bare `-F` value that is not a readable file: treat it as a path only if
    # it is shaped like one, so `grep -F foo` is ignored while
    # `git commit -F $VAR/msg.txt` (unset VAR) still fails open.
    case "$ref" in
      */*|~*|\$*) unresolved=1 ;;
    esac
  fi
done <<EOF
$(printf '%s' "$cmd" | grep -oE "$ref_re")
EOF

# ---------------------------------------------------------------- rule 1: attribution
if printf '%s' "$haystack" | grep -Eq \
   'claude\.ai/code|[Cc]laude-[Ss]ession|[Cc]o-[Aa]uthored-[Bb]y:[[:space:]]*(Claude|Codex|Copilot|Cursor)|[Gg]enerated with[^;]{0,24}(Claude|Codex)'; then
  deny "Agent attribution is not allowed in the published record.

This commit message / MR / PR text contains a session link, a Claude-Session
trailer, a Co-authored-by agent line, or a \"Generated with …\" footer. Per the
\"Merge & pull requests\" section of ~/.config/agents/GLOBAL.md, none of that goes
into commit messages, MR/PR titles or descriptions, issue text, or review
comments.

Remove it and retry. Do not ask whether to keep it — the rule is unconditional."
fi

# ---------------------------------------------------------------- rule 2: MR/PR template
case "$cmd" in
  *"glab mr create"*|*"gh pr create"*|*"az repos pr create"*) ;;
  *) allow ;;
esac

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow

templates=""
for p in \
  "$root"/.gitlab/merge_request_templates/*.md \
  "$root"/.github/pull_request_template.md \
  "$root"/.github/PULL_REQUEST_TEMPLATE.md \
  "$root"/.github/PULL_REQUEST_TEMPLATE/*.md \
  "$root"/.azuredevops/pull_request_template.md \
  "$root"/.azuredevops/pull_request_template/*.md \
  "$root"/docs/pull_request_template.md \
  "$root"/docs/merge_request_template.md \
  "$root"/pull_request_template.md \
  "$root"/.gitlab/merge_request_templates/*.markdown ; do
  [ -f "$p" ] && templates="$templates$p
"
done
[ -n "$templates" ] || allow

# Section markers, not just markdown headings: the ViuMore templates label their
# sections with **Bold** lines and have no `#` heading at all, so a heading-only
# check would silently pass on exactly the repos this guard is for.
markers_of() {
  sed -nE 's/^#{1,6}[[:space:]]+(.+)$/\1/p; s/^\*\*([^*]+)\*\*.*$/\1/p' "$1" \
    | sed -E 's/[[:space:]]+$//' | grep -v '^[[:space:]]*$'
}

best_total=0
while IFS= read -r tpl; do
  [ -n "$tpl" ] || continue
  total=0; hits=0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    total=$((total + 1))
    printf '%s' "$haystack" | grep -Fqi -- "$m" && hits=$((hits + 1))
  done <<EOF
$(markers_of "$tpl")
EOF
  # Fewer than two markers is not a structure worth judging — don't guess.
  [ "$total" -lt 2 ] && allow
  # Half the sections present is the bar. The rule says fill every section and
  # write n/a rather than delete one, so a compliant body clears this easily;
  # half keeps a reworded heading or a dropped optional section from misfiring.
  [ $((hits * 2)) -ge "$total" ] && allow
  [ "$total" -gt "$best_total" ] && { best_total=$total; best_tpl=$tpl; best_hits=$hits; }
done <<EOF
$templates
EOF

[ "$best_total" -gt 0 ] || allow

# Fail open when the command named a body file this hook could not read. Rule 2
# infers non-compliance from markers being ABSENT, and a body it never saw is
# indistinguishable from an empty one — so denying here punishes a description
# that may well be perfect. This is the "a guard that breaks unrelated commands
# is worse than no guard" rule applied to its own blind spot. Observed 2026-08-26:
# `--description "$(cat $TMPDIR/mr.md)"` denied a fully compliant body, because
# $TMPDIR was never expanded, so the only marker that matched was the word
# "description" in the flag name itself.
[ "$unresolved" -eq 1 ] && allow

deny "This repo ships an MR/PR template and the description does not follow it.

Template: ${best_tpl#$root/}
Matched ${best_hits} of ${best_total} sections.

--- template ---
$(head -c 4000 "$best_tpl")
--- end template ---

Rewrite the description with this structure: keep the headings, their order, and
the checklists; fill every section; write \"n/a\" with a one-line reason instead
of deleting a section that does not apply; tick a checkbox only if the item is
actually done.

Note that neither glab nor gh expands the template when the body is passed as a
flag — render the filled-in text yourself, e.g.
  gh pr create --body-file <file>
  glab mr create --description \"\$(cat <file>)\"

Give that file a LITERAL absolute path. This hook does not share \$TMPDIR with
the command it is checking, so a \$TMPDIR-relative body is one it cannot read:
it will not be denied, but it will not be checked for attribution either.

If the description genuinely should not follow the template, say so and re-run
with FORGE_GUARD=off in the command."

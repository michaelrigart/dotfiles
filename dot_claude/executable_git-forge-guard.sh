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
# It also carries one genuine danger gate (rule 3): `glab api` calls that write.
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
# no `set -e`; every failure path calls allow(); anything unparseable is allowed.
#
# Bypass for a one-off: put FORGE_GUARD=off anywhere in the command.
#
# Bash 3.2 compatible (macOS system bash).

set -uo pipefail

allow() { exit 0; }

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
# that even mention a commit or an MR/PR.
case "$payload" in
  *"git commit"*|*"glab mr create"*|*"glab mr update"* \
  |*"gh pr create"*|*"gh pr edit"*|*"az repos pr create"*|*"az repos pr update"* \
  |*"glab api"*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

case "$cmd" in *FORGE_GUARD=off*) allow ;; esac

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

# Precise gate: the forge command must actually sit in command position. Without
# this, `rg "git commit" docs/` or a heredoc quoting one of these would trip the
# guard on text it merely mentions.
verb_re='(^|[;&|(])[[:space:]]*(sudo[[:space:]]+)?(git[[:space:]]+commit|glab[[:space:]]+mr[[:space:]]+(create|update)|gh[[:space:]]+pr[[:space:]]+(create|edit)|az[[:space:]]+repos[[:space:]]+pr[[:space:]]+(create|update))([[:space:]]|$)'
printf '%s' "$cmd" | grep -Eq "$verb_re" || allow

# The message/description is normally inline in the command string. When it is
# not, the command names the file holding it. Scan both — that beats trying to
# parse shell quoting, and a marker matching anywhere in the command means the
# text is present either way.
haystack=$cmd
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  ref=${ref%\"}; ref=${ref#\"}
  ref=${ref%\'}; ref=${ref#\'}
  case "$ref" in "~/"*) ref="$HOME/${ref#\~/}" ;; esac
  if [ -f "$ref" ] && [ -r "$ref" ]; then
    haystack="$haystack
$(cat "$ref" 2>/dev/null)"
  fi
done <<EOF
$(printf '%s' "$cmd" \
   | grep -oE '\$\(cat [^)]+\)|--body-file[= ][^ ]+|--description-file[= ][^ ]+|-F[= ][^ ]+' \
   | sed -E 's/^\$\(cat //; s/\)$//; s/^--body-file[= ]//; s/^--description-file[= ]//; s/^-F[= ]//')
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

If the description genuinely should not follow the template, say so and re-run
with FORGE_GUARD=off in the command."

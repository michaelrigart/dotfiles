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
# Both are reported as permissionDecision=deny. That is NOT a user prompt: the
# model reads the reason and rewrites, so a violation costs a retry, not an
# interruption. Deliberately no `ask` — neither rule is a danger gate, they are
# correctness catches (see the "prompt on danger, not mechanism" rule).
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

payload=$(cat)
[ -n "$payload" ] || allow
command -v jq >/dev/null 2>&1 || allow

# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before
# any JSON parsing. Everything below is reached only by the handful of commands
# that even mention a commit or an MR/PR.
case "$payload" in
  *"git commit"*|*"glab mr create"*|*"glab mr update"* \
  |*"gh pr create"*|*"gh pr edit"*|*"az repos pr create"*|*"az repos pr update"*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

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

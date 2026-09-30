#!/usr/bin/env bash
# PermissionRequest hook: appends one line per permission prompt Michael is shown, to
# ${XDG_STATE_HOME:-~/.local/state}/agent-audit/prompts.jsonl, as
#   {ts, session, cwd, tool, subcommand}
# Approved prompts are invisible in transcripts, so this log is the only prompt count the
# safe-autonomy evaluation has (spec 2026-09-30, section 5).
#
# It NEVER decides: it prints nothing, so the prompt proceeds exactly as it would without
# the hook. It NEVER logs the tool input: a command line can carry a secret. subcommand is
# the first word of a Bash command, skipping leading VAR=value assignments, plus the
# second word only for a known multi-command tool (git push, op read); for an MCP tool it
# is the tool name; for anything else it is empty.
#
# Fails open and silent on every error. Bash 3.2 compatible.
set -uo pipefail

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent-audit"
mkdir -p "$dir" 2>/dev/null || exit 0

# Tools whose second word is a subcommand. Any other tool logs its first word only: the
# second word of an arbitrary command (echo, mysql, htpasswd) can be the secret itself.
multi='["git","glab","gh","op","docker","kubectl","helm","az","aws","terraform","brew","mise","chezmoi","basecamp","herdr","xreview","codex","claude","npm","yarn","pnpm","bundle","rails","cargo","go","uv","pip","borg","vorta","tsh","tctl","kubie"]'
line=$(printf '%s' "$payload" | jq -c --argjson multi "$multi" '
  def subcommand:
    [splits("[[:space:]]+") | select(length > 0)]
    | until((length == 0) or (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=") | not); .[1:])
    | if length == 0 then ""
      elif (.[0] | test("^[A-Za-z0-9_./+-]+$") | not) then "?"
      elif (length > 1) and (.[0] | IN($multi[])) and (.[1] | test("^[a-z][a-z0-9-]*$"))
        then "\(.[0]) \(.[1])"
      else .[0] end;
  (.tool_name // "") as $tool
  | {ts: (now | todate),
     session: (.session_id // ""),
     cwd: (.cwd // ""),
     tool: $tool,
     subcommand: (if $tool == "Bash" then ((.tool_input.command // "") | subcommand)
                  elif ($tool | startswith("mcp__")) then $tool
                  else "" end)}' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0
printf '%s\n' "$line" 2>/dev/null >> "$dir/prompts.jsonl"
exit 0

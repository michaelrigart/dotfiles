#!/usr/bin/env bash
# Claude Code per-subagent status line (agent panel) — Tokyo Night.
# The row-context JSON on stdin is not fully documented, so read it defensively.

input=$(cat)

label=$(printf '%s' "$input" | jq -r '
  .agentType // .agent // .subagent_type // .agentName // .name // .label
  // .description // "agent"' 2>/dev/null)
model=$(printf '%s' "$input" | jq -r '
  (.model.display_name // .model.id // .model // "") | tostring' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

label=$(printf '%s' "$label" | cut -c1-24)   # keep short for the narrow panel

skill=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  skill=$(grep '"name":"Skill"' "$transcript" 2>/dev/null | tail -20 \
    | jq -rc 'try (.message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill) catch empty' 2>/dev/null \
    | grep -v '^$' | tail -1)
fi

# Tokyo Night (R;G;B) — dark backgrounds, accent colors as text (all AA)
NIGHT="26;27;38"; BGHL="41;46;66"
PURPLE="157;124;216"; CYAN="125;207;255"; MAGENTA="187;154;247"

SEP=$(printf '\xee\x82\xb0')   # U+E0B0
ARR=$(printf '\xe2\x96\xb8')   # U+25B8 ▸
R=$'\033[0m'

segs=("$PURPLE|$NIGHT|$label")
[ -n "$model" ] && [ "$model" != "null" ] && segs+=("$CYAN|$BGHL|$model")
[ -n "$skill" ] && segs+=("$MAGENTA|$NIGHT|$ARR $skill")

out=""; prevbg=""
for s in "${segs[@]}"; do
  fg=${s%%|*}; rest=${s#*|}; bg=${rest%%|*}; text=${rest#*|}
  [ -n "$prevbg" ] && out+=$'\033['"38;2;${prevbg};48;2;${bg}m${SEP}"
  out+=$'\033['"38;2;${fg};48;2;${bg}m ${text} "
  prevbg=$bg
done
out+=$'\033[0m\033['"38;2;${prevbg}m${SEP}${R}"

printf '%s' "$out"

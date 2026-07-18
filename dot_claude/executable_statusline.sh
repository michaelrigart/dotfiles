#!/usr/bin/env bash
# Claude Code status line — Tokyo Night, full width.
# Segments: dir  git branch  model  most-recent skill/plugin, then a bar to the
# right edge. Receives the session JSON on stdin; terminal width from $COLUMNS.
export LC_ALL=en_US.UTF-8   # count runes, not bytes, in ${#text} width math

input=$(cat)
model=$(printf '%s' "$input"      | jq -r '.model.display_name // "Claude"')
cwd=$(printf '%s' "$input"        | jq -r '.workspace.current_dir // .cwd // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
effort=$(printf '%s' "$input"     | jq -r '.effort.level // empty')

cols="${COLUMNS:-120}"
[ "$cols" -gt 0 ] 2>/dev/null || cols=120

# --- git branch (only if cwd is a work tree) ---
branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# --- most recent Skill tool_use from the transcript ---
skill=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  skill=$(grep '"name":"Skill"' "$transcript" 2>/dev/null | tail -40 \
    | jq -rc 'try (.message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill) catch empty' 2>/dev/null \
    | grep -v '^$' | tail -1)
fi

dir=$(basename "${cwd:-$PWD}")

# --- Tokyo Night (night) palette, "R;G;B" ---
# Backgrounds are dark shades; accents are used as TEXT (the way Tokyo Night is
# designed) so nothing glares. Segments alternate two dark shades so the powerline
# separators stay visible, and every text/background pair clears WCAG AA (>=4.5).
DARK="22;22;30"       # #16161e  filler bar (darkest)
NIGHT="26;27;38"      # #1a1b26  segment bg
BGHL="41;46;66"       # #292e42  segment bg (raised)
COMMENT="86;95;137"   # #565f89  no-skill placeholder text
BLUE="122;162;247"    # #7aa2f7  dir text
CYAN="125;207;255"    # #7dcfff  model text
GREEN="158;206;106"   # #9ece6a  branch text
MAGENTA="187;154;247" # #bb9af7  skill text (accent)
YELLOW="224;175;104"  # #e0af68  effort text (beside the model)

# Glyphs are built from raw UTF-8 bytes so the source stays pure ASCII (private-use
# Nerd Font codepoints get stripped if written literally).
SEP=$(printf '\xee\x82\xb0')   # U+E0B0 powerline right separator
BR=$(printf '\xee\x82\xa0')    # U+E0A0 branch glyph
ARR=$(printf '\xe2\x96\xb8')   # U+25B8  ▸ skill marker
DASH=$(printf '\xe2\x80\x94')  # U+2014  — em dash (no-skill placeholder)
DOT=$(printf '\xc2\xb7')       # U+00B7  · middot (model / effort separator)
R=$'\033[0m'

# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)
segs=()
segs+=("$BLUE|$NIGHT|$dir")
[ -n "$branch" ] && segs+=("$GREEN|$BGHL|$BR $branch")
# model, with the live reasoning effort beside it in muted yellow (omitted when
# the model doesn't expose an effort level, i.e. .effort.level is absent)
model_seg="$model"
[ -n "$effort" ] && model_seg="$model $(printf '\033[38;2;%sm' "$YELLOW")$DOT $effort"
segs+=("$CYAN|$NIGHT|$model_seg")
if [ -n "$skill" ]; then
  segs+=("$MAGENTA|$BGHL|$ARR $skill")
else
  segs+=("$COMMENT|$BGHL|$ARR $DASH")
fi

out=""; prevbg=""
for s in "${segs[@]}"; do
  fg=${s%%|*}; rest=${s#*|}; bg=${rest%%|*}; text=${rest#*|}
  [ -n "$prevbg" ] && out+=$'\033['"38;2;${prevbg};48;2;${bg}m${SEP}"
  out+=$'\033['"38;2;${fg};48;2;${bg}m ${text} "
  prevbg=$bg
done

# Visible width of the cluster: strip ANSI, then count UTF-8 codepoints as the
# bytes that are NOT continuation bytes (0x80-0xBF). Locale-independent, so it is
# correct no matter what LC_* the harness hands us.
plain=$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g')
w=$(printf '%s' "$plain" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c)
w=$((w))

# filler bar to the right edge (total visible width == cols)
n=$((cols - w - 1))
if [ "$n" -gt 0 ]; then
  out+=$'\033['"38;2;${prevbg};48;2;${DARK}m${SEP}"
  out+=$'\033[48;2;'"${DARK}m"
  printf -v pad '%*s' "$n" ''
  out+="$pad"
fi
out+="$R"

printf '%s' "$out"

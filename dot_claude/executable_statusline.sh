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
TEAL="115;218;202"    # #73daca  tagteam account + usage text
RED="247;118;142"     # #f7768e  the same at 90% or more

# Glyphs are built from raw UTF-8 bytes so the source stays pure ASCII (private-use
# Nerd Font codepoints get stripped if written literally).
SEP=$(printf '\xee\x82\xb0')   # U+E0B0 powerline right separator
BR=$(printf '\xee\x82\xa0')    # U+E0A0 branch glyph
ARR=$(printf '\xe2\x96\xb8')   # U+25B8  ▸ skill marker
DASH=$(printf '\xe2\x80\x94')  # U+2014  — em dash (no-skill placeholder)
DOT=$(printf '\xc2\xb7')       # U+00B7  · middot (model / effort separator)
R=$'\033[0m'

# --- tagteam: the live account and its usage. Empty when tagteam is missing, fails (it
# cannot open its store inside the sandbox) or prints nothing; then no segment is shown. ---
tt=""
if command -v tagteam >/dev/null 2>&1; then
  tt=$(tagteam --no-color statusline </dev/null 2>/dev/null) || tt=""
  tt=${tt%%$'\n'*}
  # Drop OSC sequences (BEL or ESC \ terminated, e.g. hyperlinks; an unterminated one runs
  # to the end of the line), then any CSI sequence, then any other ESC sequence, then
  # whatever C0 control or DEL byte is left (CR, a stray ESC). sed and tr run under LC_ALL=C
  # so the ranges are byte-exact and invalid UTF-8 passes through whole; render then counts
  # it as unknown width and the segment is left out.
  esc=$'\033'; bel=$'\007'
  tt=$(printf '%s' "$tt" \
    | LC_ALL=C sed -E "s#${esc}\][^${bel}${esc}]*(${bel}|${esc}\\\\)##g; s#${esc}\].*\$##; s#${esc}\[[0-9:;<=>?]*[ -/]*[@-~]##g; s#${esc}[ -/]*[0-~]##g" \
    | LC_ALL=C tr -d '\000-\037\177')
fi
tt_fg=$TEAL
if [ -n "$tt" ]; then
  max=$(printf '%s' "$tt" | grep -oE '[0-9]+(\.[0-9]+)?%' | cut -d. -f1 | tr -d '%' | sort -n | tail -1)
  [ -n "$max" ] && [ "$max" -ge 90 ] && tt_fg=$RED
fi

# model, with the live reasoning effort beside it in muted yellow (omitted when
# the model doesn't expose an effort level, i.e. .effort.level is absent)
model_seg="$model"
[ -n "$effort" ] && model_seg="$model $(printf '\033[38;2;%sm' "$YELLOW")$DOT $effort"

# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)
# build_segs <0|1>: 1 adds the tagteam segment after the model; the skill segment then
# takes the NIGHT shade so neighbouring backgrounds keep alternating.
build_segs() {
  local skill_bg=$BGHL
  segs=()
  segs+=("$BLUE|$NIGHT|$dir")
  [ -n "$branch" ] && segs+=("$GREEN|$BGHL|$BR $branch")
  segs+=("$CYAN|$NIGHT|$model_seg")
  if [ "$1" = 1 ]; then
    segs+=("$tt_fg|$BGHL|$tt")
    skill_bg=$NIGHT
  fi
  if [ -n "$skill" ]; then
    segs+=("$MAGENTA|$skill_bg|$ARR $skill")
  else
    segs+=("$COMMENT|$skill_bg|$ARR $DASH")
  fi
}

# render: segs -> out, prevbg, w (the cluster's visible width) and unknown.
# w: strip ANSI, then count UTF-8 codepoints as the bytes that are NOT continuation bytes
# (0x80-0xBF). Locale-independent, so it is correct no matter what LC_* the harness hands us.
# On invalid UTF-8 that sed fails and prints nothing; unknown then leaves the segment out and
# the line is what it always was, so its error message is discarded.
# unknown: the count of bytes that belong to no character of known width. Known: printable
# ASCII, U+00A0-02FF and U+0380-07FF (C2 A0-BF, or lead C3-CB or CE-DF, then one
# continuation byte) and the glyphs SEP BR ARR DASH. Under LC_ALL=C one left-to-right pass
# over out removes the colour codes and every known non-ASCII character; unknown counts the
# bytes left that are not printable ASCII: those of a control character (C0, DEL, or C1 at
# U+0080-009F; an ESC starting a colour code has no width and is removed first),
# U+0300-037F (the combining marks, and the Greek characters U+0370-037F that
# share lead byte CD), any other three- or four-byte character, or invalid UTF-8. It reads
# out, not plain, because plain is empty on invalid UTF-8.
render() {
  local s fg rest bg text plain esc=$'\033' narrow
  printf -v narrow '\xc2[\xa0-\xbf]|[\xc3-\xcb\xce-\xdf][\x80-\xbf]'
  out=""; prevbg=""
  for s in "${segs[@]}"; do
    fg=${s%%|*}; rest=${s#*|}; bg=${rest%%|*}; text=${rest#*|}
    [ -n "$prevbg" ] && out+=$'\033['"38;2;${prevbg};48;2;${bg}m${SEP}"
    out+=$'\033['"38;2;${fg};48;2;${bg}m ${text} "
    prevbg=$bg
  done
  plain=$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g' 2>/dev/null)
  w=$(printf '%s' "$plain" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c)
  w=$((w))
  unknown=$(printf '%s' "$out" \
    | LC_ALL=C sed -E "s/${esc}\[[0-9;]*m|$SEP|$BR|$ARR|$DASH|$narrow//g" \
    | LC_ALL=C tr -d ' -~' | LC_ALL=C wc -c)
  unknown=$((unknown))
}

# The renderer never truncates, so the tagteam segment is kept only when the closing
# separator and at least one column of filler still fit (w <= cols - 2) and every
# character's width is known (unknown = 0). Then each character takes the one column w
# counts for it, or none if it is zero-width, so the line ends at $cols at the latest.
# Otherwise the line is what it was without tagteam.
if [ -n "$tt" ]; then
  build_segs 1; render
  { [ "$w" -le $((cols - 2)) ] && [ "$unknown" -eq 0 ]; } || { build_segs 0; render; }
else
  build_segs 0; render
fi

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

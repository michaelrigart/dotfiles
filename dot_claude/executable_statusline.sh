#!/usr/bin/env bash
# Claude Code status line — Tokyo Night, full width.
# Segments: dir  git branch (both left out inside a Herdr pane, whose workspace shows
# them)  model  tagteam  most-recent skill/plugin  plan progress, then a bar to the right
# edge. Receives the session JSON on stdin; terminal width from $COLUMNS.
export LC_ALL=en_US.UTF-8   # count runes, not bytes, in ${#text} width math
# Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
# 2026-10-16, sandbox write boundary). PINNED_PATH is for the suite only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH

input=$(cat)
model=$(printf '%s' "$input"      | jq -r '.model.display_name // "Claude"')
cwd=$(printf '%s' "$input"        | jq -r '.workspace.current_dir // .cwd // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
effort=$(printf '%s' "$input"     | jq -r '.effort.level // empty')
ctx=$(printf '%s' "$input"        | jq -r '.context_window.total_input_tokens | select(type == "number") | floor')

cols="${COLUMNS:-120}"
[ "$cols" -gt 0 ] 2>/dev/null || cols=120

# --- git branch (only if cwd is a work tree; Herdr's workspace shows it inside a pane) ---
branch=""
if [ -z "${HERDR_PANE_ID:-}" ] && [ -n "$cwd" ] \
   && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
ORANGE="255;158;100"  # #ff9e64  plan progress text

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

# --- plan progress: the newest subagent-driven plan run in this repository ---
# The ledger is the most recently modified <top>/.superpowers/sdd/*/progress.md. It counts
# when it was modified within 6 hours and its first line names a plan file that resolves
# inside <top>. total counts the plan's "### Task <N>" headings, done the distinct N on the
# ledger's "Task <N>: complete" lines; the segment shows while 0 < total and done < total.
# The ETA (ledger age / done x tasks left) needs a finished task and a ledger created within
# 12 hours: minutes under an hour, half hours above. Any failure leaves plan empty.
plan=""
plan_progress() {
  local top best f now mt bt first path pdir total finished age eta m halves
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return
  [ -n "$top" ] || return
  best=""
  for f in "$top"/.superpowers/sdd/*/progress.md; do
    [ -f "$f" ] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
  done
  [ -n "$best" ] || return
  now=$(date +%s)
  mt=$(stat -f %m "$best" 2>/dev/null) || return
  [ $((now - mt)) -le 21600 ] || return
  first=""
  { IFS= read -r first < "$best"; } 2>/dev/null || [ -n "$first" ] || return
  first=${first%$'\r'}
  case $first in "# SDD ledger $DASH plan: "?*) ;; *) return ;; esac
  path=${first#"# SDD ledger $DASH plan: "}
  case $path in /*) ;; *) path=$top/$path ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || return
  pdir=$(CDPATH= cd -P -- "${path%/*}" 2>/dev/null && pwd -P) || return
  case $pdir/ in "$top"/*) ;; *) return ;; esac
  total=$(grep -cE '^### Task [0-9]+([^0-9]|$)' "$path" 2>/dev/null) || return
  finished=$(grep -oE 'Task [0-9]+: complete' "$best" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [ "$total" -gt 0 ] && [ "$finished" -lt "$total" ] || return
  plan="plan $finished/$total"
  bt=$(stat -f %B "$best" 2>/dev/null) || return
  age=$((now - bt))
  [ "$finished" -ge 1 ] && [ "$age" -ge 0 ] && [ "$age" -le 43200 ] || return
  eta=$((age * (total - finished) / finished))
  m=$(((eta + 30) / 60))
  if [ "$m" -lt 60 ]; then
    [ "$m" -ge 1 ] || m=1
    plan="$plan $DOT ~${m}m"
  else
    halves=$(((eta + 900) / 1800))
    if [ $((halves % 2)) -eq 1 ]; then plan="$plan $DOT ~$((halves / 2)).5h"
    else plan="$plan $DOT ~$((halves / 2))h"; fi
  fi
}
[ -n "$cwd" ] && plan_progress

# model, with the live reasoning effort beside it in muted yellow (omitted when
# the model doesn't expose an effort level, i.e. .effort.level is absent)
model_seg="$model"
[ -n "$effort" ] && model_seg="$model $(printf '\033[38;2;%sm' "$YELLOW")$DOT $effort"

# the context size in thousands: muted below 200k, yellow from 200k, red from 400k (omitted
# when .context_window.total_input_tokens is absent, null or 0)
if [ "${ctx:-0}" -gt 0 ]; then
  ctx_fg=$COMMENT
  [ "$ctx" -ge 200000 ] && ctx_fg=$YELLOW
  [ "$ctx" -ge 400000 ] && ctx_fg=$RED
  model_seg="$model_seg $(printf '\033[38;2;%sm' "$ctx_fg")$DOT $((ctx / 1000))k"
fi

# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)
# build_segs <tagteam 0|1> <plan 0|1>: 1 adds that segment. The tagteam segment goes after
# the model and gives the skill segment the NIGHT shade; the plan segment goes last, in the
# shade the skill segment does not use, so neighbouring backgrounds keep alternating. Inside
# a Herdr pane the directory and branch segments are left out.
build_segs() {
  local skill_bg=$BGHL plan_bg
  segs=()
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    segs+=("$BLUE|$NIGHT|$dir")
    [ -n "$branch" ] && segs+=("$GREEN|$BGHL|$BR $branch")
  fi
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
  if [ "$2" = 1 ]; then
    plan_bg=$BGHL; [ "$skill_bg" = "$BGHL" ] && plan_bg=$NIGHT
    segs+=("$ORANGE|$plan_bg|$plan")
  fi
}

# render: segs -> out, prevbg, w (the cluster's visible width) and unknown.
# w: strip ANSI, then count UTF-8 codepoints as the bytes that are NOT continuation bytes
# (0x80-0xBF). Locale-independent, so it is correct no matter what LC_* the harness hands us.
# On invalid UTF-8 that sed fails and prints nothing; unknown then leaves the segment out and
# the line is what it always was, so its error message is discarded.
# unknown: the count of bytes that belong to no character of known width. Known, each
# exactly one cell wide: printable ASCII; the glyphs SEP BR ARR DASH; and these two-byte
# characters, which include no zero-width, format, unassigned or wide one:
#   U+00A0-00AC, U+00AE-02FF  Latin-1 without the soft hyphen, Latin Extended-A and B, IPA,
#                             spacing modifiers   (C2 A0-AC AE-BF, C3-CB 80-BF)
#   U+0380-03FF, assigned     Greek and Coptic    (CE 84-8A 8C 8E-A1 A3-BF, CF 80-BF)
#   U+0400-0482, U+048A-052F  Cyrillic without its combining marks
#                             (D0-D1 80-BF, D2 80-82 8A-BF, D3 80-BF, D4 80-AF)
# Ambiguous-width characters among them (Greek, Cyrillic, the glyphs) are taken as narrow,
# as everywhere in this statusline. Under LC_ALL=C one left-to-right pass over out removes
# the colour codes and every known non-ASCII character; unknown counts the bytes left that
# are not printable ASCII: those of a control character (C0, DEL, or C1 at U+0080-009F; an
# ESC starting a colour code has no width and is removed first), any other two-, three- or
# four-byte character, or invalid UTF-8. It reads out, not plain, because plain is empty on
# invalid UTF-8.
render() {
  local s fg rest bg text plain esc=$'\033' narrow
  printf -v narrow '\xc2[\xa0-\xac\xae-\xbf]|[\xc3-\xcb\xcf-\xd1\xd3][\x80-\xbf]|\xce[\x84-\x8a\x8c\x8e-\xa1\xa3-\xbf]|\xd2[\x80-\x82\x8a-\xbf]|\xd4[\x80-\xaf]'
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

# The renderer never truncates, so an optional segment (plan, tagteam) is kept only when the
# closing separator and at least one column of filler still fit (w <= cols - 2) and every
# character's width is known (unknown = 0). Then each character takes exactly the one column
# w counts for it, so the line ends exactly at $cols. The plan segment is dropped first;
# when tagteam does not fit either, the plan segment alone is tried; without both the line
# is what it always was.
fits() { [ "$w" -le $((cols - 2)) ] && [ "$unknown" -eq 0 ]; }
use_tt=0; [ -n "$tt" ] && use_tt=1
kept=0
if [ -n "$plan" ]; then build_segs "$use_tt" 1; render; fits && kept=1; fi
if [ "$kept" = 0 ] && [ "$use_tt" = 1 ]; then build_segs 1 0; render; fits && kept=1; fi
if [ "$kept" = 0 ] && [ -n "$plan" ] && [ "$use_tt" = 1 ]; then
  build_segs 0 1; render; fits && kept=1
fi
[ "$kept" = 0 ] && { build_segs 0 0; render; }

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

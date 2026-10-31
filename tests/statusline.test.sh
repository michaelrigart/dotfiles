#!/usr/bin/env bash
# Feeds a session JSON through dot_claude/executable_statusline.sh with a stub tagteam on
# PATH and checks the tagteam segment:
#   - shown in teal, and in red once a percentage reaches 90;
#   - left out when tagteam is absent, fails or prints nothing, when it would not fit, and
#     when a character of unknown width makes the line's width unknown.
# Left out means byte-identical to a run without tagteam.
# Runs under /bin/bash (3.2), the oldest bash the statusline must run under.
#
#   ./tests/statusline.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SL="$SRC/dot_claude/executable_statusline.sh"
[ -f "$SL" ] || { echo "missing script under test: $SL" >&2; exit 2; }
# The first jq on PATH that works under the suite's own conditions (an empty environment).
# A mise shim re-enters mise there and fails, so it is passed over.
JQ=""
while IFS= read -r c; do
  if env -i "$c" -n 1 >/dev/null 2>&1; then JQ="$c"; break; fi
done < <(type -ap jq)
[ -n "$JQ" ] || { echo "no jq that runs under env -i" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/statusline.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/none" "$T/tt" "$T/a-rather-long-project-directory-name"
ln -s "$JQ" "$T/none/jq"
ln -s "$JQ" "$T/tt/jq"
cat > "$T/tt/tagteam" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$STUB_ARGS"
[ -n "${TT_ERR:-}" ] && printf '%s\n' "$TT_ERR" >&2
[ -n "${TT_OUT:-}" ] && printf '%b' "$TT_OUT"
exit "${TT_RC:-0}"
EOF
chmod 755 "$T/tt/tagteam"

DOT=$(printf '\xc2\xb7')
TEAL='38;2;115;218;202'
RED='38;2;247;118;142'
INPUT=$(printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"}}' \
  "$T/a-rather-long-project-directory-name")

# run <bin: none|tt> <cols> [TT_OUT] [TT_RC] [TT_ERR] -> the statusline's stdout.
# Its stderr goes to $T/stderr, so a leak can be asserted on. HERDR_PANE, when set, is passed
# as HERDR_PANE_ID: the statusline then runs as inside a Herdr pane.
run() {
  printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/$1:/usr/bin:/bin" PINNED_PATH="$T/$1:/usr/bin:/bin" COLUMNS="$2" \
    ${HERDR_PANE:+HERDR_PANE_ID=$HERDR_PANE} \
    STUB_ARGS="$T/args" TT_OUT="${3:-}" TT_RC="${4:-0}" TT_ERR="${5:-}" bash "$SL" 2>"$T/stderr"
}
strip() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
vis()   { strip "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '; }
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TT="work $DOT 5h 31% $DOT 7d 12%"

# --- shown, teal, full width, called as `tagteam --no-color statusline` ---
out=$(run tt 200 "$TT\n")
if has "$out" "$TEAL" && has "$(strip "$out")" "$TT" && [ "$(vis "$out")" = 200 ]; then
  _pass "the segment shows the account and usage in teal, full width"
else _fail "teal segment at 200 columns" "$(strip "$out")"; fi
if [ "$(cat "$T/args")" = "--no-color statusline" ]; then
  _pass "tagteam is called as: tagteam --no-color statusline"
else _fail "tagteam arguments" "$(cat "$T/args")"; fi

# --- red from 90% (integer part decides) ---
for pct in 90 92 90.4; do
  out=$(run tt 200 "work $DOT 5h 25% $DOT 7d $pct%\n")
  if has "$out" "$RED" && ! has "$out" "$TEAL" && [ "$(vis "$out")" = 200 ]; then _pass "$pct% turns the segment red"
  else _fail "$pct% should be red" "$(strip "$out")"; fi
done
for pct in 89 89.6; do
  out=$(run tt 200 "work $DOT 5h 25% $DOT 7d $pct%\n")
  if has "$out" "$TEAL" && ! has "$out" "$RED" && [ "$(vis "$out")" = 200 ]; then _pass "$pct% stays teal"
  else _fail "$pct% should be teal" "$(strip "$out")"; fi
done

# --- no percentage at all: teal, no error ---
out=$(run tt 200 "work $DOT no usage yet\n")
if has "$out" "$TEAL" && has "$(strip "$out")" "work $DOT no usage yet"; then
  _pass "a line without percentages shows in teal"
else _fail "line without percentages" "$(strip "$out")"; fi

# --- ANSI in tagteam's output is stripped: the raw bytes equal the plain-output run ---
plain_run=$(run tt 200 "$TT\n")
out=$(run tt 200 "\033[1mwork\033[0m $DOT 5h 31% $DOT 7d 12%\n")
if has "$(strip "$plain_run")" "$TT" && [ "$out" = "$plain_run" ]; then
  _pass "ANSI escapes in tagteam's output are stripped (byte-identical to plain output)"
else _fail "ANSI in tagteam output must not reach the statusline" "$(printf '%s' "$out" | od -c | head -3)"; fi

# --- CR, other CSI and OSC 8 hyperlinks are stripped too ---
out=$(run tt 200 "\r\033[2K\033]8;;http://example.test/a\033\\\\work\033]8;;\033\\\\ $DOT 5h 31% $DOT 7d 12%\n")
if [ "$out" = "$plain_run" ]; then
  _pass "CR, a non-SGR CSI and an ESC-terminated OSC 8 hyperlink are stripped (byte-identical)"
else _fail "CR/CSI/OSC must not reach the statusline" "$(printf '%s' "$out" | od -c | head -3)"; fi
out=$(run tt 200 "\033]8;;http://example.test/a\007work\033]8;;\007 $DOT 5h 31% $DOT 7d 12%\n")
if [ "$out" = "$plain_run" ]; then
  _pass "a BEL-terminated OSC 8 hyperlink is stripped (byte-identical)"
else _fail "BEL-terminated OSC must not reach the statusline" "$(printf '%s' "$out" | od -c | head -3)"; fi

# --- every CSI final byte, other ESC sequences and an unterminated OSC are stripped ---
# (\x1b, not \033: printf %b would read "\0337" as one octal escape)
check_plain() {
  local out
  out=$(run tt 200 "$2\n")
  if [ "$out" = "$plain_run" ]; then _pass "$1 are stripped (byte-identical)"
  else _fail "$1 must not reach the statusline" "$(printf '%s' "$out" | od -c | head -3)"; fi
}
check_plain "CSI 5~ and CSI 2@" "\x1b[5~work\x1b[2@ $DOT 5h 31% $DOT 7d 12%"
check_plain "ESC ( B and ESC 7" "\x1b(Bwork\x1b7 $DOT 5h 31% $DOT 7d 12%"
check_plain "an unterminated OSC 8 after the usage text" "work $DOT 5h 31% $DOT 7d 12%\x1b]8;;http://example.test/a"

# --- only the first line is used ---
out=$(run tt 200 "$TT\nsecond line\n")
if has "$(strip "$out")" "$TT" && ! has "$(strip "$out")" "second line"; then
  _pass "only the first line of tagteam's output is used"
else _fail "multi-line output" "$(strip "$out")"; fi

# --- left out: byte-identical to a run without tagteam ---
ref=$(run none 200)
if ! has "$ref" "$TEAL" && ! has "$ref" "$RED"; then _pass "without tagteam there is no segment"
else _fail "segment without tagteam" "$(strip "$ref")"; fi
out=$(run tt 200 "$TT\n" 1 "tagteam: store error: unable to open database file")
if [ "$out" = "$ref" ]; then _pass "exit 1 (sandboxed store error) leaves the line unchanged"
else _fail "exit 1 should leave the line unchanged" "$(strip "$out")"; fi
if [ ! -s "$T/stderr" ]; then _pass "tagteam's stderr never reaches the statusline's stderr"
else _fail "tagteam stderr leaked" "$(cat "$T/stderr")"; fi
out=$(run tt 200 "")
if [ "$out" = "$ref" ]; then _pass "empty output leaves the line unchanged"
else _fail "empty output should leave the line unchanged" "$(strip "$out")"; fi

# --- skill segment background alternates: NIGHT after the tagteam segment, BGHL without ---
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"brainstorming"}}]}}' > "$T/transcript.jsonl"
INPUT_PLAIN=$INPUT
INPUT=$(printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"},"transcript_path":"%s"}' \
  "$T/a-rather-long-project-directory-name" "$T/transcript.jsonl")
MAG='38;2;187;154;247'; NIGHT_BG='48;2;26;27;38'; BGHL_BG='48;2;41;46;66'
out=$(run tt 200 "$TT\n")
if has "$(strip "$out")" "brainstorming" && has "$out" "$TEAL;$BGHL_BG" \
   && has "$out" "38;2;41;46;66;$NIGHT_BG" && has "$out" "$MAG;$NIGHT_BG" \
   && ! has "$out" "$MAG;$BGHL_BG" && [ "$(vis "$out")" = 200 ]; then
  _pass "with tagteam the skill segment takes the NIGHT background"
else _fail "skill segment background with tagteam" "$(strip "$out")"; fi
out=$(run none 200)
if has "$(strip "$out")" "brainstorming" && has "$out" "38;2;26;27;38;$BGHL_BG" \
   && has "$out" "$MAG;$BGHL_BG" && ! has "$out" "$MAG;$NIGHT_BG" && [ "$(vis "$out")" = 200 ]; then
  _pass "without tagteam the skill segment keeps the BGHL background"
else _fail "skill segment background without tagteam" "$(strip "$out")"; fi
INPUT=$INPUT_PLAIN

# --- characters of unknown width: the line's width cannot be established, so the segment
# is left out. Known: printable ASCII, U+00A0-00AC, U+00AE-02FF, the assigned U+0380-03FF,
# U+0400-0482, U+048A-052F, and the statusline's own glyphs. ---
INPUT_PLAIN=$INPUT
# in_dir <basename>: the workspace directory is $T/<basename> (a JSON string body).
in_dir() {
  INPUT=$(printf '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"workspace":{"current_dir":"%s"}}' "$T/$1")
}
# left_out <label> <TT_OUT>: byte-identical to the same input without tagteam, and the
# statusline writes nothing to stderr.
left_out() {
  local out err
  out=$(run tt 200 "$2\n"); err=$(cat "$T/stderr")
  if [ "$out" = "$(run none 200)" ] && ! has "$out" "$TEAL" && [ -z "$err" ]; then
    _pass "$1 leaves the segment out (byte-identical, no stderr)"
  else _fail "$1 should leave the segment out" "$(strip "$out" 2>&1) | stderr: $err"; fi
}
# shown <label> <TT_OUT> <expected text>...: teal, each text present, exactly 200 wide.
shown() {
  local out e ok=1
  out=$(run tt 200 "$2\n")
  for e in "${@:3}"; do has "$(strip "$out")" "$e" || ok=0; done
  if [ "$ok" = 1 ] && has "$out" "$TEAL" && [ "$(vis "$out")" = 200 ]; then
    _pass "$1 shows the segment, exactly 200 wide"
  else _fail "$1 should show the segment" "$(strip "$out")"; fi
}
# mkrepo <basename> <branch>: a work tree built by hand (no `git init`), HEAD on <branch>.
mkrepo() {
  mkdir -p "$T/$1/.git/objects" "$T/$1/.git/refs/heads"
  printf 'ref: refs/heads/%s\n' "$2" > "$T/$1/.git/HEAD"
}
mkrepo repo-main main
mkrepo repo-invalid "$(printf 'br\x80nch')"
BR=$(printf '\xee\x82\xa0'); ARR=$(printf '\xe2\x96\xb8'); DASH=$(printf '\xe2\x80\x94')
SEP=$(printf '\xee\x82\xb0')
in_dir "$(printf '\xe9\xa1\xb9\xe7\x9b\xae')"; left_out "a CJK directory" "$TT"
in_dir "$(printf 'done\xe2\x9c\x85')";        left_out "an E2-led emoji (U+2705) in the directory" "$TT"
in_dir "$(printf 'cafe\xcc\x81')";            left_out "a combining mark (U+0301) in the directory" "$TT"
in_dir 'tab\tdir';                            left_out "a tab in the directory" "$TT"
in_dir "$(printf 'nel\xc2\x85dir')";          left_out "a C1 control (U+0085) in the directory" "$TT"
in_dir "$(printf 'a\xd2\x83')";               left_out "a Cyrillic combining mark (U+0483) in the directory" "$TT"
in_dir "$(printf 'a\xd6\xb0')";               left_out "a Hebrew point (U+05B0) in the directory" "$TT"
in_dir "$(printf '\xd5\xa1')";                left_out "an Armenian letter (U+0561) in the directory" "$TT"
in_dir "$(printf 'a\xce\x8b')";               left_out "an unassigned Greek code point (U+038B) in the directory" "$TT"
in_dir repo-invalid;                          left_out "invalid UTF-8 (a stray continuation byte) in the branch" "$TT"
INPUT=$INPUT_PLAIN
left_out "a 4-byte emoji in the account alias" "work\xf0\x9f\x9a\x80 $DOT 5h 31% $DOT 7d 12%"
left_out "a fullwidth A (U+FF21) in the account alias" "work\xef\xbc\xa1 $DOT 5h 31% $DOT 7d 12%"
left_out "invalid UTF-8 (a stray continuation byte) in tagteam's output" "work\x80 $DOT 5h 31% $DOT 7d 12%"
left_out "a soft hyphen (U+00AD) in the account alias" "wo\xc2\xadrk $DOT 5h 31% $DOT 7d 12%"
in_dir "$(printf 'caf\xc3\xa9')";             shown "a precomposed accented directory" "$TT" "$TT"
in_dir "$(printf '\xd0\xb4\xd0\xb0\xd0\xbd\xd0\xbd\xd1\x8b\xd0\xb5')"; shown "a Cyrillic directory" "$TT" "$TT"
in_dir "$(printf '\xce\x84\xce\xb1')";        shown "a Greek directory (U+0384, U+03B1)" "$TT" "$TT"
in_dir "$(printf 'z\xc5\xbc')";               shown "a Latin Extended-A directory (U+017C)" "$TT" "$TT"
in_dir "$(printf 'a\xd2\x82')";               shown "U+0482, the last Cyrillic before the combining marks," "$TT" "$TT"
in_dir "$(printf 'a\xd2\x8a')";               shown "U+048A, the first Cyrillic after the combining marks," "$TT" "$TT"
# The statusline's own glyphs never trip the guard: an ASCII run with a branch carries all
# of them (SEP, BR, DOT, ARR, DASH), and they may appear in tagteam's text as well.
in_dir repo-main
shown "an ASCII run with a branch" "$TT" "$TT" "$BR main" "$ARR $DASH" "$SEP"
INPUT=$INPUT_PLAIN
GLYPHS="$SEP $BR $ARR $DASH $DOT"
shown "account text with the statusline's own glyphs" "work $GLYPHS 5h 31%" "work $GLYPHS 5h 31%"

# --- the fit boundary ---
# Cluster width without tagteam, from a wide run: total = cols = w + 1 (separator) + pad.
wide=$(strip "$(run none 500)")
trail=${wide##*[! ]}
base_w=$((500 - 1 - ${#trail}))
tt_w=$(printf '%s' "$TT" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')
with_w=$((base_w + tt_w + 3))   # separator + space + text + space
fit=$((with_w + 2))
out=$(run tt "$fit" "$TT\n")
if has "$(strip "$out")" "$TT" && [ "$(vis "$out")" = "$fit" ]; then
  _pass "at COLUMNS - 2 the segment is shown and the line is exactly $fit wide"
else _fail "segment should fit at $fit columns" "$(strip "$out")"; fi
tight=$((with_w + 1))
out=$(run tt "$tight" "$TT\n")
if [ "$out" = "$(run none "$tight")" ]; then
  _pass "at COLUMNS - 1 the segment is left out and the line is byte-identical"
else _fail "segment should be left out at $tight columns" "$(strip "$out")"; fi

# --- plan progress: the newest SDD ledger in the session's repository ---
INPUT_PLAIN=$INPUT
ORANGE='38;2;255;158;100'
mkrepo repo-plan main
PR="$T/repo-plan"; WS="$PR/.superpowers/sdd/p"; WS2="$PR/.superpowers/sdd/q"
mkdir -p "$WS" "$PR/docs" "$PR/sub" "$T/outside"
printf '# Plan\n\n### Task 1: a\n\n### Task 2: b\n\n### Task 3: c\n\n### Task 4: d\n' > "$PR/docs/plan.md"
cp "$PR/docs/plan.md" "$T/outside/plan.md"
LHEAD="# SDD ledger $DASH plan: docs/plan.md"
# ago <minutes>: a touch -t stamp that many minutes in the past.
ago() { date -v-"$1"M +%Y%m%d%H%M.%S; }
# ledger <dir> <created minutes ago> <first line> [done task numbers...]: a ledger created
# that long ago and modified now. touch -t to an earlier time moves the birth time back as
# well; the appends after it move only the modification time.
ledger() {
  local dir=$1 age=$2 first=$3 n; shift 3
  mkdir -p "$dir"; rm -f "$dir/progress.md"
  printf '%s\n' "$first" > "$dir/progress.md"
  touch -t "$(ago "$age")" "$dir/progress.md"
  for n in "$@"; do printf 'Task %s: complete (abc1234)\n' "$n" >> "$dir/progress.md"; done
  printf 'note\n' >> "$dir/progress.md"
}
# plan_is <label> <expected segment text>: shown in orange, exactly 200 wide.
plan_is() {
  local out; out=$(run none 200)
  if has "$(strip "$out")" " $2 " && has "$out" "$ORANGE" && [ "$(vis "$out")" = 200 ] \
     && [ ! -s "$T/stderr" ]; then
    _pass "$1 shows '$2', exactly 200 wide, no stderr"
  else _fail "$1 should show '$2'" "$(strip "$out") | stderr: $(cat "$T/stderr")"; fi
}
# no_plan <label>: no plan segment at all.
no_plan() {
  local out; out=$(run none 200)
  if ! has "$(strip "$out")" " plan " && ! has "$out" "$ORANGE" && [ "$(vis "$out")" = 200 ] \
     && [ ! -s "$T/stderr" ]; then
    _pass "$1 shows no plan segment, no stderr"
  else _fail "$1 should show no plan segment" "$(strip "$out") | stderr: $(cat "$T/stderr")"; fi
}
in_dir repo-plan
ledger "$WS" 10 "$LHEAD" 1;            plan_is "1 of 4 done after 10 minutes" "plan 1/4 $DOT ~30m"
ledger "$WS" 120 "$LHEAD" 1 2 3;       plan_is "3 of 4 done after 2 hours" "plan 3/4 $DOT ~40m"
ledger "$WS" 90 "$LHEAD" 1 2 2;        plan_is "a task completed twice counts once" "plan 2/4 $DOT ~1.5h"
ledger "$WS" 120 "$LHEAD" 1;           plan_is "1 of 4 done after 2 hours" "plan 1/4 $DOT ~6h"
ledger "$WS" 780 "$LHEAD" 1 2;         plan_is "a ledger created 13 hours ago" "plan 2/4"
has "$(strip "$(run none 200)")" "plan 2/4 $DOT" && _fail "no ETA past 12 hours" "ETA shown" \
  || _pass "no ETA past 12 hours"
ledger "$WS" 10 "$LHEAD";              plan_is "no finished task yet" "plan 0/4"
has "$(strip "$(run none 200)")" "plan 0/4 $DOT" && _fail "no ETA before the first finished task" "ETA shown" \
  || _pass "no ETA before the first finished task"
ledger "$WS" 10 "$LHEAD" 1 2 3 4;      no_plan "a finished plan"
ledger "$WS" 500 "$LHEAD" 1; touch -t "$(ago 420)" "$WS/progress.md"
no_plan "a ledger last modified 7 hours ago"
ledger "$WS" 10 "# notes" 1;           no_plan "a ledger whose first line names no plan"
ledger "$WS" 10 "# SDD ledger $DASH plan: docs/missing.md" 1; no_plan "a ledger whose plan file is missing"
ledger "$WS" 10 "# SDD ledger $DASH plan: ../outside/plan.md" 1; no_plan "a plan path outside the top level"
ledger "$WS" 10 "# SDD ledger $DASH plan: $T/outside/plan.md" 1; no_plan "an absolute plan path outside the top level"
ln -s "$T/outside/plan.md" "$PR/docs/link.md"
ledger "$WS" 10 "# SDD ledger $DASH plan: docs/link.md" 1; no_plan "a plan file that is a symlink to one outside the top level"
ledger "$WS" 10 "# SDD ledger $DASH plan: $PR/docs/plan.md" 1;  plan_is "an absolute plan path" "plan 1/4 $DOT ~30m"
ledger "$WS2" 60 "$LHEAD" 1 2 3; touch -t "$(ago 30)" "$WS2/progress.md"
ledger "$WS" 10 "$LHEAD" 1;            plan_is "the most recently modified ledger" "plan 1/4 $DOT ~30m"
rm -rf "$WS2"
# Unreadable files leave the segment out silently: the ledger, and the plan it names.
ledger "$WS" 10 "$LHEAD" 1; chmod 000 "$WS/progress.md"
no_plan "an unreadable ledger"
chmod 644 "$WS/progress.md"
chmod 000 "$PR/docs/plan.md"
no_plan "an unreadable plan file"
chmod 644 "$PR/docs/plan.md"
in_dir repo-plan/sub;                 plan_is "from a subdirectory" "plan 1/4 $DOT ~30m"
in_dir repo-plan

# Inside a Herdr pane the directory and branch segments go; the plan stays.
out=$(HERDR_PANE=w1:p2 run none 200)
if ! has "$(strip "$out")" "repo-plan" && ! has "$(strip "$out")" "$BR main" \
   && has "$(strip "$out")" "plan 1/4" && [ "$(vis "$out")" = 200 ]; then
  _pass "inside a Herdr pane there is no directory or branch segment"
else _fail "inside a Herdr pane" "$(strip "$out")"; fi
out=$(run none 200)
if has "$(strip "$out")" "repo-plan" && has "$(strip "$out")" "$BR main"; then
  _pass "outside a Herdr pane the directory and branch segments stay"
else _fail "outside a Herdr pane" "$(strip "$out")"; fi

# The fit boundary: the plan segment is the first one dropped.
wide=$(strip "$(run none 500)")
trail=${wide##*[! ]}
with_w=$((500 - 1 - ${#trail}))
out=$(run none "$((with_w + 2))")
if has "$(strip "$out")" "plan 1/4" && [ "$(vis "$out")" = "$((with_w + 2))" ]; then
  _pass "at COLUMNS - 2 the plan segment is shown"
else _fail "plan segment should fit at $((with_w + 2)) columns" "$(strip "$out")"; fi
narrow=$(run none "$((with_w + 1))")
mv "$WS/progress.md" "$T/progress.md.off"
if [ "$narrow" = "$(run none "$((with_w + 1))")" ]; then
  _pass "at COLUMNS - 1 the plan segment is left out and the line is byte-identical"
else _fail "plan segment should be left out at $((with_w + 1)) columns" "$(strip "$narrow")"; fi
# With tagteam too, plan goes before tagteam: where only one fits, tagteam stays.
tt_alone=$(strip "$(run tt 500 "$TT\n")"); trail=${tt_alone##*[! ]}
tt_w=$((500 - 1 - ${#trail}))
mv "$T/progress.md.off" "$WS/progress.md"
out=$(run tt "$((tt_w + 2))" "$TT\n")
mv "$WS/progress.md" "$T/progress.md.off"
if [ "$out" = "$(run tt "$((tt_w + 2))" "$TT\n")" ] && has "$(strip "$out")" "$TT"; then
  _pass "where only one fits, the plan segment goes and tagteam stays"
else _fail "plan should drop before tagteam" "$(strip "$out")"; fi
mv "$T/progress.md.off" "$WS/progress.md"
# Where tagteam cannot be shown (a character of unknown width), the plan segment that fits
# alone is still shown, and the line is what a run without tagteam gives.
out=$(run tt 200 "work\xe9\xa1\xb9 $DOT 5h 31% $DOT 7d 12%\n")
if has "$(strip "$out")" "plan 1/4" && has "$out" "$ORANGE" && ! has "$out" "$TEAL" \
   && ! has "$(strip "$out")" "5h 31%" && [ "$(vis "$out")" = 200 ] \
   && [ "$out" = "$(run none 200)" ] && [ ! -s "$T/stderr" ]; then
  _pass "tagteam of unknown width and an active plan: the plan segment alone is shown"
else _fail "plan should be shown alone when tagteam cannot be" "$(strip "$out") | stderr: $(cat "$T/stderr")"; fi
INPUT=$INPUT_PLAIN

# --- the context size sits in the model segment, after the effort: muted below 200,000,
# yellow from 200,000, red from 400,000, left out when absent, null, 0 or not a number ---
MUTED='38;2;169;177;214'
YELLOW='38;2;224;175;104'
INPUT_CTX=$INPUT_PLAIN
ctx_run() {
  INPUT=$(printf '%s' "$INPUT_CTX" | "$JQ" -c --argjson c "$1" '.context_window = {total_input_tokens: $c}')
  run none 200
}
# ctx_is <label> <tokens json> <expected figure> <expected colour>: the figure follows the
# effort in the stripped line, its escape immediately precedes the dot, the line stays 200 wide.
ctx_is() {
  out=$(ctx_run "$2")
  if has "$(strip "$out")" "Opus 5.5 $DOT high $DOT $3 " && has "$out" "$4m$DOT $3" \
     && [ "$(vis "$out")" = 200 ]; then _pass "$1"
  else _fail "$1" "$(strip "$out")"; fi
}
ctx_is "199,999 tokens: 199k, muted (rounding up to 200k would colour it wrong)" 199999 199k "$MUTED"
ctx_is "200,000 tokens: 200k, yellow" 200000 200k "$YELLOW"
ctx_is "399,999 tokens: 399k, still yellow" 399999 399k "$YELLOW"
ctx_is "400,000 tokens: 400k, red" 400000 400k "$RED"
ref=$(run none 200)
for v in null 0 '"abc"'; do
  out=$(ctx_run "$v")
  if [ "$out" = "$ref" ]; then _pass "context $v: no figure, the line is unchanged"
  else _fail "context $v should leave the line unchanged" "$(strip "$out")"; fi
done
INPUT=$(printf '%s' "$INPUT_CTX" | "$JQ" -c '.context_window = {}')
out=$(run none 200)
if [ "$out" = "$ref" ]; then _pass "context_window without the field: no figure"
else _fail "absent field should leave the line unchanged" "$(strip "$out")"; fi
INPUT=$(printf '%s' "$INPUT_CTX" | "$JQ" -c 'del(.effort) | .context_window = {total_input_tokens: 230000}')
out=$(run none 200)
if has "$(strip "$out")" "Opus 5.5 $DOT 230k " && [ "$(vis "$out")" = 200 ]; then
  _pass "without an effort the figure follows the model name directly"
else _fail "figure without effort" "$(strip "$out")"; fi
# The figure is part of the width: tagteam fits at exactly the cluster width with the figure
# plus its own, and is left out one column short of that.
INPUT=$(printf '%s' "$INPUT_CTX" | "$JQ" -c '.context_window = {total_input_tokens: 230000}')
wide=$(strip "$(run none 500)")
trail=${wide##*[! ]}
tt_cells=$(printf '%s' "$TT" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' ')
with_w=$((500 - 1 - ${#trail} + tt_cells + 3))
out=$(run tt "$((with_w + 2))" "$TT\n")
if has "$(strip "$out")" "230k" && has "$(strip "$out")" "$TT" && [ "$(vis "$out")" = "$((with_w + 2))" ]; then
  _pass "with the figure, tagteam still fits at the width the figure leaves it"
else _fail "tagteam should fit with the figure" "$(strip "$out")"; fi
out=$(run tt "$((with_w + 1))" "$TT\n")
if [ "$out" = "$(run none "$((with_w + 1))")" ] && has "$(strip "$out")" "230k"; then
  _pass "one column short, tagteam is left out: the figure is counted in the width"
else _fail "tagteam should not fit one column short" "$(strip "$out")"; fi
INPUT=$INPUT_PLAIN

# The statusline runs outside the sandbox: a tool on the caller's PATH must not reach it.
mkdir -p "$T/evil"
for t in git jq tagteam; do
  printf '#!/bin/sh\ntouch "%s/evil-%s"\n' "$T" "$t" > "$T/evil/$t"; chmod 755 "$T/evil/$t"
done
in_dir repo-main
printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/evil:/usr/bin:/bin" COLUMNS=120 bash "$SL" >/dev/null 2>&1
if ls "$T"/evil-* >/dev/null 2>&1; then _fail "the statusline's PATH is pinned" "$(ls "$T"/evil-*)"
else _pass "the statusline's PATH is pinned"; fi
INPUT=$INPUT_PLAIN

echo "statusline: $pass passed, $fail failed"
exit "$fail"

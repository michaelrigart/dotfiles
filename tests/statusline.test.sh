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
# Its stderr goes to $T/stderr, so a leak can be asserted on.
run() {
  printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/$1:/usr/bin:/bin" COLUMNS="$2" \
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

echo "statusline: $pass passed, $fail failed"
exit "$fail"

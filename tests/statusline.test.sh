#!/usr/bin/env bash
# Feeds a session JSON through dot_claude/executable_statusline.sh with a stub tagteam on
# PATH and checks the tagteam segment:
#   - shown in teal, and in red once a percentage reaches 90;
#   - left out when tagteam is absent, fails or prints nothing, and when it would not fit.
# Left out means byte-identical to a run without tagteam.
# Runs under /bin/bash, the bash that runs the statusline in practice.
#
#   ./tests/statusline.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SL="$SRC/dot_claude/executable_statusline.sh"
[ -f "$SL" ] || { echo "missing script under test: $SL" >&2; exit 2; }
# A mise shim would re-enter mise under the controlled env and fail, so skip those.
JQ=""
for c in $(type -ap jq); do
  case "$c" in */mise/shims/*) ;; *) JQ="$c"; break ;; esac
done
[ -n "$JQ" ] || { echo "a real jq (not a mise shim) is required" >&2; exit 2; }
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
  if has "$out" "$RED" && ! has "$out" "$TEAL"; then _pass "$pct% turns the segment red"
  else _fail "$pct% should be red" "$(strip "$out")"; fi
done
for pct in 89 89.6; do
  out=$(run tt 200 "work $DOT 5h 25% $DOT 7d $pct%\n")
  if has "$out" "$TEAL" && ! has "$out" "$RED"; then _pass "$pct% stays teal"
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

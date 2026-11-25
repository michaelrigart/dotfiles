#!/usr/bin/env bash
# Tests for the nav mod's terminal link handler (mods/nav/link.js, nvim.js) and the declarations
# that hand it the clicks. Run: ./tests/herdr-app-link.test.sh
#
# The handler runs headless under jsc with "herdr" stubbed (fixtures/herdr-app/link-stubs.js), as
# the rows test does. Every Neovim expression it would send is then sent, as the handler sends it
# (`nvim --server <address> --remote-expr <expression>`), to a real headless Neovim, for files whose
# names try to run something; the suite then looks for anything they made. That Neovim listens on
# local TCP, because the sandbox denies binding a Unix socket.
set -uo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
NAV=$SRC/dot_config/herdr-app/mods/nav
LAYOUT=$SRC/dot_config/herdr-app/layouts/michael.json
FIX=$SRC/tests/fixtures/herdr-app
J=/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc
for f in "$NAV/link.js" "$NAV/nvim.js" "$NAV/mod.json" "$LAYOUT" "$FIX/link.test.js" "$FIX/link-stubs.js"; do
  [ -f "$f" ] || { echo "missing ${f#"$SRC"/}" >&2; exit 2; }
done
[ -x "$J" ] || { echo "INCONCLUSIVE: no jsc" >&2; exit 2; }
for c in nvim jq timeout; do
  command -v "$c" >/dev/null || { echo "INCONCLUSIVE: no $c" >&2; exit 2; }
done
root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-app-link.XXXXXX") || exit 1
root=$(cd "$root" && pwd -P) || exit 1 # Neovim names buffers by the physical path
server=
trap '[ -n "$server" ] && kill "$server" 2>/dev/null; rm -rf "$root"' EXIT

passed=0 total=0
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  total=$((total + 1))
  if "$@"; then passed=$((passed + 1)); echo "  PASS: $what"; else echo "  FAIL: $what"; fi
}
same() { # <description> <got> <want>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "  PASS: $1"; else echo "  FAIL: $1 (got: $2, want: $3)"; fi
}

# --- the declarations ---------------------------------------------------------------------------
check "nav declares a rule for file links" jq -e '.link_handlers | any(.kind == "file")' "$NAV/mod.json" >/dev/null
check "the layout hands terminal links to nav alone" jq -e '.link_handlers == ["nav"]' "$LAYOUT" >/dev/null

# --- files to click, named to run something if any layer parses them ---------------------------
files=$root/files
mkdir -p "$files/dir" "$root/cwd" "$root/js" || exit 1
names=(
  plain.txt "a'b.txt" "x'.writefile([],'pwned-5').'y.txt" 'x|call writefile([],"pwned-1")'
  '`touch pwned-2`' '$(touch pwned-3)' "q'|!touch pwned-4" "]] .. os.execute('touch pwned-6') .. [[.lua"
  '%#.txt' '*.txt' '[ab].txt' '{a,b}.txt' '$HOME.txt' '~x' 'sp ace\back.txt' 'a b.lua' 'dq"bs\.txt' 'ü.txt'
)
for n in "${names[@]}"; do printf 'l1\nl2\nl3 hello world\nl4 four\nl5 five\n' > "$files/$n" || exit 1; done
printf 'l1\nl2\n' > "$files/late.txt" && mkfifo "$files/fifo" && ln -s plain.txt "$files/link.txt" || exit 1

# --- the handler, under jsc -----------------------------------------------------------------------
d=$root/js
for f in link nvim; do sed 's|from "herdr"|from "./link-stubs.js"|' "$NAV/$f.js" > "$d/$f.js"; done
cp "$FIX/link.test.js" "$FIX/link-stubs.js" "$d/"
{
  printf 'export const FILES = %s;\n' "$(jq -n --arg f "$files" '$f')"
  printf 'export const NAMES = %s;\n' "$(printf '%s\0' "${names[@]}" | jq -Rs 'split("\u0000")[:-1]')"
} > "$d/env.js"
check "link.js and nvim.js import only what the stubs stand in for" test -z "$(grep -h '^import .* from "[^.]' "$d/link.js" "$d/nvim.js")"
out=$("$J" -m "$d/link.test.js" 2>&1); jrc=$?
printf '%s\n' "$out" | grep -v '^REPLAY '
p=$(printf '%s\n' "$out" | grep -c '^  PASS:'); f=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
passed=$((passed + p)); total=$((total + p + f))
check "the handler test ran cleanly (jsc exit $jrc, $((p + f)) assertions)" test "$jrc" -eq 0 -a $((p + f)) -gt 0

# --- each expression, sent to a real Neovim ------------------------------------------------------
nv=(env NVIM_LOG_FILE="$root/nvim.log" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data"
  XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" nvim)
(cd "$root/cwd" && exec "${nv[@]}" --clean -n --headless --listen 127.0.0.1:0 \
  -c "call writefile([v:servername], '$root/addr')" </dev/null >/dev/null 2>&1) &
server=$!
for _ in $(seq 100); do [ -s "$root/addr" ] && break; sleep 0.1; done
addr=$(cat "$root/addr" 2>/dev/null)
[ -n "$addr" ] || { echo "INCONCLUSIVE: the headless Neovim did not start" >&2; exit 2; }
ask() { timeout 10 "${nv[@]}" --server "$addr" --remote-expr "$1" 2>&1; }

replays=0
while IFS= read -r line; do
  json=${line#REPLAY }
  what=$(jq -r .what <<<"$json")
  setup=$(jq -r '.setup // empty' <<<"$json")
  [ -z "$setup" ] || ask "$setup" >/dev/null
  same "$what: Neovim answers" "$(ask "$(jq -r .expr <<<"$json")")" "$(jq -r .want <<<"$json")"
  same "$what: then" "$(ask "$(jq -r .check <<<"$json")")" "$(jq -r .expect <<<"$json")"
  replays=$((replays + 1))
done < <(printf '%s\n' "$out" | grep '^REPLAY ')
check "expressions were replayed ($replays)" test "$replays" -gt 0
check "no clicked name ran anything" test -z "$(find "$root" -name 'pwned-*' -print)"
same "the Neovim is still answering" "$(ask '1+1')" 2

echo "$passed/$total passed"
[ "$passed" -eq "$total" ]

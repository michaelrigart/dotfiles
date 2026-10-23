#!/usr/bin/env bash
# Pins the ha-mcp launcher (dot_local/bin/executable_ha-mcp) and the env-file template
# (dot_config/private_ha-mcp/private_env.tmpl) both Claude apps run for the Home Assistant
# MCP server. `mise` is a stub on PATH, so nothing real starts and no secret is touched; the
# token is the sentinel SECRET-TOKEN-123. The template is rendered with an isolated chezmoi
# (own config and state, 1Password call replaced by a literal), never the live ones.
#
# Run: ./tests/ha-mcp.test.sh   (sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$SRC/dot_local/bin/executable_ha-mcp"
TPL="$SRC/dot_config/private_ha-mcp/private_env.tmpl"
[ -f "$LAUNCHER" ] || { echo "missing launcher: $LAUNCHER" >&2; exit 2; }
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 2; }
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ha-mcp.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/ha-mcp" "$T/proj" "$T/bin"
LOG="$T/log"
SENTINEL="SECRET-TOKEN-123"

cat > "$T/bin/mise" <<STUB
#!/bin/sh
case "\$1" in
  which) [ "\${MOCK_WHICH_RC:-0}" = 0 ] && echo /stub/python; exit "\${MOCK_WHICH_RC:-0}" ;;
  exec) printf '%s|%s|%s|%s\n' "\$PWD" "\$*" "\$HOMEASSISTANT_URL" "\${#HOMEASSISTANT_TOKEN}" >> "$LOG"; exit 0 ;;
esac
exit 99
STUB
chmod +x "$T/bin/mise"

pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$3"; fi
}

ENVF="$T/home/.config/ha-mcp/env"
OUT=""; RC=0
run() { # run launcher as the apps do: foreign cwd, bare PATH, stub mise first
  : > "$LOG"
  OUT=$(cd "$T/proj" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$LAUNCHER" 2>&1)
  RC=$?
}

echo "A. missing env file"
rm -f "$ENVF"
run
check "exits 1" "1" "$RC"
check "stderr names the file and the fix" "ha-mcp: $T/home/.config/ha-mcp/env is missing or unreadable — run chezmoi apply" "$OUT"
check "mise never ran" "" "$(cat "$LOG")"

echo "B. launches uvx on mise's Python"
printf "HOMEASSISTANT_URL='http://h:8123'\nHOMEASSISTANT_TOKEN='%s'\n" "$SENTINEL" > "$ENVF"
run
check "exits 0" "0" "$RC"
check "execs uvx on mise's Python, env exported" "$T/home|exec -- uvx --python /stub/python ha-mcp@latest|http://h:8123|16" "$(cat "$LOG")"
check "runs from HOME, not the caller's directory" "$T/home" "$(cut -d'|' -f1 "$LOG")"
case "$OUT" in *"$SENTINEL"*) _fail "token never printed" "launcher output contains the token" ;; *) _pass "token never printed" ;; esac

echo "C. mise which python fails"
MOCK_WHICH_RC=1 run
[ "$RC" -ne 0 ] && _pass "exits non-zero" || _fail "exits non-zero" "$RC"
check "mise exec never ran" "" "$(cat "$LOG")"

echo "D. POSIX sh"
check "shebang is #!/bin/sh" "#!/bin/sh" "$(head -n1 "$LAUNCHER")"
if sh -n "$LAUNCHER" 2>/dev/null; then _pass "sh -n passes"; else _fail "sh -n passes" "syntax error"; fi

echo "E. template"
EXPECTED='HOMEASSISTANT_URL={{ onepasswordRead "op://Private/Home Assistant MCP/hostname" | squote }}
HOMEASSISTANT_TOKEN={{ onepasswordRead "op://Private/Home Assistant MCP/credential" | squote }}'
check "references exactly the two 1Password fields" "$EXPECTED" "$(cat "$TPL")"

echo "F. rendered values source back literally"
# Replace each 1Password call with a Go string literal, render, and source the result in sh.
URL_LIT='http://h:8123/a b'
TOK_LIT='p$q w`x"y\z'
golit() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
sedesc() { printf '%s' "$1" | sed 's/[\\&#]/\\&/g'; }
URL_GO=$(sedesc "$(golit "$URL_LIT")")
TOK_GO=$(sedesc "$(golit "$TOK_LIT")")
sed -e "s#onepasswordRead \"op://Private/Home Assistant MCP/hostname\"#$URL_GO#" \
    -e "s#onepasswordRead \"op://Private/Home Assistant MCP/credential\"#$TOK_GO#" \
    "$TPL" > "$T/literal.tmpl"
CFG="$T/chezmoi.toml"; STATE="$T/chezmoistate.boltdb"
printf '[template]\n  options = ["missingkey=error"]\n' > "$CFG"
if chezmoi --config "$CFG" --config-format toml --persistent-state "$STATE" \
    --source "$SRC" --destination "$T/home" execute-template --file "$T/literal.tmpl" \
    > "$T/rendered.env" 2> "$T/render.err"; then
  got_url=$(sh -c 'set -a; . "$1"; printf "%s" "$HOMEASSISTANT_URL"' sh "$T/rendered.env")
  got_tok=$(sh -c 'set -a; . "$1"; printf "%s" "$HOMEASSISTANT_TOKEN"' sh "$T/rendered.env")
  check "URL with a space survives" "$URL_LIT" "$got_url"
  if [ "$got_tok" = "$TOK_LIT" ]; then _pass "token with \$ space backtick double quote backslash survives"
  else _fail "token with \$ space backtick double quote backslash survives" "length ${#got_tok}, expected ${#TOK_LIT}"; fi
else
  _fail "template renders" "$(head -c 200 "$T/render.err")"
fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

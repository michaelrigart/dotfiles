#!/usr/bin/env bash
# Pins the ha-mcp launcher (dot_local/bin/executable_ha-mcp) and the env-file template
# (dot_config/private_ha-mcp/private_env.tmpl) both Claude apps run for the Home Assistant
# MCP server. `mise` is a stub on PATH, so nothing real starts and no secret is touched; the
# token is the sentinel SECRET-TOKEN-123.
#
# Run: ./tests/ha-mcp.test.sh   (sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$SRC/dot_local/bin/executable_ha-mcp"
TPL="$SRC/dot_config/private_ha-mcp/private_env.tmpl"
[ -f "$LAUNCHER" ] || { echo "missing launcher: $LAUNCHER" >&2; exit 2; }
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ha-mcp.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/ha-mcp" "$T/proj" "$T/bin"
LOG="$T/log"
SENTINEL="SECRET-TOKEN-123"

cat > "$T/bin/mise" <<STUB
#!/bin/sh
case "\$1" in
  which) [ "\${MOCK_WHICH_RC:-0}" = 0 ] && echo /stub/python; exit "\${MOCK_WHICH_RC:-0}" ;;
  exec) printf '%s|%s|%s|%s|%s|%s\n' "\$PWD" "\$*" "\${HAMCP_ENV_FILE-unset}" "\${HOMEASSISTANT_URL-unset}" "\${HOMEASSISTANT_TOKEN-unset}" "\${HA_MCP_DISABLE_SETTINGS_UI-unset}" >> "$LOG"; exit 0 ;;
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
OUT=""; ERR=""; RC=0
run() { # run launcher as the apps do: foreign cwd, bare PATH, stub mise first
  : > "$LOG"
  OUT=$(cd "$T/proj" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$LAUNCHER" 2> "$T/stderr")
  RC=$?
  ERR=$(cat "$T/stderr")
}

echo "A. missing env file"
rm -f "$ENVF"
run
check "exits 1" "1" "$RC"
check "stdout is empty" "" "$OUT"
check "stderr names the file and the fix" "ha-mcp: $T/home/.config/ha-mcp/env is missing or unreadable — run chezmoi apply" "$ERR"
check "mise never ran" "" "$(cat "$LOG")"

echo "B. launches uvx on mise's Python"
printf "HOMEASSISTANT_URL='http://h:8123'\nHOMEASSISTANT_TOKEN='%s'\n" "$SENTINEL" > "$ENVF"
run
check "exits 0" "0" "$RC"
check "execs uvx on mise's Python, passing the env file path only" "$T/home|exec uv -- uvx --python /stub/python ha-mcp@latest|$T/home/.config/ha-mcp/env|unset|unset|1" "$(cat "$LOG")"
check "runs from HOME, not the caller's directory" "$T/home" "$(cut -d'|' -f1 "$LOG")"
case "$OUT$ERR" in *"$SENTINEL"*) _fail "token never printed" "launcher output contains the token" ;; *) _pass "token never printed" ;; esac

echo "C. mise which python fails"
MOCK_WHICH_RC=1 run
check "exits 1" "1" "$RC"
check "stdout is empty" "" "$OUT"
check "stderr says mise has no Python" "ha-mcp: mise has no Python for $T/home — run mise install" "$ERR"
check "mise exec never ran" "" "$(cat "$LOG")"
case "$OUT$ERR" in *"$SENTINEL"*) _fail "token never printed" "launcher output contains the token" ;; *) _pass "token never printed" ;; esac

echo "D. POSIX sh"
check "shebang is #!/bin/sh" "#!/bin/sh" "$(head -n1 "$LAUNCHER")"
if sh -n "$LAUNCHER" 2>/dev/null; then _pass "sh -n passes"; else _fail "sh -n passes" "syntax error"; fi

echo "E. template"
EXPECTED='HOMEASSISTANT_URL={{ onepasswordRead "op://Private/Home Assistant MCP/hostname" | squote }}
HOMEASSISTANT_TOKEN={{ onepasswordRead "op://Private/Home Assistant MCP/credential" | squote }}'
check "references exactly the two 1Password fields" "$EXPECTED" "$(cat "$TPL")"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

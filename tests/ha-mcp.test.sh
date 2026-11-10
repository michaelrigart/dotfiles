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
TPL_REMOTE="$SRC/dot_config/private_ha-mcp/private_env-remote.tmpl"
[ -f "$LAUNCHER" ] || { echo "missing launcher: $LAUNCHER" >&2; exit 2; }
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 2; }
[ -f "$TPL_REMOTE" ] || { echo "missing template: $TPL_REMOTE" >&2; exit 2; }

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

cat > "$T/bin/curl" <<STUB
#!/bin/sh
printf '%s|%s|%s\n' "\$*" "\${HOMEASSISTANT_URL-unset}" "\${HOMEASSISTANT_TOKEN-unset}" >> "$T/curl.log"
exit "\${MOCK_CURL_RC:-0}"
STUB
chmod +x "$T/bin/curl"

cat > "$T/bin/sed" <<STUB
#!/bin/sh
u=unset; t=unset
[ "\${HOMEASSISTANT_URL+x}" ] && u=set
[ "\${HOMEASSISTANT_TOKEN+x}" ] && t=set
printf '%s|%s\n' "\$u" "\$t" >> "$T/sed.log"
exec /usr/bin/sed "\$@"
STUB
chmod +x "$T/bin/sed"

pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$3"; fi
}

ENVF="$T/home/.config/ha-mcp/env"
ENVR="$T/home/.config/ha-mcp/env-remote"
OUT=""; ERR=""; RC=0
run() { # run launcher as the apps do: foreign cwd, bare PATH, stub mise first
  : > "$LOG"; : > "$T/curl.log"; : > "$T/sed.log"
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
check "stderr empty" "" "$ERR"
check "execs uvx on mise's Python, passing the env file path only" "$T/home|exec uv -- uvx --python /stub/python ha-mcp@latest|$T/home/.config/ha-mcp/env|unset|unset|1" "$(cat "$LOG")"
check "runs from HOME, not the caller's directory" "$T/home" "$(cut -d'|' -f1 "$LOG")"
check "curl never ran" "" "$(cat "$T/curl.log")"
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
EXPECTED_REMOTE='HOMEASSISTANT_URL={{ onepasswordRead "op://Private/Home Assistant MCP/remote_url" | squote }}
HOMEASSISTANT_TOKEN={{ onepasswordRead "op://Private/Home Assistant MCP/credential" | squote }}'
check "remote template references the remote_url and credential fields" "$EXPECTED_REMOTE" "$(cat "$TPL_REMOTE")"

write_env() { # write_env <home url> <remote url>: env and env-remote with the sentinel token
  printf "HOMEASSISTANT_URL='%s'\nHOMEASSISTANT_TOKEN='%s'\n" "$1" "$SENTINEL" > "$ENVF"
  printf "HOMEASSISTANT_URL='%s'\nHOMEASSISTANT_TOKEN='%s'\n" "$2" "$SENTINEL" > "$ENVR"
}
no_secret() { # no_secret <label>: the sentinel and the remote address stay out of output and curl's log
  case "$OUT$ERR" in *"$SENTINEL"*) _fail "$1: token never printed" "launcher output contains the token" ;; *) _pass "$1: token never printed" ;; esac
  case "$(cat "$T/curl.log")" in *"$SENTINEL"*|*r.example*) _fail "$1: curl never sees the token or remote address" "$(cat "$T/curl.log")" ;; *) _pass "$1: curl never sees the token or remote address" ;; esac
}
third() { cut -d'|' -f3 "$LOG"; }
PROBE="-q -k -s --noproxy * -o /dev/null --connect-timeout 1 --max-time 2"

echo "F. env-remote unreadable"
write_env 'http://h:8123' 'https://r.example'
chmod 000 "$ENVR"
run
chmod 600 "$ENVR"
check "uses env" "$ENVF" "$(third)"
check "curl never ran" "" "$(cat "$T/curl.log")"
no_secret "F"

echo "G. home answers"
write_env 'http://h:8123' 'https://r.example'
MOCK_CURL_RC=0 run
check "exits 0" "0" "$RC"
check "uses env" "$ENVF" "$(third)"
check "stderr is empty" "" "$ERR"
check "probes the home address, without the variables" "$PROBE http://h:8123/|unset|unset" "$(cat "$T/curl.log")"
no_secret "G"

echo "H. home does not answer"
for rc in 6 28; do
  write_env 'http://h:8123' 'https://r.example'
  MOCK_CURL_RC=$rc run
  check "curl exit $rc: exits 0" "0" "$RC"
  check "curl exit $rc: execs uvx on env-remote" "$T/home|exec uv -- uvx --python /stub/python ha-mcp@latest|$ENVR|unset|unset|1" "$(cat "$LOG")"
  check "curl exit $rc: stderr says env-remote" "ha-mcp: home address unreachable; using env-remote" "$ERR"
  no_secret "H $rc"
done

echo "I. trailing slash on the home address"
write_env 'http://h:8123/' 'https://r.example'
MOCK_CURL_RC=0 run
check "probes with one slash" "$PROBE http://h:8123/|unset|unset" "$(cat "$T/curl.log")"
no_secret "I"

echo "J. env has no URL line"
write_env 'http://h:8123' 'https://r.example'
printf "HOMEASSISTANT_TOKEN='%s'\n" "$SENTINEL" > "$ENVF"
MOCK_CURL_RC=6 run
check "uses env" "$ENVF" "$(third)"
check "curl never ran" "" "$(cat "$T/curl.log")"
no_secret "J"

echo "K. inherited variables"
for rc in 0 6; do
  write_env 'http://h:8123' 'https://r.example'
  HOMEASSISTANT_URL=http://stale HOMEASSISTANT_TOKEN=$SENTINEL MOCK_CURL_RC=$rc run
  [ -s "$T/sed.log" ] && _pass "curl exit $rc: sed ran" || _fail "curl exit $rc: sed ran" "sed log is empty"
  check "curl exit $rc: sed saw neither variable" "" "$(grep -v '^unset|unset$' "$T/sed.log")"
  case "$(cat "$T/curl.log")" in *"|unset|unset") _pass "curl exit $rc: curl saw neither variable" ;; *) _fail "curl exit $rc: curl saw neither variable" "$(cat "$T/curl.log")" ;; esac
  check "curl exit $rc: mise saw neither variable" "unset|unset" "$(cut -d'|' -f4-5 "$LOG")"
  no_secret "K $rc"
done

echo "L. env has two URL lines"
write_env 'http://h:8123' 'https://r.example'
printf "HOMEASSISTANT_URL='http://h:8123'\nHOMEASSISTANT_URL='http://other:8123'\nHOMEASSISTANT_TOKEN='%s'\n" "$SENTINEL" > "$ENVF"
MOCK_CURL_RC=0 run
check "probes the first URL only" "$PROBE http://h:8123/|unset|unset" "$(cat "$T/curl.log")"
no_secret "L"

echo "M. env has an empty URL"
write_env 'http://h:8123' 'https://r.example'
printf "HOMEASSISTANT_URL=''\nHOMEASSISTANT_TOKEN='%s'\n" "$SENTINEL" > "$ENVF"
MOCK_CURL_RC=6 run
check "uses env" "$ENVF" "$(third)"
check "curl never ran" "" "$(cat "$T/curl.log")"
no_secret "M"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

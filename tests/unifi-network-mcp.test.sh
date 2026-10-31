#!/usr/bin/env bash
# Pins the unifi-network-mcp launcher (dot_local/bin/executable_unifi-network-mcp) and the
# env-file template (dot_config/private_unifi-network/private_env.tmpl) that
# ~/Code/home-assistant/.mcp.json runs for the UniFi Network MCP server. `mise` is a stub on
# PATH, so nothing real starts and no secret is touched; the password is the sentinel
# SECRET-PASS-123.
#
# Run: ./tests/unifi-network-mcp.test.sh   (sandboxed is fine)

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$SRC/dot_local/bin/executable_unifi-network-mcp"
TPL="$SRC/dot_config/private_unifi-network/private_env.tmpl"
[ -f "$LAUNCHER" ] || { echo "missing launcher: $LAUNCHER" >&2; exit 2; }
[ -f "$TPL" ] || { echo "missing template: $TPL" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/unifi-network-mcp.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.config/unifi-network" "$T/proj" "$T/bin"
LOG="$T/log"
SENTINEL="SECRET-PASS-123"

cat > "$T/bin/mise" <<STUB
#!/bin/sh
case "\$1" in
  which) [ "\${MOCK_WHICH_RC:-0}" = 0 ] && echo /stub/python; exit "\${MOCK_WHICH_RC:-0}" ;;
  exec)
    printf '%s|%s\n' "\$PWD" "\$*" >> "$LOG"
    for v in UNIFI_NETWORK_HOST UNIFI_NETWORK_USERNAME UNIFI_NETWORK_PASSWORD UNIFI_NETWORK_PORT UNIFI_NETWORK_SITE UNIFI_NETWORK_VERIFY_SSL UNIFI_TOOL_REGISTRATION_MODE UNIFI_TOOL_PERMISSION_MODE UNIFI_POLICY_NETWORK_CREATE UNIFI_POLICY_NETWORK_UPDATE UNIFI_POLICY_NETWORK_DELETE; do
      eval "printf '%s=%s\n' \$v \"\\\${\$v-unset}\"" >> "$LOG"
    done
    exit 0 ;;
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
nosecret() {
  case "$OUT$ERR" in *"$SENTINEL"*) _fail "password never printed" "launcher output contains the password" ;; *) _pass "password never printed" ;; esac
}

ENVF="$T/home/.config/unifi-network/env"
OUT=""; ERR=""; RC=0
run() { # run launcher as Claude Code does: foreign cwd, bare PATH, stub mise first
  : > "$LOG"
  OUT=$(cd "$T/proj" && HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$LAUNCHER" 2> "$T/stderr")
  RC=$?
  ERR=$(cat "$T/stderr")
}
logged() { grep -m1 "^$1=" "$LOG" || true; }

echo "A. missing env file"
rm -f "$ENVF"
run
check "exits 1" "1" "$RC"
check "stdout is empty" "" "$OUT"
check "stderr names the file and the fix" "unifi-network-mcp: $T/home/.config/unifi-network/env is missing or unreadable — run chezmoi apply" "$ERR"
check "mise never ran" "" "$(cat "$LOG")"

echo "B. launches the pinned package on mise's Python"
printf "UNIFI_NETWORK_HOST='10.0.0.1'\nUNIFI_NETWORK_USERNAME='mcp'\nUNIFI_NETWORK_PASSWORD='%s'\n" "$SENTINEL" > "$ENVF"
run
check "exits 0" "0" "$RC"
check "execs uvx on mise's Python with the pinned package, from HOME" "$T/home|exec uv -- uvx --python /stub/python unifi-network-mcp==0.27.3" "$(head -n1 "$LOG")"
check "host from the env file" "UNIFI_NETWORK_HOST=10.0.0.1" "$(logged UNIFI_NETWORK_HOST)"
check "username from the env file" "UNIFI_NETWORK_USERNAME=mcp" "$(logged UNIFI_NETWORK_USERNAME)"
check "password reaches the server environment" "UNIFI_NETWORK_PASSWORD=$SENTINEL" "$(logged UNIFI_NETWORK_PASSWORD)"
check "port defaults to 443" "UNIFI_NETWORK_PORT=443" "$(logged UNIFI_NETWORK_PORT)"
check "site defaults to default" "UNIFI_NETWORK_SITE=default" "$(logged UNIFI_NETWORK_SITE)"
check "SSL verification defaults to false" "UNIFI_NETWORK_VERIFY_SSL=false" "$(logged UNIFI_NETWORK_VERIFY_SSL)"
check "tools register lazily" "UNIFI_TOOL_REGISTRATION_MODE=lazy" "$(logged UNIFI_TOOL_REGISTRATION_MODE)"
check "changes need confirmation" "UNIFI_TOOL_PERMISSION_MODE=confirm" "$(logged UNIFI_TOOL_PERMISSION_MODE)"
check "create is allowed" "UNIFI_POLICY_NETWORK_CREATE=true" "$(logged UNIFI_POLICY_NETWORK_CREATE)"
check "update is allowed" "UNIFI_POLICY_NETWORK_UPDATE=true" "$(logged UNIFI_POLICY_NETWORK_UPDATE)"
check "delete is refused" "UNIFI_POLICY_NETWORK_DELETE=false" "$(logged UNIFI_POLICY_NETWORK_DELETE)"
nosecret

echo "C. the env file overrides the connection defaults"
printf "UNIFI_NETWORK_HOST='10.0.0.1'\nUNIFI_NETWORK_USERNAME='mcp'\nUNIFI_NETWORK_PASSWORD='%s'\nUNIFI_NETWORK_PORT='8443'\nUNIFI_NETWORK_SITE='home'\n" "$SENTINEL" > "$ENVF"
run
check "port from the env file" "UNIFI_NETWORK_PORT=8443" "$(logged UNIFI_NETWORK_PORT)"
check "site from the env file" "UNIFI_NETWORK_SITE=home" "$(logged UNIFI_NETWORK_SITE)"
check "SSL verification keeps its default" "UNIFI_NETWORK_VERIFY_SSL=false" "$(logged UNIFI_NETWORK_VERIFY_SSL)"

echo "D. mise which python fails"
MOCK_WHICH_RC=1 run
check "exits 1" "1" "$RC"
check "stdout is empty" "" "$OUT"
check "stderr says mise has no Python" "unifi-network-mcp: mise has no Python for $T/home — run mise install" "$ERR"
check "mise exec never ran" "" "$(cat "$LOG")"
nosecret

echo "E. POSIX sh"
check "shebang is #!/bin/sh" "#!/bin/sh" "$(head -n1 "$LAUNCHER")"
if sh -n "$LAUNCHER" 2>/dev/null; then _pass "sh -n passes"; else _fail "sh -n passes" "syntax error"; fi
if [ -x "$LAUNCHER" ]; then _pass "launcher is executable"; else _fail "launcher is executable" "mode bits"; fi

echo "F. template"
EXPECTED='UNIFI_NETWORK_HOST={{ onepasswordRead "op://Private/UniFi Controller/host" | replace "'"'"'" "'"'"'\\'"'"''"'"'" | squote }}
UNIFI_NETWORK_USERNAME={{ onepasswordRead "op://Private/UniFi Controller/username" | replace "'"'"'" "'"'"'\\'"'"''"'"'" | squote }}
UNIFI_NETWORK_PASSWORD={{ onepasswordRead "op://Private/UniFi Controller/password" | replace "'"'"'" "'"'"'\\'"'"''"'"'" | squote }}'
check "references exactly the three 1Password fields, each escaped before squote" "$EXPECTED" "$(cat "$TPL")"

echo "G. awkward values survive render and sourcing byte for byte"
# The real template, with each onepasswordRead call swapped for an env lookup, so the escaping
# and squote are exactly the production expression and no 1Password is touched.
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "  SKIP: chezmoi absent — template escaping unverified"
else
  MARK="$T/injected"
  # shellcheck disable=SC2016
  VALS=(
    "ab'cd"
    "'"
    "a'b'c''d"
    "x\$(touch $MARK)y"
    "x\`touch $MARK\`y"
    '$HOME ${HOME} $UNSET_VAR_X'
    "has space  and	tab"
    'say "hi" \ back\\slash \n'
    "k=v=w"
    "';touch $MARK;'"
  )
  n=0
  for v in "${VALS[@]}"; do
    n=$((n + 1))
    rm -f "$MARK"
    TV_HOST="h$v" TV_USER="u$v" TV_PASS="p$v" \
      command chezmoi execute-template < <(sed -E 's/onepasswordRead "op:\/\/Private\/UniFi Controller\/host"/env "TV_HOST"/; s/onepasswordRead "op:\/\/Private\/UniFi Controller\/username"/env "TV_USER"/; s/onepasswordRead "op:\/\/Private\/UniFi Controller\/password"/env "TV_PASS"/' "$TPL") > "$T/rendered" 2> "$T/render.err"
    if [ -s "$T/render.err" ] && [ ! -s "$T/rendered" ]; then
      _fail "value $n renders" "$(head -c 200 "$T/render.err")"
      continue
    fi
    got=$(env -i PATH=/usr/bin:/bin sh -c 'set -a; . "$1"; set +a; printf "%s\n%s\n%s" "$UNIFI_NETWORK_HOST" "$UNIFI_NETWORK_USERNAME" "$UNIFI_NETWORK_PASSWORD"' sh "$T/rendered" 2>&1)
    check "value $n round-trips through render and sourcing" "h$v
u$v
p$v" "$got"
    if [ -e "$MARK" ]; then _fail "value $n executes nothing" "marker file was created"; else _pass "value $n executes nothing"; fi
  done
fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

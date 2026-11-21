#!/usr/bin/env bash
# Tests .scripts/preflight-ssh-agent.sh: which socket it allowlists, and that it fails closed.
#
# Bugs caught: the preflight still choosing the 1Password socket while the native agent is up; no
# fallback to 1Password when the native agent is absent or holds no keys; a path printed when no
# agent is usable.
#
# ssh-add is a stub on PATH (exit 0 when $SSH_AUTH_SOCK is listed in $STUB_GOOD). The sandbox
# forbids bind(), so a "present" socket is a symlink to a system socket under /var/run.
#
#   ./tests/preflight-ssh-agent.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/.scripts/preflight-ssh-agent.sh"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
target=$(find /var/run -maxdepth 1 -type s 2>/dev/null | head -1)
[ -n "$target" ] || { echo "INCONCLUSIVE: no system unix socket under /var/run to symlink" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2 (want $3)"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/preflight-ssh-agent.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

STUBS="$T/stubs"
mkdir "$STUBS"
cat >"$STUBS/ssh-add" <<'STUB'
#!/bin/bash
case ":${STUB_GOOD:-}:" in *":$SSH_AUTH_SOCK:"*) exit 0 ;; esac
exit 1
STUB
chmod 755 "$STUBS/ssh-add"

n=0
# fresh_home: a new temp HOME with no sockets; sets H and the three socket paths.
fresh_home() {
  n=$((n + 1))
  H="$T/home$n"
  NATIVE="$H/.local/state/ssh-agent/agent.sock"
  OP="$H/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  mkdir -p "$H"
}
present() { mkdir -p "$(dirname "$1")" && ln -s "$target" "$1"; }
runit() { # runit <good-list>: sets OUT (stdout) and RC
  OUT=$(env -u SSH_AUTH_SOCK HOME="$H" PATH="$STUBS:/usr/bin:/bin" STUB_GOOD="$1" /bin/bash "$SCRIPT" 2>/dev/null)
  RC=$?
}

echo "== native agent is chosen first"
fresh_home; present "$NATIVE"; present "$OP"
runit "$NATIVE:$OP"
check "stdout is the native path" "$OUT" "$NATIVE"
check "rc 0" "$RC" 0

echo "== 1Password is the fallback when the native socket is absent"
fresh_home; present "$OP"
runit "$OP"
check "stdout is the 1Password path" "$OUT" "$OP"
check "rc 0" "$RC" 0

echo "== 1Password is the fallback when the native agent holds no keys"
fresh_home; present "$NATIVE"; present "$OP"
runit "$OP"
check "stdout is the 1Password path" "$OUT" "$OP"
check "rc 0" "$RC" 0

echo "== no usable agent fails closed"
fresh_home
runit ""
check "stdout is empty" "$OUT" ""
check "rc 2" "$RC" 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

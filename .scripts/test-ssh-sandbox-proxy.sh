#!/usr/bin/env bash
# Source-level checks for the Claude-scoped authenticated SOCKS5 SSH helper.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/dot_local/bin/executable_ssh-sandbox-proxy"
GIT_SHIM="$ROOT/dot_local/bin/executable_git"
pass=0; fail=0

if [ -x "$HELPER" ]; then
  echo "  PASS: helper exists and is executable"
  pass=$((pass + 1))
else
  echo "  FAIL: helper exists and is executable"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] && /bin/bash -n "$HELPER"; then
  echo "  PASS: helper parses as Bash"
  pass=$((pass + 1))
else
  echo "  FAIL: helper parses as Bash"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] &&
   grep -q 'NCAT_PROXY_AUTH' "$HELPER" &&
   ! grep -q -- '--proxy-auth' "$HELPER"; then
  echo "  PASS: proxy credentials use the environment, not process arguments"
  pass=$((pass + 1))
else
  echo "  FAIL: proxy credentials must use NCAT_PROXY_AUTH only"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] &&
   grep -qF '127.0.0.1' "$HELPER" &&
   grep -qF 'localhost' "$HELPER" &&
   grep -qF '\[::1\]' "$HELPER"; then
  echo "  PASS: proxy credentials are restricted to loopback endpoints"
  pass=$((pass + 1))
else
  echo "  FAIL: helper must reject non-loopback proxy endpoints"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] &&
   grep -qF 'http://*' "$HELPER" &&
   grep -qF 'proxy_type=http' "$HELPER"; then
  echo "  PASS: helper supports Claude's observed authenticated HTTP proxy"
  pass=$((pass + 1))
else
  echo "  FAIL: helper must support Claude's authenticated HTTP proxy"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] &&
   grep -q 'FTP_PROXY' "$HELPER" &&
   grep -qF 'socks5h://*' "$HELPER"; then
  echo "  PASS: helper prefers Claude's authenticated SOCKS transport"
  pass=$((pass + 1))
else
  echo "  FAIL: helper must prefer Claude's authenticated SOCKS transport"
  fail=$((fail + 1))
fi

if [ -f "$HELPER" ] &&
   grep -qF 'endpoint="127.0.0.1:$port"' "$HELPER"; then
  echo "  PASS: localhost proxy endpoints normalize to IPv4 loopback"
  pass=$((pass + 1))
else
  echo "  FAIL: localhost proxy endpoints must normalize to IPv4 loopback"
  fail=$((fail + 1))
fi

if [ -x "$GIT_SHIM" ] && /bin/bash -n "$GIT_SHIM"; then
  echo "  PASS: Git shim exists, is executable, and parses as Bash"
  pass=$((pass + 1))
else
  echo "  FAIL: Git shim exists, is executable, and parses as Bash"
  fail=$((fail + 1))
fi

if [ -f "$GIT_SHIM" ] &&
   grep -q 'CLAUDECODE' "$GIT_SHIM" &&
   grep -q 'GIT_SSH_COMMAND=' "$GIT_SHIM" &&
   grep -qF 'exec /usr/bin/git "$@"' "$GIT_SHIM"; then
  echo "  PASS: Git shim overrides SSH only inside Claude and execs system Git"
  pass=$((pass + 1))
else
  echo "  FAIL: Git shim must be Claude-scoped and transparent elsewhere"
  fail=$((fail + 1))
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

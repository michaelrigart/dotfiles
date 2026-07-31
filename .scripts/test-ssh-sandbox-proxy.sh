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
  echo "  PASS: git shim exists, is executable, and parses as Bash"
  pass=$((pass + 1))
else
  echo "  FAIL: git shim must exist, be executable, and parse as Bash"
  fail=$((fail + 1))
fi

# Gate on CLAUDECODE ONLY: ssh-sandbox-proxy owns proxy selection, and a second copy of
# that logic here could drift out of step with it and silently stop firing.
if [ -f "$GIT_SHIM" ] &&
   grep -q 'CLAUDECODE' "$GIT_SHIM" &&
   grep -qF 'GIT_SSH_COMMAND="$HOME/.local/bin/ssh-sandbox-proxy"' "$GIT_SHIM" &&
   ! grep -vE '^[[:space:]]*#' "$GIT_SHIM" | grep -qE 'ALL_PROXY|FTP_PROXY'; then
  echo "  PASS: shim is Claude-scoped and delegates proxy selection to the helper"
  pass=$((pass + 1))
else
  echo "  FAIL: shim must gate on CLAUDECODE alone and not duplicate proxy selection"
  fail=$((fail + 1))
fi

# ~/.local/bin leads PATH in-session, so this shim intercepts EVERY git call. Exec'ing
# Apple's git would silently downgrade them — that downgrade is why ffdbe07 removed the
# shim, so delegating to Homebrew git is what allows it to exist at all.
if [ -f "$GIT_SHIM" ] &&
   grep -qF 'exec /opt/homebrew/bin/git "$@"' "$GIT_SHIM"; then
  echo "  PASS: shim delegates to Homebrew git, not Apple's /usr/bin/git"
  pass=$((pass + 1))
else
  echo "  FAIL: shim must exec /opt/homebrew/bin/git so in-session git is not downgraded"
  fail=$((fail + 1))
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

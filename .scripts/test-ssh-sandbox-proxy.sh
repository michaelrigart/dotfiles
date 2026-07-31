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

# The git PATH shim was replaced by GIT_SSH_COMMAND, exported from a SessionStart hook via
# CLAUDE_ENV_FILE (asserted in test-claude-settings.sh). Assert the shim's ABSENCE rather
# than its shape: ~/.local/bin leads PATH in-session, so a reintroduced shim silently takes
# precedence over the env-based mechanism and this suite would still pass.
#
# A shim is not merely redundant, it is actively harmful. It is a `#!/usr/bin/env bash`
# script, so it needs `bash` on PATH; test-wt-functions.sh builds a deliberately stripped
# PATH (env, git, awk, mkdir) to simulate a missing wtcp, and there `git` dies with
# "env: bash: No such file or directory" (rc=127) before the lifecycle reaches the wtcp
# check. That cost three assertions in that suite while this one stayed green.
if [ ! -e "$GIT_SHIM" ]; then
  echo "  PASS: no git PATH shim in the chezmoi source — SSH routes via GIT_SSH_COMMAND"
  pass=$((pass + 1))
else
  echo "  FAIL: a git PATH shim reappeared at $GIT_SHIM; GIT_SSH_COMMAND is the supported mechanism"
  fail=$((fail + 1))
fi

# Deleting the source does NOT retract an already-deployed target: chezmoi only removes
# targets listed in .chezmoiremove. A stale ~/.local/bin/git keeps breaking git for the
# whole session, so the deployed path is checked independently of the source.
if [ ! -e "$HOME/.local/bin/git" ]; then
  echo "  PASS: no deployed git shim at ~/.local/bin/git — git resolves to the real binary"
  pass=$((pass + 1))
else
  echo "  FAIL: a deployed git shim remains at ~/.local/bin/git; remove it, not just the source"
  fail=$((fail + 1))
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

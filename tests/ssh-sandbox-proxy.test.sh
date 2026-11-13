#!/usr/bin/env bash
# Source-level checks for the Claude-scoped authenticated SOCKS5 SSH helper.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/dot_local/bin/executable_ssh-sandbox-proxy"
GIT_SHIM="$ROOT/dot_local/bin/executable_git"
CFG_SRC_GUARD="$ROOT/dot_config/agent-identity/ssh_config"
[ -f "$HELPER" ] || { echo "missing subject: $HELPER" >&2; exit 2; }
[ -f "$CFG_SRC_GUARD" ] || { echo "missing subject: $CFG_SRC_GUARD" >&2; exit 2; }
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
# CLAUDE_ENV_FILE (asserted in claude-settings.test.sh). Assert the shim's ABSENCE rather
# than its shape: ~/.local/bin leads PATH in-session, so a reintroduced shim silently takes
# precedence over the env-based mechanism and this suite would still pass.
#
# A shim is not merely redundant, it is actively harmful. It is a `#!/usr/bin/env bash`
# script, so it needs `bash` on PATH; wt-functions.test.sh builds a deliberately stripped
# PATH (env, git, awk, mkdir) to simulate a missing tool, and there `git` dies with
# "env: bash: No such file or directory" (rc=127). That cost three assertions in that
# suite while this one stayed green.
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

# --- agent GitHub SSH identity (spec 2026-11-12-forge-push-protection, section 1.1) ---------
CFG_SRC="$ROOT/dot_config/agent-identity/ssh_config"
KEY_TPL="$ROOT/private_dot_ssh/private_github-agent.pub.tmpl"

T="$(mktemp -d "${TMPDIR:-/tmp}/ssh-sandbox-proxy.XXXXXX")"
trap 'rm -rf "$T"' EXIT

_ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
_bad() { echo "  FAIL: $1"; [ -n "${2:-}" ] && printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }

# The proxy under HOME=$T with no proxy variables: `ssh -G` prints the resolved
# configuration and connects to nothing.
proxy_g() { # <extra env assignment or ''> -> prints ssh -G output
  env -u FTP_PROXY -u ftp_proxy -u ALL_PROXY -u all_proxy HOME="$T/home" "$@" \
    "$HELPER" -G example.invalid 2>&1
}

# resolved <rc> <out>: ssh -G finished and printed the resolved configuration for the host,
# so a "not used" row cannot pass on a proxy that merely failed.
resolved() { [ "$1" -eq 0 ] && printf '%s\n' "$2" | grep -qx 'hostname example.invalid'; }

mkdir -p "$T/home/.config/agent-identity" "$T/home/.ssh"
printf 'User proxy-marker\n' > "$T/home/.config/agent-identity/ssh_config"

echo "proxy selects the agent SSH configuration only when both files are readable"
rm -f "$T/home/.ssh/github-agent.pub"
out=$(proxy_g); rc=$?
if printf '%s\n' "$out" | grep -qx 'user proxy-marker'; then
  _bad "no key file: the agent configuration must not be used" "$(printf '%s' "$out" | grep -i '^user ')"
elif ! resolved "$rc" "$out"; then
  _bad "no key file: ssh -G must still resolve the host (rc $rc)" "$(printf '%s' "$out" | head -c 200)"
else _ok "no key file: the agent configuration is not used and the host resolves"; fi
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFix0 fixture\n' \
  > "$T/home/.ssh/github-agent.pub"
out=$(proxy_g) || true
if printf '%s\n' "$out" | grep -qx 'user proxy-marker'; then
  _ok "key file present: the agent configuration is used"
else _bad "key file present: the agent configuration is used" "$(printf '%s' "$out" | head -c 200)"; fi

pout() { # same pair through the proxy branch
  env -u ALL_PROXY -u all_proxy -u ftp_proxy HOME="$T/home" FTP_PROXY=socks5h://u:p@127.0.0.1:1 \
    "$HELPER" -G example.invalid 2>&1
}
out=$(pout) || true
if printf '%s\n' "$out" | grep -qx 'user proxy-marker' && printf '%s\n' "$out" | grep -q '^proxycommand .*ncat'; then
  _ok "proxy branch, key file present: agent configuration and ncat ProxyCommand both applied"
else _bad "proxy branch, key file present: agent configuration and ncat ProxyCommand both applied" "$(printf '%s' "$out" | grep -iE '^(user|proxycommand) ')"; fi
rm -f "$T/home/.ssh/github-agent.pub"
out=$(pout); rc=$?
if printf '%s\n' "$out" | grep -qx 'user proxy-marker'; then
  _bad "proxy branch, no key file: the agent configuration must not be used" "$(printf '%s' "$out" | grep -i '^user ')"
elif ! resolved "$rc" "$out"; then
  _bad "proxy branch, no key file: ssh -G must still resolve the host (rc $rc)" "$(printf '%s' "$out" | head -c 200)"
else _ok "proxy branch, no key file: the agent configuration is not used and the host resolves"; fi
rm -f "$T/home/.config/agent-identity/ssh_config"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFix0 fixture\n' \
  > "$T/home/.ssh/github-agent.pub"
out=$(proxy_g); rc=$?
if printf '%s\n' "$out" | grep -qx 'user proxy-marker'; then
  _bad "no agent configuration file: the argv must be today's" "$(printf '%s' "$out" | grep -i '^user ')"
elif ! resolved "$rc" "$out"; then
  _bad "no agent configuration file: ssh -G must still resolve the host (rc $rc)" "$(printf '%s' "$out" | head -c 200)"
else _ok "no agent configuration file: the argv is today's and the host resolves"; fi

echo "the shipped agent configuration pins github.com and ssh.github.com and leaves every other host to ~/.ssh/config"
inc=$(grep -c '^ *Include ~/\.ssh/config$' "$CFG_SRC")
if [ "$inc" = 1 ] && [ "$(grep -ci '^ *Include ' "$CFG_SRC")" = 1 ]; then
  _ok "exactly one Include, of ~/.ssh/config"
else _bad "exactly one Include, of ~/.ssh/config" "matching: $inc"; fi

FIXTURE="$T/fixture-ssh-config"
cat > "$FIXTURE" <<'FIX'
Host github.com
  IdentityFile ~/.ssh/fixture-github
  User fixture-user
Host *
  IdentityFile ~/.ssh/fixture-default
  User fixture-user
FIX
COPY="$T/agent-copy"
sed "s|~/.ssh/config|$FIXTURE|" "$CFG_SRC" > "$COPY"
g() { /usr/bin/ssh -G -F "$COPY" "$1" 2>&1; }
for h in github.com GitHub.com ssh.github.com SSH.GitHub.com; do
  out=$(g "$h")
  n=$(printf '%s\n' "$out" | grep -c '^identityfile ')
  last=$(printf '%s\n' "$out" | grep '^identityfile ' | head -1)
  if [ "$n" = 1 ] && case "$last" in *github-agent.pub) true ;; *) false ;; esac; then
    _ok "$h: exactly one identityfile, github-agent.pub"
  else _bad "$h: exactly one identityfile, github-agent.pub" "$n: $(printf '%s' "$out" | grep '^identityfile ')"; fi
  if printf '%s\n' "$out" | grep -qx 'identitiesonly yes'; then _ok "$h: identitiesonly yes"
  else _bad "$h: identitiesonly yes" "$(printf '%s' "$out" | grep -i '^identitiesonly')"; fi
  if printf '%s\n' "$out" | grep '^identityagent ' | grep -q '1password/t/agent.sock'; then
    _ok "$h: identityagent is the 1Password socket"
  else _bad "$h: identityagent is the 1Password socket" "$(printf '%s' "$out" | grep '^identityagent ')"; fi
  if printf '%s\n' "$out" | grep -qx 'user fixture-user'; then
    _bad "$h: Michael's configuration must not be read" "user fixture-user"
  else _ok "$h: Michael's configuration is not read"; fi
done
for h in gitlab.com notgithub.com gist.github.com ssh.github.com.example; do
  out=$(g "$h")
  if printf '%s\n' "$out" | grep '^identityfile ' | grep -q 'fixture-default' &&
     printf '%s\n' "$out" | grep -qx 'user fixture-user' &&
     ! printf '%s\n' "$out" | grep -q 'github-agent.pub'; then
    _ok "$h: the fixture's identity and user, no github-agent.pub"
  else _bad "$h: the fixture's identity and user, no github-agent.pub" "$(printf '%s' "$out" | grep -E '^(identityfile|user) ')"; fi
done

echo "the public-key template renders only when 1Password lists the item"
[ -f "$KEY_TPL" ] || { echo "missing template: $KEY_TPL" >&2; exit 2; }
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "INCONCLUSIVE: chezmoi is not on PATH" >&2; exit 2
fi
mkdir -p "$T/stub"
OP_LOG="$T/op.log"; : > "$OP_LOG"
FIXTURE_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStubStubStub0 stub-agent'
cat > "$T/stub/op" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$OP_LOG"
if [ "$1" = "--version" ]; then echo "2.30.0"; exit 0; fi
if [ "$*" = "signin --raw" ]; then echo "stub-session-token"; exit 0; fi
if [ "$*" = "item list --vault Private --format json" ]; then
  if [ "${OP_LISTED:-}" = 1 ]; then
    echo '[{"id":"a1","title":"Unrelated"},{"id":"b2","title":"GitHub Agent SSH Key"}]'
  else
    echo '[{"id":"a1","title":"Unrelated"},{"id":"c3","title":"GitHub Agent SSH Key Old"}]'
  fi
  exit 0
fi
if [ "$*" = "--session stub-session-token read --no-newline op://Private/GitHub Agent SSH Key/public key" ]; then
  printf '%s' "$STUB_KEY"; exit 0
fi
echo "stub op: unexpected call: $*" >&2
exit 99
STUB
chmod 755 "$T/stub/op"
CZCFG="$T/chezmoi.toml"
printf '[template]\n  options = ["missingkey=error"]\n' > "$CZCFG"
render() {
  PATH="$T/stub:$PATH" OP_LOG="$OP_LOG" STUB_KEY="$FIXTURE_KEY" OP_LISTED="$1" \
    chezmoi --config "$CZCFG" --config-format toml --persistent-state "$T/state.boltdb" \
      --source "$ROOT" --destination "$T/home" execute-template --file "$KEY_TPL" 2>"$T/render.err"
}
: > "$OP_LOG"
if out=$(render 1); then
  if [ "$(printf '%s' "$out" | tr -d '\n')" = "$FIXTURE_KEY" ]; then _ok "listed: the stub's public key"
  else _bad "listed: the stub's public key" "$(printf '%s' "$out" | head -c 120)"; fi
else _bad "listed: the template rendered" "$(head -c 300 "$T/render.err")"; fi
if grep -q 'unexpected call' "$T/render.err" 2>/dev/null; then
  _bad "listed: chezmoi made only calls the stub knows" "$(cat "$OP_LOG" | head -5)"
else _ok "listed: chezmoi made only calls the stub knows"; fi
: > "$OP_LOG"
if out=$(render 0); then
  if [ -z "$out" ]; then _ok "not listed (a similar title only): empty output"
  else _bad "not listed: empty output" "$(printf '%s' "$out" | head -c 120)"; fi
else _bad "not listed: the template rendered" "$(head -c 300 "$T/render.err")"; fi
if grep -q 'read' "$OP_LOG"; then _bad "not listed: no op read at all" "$(cat "$OP_LOG")"
else _ok "not listed: no op read at all"; fi

echo "chezmoi manages both targets"
if ! managed=$(PATH="$T/stub:$PATH" OP_LOG="$OP_LOG" STUB_KEY="$FIXTURE_KEY" OP_LISTED=1 \
    chezmoi --source "$ROOT" managed 2>"$T/managed.err"); then
  printf 'INCONCLUSIVE: chezmoi managed failed: %s\n  a cold external cache does this; warm it outside the sandbox: command chezmoi --source %s managed >/dev/null\n' \
    "$(awk 'NF { print; exit }' "$T/managed.err")" "$ROOT" >&2
  exit 2
fi
for p in .config/agent-identity/ssh_config .ssh/github-agent.pub; do
  if printf '%s\n' "$managed" | grep -qx "$p"; then _ok "managed lists $p"
  else _bad "managed lists $p"; fi
done

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

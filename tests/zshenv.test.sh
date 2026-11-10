#!/usr/bin/env bash
# Starts a clean interactive LOGIN zsh (env -i, as Ghostty starts one, so /etc/zprofile's
# path_helper runs first) that sources the SOURCE zshenv the way dot_zshrc does, and checks
# where commands resolve.
#
# The bug this pins: `brew shellenv` PREPENDS /opt/homebrew/bin, so everything zshenv put on
# PATH before it ended up behind Homebrew, and Homebrew's `codex` shadowed the
# ~/.local/bin/codex launcher in every interactive shell.
#
# HOME is a temp directory holding a stub launcher, so the check never depends on what is
# deployed. Real Homebrew is used on purpose: its shellenv is the thing being ordered.
#
#   ./tests/zshenv.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ZSHENV="$SRC/dot_config/zsh/zshenv"
[ -f "$ZSHENV" ] || { echo "missing script under test: $ZSHENV" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
[ -x /opt/homebrew/bin/brew ] || { echo "Homebrew is not at /opt/homebrew; this suite needs it" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshenv.XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAKE="$T/home"
mkdir -p "$FAKE/.local/bin"
printf '#!/bin/sh\necho launcher\n' > "$FAKE/.local/bin/codex"
chmod 755 "$FAKE/.local/bin/codex"
printf 'source "%s"\n' "$ZSHENV" > "$FAKE/.zshrc"

probe() { # probe <zsh code> [VAR=value ...] -> its stdout in a clean interactive login shell
  local code=$1; shift
  env -i HOME="$FAKE" USER="${USER:-michael}" TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    ZDOTDIR="$FAKE" "$@" /bin/zsh -il -c "$code" 2>/dev/null
}

first=$(probe 'type -a codex' | head -1)
if [ "$first" = "codex is $FAKE/.local/bin/codex" ]; then
  _pass "type -a codex lists the ~/.local/bin launcher first"
else
  _fail "type -a codex lists the ~/.local/bin launcher first" "$first"
fi
if [ -x /opt/homebrew/bin/codex ]; then
  if probe 'type -a codex' | grep -qx 'codex is /opt/homebrew/bin/codex'; then
    _pass "Homebrew's codex is still reachable, behind the launcher"
  else
    _fail "Homebrew's codex is still reachable, behind the launcher" "$(probe 'type -a codex' | tr '\n' '|')"
  fi
fi

path=$(probe 'print -r -- $PATH')
index_of() { printf '%s\n' "$path" | tr ':' '\n' | grep -nxF -- "$1" | head -1 | cut -d: -f1; }
bin=$(index_of "$FAKE/.local/bin"); brew=$(index_of /opt/homebrew/bin)
if [ -n "$bin" ] && [ -n "$brew" ] && [ "$bin" -lt "$brew" ]; then
  _pass "~/.local/bin precedes /opt/homebrew/bin on PATH"
else
  _fail "~/.local/bin precedes /opt/homebrew/bin on PATH" "$path"
fi

got=$(probe 'print -r -- $HOMEBREW_PREFIX')
[ "$got" = /opt/homebrew ] && _pass "HOMEBREW_PREFIX comes from brew shellenv" || _fail "HOMEBREW_PREFIX comes from brew shellenv" "$got"
got=$(probe 'print -r -- $RUBY_CONFIGURE_OPTS')
[ "$got" = "--with-jemalloc=/opt/homebrew/opt/jemalloc" ] \
  && _pass "the jemalloc path is built from HOMEBREW_PREFIX" \
  || _fail "the jemalloc path is built from HOMEBREW_PREFIX" "$got"
# `brew --prefix <formula>` can reach the network (it refreshes the API index), which is a
# slow shell start at best. Nothing in zshenv may call it.
if grep -v '^[[:space:]]*#' "$ZSHENV" | grep -q 'brew --prefix'; then
  _fail "zshenv calls no brew --prefix" "$(grep -n 'brew --prefix' "$ZSHENV")"
else
  _pass "zshenv calls no brew --prefix"
fi

# Regression: op asks for the account password instead of Touch ID. Since macOS 27.2 the
# terminal may not read the 1Password app's group-container settings, so op cannot see that
# the app integration is on unless the environment says so. Read from a child process: op
# and chezmoi see only what is exported.
got=$(probe '/usr/bin/printenv OP_BIOMETRIC_UNLOCK_ENABLED')
[ "$got" = true ] && _pass "child processes get OP_BIOMETRIC_UNLOCK_ENABLED=true" \
  || _fail "child processes get OP_BIOMETRIC_UNLOCK_ENABLED=true" "${got:-unset}"

# Regression: git's SSH commit signing failed with "No private key found" after a herdr
# restart. herdr points every pane's SSH_AUTH_SOCK at a proxy that holds no keys until a
# client registers its agent, so a local shell must use the 1Password agent directly; an SSH
# login keeps its forwarded agent, and a machine without 1Password keeps its own. The socket
# is bound by relative name because macOS caps socket paths at 104 bytes.
HERDR_SOCK="$FAKE/.config/herdr/herdr.sock.agent"
OP_DIR="$FAKE/Library/Group Containers/2BUA8C4S2C.com.1password/t"
got=$(probe '/usr/bin/printenv SSH_AUTH_SOCK' SSH_AUTH_SOCK="$HERDR_SOCK")
[ "$got" = "$HERDR_SOCK" ] && _pass "without a 1Password socket, a preset SSH_AUTH_SOCK is kept" \
  || _fail "without a 1Password socket, a preset SSH_AUTH_SOCK is kept" "${got:-unset}"

# The sandbox forbids bind() on unix sockets, so the fake agent is a symlink to a system
# socket; -S follows it, as it does for the real check.
target=$(find /var/run -maxdepth 1 -type s 2>/dev/null | head -1)
[ -n "$target" ] || { echo "INCONCLUSIVE: no system unix socket under /var/run to symlink" >&2; exit 2; }
mkdir -p "$OP_DIR"
ln -s "$target" "$OP_DIR/agent.sock"
got=$(probe '/usr/bin/printenv SSH_AUTH_SOCK' SSH_AUTH_SOCK="$HERDR_SOCK")
[ "$got" = "$OP_DIR/agent.sock" ] && _pass "a local shell replaces a herdr SSH_AUTH_SOCK with the 1Password agent" \
  || _fail "a local shell replaces a herdr SSH_AUTH_SOCK with the 1Password agent" "${got:-unset}"
got=$(probe '/usr/bin/printenv SSH_AUTH_SOCK' SSH_AUTH_SOCK="$HERDR_SOCK" SSH_CONNECTION="10.0.0.1 50000 10.0.0.2 22")
[ "$got" = "$HERDR_SOCK" ] && _pass "an SSH login keeps its forwarded SSH_AUTH_SOCK" \
  || _fail "an SSH login keeps its forwarded SSH_AUTH_SOCK" "${got:-unset}"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

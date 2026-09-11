#!/usr/bin/env bash
# Tests the codex-code-mode-host shim.
#
# The shim exists because the Homebrew cask links `bin/codex` and not the
# `codex-code-mode-host` that ships beside it, so Codex runs with code mode enabled and no
# host to run it in. That failure is silent in the worst way: the session reads, reasons
# and answers normally, and only admits its tool runtime is dead when something asks it to
# execute. A cross-review reviewed a diff by eye for two rounds before saying so.
#
# What matters here is that it resolves the host through whatever `codex` currently points
# at, rather than a Caskroom path pinned at install time — a pinned path dangles on the
# next `brew upgrade` and reintroduces the identical silent failure.
#
# Run: ./tests/codex-code-mode-host.test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="$ROOT/dot_local/bin/executable_codex-code-mode-host"

pass=0; fail=0
_pass() { echo "  ok  $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (got '$2', want '$3')"; fi; }

if [ ! -r "$SHIM" ]; then
  echo "FATAL: $SHIM not found — every assertion below would pass vacuously." >&2
  echo "RESULT: 0 passed, 1 total, 1 failed"
  exit 2
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-host-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# A fake cask: a versioned directory holding both binaries, and a bin/ that links only
# codex — exactly the shape the real cask installs.
mkdir -p "$T/cask/1.0.0/bin" "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/cask/1.0.0/bin/codex"
printf '#!/bin/sh\necho HOST-1.0.0 "$@"\n' > "$T/cask/1.0.0/bin/codex-code-mode-host"
chmod +x "$T/cask/1.0.0/bin/codex" "$T/cask/1.0.0/bin/codex-code-mode-host"
ln -s "$T/cask/1.0.0/bin/codex" "$T/bin/codex"

[ -x "$T/bin/codex" ] || { echo "FIXTURE BROKEN: codex link not created" >&2; exit 2; }
[ -e "$T/bin/codex-code-mode-host" ] && { echo "FIXTURE BROKEN: the cask must NOT link the host" >&2; exit 2; }

run() { PATH="$T/bin:/usr/bin:/bin" sh "$SHIM" "$@" 2>&1; }

echo "A. it finds the host the cask did not link"
is "the host is reached through the codex symlink" "$(run)" "HOST-1.0.0"
is "arguments are passed through" "$(run --port 5 --x)" "HOST-1.0.0 --port 5 --x"

echo
echo "B. a cask upgrade does not break it"
# The whole reason this is a wrapper and not a symlink. Moving to a new version directory
# is what `brew upgrade` does, and a path resolved at install time dangles here.
mkdir -p "$T/cask/2.0.0/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/cask/2.0.0/bin/codex"
printf '#!/bin/sh\necho HOST-2.0.0 "$@"\n' > "$T/cask/2.0.0/bin/codex-code-mode-host"
chmod +x "$T/cask/2.0.0/bin/codex" "$T/cask/2.0.0/bin/codex-code-mode-host"
rm -rf "$T/cask/1.0.0"
ln -sf "$T/cask/2.0.0/bin/codex" "$T/bin/codex"
is "it follows codex to the new version" "$(run)" "HOST-2.0.0"

echo
echo "C. it fails loudly, never silently"
# Silence is the actual bug being fixed. Both failure modes must say so and exit non-zero,
# because a shim that exits 0 with no output reproduces the thing it was written to stop.
rm -f "$T/cask/2.0.0/bin/codex-code-mode-host"
out="$(run)"; rc=$?
is "a missing host is an error"        "$rc" "127"
is "and it names where it looked"      "$(printf '%s' "$out" | grep -c 'not found beside')" "1"

out="$(PATH="/usr/bin:/bin" sh "$SHIM" 2>&1)"; rc=$?
is "no codex on PATH is an error"      "$rc" "127"
is "and it says why"                   "$(printf '%s' "$out" | grep -c 'no codex on PATH')" "1"

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]

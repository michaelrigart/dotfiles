#!/usr/bin/env bash
# Tests for dot_config/mise/config.toml: the global rust toolchain carries rust-analyzer.
#
# The rust-analyzer-lsp Claude Code plugin runs `rust-analyzer` from PATH. With the rustup
# component missing, ~/.cargo/bin/rust-analyzer (the rustup proxy) falls back to the mise shim
# of the same name, which calls the proxy again: "error: infinite recursion detected", exit 1,
# so the language server never starts and Claude Code never sees a diagnostic.
#
# A plain string form (`rust = "1.99.1"`) has no components, so it fails the check.
#
# Reads the SOURCE config with `mise config get -f`, which only parses the file.
#
#   ./tests/mise-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$SRC/dot_config/mise/config.toml"
[ -f "$CFG" ] || { echo "missing file under test: $CFG" >&2; exit 2; }
command -v mise >/dev/null 2>&1 || { echo "mise is not installed (Brewfile)" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

get() { mise config get -f "$CFG" "$1" 2>/dev/null; }

comps=",$(get tools.rust.components | tr -d ' [\"]'),"
case "$comps" in
  *,rust-analyzer,*) _pass "rust installs the rust-analyzer component" ;;
  *) _fail "rust installs the rust-analyzer component" "components: $comps" ;;
esac

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]

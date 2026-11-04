#!/usr/bin/env bash
# Tests for dot_config/mise/config.toml: the global rust toolchain carries rust-analyzer, and
# the global postinstall hook installs default-gems into every Ruby.
#
# The rust-analyzer-lsp Claude Code plugin runs `rust-analyzer` from PATH. With the rustup
# component missing, ~/.cargo/bin/rust-analyzer (the rustup proxy) falls back to the mise shim
# of the same name, which calls the proxy again: "error: infinite recursion detected", exit 1,
# so the language server never starts and Claude Code never sees a diagnostic.
#
# A plain string form (`rust = "1.99.1"`) has no components, so it fails the check.
#
# Reads the SOURCE config with `mise config get -f`, which only parses the file, and drives
# the SOURCE hook script from a temp copy beside a temp default-gems list.
#
#   ./tests/mise-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$SRC/dot_config/mise/config.toml"
HOOK="$SRC/dot_config/mise/executable_ruby-default-gems"
[ -f "$CFG" ] || { echo "missing file under test: $CFG" >&2; exit 2; }
[ -f "$HOOK" ] || { echo "missing file under test: $HOOK" >&2; exit 2; }
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

# Regression: the deprecated setting returns and mise warns on every command.
dpf="$(get settings.ruby.default_packages_file)"
is "config.toml does not set ruby.default_packages_file" "$dpf" ""

# Regression: the hook is dropped or points elsewhere, so project-pinned Rubies lose ruby-lsp.
is "global postinstall hook runs ruby-default-gems" \
  "$(get hooks.postinstall)" '"$HOME/.config/mise/ruby-default-gems"'

# Regression: a clone without the exec bit makes mise's hook fail with "permission denied".
mode="$(git -C "$SRC" ls-files -s -- dot_config/mise/executable_ruby-default-gems | cut -d' ' -f1)"
is "ruby-default-gems is mode 100755 in git" "$mode" 100755

T="$(mktemp -d "${TMPDIR:-/tmp}/mise-config.XXXXXX")"; trap 'rm -rf "$T"' EXIT
cp "$HOOK" "$T/ruby-default-gems"; chmod 755 "$T/ruby-default-gems"
mkdir -p "$T/r1/bin" "$T/r2/bin"
for r in r1 r2; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$r" "$T" > "$T/$r/bin/gem"
  chmod 755 "$T/$r/bin/gem"
done
printf 'ruby-lsp\n' > "$T/default-gems"

# run <json|UNSET>: exit status in $rc, stderr in $err, gem calls in $calls.
run() {
  : > "$T/calls"
  if [ "$1" = UNSET ]; then
    err="$(env -u MISE_INSTALLED_TOOLS "$T/ruby-default-gems" 2>&1 >/dev/null)"
  else
    err="$(MISE_INSTALLED_TOOLS="$1" "$T/ruby-default-gems" 2>&1 >/dev/null)"
  fi
  rc=$?; calls="$(cat "$T/calls")"
}
entry() { printf '{"name":"%s","version":"x","install_path":"%s"}' "$1" "$T/$2"; }

# Regression: a newly installed Ruby gets no ruby-lsp.
run "[$(entry ruby r1)]"
is "one ruby entry installs the listed gem once" "$calls" "r1 install --no-document ruby-lsp"

# Regression: gems installed into a non-Ruby tool's path.
run "[$(entry node r1)]"
is "a non-ruby entry makes no gem call" "$calls" ""

# Regression: a no-op install runs gem anyway or fails.
run '[]'
is "[] makes no gem call and exits 0" "$calls:$rc" ":0"
run UNSET
is "unset MISE_INSTALLED_TOOLS makes no gem call and exits 0" "$calls:$rc" ":0"

# Regression: only the first Ruby of a multi-install gets its gems.
run "[$(entry ruby r1),$(entry ruby r2)]"
is "two ruby entries make two gem calls" "$calls" "r1 install --no-document ruby-lsp
r2 install --no-document ruby-lsp"

# Regression: comments or blanks reach gem install as arguments.
printf '# comment\n\n  ruby-lsp  # trailing\n   \nfoo --version 1.0\n' > "$T/default-gems"
run "[$(entry ruby r1)]"
is "comment and blank lines in the list are ignored" "$calls" "r1 install --no-document ruby-lsp
r1 install --no-document foo --version 1.0"
printf 'ruby-lsp\n' > "$T/default-gems"

# Regression: a failing gem install aborts the hook and fails the Ruby install.
printf '#!/bin/sh\nexit 1\n' > "$T/r1/bin/gem"
run "[$(entry ruby r1)]"
is "a failing gem install exits 0" "$rc" 0
case "$err" in
  *ruby-lsp*"$T/r1"*) _pass "a failing gem install warns naming gem and Ruby" ;;
  *) _fail "a failing gem install warns naming gem and Ruby" "$err" ;;
esac

# Regression: unparseable JSON aborts the hook or passes silently.
run 'not json'
is "malformed JSON exits 0" "$rc" 0
case "$err" in
  ?*) _pass "malformed JSON warns" ;;
  *) _fail "malformed JSON warns" "no stderr" ;;
esac

printf '\n%d/%d passed\n' "$pass" "$((pass + fail))"
[ "$fail" -eq 0 ]

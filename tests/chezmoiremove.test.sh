#!/usr/bin/env bash
# Verifies .chezmoiremove takes a retired target out of an existing home. Deleting a file
# from the source leaves the deployed copy where it is: only its entry here removes it, so
# a missing or mistyped entry leaves the retired script on PATH with every other suite green.
# Applies the real .chezmoiremove, alone, to a throwaway destination under $TMPDIR.
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
REMOVE="$SRC/.chezmoiremove"
pass=0; fail=0

if [ ! -f "$REMOVE" ]; then
  echo "INCONCLUSIVE: $REMOVE is missing; nothing to test"
  exit 2
fi
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "INCONCLUSIVE: chezmoi is not on PATH"
  exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/chezmoiremove.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

mkdir -p "$T/src" "$T/home/.local/bin" "$T/home/.config/ci-runner"
cp "$REMOVE" "$T/src/.chezmoiremove"
: >"$T/config.toml"
echo retired >"$T/home/.local/bin/app-cleaner"
echo retired >"$T/home/.config/ci-runner/lima.yaml"
echo kept >"$T/home/.local/bin/unrelated"
echo kept >"$T/home/.config/unrelated"

if ! out=$(command chezmoi --config "$T/config.toml" --persistent-state "$T/state.boltdb" \
    --cache "$T/cache" --source "$T/src" --destination "$T/home" --no-tty --force apply 2>&1); then
  echo "INCONCLUSIVE: chezmoi apply failed on the fixture: $out"
  exit 2
fi

if [ ! -e "$T/home/.local/bin/app-cleaner" ]; then
  ok "apply removes a deployed app-cleaner"
else
  bad "apply removes a deployed app-cleaner"
fi

if [ ! -e "$T/home/.config/ci-runner" ]; then
  ok "apply removes the deployed CI runner config and its directory"
else
  bad "apply removes the deployed CI runner config and its directory"
fi

if [ -e "$T/home/.local/bin/unrelated" ] && [ -e "$T/home/.config/unrelated" ]; then
  ok "apply leaves files with no entry alone, beside each retired target"
else
  bad "apply leaves files with no entry alone, beside each retired target"
fi

if [ ! -e "$SRC/dot_local/bin/executable_app-cleaner" ]; then
  ok "app-cleaner is gone from the source"
else
  bad "app-cleaner is gone from the source"
fi

if [ ! -e "$SRC/dot_config/ci-runner" ]; then
  ok "the CI runner config is gone from the source"
else
  bad "the CI runner config is gone from the source"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

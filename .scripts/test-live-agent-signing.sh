#!/usr/bin/env bash
# Run inside a fresh Claude sandbox. Proves Git signs through the agent and verifies the
# signature with the deployed XDG allowed-signers file.
set -u
test_root=$(mktemp -d "${TMPDIR%/}/claude-agent-signing.XXXXXX") || exit 1
trap 'rm -rf "$test_root"' EXIT

git init -q "$test_root/repo" || exit 1
if git -C "$test_root/repo" commit --allow-empty -m "Verify sandbox signing" >/dev/null 2>&1; then
  echo "COMMIT=SIGNED"
else
  echo "COMMIT=FAILED"
  exit 1
fi

if git -C "$test_root/repo" cat-file commit HEAD | grep -q '^gpgsig '; then
  echo "SIGNATURE=PRESENT"
else
  echo "SIGNATURE=ABSENT"
  exit 1
fi

if git -C "$test_root/repo" verify-commit HEAD >/dev/null 2>&1; then
  echo "VERIFICATION=GOOD"
else
  echo "VERIFICATION=FAILED"
  exit 1
fi

#!/usr/bin/env bash
# Verifies that Git signs with the existing public identity from XDG config while the
# private key remains agent-held. This inspects source templates only; it never reads keys.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/dot_config/git/config"
PUBLIC_TEMPLATE="$ROOT/dot_config/git/signing.pub.tmpl"
SIGNERS_TEMPLATE="$ROOT/dot_config/git/allowed_signers.tmpl"
pass=0; fail=0

check_equal() {
  if [ "$1" = "$2" ]; then
    echo "  PASS: $3"
    pass=$((pass + 1))
  else
    echo "  FAIL: $3"
    fail=$((fail + 1))
  fi
}

check_file() {
  if [ -f "$1" ]; then
    echo "  PASS: $2"
    pass=$((pass + 1))
  else
    echo "  FAIL: $2"
    fail=$((fail + 1))
  fi
}

signing_key=$(git config --file "$CONFIG" --get user.signingkey 2>/dev/null || true)
allowed_signers=$(git config --file "$CONFIG" --get gpg.ssh.allowedSignersFile 2>/dev/null || true)
check_equal "$signing_key" '~/.config/git/signing.pub' \
  "user.signingKey points to the XDG public key"
check_equal "$allowed_signers" '~/.config/git/allowed_signers' \
  "gpg.ssh.allowedSignersFile points to the XDG verifier"

check_file "$PUBLIC_TEMPLATE" "public signing-key template exists"
check_file "$SIGNERS_TEMPLATE" "allowed-signers template exists"

if [ -f "$PUBLIC_TEMPLATE" ] &&
   grep -qF '{{ onepasswordRead "op://Private/michael/public key" }}' "$PUBLIC_TEMPLATE" &&
   ! grep -q 'PRIVATE KEY' "$PUBLIC_TEMPLATE"; then
  echo "  PASS: signing identity reuses the existing public-key reference"
  pass=$((pass + 1))
else
  echo "  FAIL: signing identity must contain only the existing public-key reference"
  fail=$((fail + 1))
fi

if [ -f "$SIGNERS_TEMPLATE" ] &&
   grep -qF '{{ .email }} namespaces="git" {{ onepasswordRead "op://Private/michael/public key" }}' \
     "$SIGNERS_TEMPLATE" &&
   ! grep -q 'PRIVATE KEY' "$SIGNERS_TEMPLATE"; then
  echo "  PASS: allowed signers binds the existing identity to Git signatures"
  pass=$((pass + 1))
else
  echo "  FAIL: allowed signers must bind the existing public key to the Git namespace"
  fail=$((fail + 1))
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

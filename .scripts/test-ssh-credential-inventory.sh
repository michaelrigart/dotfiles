#!/usr/bin/env bash
# Deny-by-default inventory: every regular file directly under ~/.ssh must have a
# sandbox.credentials.files entry unless explicitly exempt. Filenames only — this never
# reads key material.
#
# REQUIRES UNSANDBOXED EXECUTION. The deployed Read(~/.ssh/**) deny blocks directory
# enumeration for sandboxed processes, so inside a Claude session this check cannot see
# the directory at all. It then reports INCONCLUSIVE (exit 2) rather than passing or
# failing: a guard that cannot enumerate must never report green, and must not emit a
# wall of false "stale entry" failures that invite it being deleted as noise.
#
# Run from a terminal:  bash .scripts/test-ssh-credential-inventory.sh
set -u
MOD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/modify_private_settings.json"
pass=0; fail=0

is_exempt() {
  case "$1" in
    config|known_hosts|known_hosts.old|allowed_signers|.DS_Store) return 0 ;;
    *.pub) return 0 ;;
    *) return 1 ;;
  esac
}

entries=$(printf '{}' | /bin/bash "$MOD" | jq -r '.sandbox.credentials.files[]?.path')

# Capability gate, before any assertion. Enumeration and stat must BOTH work: the stale
# check below uses [ -f ], which fails closed the same way and would otherwise report
# every configured path as absent.
probe=$(find "$HOME/.ssh" -maxdepth 1 -type f -print 2>&1 >/dev/null)
if [ -n "$probe" ] || [ ! -r "$HOME/.ssh" ]; then
  echo "INCONCLUSIVE: cannot enumerate ~/.ssh — Read(~/.ssh/**) denies it for sandboxed"
  echo "processes, which is the deployed policy working as intended."
  echo
  echo "This guard detects a NEW key appearing without a credentials.files entry, so it"
  echo "must run where it can list the directory:"
  echo "    bash .scripts/test-ssh-credential-inventory.sh    # from a normal terminal"
  exit 2
fi

while IFS= read -r -d '' path; do
  name=${path##*/}
  is_exempt "$name" && continue
  if printf '%s\n' "$entries" | grep -qxF "~/.ssh/$name"; then
    echo "  PASS: covered ~/.ssh/$name"; pass=$((pass + 1))
  else
    echo "  FAIL: UNCOVERED ~/.ssh/$name"; fail=$((fail + 1))
  fi
done < <(find "$HOME/.ssh" -maxdepth 1 -type f -print0)

while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    "~/.ssh/"*)
      if [ ! -f "$HOME/${entry#\~/}" ]; then
        echo "  FAIL: stale entry $entry (file absent)"
        fail=$((fail + 1))
      fi ;;
  esac
done <<EOF
$entries
EOF

echo
echo "RESULT: $pass covered, $fail failed"
[ "$fail" -eq 0 ]

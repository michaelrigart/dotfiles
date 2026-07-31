#!/usr/bin/env bash
# Deny-by-default inventory: every regular file directly under ~/.ssh must have a
# sandbox.credentials.files entry unless explicitly exempt. Filenames only.
# Run: bash .scripts/test-ssh-credential-inventory.sh
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

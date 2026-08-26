#!/usr/bin/env bash
# Regression suite for dot_claude/executable_git-forge-guard.sh.
#
#   tests/git-forge-guard.test.sh [path-to-guard]
#
# Defaults to the chezmoi SOURCE copy, so it tests what will be deployed rather
# than what currently is. Pass ~/.claude/git-forge-guard.sh to check the
# deployed copy instead — they should agree, and disagreeing means a hand-edit
# of a deployed dotfile that `chezmoi apply` is about to discard.
#
# The guard speaks the PreToolUse hook protocol: a JSON payload on stdin, and
# either no output (allow) or a decision object on stdout. Everything here goes
# through that interface, so the tests exercise it exactly as Claude Code does.
#
# Self-contained: builds its own fixtures and throwaway git repo under a temp
# directory, and removes them on exit. No network, no state outside $TMPDIR.

set -uo pipefail

GUARD=${1:-"$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_git-forge-guard.sh"}
[ -f "$GUARD" ] || { echo "guard not found: $GUARD" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-test.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# The guard expands variables from its OWN environment, so the fixtures are
# addressed through one this harness exports. Note that this is also the
# limitation being tested: a variable the hook cannot see must fail open.
export GUARDTMP="$WORK"

REPO="$WORK/repo"
mkdir -p "$REPO/.gitlab/merge_request_templates"
git -C "$REPO" init -q
cat > "$REPO/.gitlab/merge_request_templates/Default.md" <<'EOF'
**Story**: [Basecamp](https://app.basecamp.com/)

**Description**

_disclose other information that might be useful_

**Changes proposed in this merge request**

- ...
- ...
EOF

cat > "$WORK/good.md" <<'EOF'
**Story**: [Basecamp](https://app.basecamp.com/1/x)

**Description**

A real description.

**Changes proposed in this merge request**

- a thing
EOF

cat > "$WORK/bad.md" <<'EOF'
Freeform text with none of the template's structure.
EOF

# Rule 1 fixture. The footer is the thing under test, not an endorsement of it.
cat > "$WORK/attrib.md" <<'EOF'
**Story**: [Basecamp](https://app.basecamp.com/1/x)

**Description**

Fix.

Generated with Claude Code

**Changes proposed in this merge request**

- a thing
EOF

mkdir -p "$WORK/with space"
cp "$WORK/good.md" "$WORK/with space/good.md"

pass=0
fail=0

# run <command> -> allow | deny | ask | other
run() {
  local out decision
  out=$(printf '%s' "$1" \
    | jq -Rs --arg cwd "$REPO" '{tool_input:{command:.},cwd:$cwd}' \
    | bash "$GUARD" 2>/dev/null)
  decision=$(printf '%s' "$out" \
    | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ -n "$decision" ]; then
    printf '%s' "$decision"
  elif [ -z "$out" ]; then
    printf 'allow'
  else
    printf 'other'
  fi
}

# check <name> <expected> <command>
check() {
  local got
  got=$(run "$3")
  if [ "$got" = "$2" ]; then
    pass=$((pass + 1)); printf '  ok   %-46s -> %s\n' "$1" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-46s -> %s (want %s)\n' "$1" "$got" "$2"
  fi
}

echo "guard: $GUARD"
echo

echo "== rule 2: template compliance =="
check "inline compliant"           allow "glab mr create --description \"\$(cat $WORK/good.md)\""
check "inline non-compliant"       deny  "glab mr create --description 'just freeform text'"
check "file literal non-compliant" deny  "glab mr create --description \"\$(cat $WORK/bad.md)\""

echo "== variable-referenced paths (regression: false deny) =="
check "\$VAR/path compliant"        allow "glab mr create --description \"\$(cat \$GUARDTMP/good.md)\""
check "\${VAR}/path compliant"      allow "glab mr create --description \"\$(cat \${GUARDTMP}/good.md)\""
check "\$VAR/path non-compliant"    deny  "glab mr create --description \"\$(cat \$GUARDTMP/bad.md)\""
# The tilde here is deliberately literal: it is the unexpanded text the guard
# is being asked to resolve, not a path this script dereferences.
# shellcheck disable=SC2088
check "~/ path unresolvable"       allow "glab mr create --description \"\$(cat ~/definitely-absent-xyz.md)\""

echo "== fail open when the body file cannot be read =="
check "unset var"                  allow "glab mr create --description \"\$(cat \$NO_SUCH_VAR_HERE/x.md)\""
check "missing file"               allow "glab mr create --description \"\$(cat $WORK/absent.md)\""

echo "== quoting and flag spellings =="
check "path with space (quoted)"   allow "glab mr create --description \"\$(cat '$WORK/with space/good.md')\""
check "gh --body-file compliant"   allow "gh pr create --body-file $WORK/good.md"
check "gh --body-file=compliant"   allow "gh pr create --body-file=$WORK/good.md"
check "gh --body-file bad"         deny  "gh pr create --body-file $WORK/bad.md"
check "\$(< file) compliant"        allow "glab mr create --description \"\$(< $WORK/good.md)\""

echo "== rule 1: attribution, including through variables =="
check "attribution inline"         deny  "git commit -m 'fix

Generated with Claude Code'"
check "attribution via literal -F" deny  "git commit -F $WORK/attrib.md"
check "attribution via \$VAR -F"    deny  "git commit -F \$GUARDTMP/attrib.md"
check "attribution via --file="    deny  "git commit --file=\$GUARDTMP/attrib.md"
check "clean commit"               allow "git commit -m 'Task: do a thing'"

echo "== unrelated commands and bypass =="
check "unrelated command"          allow "ls -la"
check "mention in rg pattern"      allow "rg 'glab mr create' docs/"
check "FORGE_GUARD=off bypass"     allow "FORGE_GUARD=off glab mr create --description 'freeform'"

echo "== adversarial: fail-open must not be trippable =="
# A bare -F is also grep's fixed-string flag and sort's field separator. Reading
# one as a body-file reference would fail open and silently retire rule 2.
check "non-compliant + grep -F"    deny  "glab mr create --description 'freeform' | grep -F foo"
check "non-compliant + sort -F"    deny  "glab mr create --description 'freeform' && sort -F x"
check "compliant + grep -F"        allow "glab mr create --description \"\$(cat \$GUARDTMP/good.md)\" | grep -F foo"
check "commit -F real path denies" deny  "git commit -F \$GUARDTMP/attrib.md"

echo "== rule 3: glab api read vs write =="
check "glab api read"              allow "glab api projects/1/merge_requests/2"
check "glab api write -X"          ask   "glab api projects/1/mr -X DELETE"
check "glab api write -f"          ask   "glab api projects/1/mr -f title=x"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Tests that dot_claude/skills/live-feedback/SKILL.md deploys, and that everything it
# names exists. The skill is executable documentation: a tier that is not an agent type,
# a lock command lockf rejects, or a baseline that collapses untracked directories is a
# wrong instruction that gets followed. One direction only, as in xreview-skill.test.sh:
# what the skill names must exist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/dot_claude/skills/live-feedback/SKILL.md"
AGENTS="$ROOT/dot_claude/agents"
[ -f "$SKILL" ] || { echo "missing file under test: $SKILL" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | %s\n' "$1" "$2"; fail=$((fail + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/live-feedback-skill.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# --- frontmatter ----------------------------------------------------------------
front="$(awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f' "$SKILL")"
if printf '%s\n' "$front" | grep -qx 'name: live-feedback'; then
  _pass "frontmatter name is live-feedback, matching its directory"
else
  _fail "frontmatter name is live-feedback, matching its directory" \
        "$(printf '%s\n' "$front" | grep '^name:' || echo 'no name: line')"
fi
if printf '%s\n' "$front" | grep -qE '^description: .{40,}'; then
  _pass "frontmatter carries a description"
else
  _fail "frontmatter carries a description" "missing or shorter than 40 characters"
fi

# --- deployment -----------------------------------------------------------------
# .chezmoiignore is an allowlist for ~/.claude: without its own entries the skill never
# deploys, and every other check here would still pass.
managed="$(chezmoi --source "$ROOT" managed 2>/dev/null)"
if printf '%s\n' "$managed" | grep -qx '.claude/skills/live-feedback/SKILL.md'; then
  _pass "chezmoi manages .claude/skills/live-feedback/SKILL.md"
else
  _fail "chezmoi manages .claude/skills/live-feedback/SKILL.md" \
        "not in \`chezmoi managed\` - a .chezmoiignore allowlist entry is missing"
fi

# --- agent tiers ----------------------------------------------------------------
tiers="$(grep -oE '\bsp-[a-z]+' "$SKILL" | sort -u)"
[ -n "$tiers" ] || { echo "SKILL.md names no sp-* agent type - the extractor is broken" >&2; exit 1; }
for t in $tiers; do
  f="$AGENTS/$t.md"
  if [ -f "$f" ] && grep -qx "name: $t" "$f"; then
    _pass "agent type $t exists with a matching name:"
  else
    _fail "agent type $t exists with a matching name:" "no $f, or its name: line differs"
  fi
done
for t in sp-mechanical sp-standard sp-architect; do
  if printf '%s\n' "$tiers" | grep -qx "$t"; then _pass "the skill offers tier $t"
  else _fail "the skill offers tier $t" "not named in SKILL.md"; fi
done

# --- the lock -------------------------------------------------------------------
lockline="$(grep -oE 'lockf [^"]*"\$\(git rev-parse --git-common-dir\)/live-feedback\.lock"' "$SKILL" | head -1)"
if [ -n "$lockline" ]; then
  _pass "the lock sits in the git common directory"
else
  _fail "the lock sits in the git common directory" \
        "no 'lockf … \"\$(git rev-parse --git-common-dir)/live-feedback.lock\"' in SKILL.md"
fi
if command -v lockf >/dev/null 2>&1; then _pass "lockf is on PATH"
else _fail "lockf is on PATH" "not found"; fi
if [ -n "$lockline" ] && command -v lockf >/dev/null 2>&1; then
  flags="$(printf '%s' "$lockline" | sed -E 's/^lockf (.*) "\$\(git rev-parse.*$/\1/')"
  # shellcheck disable=SC2086 # the flags are words on purpose
  lockf $flags "$T/plain.lock" true; rc=$?
  if [ "$rc" = 0 ]; then _pass "the skill's lockf flags run a command"
  else _fail "the skill's lockf flags run a command" "exit $rc"; fi
  # shellcheck disable=SC2086
  lockf $flags "$T/plain.lock" sh -c 'exit 3'; rc=$?
  if [ "$rc" = 3 ]; then _pass "lockf passes the command's exit status through"
  else _fail "lockf passes the command's exit status through" "exit $rc, expected 3"; fi
  # wt worktrees of one repository share a database, so they must share the lock: from
  # a linked worktree the common directory is the main checkout's .git.
  git init -q "$T/main" \
    && git -C "$T/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$T/main" worktree add -q "$T/wt" -b wt-branch 2>/dev/null
  common="$(git -C "$T/wt" rev-parse --git-common-dir 2>/dev/null)"
  # shellcheck disable=SC2086
  if [ -n "$common" ] && lockf $flags "$common/live-feedback.lock" true \
     && [ -f "$T/main/.git/live-feedback.lock" ]; then
    _pass "from a linked worktree the lock lands in the main checkout's .git"
  else
    _fail "from a linked worktree the lock lands in the main checkout's .git" \
          "common dir '$common'; no $T/main/.git/live-feedback.lock"
  fi
fi

# --- the baseline ---------------------------------------------------------------
# Without --untracked-files=all an untracked directory collapses to one "dir/" line, so
# Michael's files inside it would not match an exclusion by path.
if grep -qF 'git status --porcelain --untracked-files=all' "$SKILL"; then
  _pass "the baseline lists every untracked file"
else
  _fail "the baseline lists every untracked file" "no 'git status --porcelain --untracked-files=all'"
fi
bare="$(grep -nF 'git status --porcelain' "$SKILL" | grep -vF -- '--untracked-files=all')"
if [ -z "$bare" ]; then
  _pass "no git status --porcelain without --untracked-files=all"
else
  _fail "no git status --porcelain without --untracked-files=all" "$bare"
fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

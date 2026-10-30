#!/usr/bin/env bash
# Renders the three agent-instruction targets from the chezmoi source and checks what each
# one carries (spec 2026-09-30, section 3).
#
#   dot_config/agents/GLOBAL.md.tmpl  -> the shared fragment
#   dot_codex/AGENTS.md.tmpl          -> the shared fragment
#   dot_claude/CLAUDE.md.tmpl         -> the shared fragment, then the Claude addendum
#
# Both fragments live in .chezmoitemplates/agents/, which chezmoi never deploys. This repo
# is PUBLIC and the fragments are plain tracked text: no template actions, no 1Password.
#
#   ./tests/agent-instructions.test.sh   (sandboxed is fine; needs no op)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
FRAG="$SRC/.chezmoitemplates/agents"
GLOBAL_T=dot_config/agents/GLOBAL.md.tmpl
CODEX_T=dot_codex/AGENTS.md.tmpl
CLAUDE_T=dot_claude/CLAUDE.md.tmpl
for f in "$FRAG/global.md" "$FRAG/claude-code.md" "$SRC/$GLOBAL_T" "$SRC/$CODEX_T" "$SRC/$CLAUDE_T"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The heading claude-code.md opens with. Only the Claude target may carry it.
MARKER='## Claude Code only'
T="$(mktemp -d "${TMPDIR:-/tmp}/agentinstr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --config /dev/null: render from this source alone, never from Michael's chezmoi config.
render() { # render <template, relative to the source> <out-file>
  chezmoi --config /dev/null --config-format toml --source "$SRC" --destination "$HOME" \
    execute-template --file "$SRC/$1" > "$2" 2>"$T/err"
}

first_line=$(head -1 "$FRAG/global.md")
frag_lines=$(wc -l < "$FRAG/global.md" | tr -d ' ')
for t in "$GLOBAL_T" "$CODEX_T" "$CLAUDE_T"; do
  out="$T/$(basename "$t")"
  if render "$t" "$out" && [ -s "$out" ]; then
    _pass "$t renders"
  else
    _fail "$t renders" "$(cat "$T/err")"
  fi
  # The whole fragment, not a line of it: the target must open with global.md verbatim.
  if [ "$(head -n "$frag_lines" "$out")" = "$(cat "$FRAG/global.md")" ]; then
    _pass "$t carries the shared fragment"
  else
    _fail "$t carries the shared fragment" "$(diff <(head -n "$frag_lines" "$out") "$FRAG/global.md" | head -3)"
  fi
  if grep -q 'onepasswordRead' "$SRC/$t"; then
    _fail "$t no longer reads 1Password" "$(grep -n onepasswordRead "$SRC/$t")"
  else
    _pass "$t no longer reads 1Password"
  fi
done

for t in "$GLOBAL_T" "$CODEX_T"; do
  if grep -qF -- "$MARKER" "$T/$(basename "$t")"; then
    _fail "$t carries no Claude-only section" "found '$MARKER'"
  else
    _pass "$t carries no Claude-only section"
  fi
done
claude_out="$T/$(basename "$CLAUDE_T")"
marker_at=$(grep -nxF -- "$MARKER" "$claude_out" | head -1 | cut -d: -f1)
shared_at=$(grep -nxF -- "$first_line" "$claude_out" | head -1 | cut -d: -f1)
if [ -n "$marker_at" ] && [ -n "$shared_at" ] && [ "$shared_at" -lt "$marker_at" ] \
   && [ "$marker_at" -eq $((frag_lines + 2)) ] && [ -n "$(tail -n 1 "$claude_out")" ]; then
  _pass "the Claude target is the shared fragment, one blank line, the addendum, no trailing blank"
else
  _fail "the Claude target is the shared fragment, one blank line, the addendum, no trailing blank" "shared at '$shared_at', marker at '$marker_at' (expected $((frag_lines + 2))), last line '$(tail -n 1 "$claude_out")'"
fi

is_first() { [ "$(head -1 "$1")" = "$2" ]; }
is_first "$FRAG/claude-code.md" "$MARKER" && _pass "claude-code.md opens with '$MARKER'" \
  || _fail "claude-code.md opens with '$MARKER'" "$(head -1 "$FRAG/claude-code.md")"
grep -qF -- "$MARKER" "$FRAG/global.md" && _fail "global.md holds no Claude-only heading" "found it" \
  || _pass "global.md holds no Claude-only heading"

lines=$(wc -l < "$FRAG/global.md" | tr -d ' ')
[ "$lines" -le 180 ] && _pass "global.md is at most 180 lines ($lines)" || _fail "global.md is at most 180 lines" "$lines"
lines=$(wc -l < "$FRAG/claude-code.md" | tr -d ' ')
[ "$lines" -le 50 ] && _pass "claude-code.md is at most 50 lines ($lines)" || _fail "claude-code.md is at most 50 lines" "$lines"

# On case-insensitive APFS a fragment named claude.md IS a CLAUDE.md, and Claude Code loads
# it as nested instructions whenever it reads a file in that directory.
nested=$(find "$SRC/.chezmoitemplates" -iname 'claude.md' 2>/dev/null)
[ -z "$nested" ] && _pass "no fragment is a CLAUDE.md in another letter case" \
  || _fail "no fragment is a CLAUDE.md in another letter case" "$nested"

# A template action inside a fragment would run at apply time, with this machine's data,
# in a file the repo publishes. The fragments are plain text.
for f in global.md claude-code.md; do
  if grep -q '{{' "$FRAG/$f"; then _fail "$f contains no template action" "$(grep -n '{{' "$FRAG/$f" | head -3)"
  else _pass "$f contains no template action"; fi
done

# The rules specs 2026-10-16 and 2026-10-30 add: the git configuration escape, both shapes
# the path-resolution guard denies, the plan workspace cleaner, and progress on a long run.
# Each is a fixed string on one line.
need() { # need <fragment> <fixed text> <label>
  if grep -qF -- "$2" "$FRAG/$1"; then _pass "$3"; else _fail "$3" "missing: $2"; fi
}
need claude-code.md '- **Path-resolution guard.** Never chain commands after a leading `cd`: use absolute paths' \
  "claude-code.md carries the path-resolution guard rule"
need claude-code.md '  - Needs the escape: `op`, and git configuration writes in any repository: `init`,' \
  "claude-code.md names git configuration writes in any repository as needing the escape"
need claude-code.md '    `clone`, `config`, `remote add`, `branch -u`, `submodule`, `worktree add`,' \
  "the escape line lists the explicit git commands that write configuration"
need claude-code.md '    `switch --track`, or a new branch started from a remote ref (`switch -c b origin/x`).' \
  "the escape line names tracking and a branch started from a remote ref"
need claude-code.md '  or `git -C`; a lone `cd` lasts only in the main session. Name directories, not a recursive' \
  "the path-resolution rule says a lone cd lasts only in the main session"
need claude-code.md '`grep`/`rg` over `.`, which re-prompts in any tree that could hold a deny-glob match.' \
  "the path-resolution rule keeps the recursive-search shape"
need claude-code.md '`sdd-clean <workspace>`, never `rm -rf`.' \
  "claude-code.md deletes a finished plan workspace with sdd-clean"
need global.md 'to take over about 15 minutes, give its size and ETA at the start and one line per' \
  "global.md's Momentum rule asks for size and ETA on a long run"
need global.md '  merged branch'"'"'s pinned delete, `git branch -d`. Harness prompts are a backstop, not the check.' \
  "global.md exempts a merged branch's pinned delete from confirm-first"
if grep -qF -- '**Recursive search.**' "$FRAG/claude-code.md"; then
  _fail "the Recursive search bullet is folded into the path-resolution rule" "still present"
else
  _pass "the Recursive search bullet is folded into the path-resolution rule"
fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

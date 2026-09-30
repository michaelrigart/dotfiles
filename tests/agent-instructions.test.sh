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
for f in "$FRAG/global.md" "$FRAG/claude.md" "$SRC/$GLOBAL_T" "$SRC/$CODEX_T" "$SRC/$CLAUDE_T"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The heading claude.md opens with. Only the Claude target may carry it.
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
is_first "$FRAG/claude.md" "$MARKER" && _pass "claude.md opens with '$MARKER'" \
  || _fail "claude.md opens with '$MARKER'" "$(head -1 "$FRAG/claude.md")"
grep -qF -- "$MARKER" "$FRAG/global.md" && _fail "global.md holds no Claude-only heading" "found it" \
  || _pass "global.md holds no Claude-only heading"

lines=$(wc -l < "$FRAG/global.md" | tr -d ' ')
[ "$lines" -le 180 ] && _pass "global.md is at most 180 lines ($lines)" || _fail "global.md is at most 180 lines" "$lines"
lines=$(wc -l < "$FRAG/claude.md" | tr -d ' ')
[ "$lines" -le 50 ] && _pass "claude.md is at most 50 lines ($lines)" || _fail "claude.md is at most 50 lines" "$lines"

# A template action inside a fragment would run at apply time, with this machine's data,
# in a file the repo publishes. The fragments are plain text.
for f in global.md claude.md; do
  if grep -q '{{' "$FRAG/$f"; then _fail "$f contains no template action" "$(grep -n '{{' "$FRAG/$f" | head -3)"
  else _pass "$f contains no template action"; fi
done

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

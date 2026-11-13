#!/usr/bin/env bash
# Renders the three agent-instruction targets from the chezmoi source and checks what each
# one carries (spec 2026-09-30, section 3).
#
#   dot_config/agents/GLOBAL.md.tmpl  -> the shared fragment
#   dot_codex/AGENTS.md.tmpl          -> the shared fragment, then the Codex addendum
#   dot_claude/CLAUDE.md.tmpl         -> the shared fragment, then the Claude addendum
#
# All three fragments live in .chezmoitemplates/agents/, which chezmoi never deploys. This repo
# is PUBLIC and the fragments are plain tracked text: no template actions, no 1Password.
#
#   ./tests/agent-instructions.test.sh   (sandboxed is fine; needs no op)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
FRAG="$SRC/.chezmoitemplates/agents"
RULES="$SRC/tests/fixtures/agent-instructions/rules.tsv"
GLOBAL_T=dot_config/agents/GLOBAL.md.tmpl
CODEX_T=dot_codex/AGENTS.md.tmpl
CLAUDE_T=dot_claude/CLAUDE.md.tmpl
for f in "$FRAG/global.md" "$FRAG/claude-code.md" "$FRAG/codex.md" "$SRC/AGENTS.md" "$SRC/tests/AGENTS.md" "$SRC/$GLOBAL_T" "$SRC/$CODEX_T" "$SRC/$CLAUDE_T" "$RULES"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The heading claude-code.md opens with. Only the Claude target may carry it.
MARKER='## Claude Code only'
# The heading codex.md opens with. Only the Codex target may carry it.
CODEX_MARKER='## Codex only'
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

codex_out="$T/$(basename "$CODEX_T")"
codex_marker_at=$(grep -nxF -- "$CODEX_MARKER" "$codex_out" | head -1 | cut -d: -f1)
codex_shared_at=$(grep -nxF -- "$first_line" "$codex_out" | head -1 | cut -d: -f1)
if [ -n "$codex_marker_at" ] && [ -n "$codex_shared_at" ] && [ "$codex_shared_at" -lt "$codex_marker_at" ] \
   && [ "$codex_marker_at" -eq $((frag_lines + 2)) ] && [ -n "$(tail -n 1 "$codex_out")" ]; then
  _pass "the Codex target is the shared fragment, one blank line, the addendum, no trailing blank"
else
  _fail "the Codex target is the shared fragment, one blank line, the addendum, no trailing blank" "shared at '$codex_shared_at', marker at '$codex_marker_at' (expected $((frag_lines + 2))), last line '$(tail -n 1 "$codex_out")'"
fi
# Byte for byte, so a target that keeps its heading but loses its fragment's body fails.
renders_exactly() {  # <label> <rendered file> <fragment>...: the fragments joined by one blank line
  local label=$1 out=$2 want="$T/want" f first=1
  shift 2
  : > "$want"
  for f in "$@"; do
    [ "$first" = 1 ] || printf '\n' >> "$want"
    cat "$FRAG/$f" >> "$want"
    first=0
  done
  if cmp -s "$out" "$want"; then
    _pass "$label"
  else
    _fail "$label" "$(diff "$want" "$out" | head -3)"
  fi
}
renders_exactly "the GLOBAL target is global.md exactly" "$T/$(basename "$GLOBAL_T")" global.md
renders_exactly "the Claude target is global.md, one blank line, claude-code.md exactly" "$claude_out" \
  global.md claude-code.md
renders_exactly "the Codex target is global.md, one blank line, codex.md exactly" "$codex_out" \
  global.md codex.md

for t in "$GLOBAL_T" "$CLAUDE_T"; do
  if grep -qxF -- "$CODEX_MARKER" "$T/$(basename "$t")"; then
    _fail "$t carries no Codex-only section" "found '$CODEX_MARKER'"
  else
    _pass "$t carries no Codex-only section"
  fi
done

is_first() { [ "$(head -1 "$1")" = "$2" ]; }
is_first "$FRAG/claude-code.md" "$MARKER" && _pass "claude-code.md opens with '$MARKER'" \
  || _fail "claude-code.md opens with '$MARKER'" "$(head -1 "$FRAG/claude-code.md")"
is_first "$FRAG/codex.md" "$CODEX_MARKER" && _pass "codex.md opens with '$CODEX_MARKER'" \
  || _fail "codex.md opens with '$CODEX_MARKER'" "$(head -1 "$FRAG/codex.md")"
grep -qF -- "$MARKER" "$FRAG/global.md" && _fail "global.md holds no Claude-only heading" "found it" \
  || _pass "global.md holds no Claude-only heading"
grep -qF -- "$CODEX_MARKER" "$FRAG/global.md" && _fail "global.md holds no Codex-only heading" "found it" \
  || _pass "global.md holds no Codex-only heading"
grep -qF -- "$CODEX_MARKER" "$FRAG/claude-code.md" && _fail "claude-code.md holds no Codex-only heading" "found it" \
  || _pass "claude-code.md holds no Codex-only heading"

lines=$(wc -l < "$FRAG/global.md" | tr -d ' ')
[ "$lines" -le 150 ] && _pass "global.md is at most 150 lines ($lines)" || _fail "global.md is at most 150 lines" "$lines"
too_wide=$(awk 'length($0) > 100 {print FILENAME ":" NR}' "$FRAG/global.md" | head -3)
[ -z "$too_wide" ] && _pass "global.md has no line wider than 100 columns" || _fail "global.md has no line wider than 100 columns" "$too_wide"
lines=$(wc -l < "$SRC/AGENTS.md" | tr -d ' ')
[ "$lines" -le 240 ] && _pass "AGENTS.md is at most 240 lines ($lines)" || _fail "AGENTS.md is at most 240 lines" "$lines"
lines=$(wc -l < "$FRAG/claude-code.md" | tr -d ' ')
[ "$lines" -le 50 ] && _pass "claude-code.md is at most 50 lines ($lines)" || _fail "claude-code.md is at most 50 lines" "$lines"
lines=$(wc -l < "$FRAG/codex.md" 2>/dev/null | tr -d ' ')
[ "${lines:-99}" -le 30 ] && _pass "codex.md is at most 30 lines ($lines)" || _fail "codex.md is at most 30 lines" "$lines"

# A reflow once cut the last line of global.md; each fragment must end on a finished sentence.
for f in global.md claude-code.md codex.md; do
  last=$(grep -v '^[[:space:]]*$' "$FRAG/$f" | tail -1)
  case "$last" in
    *.) _pass "$f ends on a finished sentence" ;;
    *) _fail "$f ends on a finished sentence" "$last" ;;
  esac
done

# On case-insensitive APFS a fragment named claude.md IS a CLAUDE.md, and Claude Code loads
# it as nested instructions whenever it reads a file in that directory.
nested=$(find "$SRC/.chezmoitemplates" -iname 'claude.md' 2>/dev/null)
[ -z "$nested" ] && _pass "no fragment is a CLAUDE.md in another letter case" \
  || _fail "no fragment is a CLAUDE.md in another letter case" "$nested"

# A template action inside a fragment would run at apply time, with this machine's data,
# in a file the repo publishes. The fragments are plain text.
for f in global.md claude-code.md codex.md; do
  if grep -q '{{' "$FRAG/$f"; then _fail "$f contains no template action" "$(grep -n '{{' "$FRAG/$f" | head -3)"
  else _pass "$f contains no template action"; fi
done

# The rules the three fragments and the skills they cite must state, one row per rule in
# tests/fixtures/agent-instructions/rules.tsv: id, file, anchor, safety, terms, note. The block
# that holds the anchor must hold every term, so a rule survives a rewrap and a reword outside
# its terms but fails when a clause of it is cut. `terms` are separated by `;` (`\;` is a
# literal semicolon). A safety row's terms keep every clause of the rule; a non-safety row's
# keep its shortest identifying phrases.
# A block is what the audit harness mutates: a bullet (an indented one too) with its
# continuation lines, a paragraph, a heading or a table row. Whitespace runs collapse to one
# space in the block, the anchor and the terms.
# A row passes only on the awk program's positive verdict ("ok"): an awk that exits non-zero,
# prints nothing or cannot read the file fails the row with that reason. The fields are split
# on a non-whitespace separator (tabs become \037), so an empty field keeps its column.
rule() { # rule <rules.tsv> <source root>
  local tsv=$1 root=$2 id file anchor safety terms note why line=0 rows=0 live
  while IFS=$'\037' read -r id file anchor safety terms note || [ -n "$id" ]; do
    line=$((line + 1))
    case "$id" in '' | '#'*) continue ;; esac
    case "$safety" in yes | no) ;; *) echo "$tsv: line $line: safety must be yes or no" >&2; exit 2 ;; esac
    [ -n "$file" ] && [ -n "$anchor" ] || { echo "$tsv: line $line: file and anchor are required" >&2; exit 2; }
    live=; rest=${terms//\\;/x}
    while [ -n "$rest" ]; do # a `-` term is the harness's no-terms marker, as empty as no term
      t=${rest%%;*}; t=${t//[[:space:]]/}
      case $rest in *\;*) rest=${rest#*;} ;; *) rest= ;; esac
      [ "$t" = - ] || live=$live$t
    done
    [ -n "$live" ] || { echo "$tsv: line $line: at least one term is required" >&2; exit 2; }
    rows=$((rows + 1))
    if [ ! -f "$root/$file" ]; then
      why="missing file: $file"
    else
      why=$(RC_ANCHOR=$anchor RC_TERMS=$terms awk '
        function squash(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
        # \s{0,3}#{1,6}\s
        function is_heading(s,   n, rest, h) {
          match(s, /^[[:space:]]*/); n = RLENGTH
          if (n > 3) return 0
          rest = substr(s, n + 1); h = 0
          while (substr(rest, h + 1, 1) == "#") h++
          return (h >= 1 && h <= 6 && substr(rest, h + 1, 1) ~ /^[[:space:]]$/)
        }
        function flush(   flat) {
          if (cur == "") return
          flat = squash(cur)
          if (index(flat, anchor)) { hits++; if (hits == 1) held = flat }
          cur = ""; kind = ""
        }
        BEGIN {
          anchor = squash(ENVIRON["RC_ANCHOR"]); spec = ENVIRON["RC_TERMS"]
          gsub(/\\;/, "\034", spec); n = split(spec, terms, ";")
          for (i = 1; i <= n; i++) gsub(/\034/, ";", terms[i])
        }
        {
          line = $0
          if (line ~ /^[[:space:]]*$/) { flush(); next }
          single = (is_heading(line) || line ~ /^[[:space:]]*\|/)
          starts = (single || line ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/)
          if (cur != "" && kind == "text" && !starts) { cur = cur " " line; next }
          flush()
          cur = line; kind = single ? "single" : "text"
        }
        END {
          flush()
          if (anchor == "") { print "empty anchor"; exit }
          if (hits == 0) { print "anchor not found: " anchor; exit }
          if (hits > 1) { print "anchor in " hits " blocks: " anchor; exit }
          for (i = 1; i <= n; i++) {
            t = squash(terms[i])
            if (t == "" || t == "-") continue
            if (!index(held, t)) { print "missing from the block of \"" anchor "\": " t; exit }
          }
          print "ok"
        }' "$root/$file" 2>&1) || why="awk exited $?: ${why:-no output}"
    fi
    if [ "$why" = ok ]; then _pass "rule $id: $note"; else _fail "rule $id: $note" "${why:-awk gave no verdict}"; fi
  done < <(tr '\t' '\037' < "$tsv")
  [ "$rows" -gt 0 ] || { echo "no rules in $tsv" >&2; exit 2; }
}

# The helper must be able to fail: over a row that holds, a row whose term is absent and an awk
# that is broken, each in a subshell with its own counters. A helper that always passes fails here.
mkdir -p "$T/self"
printf -- '- **Rule.** alpha beta gamma.\n' > "$T/self/doc.md"
{ printf 'r1\tdoc.md\t**Rule.**\tno\talpha;beta\tholds\n'
  printf 'r2\tdoc.md\t**Rule.**\tno\talpha;delta\tabsent\n'; } > "$T/self/rules.tsv"
got=$( pass=0; fail=0; rule "$T/self/rules.tsv" "$T/self" > /dev/null; echo "$pass/$fail" )
[ "$got" = 1/1 ] && _pass "rule: a row that holds passes and a row with an absent term fails" \
  || _fail "rule: a row that holds passes and a row with an absent term fails" "pass/fail: $got"
got=$( pass=0; fail=0; awk() { return 2; }; rule "$T/self/rules.tsv" "$T/self" > /dev/null; echo "$pass/$fail" )
[ "$got" = 0/2 ] && _pass "rule: an awk that exits non-zero fails every row" \
  || _fail "rule: an awk that exits non-zero fails every row" "pass/fail: $got"
got=$( pass=0; fail=0; awk() { return 0; }; rule "$T/self/rules.tsv" "$T/self" > /dev/null; echo "$pass/$fail" )
[ "$got" = 0/2 ] && _pass "rule: an awk that prints no verdict fails every row" \
  || _fail "rule: an awk that prints no verdict fails every row" "pass/fail: $got"
printf 'r3\tdoc.md\t**Rule.**\tno\t;\tno terms\n' > "$T/self/empty.tsv"
got=$( ( rule "$T/self/empty.tsv" "$T/self" ) > /dev/null 2>&1; echo "exit $?" )
[ "$got" = "exit 2" ] && _pass "rule: a row with no term exits 2" || _fail "rule: a row with no term exits 2" "$got"
printf 'r3\tdoc.md\t**Rule.**\tno\t-\tno terms, the harness spelling\n' > "$T/self/dash.tsv"
got=$( ( rule "$T/self/dash.tsv" "$T/self" ) > /dev/null 2>&1; echo "exit $?" )
[ "$got" = "exit 2" ] && _pass "rule: a row whose terms are only the no-terms marker - exits 2" \
  || _fail "rule: a row whose terms are only the no-terms marker - exits 2" "$got"
printf 'r4\tdoc.md\t**Rule.**\tno\t\talpha\n' > "$T/self/shift.tsv"
got=$( ( rule "$T/self/shift.tsv" "$T/self" ) > /dev/null 2>&1; echo "exit $?" )
[ "$got" = "exit 2" ] && _pass "rule: an empty terms field keeps its column, so the note is not read as terms" \
  || _fail "rule: an empty terms field keeps its column, so the note is not read as terms" "$got"

rule "$RULES" "$SRC"

# Superseded wording a row cannot see, because a row checks what a rule says, not what it
# stopped saying.
if tr '\n' ' ' < "$FRAG/global.md" | tr -s ' ' | grep -qF -- 'The driver may open'; then
  _fail "global.md no longer makes a wt checkout optional" "still present"
else _pass "global.md no longer makes a wt checkout optional"; fi
if tr '\n' ' ' < "$FRAG/global.md" | tr -s ' ' | grep -qF -- 'The dotfiles never use'; then
  _fail "global.md no longer keeps wt out of the dotfiles" "still present"
else _pass "global.md no longer keeps wt out of the dotfiles"; fi
if tr '\n' ' ' < "$FRAG/claude-code.md" | tr -s ' ' | grep -qF -- '(dotfiles: a harness worktree)'; then
  _fail "claude-code.md no longer sends a dotfiles plan to a harness worktree" "still present"
else _pass "claude-code.md no longer sends a dotfiles plan to a harness worktree"; fi
if grep -qF -- '**Recursive search.**' "$FRAG/claude-code.md"; then
  _fail "the Recursive search bullet is folded into the path-resolution rule" "still present"
else
  _pass "the Recursive search bullet is folded into the path-resolution rule"
fi

# Whole-line frontmatter pins: a row matches a substring, so an added tool or a commented-out
# key would still pass it.
WR="$SRC/dot_claude/agents/web-researcher.md"
for line in 'name: web-researcher' 'tools: WebFetch, WebSearch' 'model: opus' 'effort: medium' 'omitClaudeMd: true'; do
  if [ -f "$WR" ] && awk '/^---$/{n++; next} n==1' "$WR" | grep -qx -- "$line"; then _pass "web-researcher frontmatter has $line"
  else _fail "web-researcher frontmatter has $line" "missing"; fi
done
SR="$SRC/dot_claude/agents/sp-reviewer.md"
if [ -f "$SR" ] && awk '/^---$/{n++; next} n==1' "$SR" | grep -qx -- 'disallowedTools: Edit, Write, NotebookEdit'; then _pass "sp-reviewer frontmatter denies Edit, Write and NotebookEdit"
else _fail "sp-reviewer frontmatter denies Edit, Write and NotebookEdit" "missing"; fi
DR=dot_claude/skills/design-records/SKILL.md
for line in 'name: design-records' 'description: Use when creating, updating, completing or abandoning a spec or plan under `docs/superpowers/`, or setting its Status.'; do
  if [ -f "$SRC/$DR" ] && awk '/^---$/{n++; next} n==1' "$SRC/$DR" | grep -qxF -- "$line"; then _pass "design-records frontmatter has ${line%%:*}"
  else _fail "design-records frontmatter has ${line%%:*}" "missing: $line"; fi
done

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

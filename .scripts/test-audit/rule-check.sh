#!/usr/bin/env bash
# Checks a rules TSV against a source tree: for each row, the block that holds the anchor must hold
# every term. The draft of the loop that agent-instructions.test.sh will run over
# tests/fixtures/agent-instructions/rules.tsv.
#
#   rule-check.sh <rules.tsv> <source root>
#
# Columns (tab-separated, no header): id, file, anchor, safety, terms, note. `terms` are separated
# by `;` (`\;` is a literal semicolon). The harness stores terms split on a bare `;`, so a check
# that reads this TSV must honour `\;` the way this script does. A line starting with `#` and a
# blank line are skipped.
# Blocks are the ones the audit harness mutates: a bullet (indented ones too) with its continuation
# lines, a paragraph, a heading, a table row. Whitespace runs collapse to one space in the block,
# the anchor and the terms.
# The block and whitespace patterns are those of rules.py (START_RE, SINGLE_RE, str.isspace).
# Prints `  PASS: rule <id>` or `  FAIL: rule <id>`; a FAIL is followed by the reason, and the totals
# close the output. Exit status: 0 when every rule passes, 1 when any fails, 2 when the TSV or the
# source root is unusable.
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <rules.tsv> <source root>" >&2; exit 2; }
tsv=$1 root=$2
[ -f "$tsv" ] || { echo "missing rules file: $tsv" >&2; exit 2; }
[ -d "$root" ] || { echo "missing source root: $root" >&2; exit 2; }

# check_block <file> <anchor> <terms>: prints nothing when the anchor sits in exactly one block that
# holds every term; otherwise one reason line.
check_block() {
  RC_ANCHOR=$2 RC_TERMS=$3 awk '
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
        if (t == "") continue
        if (!index(held, t)) { print "missing from the block of \"" anchor "\": " t; exit }
      }
    }' "$1"
}

pass=0 fail=0 line=0
while IFS=$'\t' read -r id file anchor safety terms note || [ -n "$id" ]; do
  line=$((line + 1))
  case "$id" in '' | '#'*) continue ;; esac
  case "$safety" in yes | no) ;; *) echo "$tsv: line $line: safety must be yes or no" >&2; exit 2 ;; esac
  [ -n "$file" ] && [ -n "$anchor" ] || { echo "$tsv: line $line: file and anchor are required" >&2; exit 2; }
  if [ ! -f "$root/$file" ]; then
    why="missing file: $file"
  else
    why=$(check_block "$root/$file" "$anchor" "$terms")
  fi
  if [ -z "$why" ]; then
    printf '  PASS: rule %s\n' "$id"
    pass=$((pass + 1))
  else
    printf '  FAIL: rule %s\n    | %s\n' "$id" "$why"
    fail=$((fail + 1))
  fi
done < "$tsv"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ $((pass + fail)) -gt 0 ] || { echo "no rules in $tsv" >&2; exit 2; }
[ "$fail" -eq 0 ]

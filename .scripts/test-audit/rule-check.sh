#!/usr/bin/env bash
# Checks a rules TSV against a source tree: for each row, the block that holds the anchor must hold
# every term. The draft of the loop that agent-instructions.test.sh will run over
# tests/fixtures/agent-instructions/rules.tsv.
#
#   rule-check.sh <rules.tsv> <source root>
#
# Columns (tab-separated, no header): id, file, anchor, safety, terms, note. `terms` are separated
# by `;`. A line starting with `#` and a blank line are skipped. Blocks are the ones the audit
# harness mutates: a bullet (indented ones too) with its continuation lines, a paragraph, a heading,
# a table row. Whitespace runs collapse to one space in the block, the anchor and the terms.
# Prints `  PASS: rule <id>` or `  FAIL: rule <id>`; a FAIL is followed by the reason. Exit status:
# the failure count (at most 255); 2 when the TSV or the source root is unusable.
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <rules.tsv> <source root>" >&2; exit 2; }
tsv=$1 root=$2
[ -f "$tsv" ] || { echo "missing rules file: $tsv" >&2; exit 2; }
[ -d "$root" ] || { echo "missing source root: $root" >&2; exit 2; }

# check_block <file> <anchor> <terms>: prints nothing when the anchor sits in exactly one block that
# holds every term; otherwise one reason line.
check_block() {
  RC_ANCHOR=$2 RC_TERMS=$3 awk '
    function flush(   flat) {
      if (cur == "") return
      flat = cur; gsub(/[ \t]+/, " ", flat); sub(/^ /, "", flat); sub(/ $/, "", flat)
      if (index(flat, anchor)) { hits++; if (hits == 1) held = flat }
      cur = ""; kind = ""
    }
    function squash(s) { gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    BEGIN { anchor = squash(ENVIRON["RC_ANCHOR"]); n = split(ENVIRON["RC_TERMS"], terms, ";") }
    {
      line = $0
      if (line ~ /^[ \t]*$/) { flush(); next }
      starts = (line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ || line ~ /^ ? ? ?#+[ \t]/ || line ~ /^[ \t]*\|/)
      single = (line ~ /^ ? ? ?#+[ \t]/ || line ~ /^[ \t]*\|/)
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
[ "$fail" -le 255 ] && exit "$fail" || exit 255

#!/usr/bin/env bash
# SessionStart hook: checks the session's project memory index and, only when something is
# wrong, tells the agent what to fix (spec 2026-10-06 section 4). Healthy is silent.
#
# The memory directory is where Claude Code keeps auto-memory: transcripts are keyed on the
# session cwd, memory on the main repository root. So the root is the parent of the cwd's
# `git rev-parse --git-common-dir` (a linked worktree maps to its main checkout, a
# subdirectory to its checkout), the project key is that root with every character outside
# [A-Za-z0-9] turned into "-", and the directory is <projects dir>/<key>/memory. No usable
# cwd or no repository: the transcript's own directory + /memory.
#
#   - MEMORY.md at 90% or more of the limits Claude Code loads it under, 200 lines and
#     25,000 characters (read from the Claude Code 2.1.289 binary), counted on the trimmed
#     content as Claude Code counts it: characters are UTF-16 code units (a JavaScript
#     string length), so an emoji counts two.
#   - an index line longer than 200 characters, counted as it stands in the file (untrimmed);
#   - an index link ](name.md) whose file does not exist;
#   - a memory file that no index link names.
# [[name]] links are not checked: a link to a memory not yet written is allowed.
#
# Read-only. Fails open and silent on every error. Bash 3.2 compatible.
# Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
# 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
set -uo pipefail
exec 2>/dev/null

LIMIT_LINES=200 LIMIT_CHARS=25000   # Claude Code 2.1.289
LINE_CHARS=200                      # longest index line left unwarned
WARN_LINES=180 WARN_CHARS=22500     # 90% of each

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty') || exit 0
[ -n "$transcript" ] || exit 0
tdir=$(dirname "$transcript")
dir="$tdir/memory"
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty') || cwd=""
if [ -n "$cwd" ] && [ -d "$cwd" ] && command -v git >/dev/null 2>&1; then
  common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir) || common=""
  if [ -n "$common" ]; then
    root=$(dirname "$common")
    key=$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')
    [ -n "$key" ] && dir="$(dirname "$tdir")/$key/memory"
  fi
fi
[ -d "$dir" ] || exit 0
index="$dir/MEMORY.md"

problems=""
add() { problems="${problems}- $1
"; }

linked=""
if [ -f "$index" ]; then
  content=$(cat "$index") || exit 0
  # Trim leading and trailing whitespace, as Claude Code does before counting.
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  lines=0 units=0
  if [ -n "$content" ]; then
    lines=$(printf '%s' "$content" | awk 'END { print NR }') || exit 0
    units=$(printf '%s' "$content" | iconv -f UTF-8 -t UTF-16LE | wc -c | tr -d ' ') || exit 0
  fi
  case "$lines" in ''|*[!0-9]*) exit 0 ;; esac
  case "$units" in ''|*[!0-9]*) exit 0 ;; esac
  chars=$((units / 2))
  if [ "$lines" -ge "$WARN_LINES" ] || [ "$chars" -ge "$WARN_CHARS" ]; then
    add "MEMORY.md is at $lines lines and $chars characters; Claude Code loads at most $LIMIT_LINES lines and $LIMIT_CHARS characters of it. Consolidate the index (merge or shorten entries, one line each) to under $WARN_LINES lines and $WARN_CHARS characters."
  fi
  # UTF-16 units never exceed UTF-8 bytes, so only a line over LINE_CHARS bytes can be too
  # long; the cheap byte count spares iconv a fork on the rest. n counts file lines.
  nbytes() { local LC_ALL=C; REPLY=${#1}; }
  longlines=""
  n=0
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1))
    nbytes "$l"
    [ "$REPLY" -gt "$LINE_CHARS" ] || continue
    u=$(printf '%s' "$l" | iconv -f UTF-8 -t UTF-16LE | wc -c | tr -d ' ') || exit 0
    case "$u" in ''|*[!0-9]*) exit 0 ;; esac
    [ $((u / 2)) -gt "$LINE_CHARS" ] || continue
    e=$(printf '%s' "$l" | sed -n 's/^[^]]*](\([^)]*\)).*$/\1/p')
    longlines="${longlines:+$longlines, }${e:-line $n} ($((u / 2)))"
  done < "$index"
  [ -z "$longlines" ] || add "MEMORY.md has index lines longer than $LINE_CHARS characters (length in parentheses): $longlines. Shorten each to one short line; move detail into the memory file."
  raw=$(grep -oE '\]\([^)#]+\.md(#[^)]*)?( "[^"]*")?\)' "$index"); rc=$?
  # grep exits 1 when the index has no links; anything above that is a read error, and a
  # read error must stay silent rather than report every file as unindexed.
  [ "$rc" -le 1 ] || exit 0
  linked=$(printf '%s\n' "$raw" | sed -e 's/^](//' -e 's/)$//' -e 's/ "[^"]*"$//' -e 's/#.*$//' -e 's|^\./||' \
             | awk 'NF && !/:\/\//' | sort -u) || exit 0
fi

dangling=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -f "$dir/$name" ] || dangling="${dangling:+$dangling, }$name"
done <<EOF
$linked
EOF

unindexed=""
for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  name=${f##*/}
  [ "$name" = MEMORY.md ] && continue
  # A case match, not a grep pipe: no pipe can lose a match to SIGPIPE under pipefail.
  case "
$linked
" in
    *"
$name
"*) ;;
    *) unindexed="${unindexed:+$unindexed, }$name" ;;
  esac
done

[ -z "$dangling" ] || add "MEMORY.md links to files that do not exist: $dangling. Remove each entry, or restore the file if it was deleted by mistake."
[ -z "$unindexed" ] || add "Memory files that MEMORY.md does not list: $unindexed. Add an index line for each, or delete the file if it is obsolete."
[ -n "$problems" ] || exit 0

jq -cn --arg m "Memory health check for $dir:
$problems" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}' || exit 0
exit 0

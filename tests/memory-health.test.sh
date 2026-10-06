#!/usr/bin/env bash
# Tests for dot_claude/hooks/executable_memory-health.sh, the SessionStart hook that reports
# a project memory index nearing Claude Code's limits, index links to missing files and
# memory files the index never lists (spec 2026-10-06 section 4). Healthy is silent.
#
#   ./tests/memory-health.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/dot_claude/hooks/executable_memory-health.sh"
[ -f "$HOOK" ] || { echo "missing script under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
has() { case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1" "$2" ;; esac; }

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/memhealth.XXXXXX")" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# mem <project> -> creates a fresh project with an empty memory dir; prints the memory dir
mem() { rm -rf "${ROOT:?}/$1"; mkdir -p "$ROOT/$1/memory"; printf '%s' "$ROOT/$1/memory"; }
# fire <project> -> the hook's stdout for a session whose transcript lives in that project
fire() {
  jq -cn --arg t "$ROOT/$1/sess.jsonl" \
    '{hook_event_name:"SessionStart",source:"startup",session_id:"s",transcript_path:$t}' \
    | bash "$HOOK"
}
ctx() { fire "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# note <dir> <file> -> a memory file; link <file> -> an index line linking it
note() { printf -- '---\nname: x\n---\nbody\n' > "$1/$2"; }
link() { printf -- '- [%s](%s) — hook\n' "$1" "$1"; }
filler() { i=0; while [ "$i" -lt "$1" ]; do printf -- '- plain line %d\n' "$i"; i=$((i + 1)); done; }

echo "A. healthy is silent"
d="$(mem ok)"; note "$d" a.md; note "$d" b.md
{ link a.md; link b.md; } > "$d/MEMORY.md"
is "a small, consistent index prints nothing" "$(fire ok)" ""
fire ok >/dev/null; is "and exits 0" "$?" 0

echo "B. size"
d="$(mem lines)"; { filler 179; } > "$d/MEMORY.md"
is "179 lines is silent" "$(fire lines)" ""
{ filler 180; } > "$d/MEMORY.md"
has "180 lines warns, with the count" "$(ctx lines)" "180 lines"
{ filler 179; printf '\n\n\n   \n'; } > "$d/MEMORY.md"
is "179 lines plus trailing blank lines is silent (counted trimmed)" "$(fire lines)" ""
d="$(mem leading)"; { printf '\n\n\n\n\n'; filler 179; } > "$d/MEMORY.md"
is "five leading blank lines plus 179 content lines is silent (counted trimmed)" "$(fire leading)" ""
d="$(mem chars)"; printf '%*s' 22499 '' | tr ' ' x > "$d/MEMORY.md"
is "22,499 characters is silent" "$(fire chars)" ""
printf '%*s' 22500 '' | tr ' ' x > "$d/MEMORY.md"
has "22,500 characters warns, with the count" "$(ctx chars)" "22500 characters"
d="$(mem dashes)"; printf '—%.0s' $(seq 8000) > "$d/MEMORY.md"
is "8,000 em dashes (24,000 bytes) is silent: characters, not bytes" "$(fire dashes)" ""
d="$(mem emoji)"; printf '😀%.0s' $(seq 11249) > "$d/MEMORY.md"
is "11,249 emoji (22,498 UTF-16 units) is silent" "$(fire emoji)" ""
printf '😀%.0s' $(seq 11250) > "$d/MEMORY.md"
has "11,250 emoji (22,500 UTF-16 units) warns: an emoji counts two, as in Claude Code" "$(ctx emoji)" "22500 characters"

echo "C. index consistency"
d="$(mem dangling)"; note "$d" a.md; { link a.md; link gone.md; } > "$d/MEMORY.md"
has "a link to a missing file is named" "$(ctx dangling)" "gone.md"
d="$(mem orphan)"; note "$d" a.md; note "$d" orphan.md; link a.md > "$d/MEMORY.md"
has "an unindexed memory file is named" "$(ctx orphan)" "orphan.md"
d="$(mem names)"; note "$d" 'my note.md'; note "$d" 'a+b.md'
{ link 'my note.md'; link 'a+b.md'; } > "$d/MEMORY.md"
is "names with spaces and regex characters match exactly" "$(fire names)" ""
d="$(mem anchor)"; note "$d" a.md; printf -- '- [a](a.md#sec) — hook\n' > "$d/MEMORY.md"
is "a link with an #anchor is the same file" "$(fire anchor)" ""
d="$(mem titled)"; note "$d" o.md; printf -- '- [o](o.md "t") — hook\n' > "$d/MEMORY.md"
is "a link with a title is the same file" "$(fire titled)" ""
d="$(mem dotslash)"; note "$d" a.md; printf -- '- [a](./a.md) — hook\n' > "$d/MEMORY.md"
is "a ./ link prefix is the same file" "$(fire dotslash)" ""
d="$(mem wiki)"; note "$d" a.md; { link a.md; printf -- '- see [[not-yet]]\n'; } > "$d/MEMORY.md"
is "a [[wiki-link]] to a memory not yet written is not flagged" "$(fire wiki)" ""
d="$(mem noindex)"; note "$d" a.md; note "$d" b.md
out="$(ctx noindex)"
has "no MEMORY.md: every file is named as unindexed (a.md)" "$out" "a.md"
has "no MEMORY.md: every file is named as unindexed (b.md)" "$out" "b.md"

echo "D. output shape"
d="$(mem shape)"; note "$d" a.md; { link a.md; link gone.md; } > "$d/MEMORY.md"
is "the output is SessionStart additionalContext" \
   "$(fire shape | jq -r '.hookSpecificOutput.hookEventName')" SessionStart
has "it names the memory directory" "$(ctx shape)" "$d"
before="$(find "$d" -type f -exec shasum {} + | sort)"
fire shape >/dev/null
is "the hook never writes to the memory directory" "$(find "$d" -type f -exec shasum {} + | sort)" "$before"

echo "E. fails open and silent"
mkdir -p "$ROOT/nomem"
is "no memory directory is silent" "$(fire nomem)" ""
out="$(printf '%s' '{"hook_event_name":"SessionStart"}' | bash "$HOOK")"; rc=$?
is "no transcript_path is silent, exit 0" "$rc/$out" "0/"
out="$(printf '%s' 'not json' | bash "$HOOK")"; rc=$?
is "malformed input is silent, exit 0" "$rc/$out" "0/"
out="$(bash "$HOOK" </dev/null)"; rc=$?
is "empty input is silent, exit 0" "$rc/$out" "0/"
stub="$ROOT/stub"; mkdir -p "$stub"; printf '#!/bin/sh\nexit 2\n' > "$stub/grep"; chmod +x "$stub/grep"
d="$(mem greperr)"; note "$d" a.md; note "$d" orphan.md; link a.md > "$d/MEMORY.md"
out="$(jq -cn --arg t "$ROOT/greperr/sess.jsonl" '{transcript_path:$t}' | PATH="$stub:$PATH" bash "$HOOK")"; rc=$?
is "a grep read error is silent, exit 0, never 'unindexed' advice" "$rc/$out" "0/"

echo "F. the memory directory follows the repository root, not the session cwd"
# Claude Code keys transcripts on the session cwd and auto-memory on the main repository
# root, so a linked-worktree or subdirectory session must read the main checkout's memory.
key() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
PROJ="$ROOT/projects"; mkdir -p "$PROJ"
REPO="$ROOT/repo"; WT="$ROOT/repo-wt"
git init -q "$REPO" >/dev/null 2>&1
git -C "$REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init >/dev/null 2>&1
git -C "$REPO" worktree add -q -b wt "$WT" >/dev/null 2>&1
mkdir -p "$REPO/sub" "$PROJ/$(key "$REPO")/memory"
note "$PROJ/$(key "$REPO")/memory" a.md; note "$PROJ/$(key "$REPO")/memory" orphan.md
link a.md > "$PROJ/$(key "$REPO")/memory/MEMORY.md"
# fireat <transcript> <cwd> -> the hook's additionalContext
fireat() {
  jq -cn --arg t "$1" --arg c "$2" '{hook_event_name:"SessionStart",transcript_path:$t,cwd:$c}' \
    | bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty'
}
out="$(fireat "$PROJ/$(key "$WT")/sess.jsonl" "$WT")"
has "a linked-worktree session reports the main checkout's memory" "$out" "orphan.md"
has "and names that memory directory" "$out" "$PROJ/$(key "$REPO")/memory"
out="$(fireat "$PROJ/$(key "$REPO/sub")/sess.jsonl" "$REPO/sub")"
has "a subdirectory session reports the main checkout's memory" "$out" "orphan.md"
out="$(fireat "$PROJ/$(key "$REPO")/sess.jsonl" "$REPO")"
has "a main-checkout session reports its own memory" "$out" "orphan.md"
mkdir -p "$ROOT/plain" "$ROOT/nogit"
d="$(mem plain)"; note "$d" a.md; note "$d" orphan.md; link a.md > "$d/MEMORY.md"
out="$(fireat "$ROOT/plain/sess.jsonl" "$ROOT/nogit")"
has "a non-git cwd falls back to the transcript's own directory" "$out" "orphan.md"
out="$(fireat "$ROOT/plain/sess.jsonl" "$ROOT/does-not-exist")"
has "a missing cwd falls back to the transcript's own directory" "$out" "orphan.md"
is "a non-git cwd with no memory beside the transcript is silent" \
   "$(fireat "$PROJ/$(key "$WT")/sess.jsonl" "$ROOT/nogit")" ""

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

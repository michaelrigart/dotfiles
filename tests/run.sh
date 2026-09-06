#!/usr/bin/env bash
# Runs the suites in this directory and reports passed/total.
#
#   ./tests/run.sh                 # every suite with no special requirement
#   ./tests/run.sh --all           # those too, requirements printed, run anyway
#   ./tests/run.sh forge worktree  # only suites whose name contains one of these
#
# This exists because all three ways of getting a run wrong are silent:
#
#   1. Wrong interpreter. `bash a-zsh-suite.sh` reports bogus syntax errors that read
#      as a regression. Every suite here carries a correct shebang, so this runner
#      EXECUTES the file and never prefixes an interpreter. Neither should you.
#   2. Brace expansion. `bash tests/live-{a,b}.test.sh` runs only the first and passes
#      the second as an ignored $1 — the skipped suite prints nothing, so the run looks
#      clean. This runner takes a glob and a filter, never a brace list.
#   3. Miscounting. A suite that dies partway prints only the assertions it reached and
#      can look green. Every suite is judged on its EXIT STATUS, and the counted
#      assertions are cross-checked against it; a suite that exits 0 while printing a
#      FAIL, or exits non-zero with none, is reported as INCONSISTENT rather than
#      folded into a total.
#
# A suite may declare arguments with `# test-args:` (`{repo}` = this repo's root).
#
# Suites with a `# test-requires:` line need conditions this runner cannot create
# (an unsandboxed shell, a live herdr, a fresh Claude session). They are listed and
# skipped unless named or --all is passed. Read the tag before believing their output.
set -uo pipefail

self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
cd "$(dirname "$self")" || exit 2
repo_root=$(cd .. && pwd)

all=0
filters=()
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;
    -h|--help) sed -n '2,/^set /p' "$self" | sed '$d; s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) filters+=("$a") ;;
  esac
done

matches() { # matches <name>
  [ ${#filters[@]} -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}

suites=0 green=0 red=0 broken=0 skipped=0
declare -a problems=()

for f in ./*.test.sh; do
  name=$(basename "$f" .test.sh)
  matches "$name" || continue

  req=$(sed -n 's/^# test-requires: *//p' "$f" | head -1)
  req=${req%%  #*}
  if [ -n "$req" ] && [ "$all" -eq 0 ] && [ ${#filters[@]} -eq 0 ]; then
    printf '  skip  %-28s needs: %s\n' "$name" "$req"
    skipped=$((skipped + 1))
    continue
  fi

  # A suite may declare its arguments; `{repo}` is this repository's root. Without this
  # live-agent-auth ran with no $1, died in its own usage guard, and reported nothing.
  args=$(sed -n 's/^# test-args: *//p' "$f" | head -1)
  args=${args%%  #*}
  set --
  [ -n "$args" ] && set -- ${args//\{repo\}/$repo_root}

  out=$("$f" "$@" 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(ok|PASS)([[:space:]]|:)')
  fl=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(FAIL|not ok)([[:space:]]|:)')
  # The live-* suites deliberately report machine-readable status (`michael=DENIED`,
  # `AUTH=READY`) instead of prose, so they never emit an `ok`/`PASS` line. Counting
  # only the prose idiom reported them as "asserted nothing" — a false alarm on the
  # three suites whose output matters most. Fall back to the KEY=VALUE shape.
  idiom=prose
  if [ "$((p + fl))" -eq 0 ]; then
    p=$(printf '%s\n' "$out" | grep -cE '^[A-Za-z_][A-Za-z0-9_.-]*=[A-Za-z_]+$')
    [ "$p" -gt 0 ] && idiom=kv
  fi
  tot=$((p + fl))
  suites=$((suites + 1))
  note=""
  [ -n "$req" ] && note="  [needs: $req]"

  # Exit status is the verdict; the counts only describe it. Disagreement means the
  # suite died partway or never asserted, and either way its total is not trustworthy.
  # The cross-check needs both signals, so it applies only to the prose idiom. A kv
  # suite encodes its failures in the VALUES (`michael=READABLE`) and its exit status
  # is the count of them, so "non-zero with no FAIL line" is its normal way to fail,
  # not an inconsistency.
  if [ "$idiom" = prose ] && { { [ "$rc" -eq 0 ] && [ "$fl" -gt 0 ]; } || { [ "$rc" -ne 0 ] && [ "$fl" -eq 0 ] && [ "$tot" -gt 0 ]; }; }; then
    printf '  ????  %-28s %s/%s asserted but exit=%s — INCONSISTENT%s\n' "$name" "$p" "$tot" "$rc" "$note"
    problems+=("$name (inconsistent: exit=$rc, $fl failed assertions)")
    broken=$((broken + 1))
  elif [ "$tot" -eq 0 ]; then
    printf '  ????  %-28s no assertions, exit=%s%s\n' "$name" "$rc" "$note"
    problems+=("$name (asserted nothing)")
    broken=$((broken + 1))
  elif [ "$rc" -eq 0 ]; then
    printf '  ok    %-28s %s/%s%s\n' "$name" "$p" "$tot" "$note"
    green=$((green + p))
  else
    printf '  FAIL  %-28s %s/%s (exit=%s)%s\n' "$name" "$p" "$tot" "$rc" "$note"
    printf '%s\n' "$out" | grep -E '^[[:space:]]*(FAIL|not ok)' | sed 's/^/          /'
    if [ "$idiom" = kv ]; then problems+=("$name (exit=$rc)"); else problems+=("$name ($fl failed)"); fi
    red=$((red + p))
  fi
done

echo
printf '%s suites run' "$suites"
[ "$skipped" -gt 0 ] && printf ', %s skipped (see the needs: lines)' "$skipped"
printf '\n'

if [ ${#problems[@]} -gt 0 ]; then
  echo "NOT OK:"
  printf '  - %s\n' "${problems[@]}"
  exit 1
fi
[ "$suites" -eq 0 ] && { echo "no suites matched"; exit 2; }
printf 'all %s suites passed (%s assertions)\n' "$suites" "$green"

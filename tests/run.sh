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
# Suites run concurrently, RUN_JOBS at a time (default: half the online CPUs, at least 2;
# 4 when the count cannot be read). RUN_JOBS=1 restores sequential order. Each suite's
# output is buffered and printed in name order, so the report is the same either way. A
# suite that cannot share the machine (timing assertions, fixed ports, shared state)
# carries a `# test-serial` line and runs alone after the parallel ones.
#
# One runner per machine: every invocation, filtered or not, takes a lockf lock on
# RUN_SH_LOCK (default /tmp/claude-$(id -u)/tests-run.lock) and says so when it has to
# wait. The runner exports RUN_SH_LOCKED=1 to its suites, and an invocation that sees it
# does not lock again, so a runner nested in a suite cannot wait for its parent's lock.
# Never wrap this runner in lockf yourself.
#
# Suites with a `# test-requires:` line need conditions this runner cannot create
# (an unsandboxed shell, a live herdr, a fresh Claude session) or are `heavy`, a policy
# choice for their length (minutes), not a missing condition. They are listed and
# skipped unless named EXACTLY (`./tests/run.sh live-agent-auth`) or --all is passed; a
# substring filter (`live`) still skips them. Read the tag before believing their output.
set -uo pipefail

self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
# Suites run from tests/, so a suite cannot tell which directory the session started in; tell it.
[ "${1:-}" = --run-one ] || RUN_SH_START_DIR=$(pwd -P)
export RUN_SH_START_DIR

all=0 one=0
filters=()
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;
    --run-one) one=1 ;; # internal: the xargs driver runs a single suite, named by the filter
    -h|--help) sed -n '2,/^set /p' "$self" | sed '$d; s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) filters+=("$a") ;;
  esac
done

if [ "$one" -eq 0 ] && [ "${RUN_SH_LOCKED:-}" != 1 ]; then
  lock=${RUN_SH_LOCK:-/tmp/claude-$(id -u)/tests-run.lock}
  mkdir -p "$(dirname "$lock")" || exit 2
  lockf -k -t 0 "$lock" true 2>/dev/null
  [ $? -eq 75 ] && echo "run.sh: waiting for the test-run lock $lock, held by another run" >&2
  RUN_SH_LOCKED=1 exec lockf -k "$lock" "$self" "$@"
fi
export RUN_SH_LOCKED=1

cd "$(dirname "$self")" || exit 2
repo_root=$(cd .. && pwd)

matches() { # matches <name>
  [ ${#filters[@]} -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}

# Only an exact suite name lifts the requirement gate. A substring filter used to lift it
# too, so `./tests/run.sh live` ran the sandbox-measuring suites in whatever mode the
# shell happened to be in — the inverted-result trap AGENTS.md warns about.
named() { # named <name>
  [ ${#filters[@]} -eq 0 ] && return 1
  local f
  for f in "${filters[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

# A suite that cannot decide (a cold cache, say) prints `INCONCLUSIVE:` plus indented
# lines saying how to fix it. It lands in a ???? row, which otherwise hides its output.
show_inconclusive() {
  printf '%s\n' "$out" | awk '
    /^[[:space:]]*INCONCLUSIVE:/ { print; keep = 1; next }
    keep && /^[[:space:]]+[^[:space:]]/ && !/^[[:space:]]*(ok|PASS|FAIL|not ok)([[:space:]]|:)/ { print; next }
    { keep = 0 }' | sed 's/^/          /'
}

# select <file> sets name and req; returns 1 when the filters exclude the suite and 2 when
# its requirement gate skips it.
select_suite() {
  name=$(basename "$1" .test.sh)
  matches "$name" || return 1
  req=$(sed -n 's/^# test-requires: *//p' "$1" | head -1)
  req=${req%%  #*}
  if [ -n "$req" ] && [ "$all" -eq 0 ] && ! named "$name"; then return 2; fi
  return 0
}

if [ "$one" -eq 1 ]; then
  name=${filters[0]}
  f=./$name.test.sh
  # A suite may declare its arguments; `{repo}` is this repository's root. Without this
  # live-agent-auth ran with no $1, died in its own usage guard, and reported nothing.
  args=$(sed -n 's/^# test-args: *//p' "$f" | head -1)
  args=${args%%  #*}
  set --
  [ -n "$args" ] && set -- ${args//\{repo\}/$repo_root}
  "$f" "$@" </dev/null >"$RUN_SH_WORK/$name.out" 2>&1
  echo $? >"$RUN_SH_WORK/$name.rc"
  exit 0
fi

jobs=${RUN_JOBS:-}
if [ -z "$jobs" ]; then
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
  case "$cpus" in
    ''|*[!0-9]*) jobs=4 ;;
    *) jobs=$((cpus / 2)); [ "$jobs" -lt 2 ] && jobs=2 ;;
  esac
fi

RUN_SH_WORK=$(mktemp -d "${TMPDIR:-/tmp}/run-sh.XXXXXX") || exit 2
export RUN_SH_WORK
trap 'rm -rf "$RUN_SH_WORK"' EXIT
trap 'exit 130' INT TERM

parallel=() serial=()
for f in ./*.test.sh; do
  select_suite "$f" || continue
  if grep -qE '^# test-serial([[:space:]]|$)' "$f"; then serial+=("$name"); else parallel+=("$name"); fi
done
[ ${#parallel[@]} -gt 0 ] && printf '%s\0' "${parallel[@]}" | xargs -0 -n1 -P "$jobs" "$self" --run-one
[ ${#serial[@]} -gt 0 ] && printf '%s\0' "${serial[@]}" | xargs -0 -n1 -P 1 "$self" --run-one

suites=0 green=0 red=0 broken=0 skipped=0
declare -a problems=()

for f in ./*.test.sh; do
  select_suite "$f"
  case $? in
    1) continue ;;
    2)
      printf '  skip  %-28s needs: %s\n' "$name" "$req"
      skipped=$((skipped + 1))
      continue ;;
  esac

  if [ -f "$RUN_SH_WORK/$name.rc" ]; then
    out=$(<"$RUN_SH_WORK/$name.out"); rc=$(<"$RUN_SH_WORK/$name.rc")
  else
    out="run.sh: $name left no result"; rc=70
  fi
  p=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(ok|PASS)([[:space:]]|:)')
  fl=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*(FAIL|not ok)([[:space:]]|:)')
  # The live-* suites deliberately report machine-readable status (`michael=DENIED`,
  # `AUTH=READY`) instead of prose, so they never emit an `ok`/`PASS` line. Counting
  # only the prose idiom reported them as "asserted nothing" — a false alarm on the
  # three suites whose output matters most. Fall back to the KEY=VALUE shape.
  idiom=prose
  if [ "$((p + fl))" -eq 0 ]; then
    # A probe that reports SKIPPED did not assert anything, so it is not counted.
    p=$(printf '%s\n' "$out" | grep -E '^[A-Za-z_][A-Za-z0-9_.-]*=[A-Za-z_]+$' | grep -vcE '=SKIPPED$|^failed_keys=')
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
    show_inconclusive
    problems+=("$name (inconsistent: exit=$rc, $fl failed assertions)")
    broken=$((broken + 1))
  elif [ "$tot" -eq 0 ]; then
    printf '  ????  %-28s no assertions, exit=%s%s\n' "$name" "$rc" "$note"
    show_inconclusive
    problems+=("$name (asserted nothing)")
    broken=$((broken + 1))
  elif [ "$rc" -eq 0 ]; then
    printf '  ok    %-28s %s/%s%s\n' "$name" "$p" "$tot" "$note"
    green=$((green + p))
  else
    printf '  FAIL  %-28s %s/%s (exit=%s)%s\n' "$name" "$p" "$tot" "$rc" "$note"
    if [ "$idiom" = kv ]; then
      # A kv suite closes with failed_keys=<key>,<key> when it fails. Only that line is shown, and only
      # when it is made of key characters: nothing else a suite prints is echoed, so no value leaks.
      printf '%s\n' "$out" | grep -E '^failed_keys=[A-Za-z0-9_.,-]+$' | tail -n 1 | sed 's/^/          /'
      problems+=("$name (exit=$rc)")
    else
      # Each failure with up to 3 continuation lines (the suite's `| got:` detail).
      printf '%s\n' "$out" | awk '
        /^[[:space:]]*(FAIL|not ok)/ { print; keep = 3; next }
        keep > 0 && /^[[:space:]]+[^[:space:]]/ && !/^[[:space:]]*(ok|PASS)([[:space:]]|:)/ { print; keep--; next }
        { keep = 0 }' | sed 's/^/          /'
      problems+=("$name ($fl failed)")
    fi
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

#!/usr/bin/env bash
# Runs the suites in this directory and reports passed/total.
#
#   ./tests/run.sh                 # every suite with no special requirement
#   ./tests/run.sh --all           # those too, requirements printed, run anyway
#   ./tests/run.sh forge worktree  # only suites whose name contains one of these
#   ./tests/run.sh --changed       # the default suites, plus each heavy suite whose subject changed against main
#   ./tests/run.sh --changed=<ref> # the same against another base
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
# output is buffered and printed in name order, so the verdicts are the same either way (a
# load-sensitive suite's assertion count may differ). A suite that cannot share the
# machine (timing assertions, fixed ports, shared state) carries a `# test-serial` line and
# runs alone after the parallel ones; so does every suite gated on a condition other than
# `heavy` (a live herdr, a pty, the real daemon), which --all or an exact name selects.
#
# One runner per machine: every invocation, filtered or not, takes a lockf lock on
# RUN_SH_LOCK (default /tmp/claude-$(id -u)/tests-run.lock). The runner that holds it writes
# <lock>.holder (start time, checkout and arguments, one line) and removes it on exit; one
# that has to wait prints at once, and then each minute, who holds the lock and for how
# long, and, once it has the lock, how long it waited. The record is advisory: without a
# usable one the line says only that another run holds it. RUN_SH_LOCK_WAIT=<seconds> bounds
# the wait (0 does not wait): the runner then prints "giving up", runs nothing and exits 75;
# unset, it waits without bound. A value that is not a non-negative integer exits 2.
# The runner exports RUN_SH_LOCKED=1 to its suites, and an invocation that sees it does not
# lock again, so a runner nested in a suite cannot wait for its parent's lock.
# Never wrap this runner in lockf yourself.
#
# Suites with a `# test-requires:` line need conditions this runner cannot create
# (an unsandboxed shell, a live herdr, a fresh Claude session) or are `heavy`, a policy
# choice for their length (minutes), not a missing condition. They are listed and
# skipped unless named EXACTLY (`./tests/run.sh live-agent-auth`) or --all is passed; a
# substring filter (`live`) still skips them. Read the tag before believing their output.
#
# --changed lifts the `heavy` gate, and only that gate (a suite is heavy when its requirement
# is exactly `heavy`), for each heavy suite with a changed subject. A suite's subjects are the
# files of .scripts/test-audit/subjects.tsv rows (file, lang, own_suite, loaded_by) whose
# loaded_by lists it, its own file and tests/run.sh, under the map in the working tree or the
# map at the merge base. The changed files are those of `git diff` against the merge base of
# <ref> (default main) and HEAD, that is the working tree against the merge base (so a change
# staged and then reverted in the working tree is not listed), plus untracked unignored files;
# they are read NUL-delimited and compared byte for byte. A heavy suite left out prints
# "(no subject changed since <merge base>)"; one that runs carries [needs: heavy; changed:
# <first changed subject>(, +N more)]. Whatever the runner cannot read or decide runs every
# heavy suite and says why in the same bracket: not a git work tree, an
# unresolvable base, no merge base, a failing git command, a missing, unreadable or malformed
# subject map (working tree or merge base), or a suite with no row. An exact name or --all
# still runs a heavy suite whatever the diff; every other gate stays.
set -uo pipefail

self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
# Suites run from tests/, so a suite cannot tell which directory the session started in; tell it.
[ "${1:-}" = --run-one ] || RUN_SH_START_DIR=$(pwd -P)
export RUN_SH_START_DIR

all=0 one=0 changed=0 base=main
filters=()
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;
    --changed) changed=1 base=main ;;
    --changed=?*) changed=1 base=${a#--changed=} ;;
    --run-one) one=1 ;; # internal: the xargs driver runs a single suite, named by the filter
    -h|--help) sed -n '2,/^set /p' "$self" | sed '$d; s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) filters+=("$a") ;;
  esac
done

lock=${RUN_SH_LOCK:-/tmp/claude-$(id -u)/tests-run.lock}
case "$lock" in /*) ;; *) lock=$PWD/$lock ;; esac # the record is written after a cd

# norm <digits>: the value in base 10 (a leading 0 would read as octal), capped so it cannot overflow.
norm() {
  local v=${1#"${1%%[!0]*}"}
  [ -n "$v" ] || v=0
  [ ${#v} -le 9 ] || v=999999999
  echo "$v"
}

# Who holds the lock, as the clause of the waiting and giving-up lines. The record is
# advisory: a missing or unparsable one degrades to "held by another run"; a parsable one is
# shown with its age, even when the runner that wrote it died without removing it.
holder_clause() {
  local rec= ts chk args age
  [ -r "$lock.holder" ] && IFS= read -r rec <"$lock.holder"
  case "$rec" in
    *$'\t'*$'\t'*)
      ts=${rec%%$'\t'*}; rec=${rec#*$'\t'}
      chk=${rec%%$'\t'*}; args=${rec#*$'\t'} ;;
    *) ts= chk= ;;
  esac
  case "$ts" in ''|*[!0-9]*) ts= ;; esac
  if [ -z "$ts" ] || [ ${#ts} -gt 12 ] || [ -z "$chk" ]; then
    echo "held by another run"
    return
  fi
  age=$(($(date +%s) - 10#$ts)); [ "$age" -lt 0 ] && age=0
  args=${args//$'\t'/ }
  echo "held for $((age / 60)) min by 'run.sh${args:+ $args}' in ${chk//$'\t'/ }"
}

# The outer runner only waits; the locked one it starts runs the suites and is the only one
# that writes the holder record. lockf runs in the foreground, so an interrupt reaches the
# whole chain at once, as it did before the runner reported its wait. Every path out of
# this function is an exit; the guard after the call is for an expansion error, which bash
# answers by abandoning the whole top-level `if` (and its `exit`), not just the function.
take_lock() {
  local wait_max= poll since= waited=0 t=0 rc
  if [ -n "${RUN_SH_LOCK_WAIT+x}" ]; then
    case "$RUN_SH_LOCK_WAIT" in
      ''|*[!0-9]*) echo "run.sh: RUN_SH_LOCK_WAIT must be a non-negative integer" >&2; exit 2 ;;
    esac
    wait_max=$(norm "$RUN_SH_LOCK_WAIT")
  fi
  poll=${RUN_SH_LOCK_POLL:-60} # seconds between waiting lines; a seam for the tests
  case "$poll" in ''|*[!0-9]*) poll=60 ;; *) poll=$(norm "$poll"); [ "$poll" -gt 0 ] || poll=60 ;; esac
  mkdir -p "$(dirname "$lock")" || exit 2
  while :; do
    RUN_SH_LOCKED=1 RUN_SH_LOCK_OWNER=1 RUN_SH_LOCK_SINCE=$since lockf -s -k -t "$t" "$lock" "$self" "$@"
    rc=$?
    [ "$rc" -eq 73 ] && exit 2 # lockf could not open the lock file and said so
    [ "$rc" -eq 75 ] || exit "$rc"
    if [ -z "$since" ]; then
      since=$(date +%s)
    else
      waited=$(($(date +%s) - since)); [ "$waited" -lt 0 ] && waited=0
    fi
    if [ -n "$wait_max" ] && [ "$waited" -ge "$wait_max" ]; then
      echo "run.sh: giving up after $waited s: $(holder_clause)" >&2
      exit 75
    fi
    echo "run.sh: waiting for the test-run lock $lock, $(holder_clause)" >&2
    t=$poll
    [ -n "$wait_max" ] && [ $((wait_max - waited)) -lt "$t" ] && t=$((wait_max - waited))
  done
}

if [ "$one" -eq 0 ] && [ "${RUN_SH_LOCKED:-}" != 1 ]; then
  take_lock "$@"
  exit 2
fi
[ "$one" -eq 1 ] || [ "${RUN_SH_LOCKED:-}" = 1 ] || { echo "run.sh: the lock block failed; not running unlocked" >&2; exit 2; }
lock_owner=${RUN_SH_LOCK_OWNER:-} lock_since=${RUN_SH_LOCK_SINCE:-}
unset RUN_SH_LOCK_OWNER RUN_SH_LOCK_SINCE RUN_SH_LOCK_WAIT RUN_SH_LOCK_POLL
export RUN_SH_LOCKED=1
if [ "$lock_owner" = 1 ] && [ -n "$lock_since" ]; then
  e=$(($(date +%s) - lock_since)); [ "$e" -lt 0 ] && e=0
  if [ "$e" -ge 60 ]; then echo "run.sh: waited $((e / 60)) min for the test-run lock" >&2
  else echo "run.sh: waited $e s for the test-run lock" >&2; fi
fi

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

# map_check <file>: 0 when every row has four tab-separated fields, none with whitespace at
# either end, no CR, and a loaded_by of comma-separated names with no whitespace and no empty
# name (comment and empty lines are skipped); 1 when one has not, 2 when awk cannot read the
# file. Whitespace would otherwise become part of a name that never matches.
map_check() {
  awk -F'\t' '/^#/ || $0 == "" { next }
    NF != 4 || /\r/ || $4 ~ /[[:space:]]|^,|,,|,$/ { bad = 1; next }
    { for (i = 1; i <= 4; i++) if ($i ~ /^[[:space:]]|[[:space:]]$/) bad = 1 }
    END { exit bad }' "$1"
}

# map_rows <suite> <file>: the files of the rows whose loaded_by lists the suite, one per line.
map_rows() {
  SUITE=$1 awk -F'\t' '/^#/ || $0 == "" { next }
    { n = split($4, l, ","); for (i = 1; i <= n; i++) if (l[i] == ENVIRON["SUITE"]) { print $1; break } }' "$2" 2>/dev/null
}

# The files the branch changed and the two subject maps, read once for --changed. Any reason
# left in sel_reason selects every heavy suite. The caller sets it before the call and only a
# computation that ran to the end clears it, so a shell error that abandons this function
# (bash drops the whole enclosing command) can only select, never skip.
compute_selection() {
  local map_rel=.scripts/test-audit/subjects.tsv inside sha b rc tree c
  case $base in -*) sel_reason="base $base does not resolve"; return ;; esac
  inside=$(git -C "$repo_root" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null) || inside=
  [ "$inside" = true ] || { sel_reason="not a git work tree"; return; }
  sha=$(git -C "$repo_root" rev-parse --verify -q "$base^{commit}" 2>/dev/null) || { sel_reason="base $base does not resolve"; return; }
  b=$(git -C "$repo_root" merge-base "$sha" HEAD 2>/dev/null); rc=$?
  if [ "$rc" -eq 1 ]; then sel_reason="no merge base with $base"; return; fi
  if [ "$rc" -ne 0 ] || [ -z "$b" ]; then sel_reason="git failed"; return; fi
  sel_short=$(git -C "$repo_root" rev-parse --short "$b" 2>/dev/null) || { sel_reason="git failed"; return; }

  map_wt=$RUN_SH_WORK/map.wt map_base=$RUN_SH_WORK/map.base have_base=0
  [ -e "$repo_root/$map_rel" ] || { sel_reason="subject map missing"; return; }
  cat "$repo_root/$map_rel" >"$map_wt" 2>/dev/null || { sel_reason="subject map unreadable"; return; }
  map_check "$map_wt"; rc=$?
  if [ "$rc" -eq 1 ]; then sel_reason="subject map malformed"; return; fi
  if [ "$rc" -ne 0 ]; then sel_reason="subject map unreadable"; return; fi
  # Absence at the base is only a successful ls-tree that names nothing.
  tree=$(git -C "$repo_root" ls-tree "$b" -- "$map_rel" 2>/dev/null) || { sel_reason="git failed"; return; }
  if [ -n "$tree" ]; then
    git -C "$repo_root" show "$b:$map_rel" >"$map_base" 2>/dev/null || { sel_reason="subject map at $sel_short unreadable"; return; }
    map_check "$map_base"; rc=$?
    if [ "$rc" -eq 1 ]; then sel_reason="subject map at $sel_short malformed"; return; fi
    if [ "$rc" -ne 0 ]; then sel_reason="subject map at $sel_short unreadable"; return; fi
    have_base=1
  fi

  git -C "$repo_root" diff --name-only --no-renames -z "$b" -- >"$RUN_SH_WORK/changed.z" 2>/dev/null || { sel_reason="git failed"; return; }
  git -C "$repo_root" ls-files --others --exclude-standard -z >>"$RUN_SH_WORK/changed.z" 2>/dev/null || { sel_reason="git failed"; return; }
  changed_files=()
  while IFS= read -r -d '' c; do changed_files+=("$c"); done <"$RUN_SH_WORK/changed.z"
  sel_reason=
}

# changed_subjects <suite> sets why; returns 0 to run the heavy suite, 2 to skip it.
changed_subjects() {
  local subjects base_subjects i c hits
  if [ -n "$sel_reason" ]; then why=$sel_reason; return 0; fi
  subjects=$(map_rows "$1" "$map_wt") || { why="subject map unreadable"; return 0; }
  if [ -z "$subjects" ]; then why="no subject-map row"; return 0; fi
  if [ "$have_base" -eq 1 ]; then
    base_subjects=$(map_rows "$1" "$map_base") || { why="subject map at $sel_short unreadable"; return 0; }
    subjects="$subjects"$'\n'"$base_subjects"
  fi
  subjects="$subjects"$'\n'"tests/$1.test.sh"$'\n'"tests/run.sh"
  hits=()
  i=0
  while [ "$i" -lt "${#changed_files[@]}" ]; do
    c=${changed_files[$i]}
    case $'\n'"$subjects"$'\n' in *$'\n'"$c"$'\n'*) hits+=("$c") ;; esac
    i=$((i + 1))
  done
  if [ "${#hits[@]}" -eq 0 ]; then why="(no subject changed since $sel_short)"; return 2; fi
  why="changed: ${hits[0]}"
  if [ "${#hits[@]}" -gt 1 ]; then why="$why, +$((${#hits[@]} - 1)) more"; fi
  return 0
}

# select <file> sets name, req and why; returns 1 when the filters exclude the suite and 2 when
# its requirement gate skips it. Under --changed a heavy suite is gated by its subjects instead.
select_suite() {
  name=$(basename "$1" .test.sh)
  why=
  matches "$name" || return 1
  req=$(sed -n 's/^# test-requires: *//p' "$1" | head -1)
  req=${req%%  #*}
  if [ -n "$req" ] && [ "$all" -eq 0 ] && ! named "$name"; then
    [ "$changed" -eq 1 ] && [ "$req" = heavy ] && { changed_subjects "$name"; return $?; }
    return 2
  fi
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
trap 'rm -rf "$RUN_SH_WORK"; [ "$lock_owner" != 1 ] || rm -f "$lock.holder"' EXIT
trap 'exit 130' INT TERM

# The runner that took the lock says who it is: start time, checkout and arguments, one line
# with no tab or newline inside a field, written to a temporary file and renamed.
if [ "$lock_owner" = 1 ] && [ "$one" -eq 0 ]; then
  rec_args="$*"
  rec_args=${rec_args//$'\t'/ }; rec_args=${rec_args//$'\n'/ }
  rec_dir=${RUN_SH_START_DIR//$'\t'/ }; rec_dir=${rec_dir//$'\n'/ }
  { printf '%s\t%s\t%s\n' "$(date +%s)" "$rec_dir" "$rec_args" >"$lock.holder.$$" && mv "$lock.holder.$$" "$lock.holder"; } 2>/dev/null || rm -f "$lock.holder.$$"
fi

sel_reason="git failed" # the safe state; compute_selection clears it only when it ran to the end
[ "$changed" -eq 0 ] || compute_selection
# A shell error in a loop (an expansion error, say) abandons the whole top-level command, not
# just the loop, and the script goes on with what it had. Each suite loop is therefore a group
# whose last command records that it ran to the end: a selection that stopped partway runs no
# suite, and a report that stopped partway gives no verdict.
parallel=() serial=() dispatch_done=0
{ for f in ./*.test.sh; do
  select_suite "$f" || continue
  if grep -qE '^# test-serial([[:space:]]|$)' "$f" || { [ -n "$req" ] && [ "$req" != heavy ]; }; then
    serial+=("$name")
  else
    parallel+=("$name")
  fi
done; dispatch_done=1; }
[ "$dispatch_done" = 1 ] || { echo "run.sh: selecting the suites failed; running none" >&2; exit 2; }
[ ${#parallel[@]} -gt 0 ] && printf '%s\0' "${parallel[@]}" | xargs -0 -n1 -P "$jobs" "$self" --run-one
[ ${#serial[@]} -gt 0 ] && printf '%s\0' "${serial[@]}" | xargs -0 -n1 -P 1 "$self" --run-one

suites=0 green=0 red=0 broken=0 skipped=0 report_done=0
declare -a problems=()

{ for f in ./*.test.sh; do
  select_suite "$f"
  case $? in
    1) continue ;;
    2)
      printf '  skip  %-28s needs: %s%s\n' "$name" "$req" "${why:+ $why}"
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
  [ -n "$req" ] && note="  [needs: $req${why:+; $why}]"

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
    # A suite stopped by a guard says why in its first lines (`missing file under test: …`).
    # Never a KEY=VALUE line, so no status value is echoed.
    if printf '%s\n' "$out" | grep -qE '^[[:space:]]*INCONCLUSIVE:'; then
      show_inconclusive
    else
      printf '%s\n' "$out" | grep -vE '^[[:space:]]*$|^[A-Za-z_][A-Za-z0-9_.-]*=' | head -n 3 | sed 's/^/          /'
    fi
    problems+=("$name (asserted nothing)")
    broken=$((broken + 1))
  elif [ "$rc" -eq 0 ]; then
    printf '  ok    %-28s %s/%s%s\n' "$name" "$p" "$tot" "$note"
    green=$((green + p))
  else
    printf '  FAIL  %-28s %s/%s (exit=%s)%s\n' "$name" "$p" "$tot" "$rc" "$note"
    if [ "$idiom" = kv ]; then
      # A kv suite closes with failed_keys=<key>,<key> when it fails. That line is shown, and only when
      # it is made of key characters; no other line is echoed except INCONCLUSIVE: ones (below), so no
      # status value leaks.
      printf '%s\n' "$out" | grep -E '^failed_keys=[A-Za-z0-9_.,-]+$' | tail -n 1 | sed 's/^/          /'
      # A suite that could not measure one probe says so on INCONCLUSIVE: lines, which carry a
      # reason and a command, never a status value; a run that exits on that alone has no failed_keys.
      show_inconclusive
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
done; report_done=1; }
[ "$report_done" = 1 ] || { echo "run.sh: the report stopped partway; no verdict" >&2; exit 2; }

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

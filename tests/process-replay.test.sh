#!/usr/bin/env bash
# Tests for .scripts/process-replay.py and the package .scripts/process_replay/: the harness that
# measures, from October's recorded reviews, whether parts of the review process can be removed
# (spec docs/superpowers/specs/2026-11-02-replay-set-design.md).
#
# One tests/process-replay/t_<module>.py per module, each run with /usr/bin/python3 -I -B in an
# isolated git configuration. Each prints PASS:/FAIL: lines; this wrapper prints them and exits
# with the number of FAIL lines (a t_*.py that exits non-zero without printing FAIL counts as one).
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
for f in "$SRC/.scripts/process-replay.py" "$SRC/.scripts/process_replay/__init__.py" \
         "$SRC/.scripts/process_replay/common.py" "$SRC/.scripts/process_replay/scratch.py" \
         "$SRC/.scripts/process_replay/codexhome.py" "$SRC/.scripts/process_replay/inventory.py" \
         "$SRC/.scripts/process_replay/merges.py" "$SRC/.scripts/process_replay/inject.py" \
         "$SRC/.scripts/process_replay/loop.py" "$SRC/.scripts/process_replay/bar.py" \
         "$SRC/.scripts/process_replay/patches.py" "$SRC/.scripts/process_replay/gate.py" \
         "$SRC/.scripts/xreview-replay.py" "$SRC/dot_claude/xreview-packet.py" \
         "$SRC/dot_claude/xreview-ledger.py" "$SRC/tests/process-replay/helpers.py"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
shopt -s nullglob
suites=("$SRC"/tests/process-replay/t_*.py)
[ "${#suites[@]}" -gt 0 ] || { echo "no tests/process-replay/t_*.py" >&2; exit 2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prt.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$ROOT"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
mkdir -p "$ROOT/home" "$ROOT/state" "$ROOT/codex"
# A backstop: no t_*.py can reach the real ~/.local/state, ~/.codex or home directory by default.
export T_ROOT="$ROOT" HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state" CODEX_HOME="$ROOT/codex"

pass=0 fail=0
for t in "${suites[@]}"; do
  name="$(basename "$t")"
  echo "== $name"
  out="$(/usr/bin/python3 -I -B "$t" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  p=$(printf '%s\n' "$out" | grep -c '^  PASS:')
  f=$(printf '%s\n' "$out" | grep -c '^  FAIL:')
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
    echo "  FAIL: $name exited $rc without a FAIL line"
    f=1
  fi
  pass=$((pass + p))
  fail=$((fail + f))
done
printf '\npassed: %d/%d  failed: %d\n' "$pass" "$((pass + fail))" "$fail"
exit $((fail > 255 ? 255 : fail))

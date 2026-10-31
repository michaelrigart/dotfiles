#!/usr/bin/env bash
# Regenerates the golden packets in this directory: the oracle for "every switch off gives
# today's packet" (tests/xreview-packet.test.sh, K1).
#
# The reference is the dispatcher as it stood before xreview-packet.py existed:
#   git show 7aab009:dot_local/bin/executable_xreview
# It is run unmodified, with the stubs of that revision's tests/xreview.test.sh (herdr, lsof,
# codex-daemon and xreview-rpc on PATH; the stub xreview-rpc copies the packet it is handed
# to $P/packet). The stub block is lifted from that revision rather than copied here, so the
# fixtures never drift from the reference. Never regenerate them from a newer dispatcher: the
# point is that they do not change when xreview does.
#
# Writes next to this script:
#   reviewer.md                    the shipped reviewer instructions, overlaid on the reference tree
#   body-nl.md, body-nonl.md       the two bodies, ending in a newline and not
#   d1.patch, d2.patch               the two diffs, as the ledger prints them (spec in SPECS below)
#   {none,one,two}-{nl,nonl}.packet  the six packets
set -euo pipefail
# The reference ledger renders with the user's diff settings (diff.noprefix, diff.mnemonicPrefix):
# none may reach the fixtures. The fixture repository sets its own identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REF=7aab009
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
SPEC1='HEAD~1..HEAD'
SPEC2='HEAD~2..HEAD'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xreview-golden.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"; mkdir -p "$SRC"
git -C "$REPO_ROOT" archive "$REF" dot_config dot_local dot_claude | tar -x -C "$SRC"
# The reference tree carries the old reviewer.md; the golden packets follow the shipped one. Overlay it
# before the stub block copies it into place. The dispatcher, ledger and stubs stay the reference's.
cp "$REPO_ROOT/dot_config/xreview/reviewer.md" "$SRC/dot_config/xreview/reviewer.md"
git -C "$REPO_ROOT" show "$REF:tests/xreview.test.sh" > "$WORK/reference-test.sh"
XREVIEW="$SRC/dot_local/bin/executable_xreview"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
[ -f "$XREVIEW" ] && [ -f "$LEDGER" ] || { echo "reference $REF is missing the dispatcher or ledger" >&2; exit 2; }

# The reference suite's fixture repo, environment and stubs: from `ROOT=` up to `called()`.
sed -n '/^ROOT="\$(mktemp/,/^called() {/p' "$WORK/reference-test.sh" | sed '$d' > "$WORK/stubs.sh"
[ -s "$WORK/stubs.sh" ] || { echo "cannot lift the stub block from $REF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$WORK/stubs.sh"
trap 'rm -rf "$WORK" "$ROOT"' EXIT   # the lifted block set its own trap

# Two commits on top of the fixture repo, so both specs name a real, non-empty change.
printf 'alpha\nbeta\n' > a.txt && git add a.txt && git commit -q -m one
printf 'alpha\nbeta\ngamma\n' > a.txt
printf 'no newline at the end' > c.txt
git add a.txt c.txt && git commit -q -m two

printf 'Review this change.\nSettled: nothing.\n' > "$WORK/body-nl.md"
printf 'Review this change.\nSettled: nothing.' > "$WORK/body-nonl.md"

dispatch() { # dispatch <body> <packet name> [specs...]
  local body="$1" name="$2"; shift 2
  local args=() s
  for s in "$@"; do args+=(--diff "$s"); done
  fresh
  bash "$XREVIEW" dispatch --checkpoint plan "${args[@]+"${args[@]}"}" "$body" >/dev/null 2>&1 \
    || { echo "dispatch failed for $name" >&2; exit 1; }
  [ -f "$P/packet" ] || { echo "no packet captured for $name" >&2; exit 1; }
  cp "$P/packet" "$HERE/$name.packet"
}
for kind in nl nonl; do
  dispatch "$WORK/body-$kind.md" "none-$kind"
  dispatch "$WORK/body-$kind.md" "one-$kind" "$SPEC1"
  dispatch "$WORK/body-$kind.md" "two-$kind" "$SPEC1" "$SPEC2"
done

cp "$WORK/body-nl.md" "$WORK/body-nonl.md" "$HERE/"
cp "$SRC/dot_config/xreview/reviewer.md" "$HERE/reviewer.md"
python3 "$LEDGER" diff "$PWD" "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)" > "$HERE/d1.patch"
python3 "$LEDGER" diff "$PWD" "$(git rev-parse HEAD~2)" "$(git rev-parse HEAD)" > "$HERE/d2.patch"
chmod 644 "$HERE"/*.packet   # mktemp made them 600
printf 'wrote %s\n' "$(cd "$HERE" && ls ./*.packet | wc -l | tr -d ' ') packets to $HERE"

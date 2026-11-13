#!/usr/bin/env bash
set -u
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/lock.ran"
lockf -t 0 "$RUN_SH_LOCK" true
rc=$?
if [ "$rc" -eq 75 ] && [ "${RUN_SH_LOCKED:-}" = 1 ]; then
  echo "  PASS: lock is held during the run"
else
  echo "  FAIL: lock is held during the run (lockf rc=$rc, RUN_SH_LOCKED=${RUN_SH_LOCKED:-})"
  exit 1
fi

#!/usr/bin/env bash
set -u
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/red.ran"
echo "  PASS: the fine case"
echo "  FAIL: the broken case"
exit 1

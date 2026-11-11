#!/usr/bin/env bash
# test-requires: unsandboxed
set -u
[ -n "${AUDIT_MARKERS:-}" ] && echo run >> "$AUDIT_MARKERS/gated.ran"
echo "  PASS: needs a live machine"

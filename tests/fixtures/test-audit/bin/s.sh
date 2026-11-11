#!/usr/bin/env bash
# Fixture subject for the test-audit suite: a sourced library. A && B stays inert in a comment.
add() {
  echo $(( $1 + $2 ))
}
flag() {
  FLAG=on
  return 0
}
greet() {
  if [ -z "${1:-}" ]; then
    echo hello
  fi
}
scratch() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/s-scratch.XXXXXX") && echo "$d"; }
uncovered() {
  echo never-called
  [ -n "${1:-}" ] || return 1
}
banner() {
  cat <<EOF
exit 0
EOF
}

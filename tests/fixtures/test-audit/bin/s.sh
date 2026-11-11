#!/usr/bin/env bash
# Fixture subject for the test-audit suite: a sourced library.
add() { echo $(( $1 + $2 )); }
flag() { FLAG=on; }
greet() { echo hello; }
scratch() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/s-scratch.XXXXXX") && echo "$d"; }
uncovered() { echo never-called; }

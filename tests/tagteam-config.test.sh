#!/usr/bin/env bash
# Checks the chezmoi-managed tagteam settings with tagteam itself. A copy of the source file
# is read through XDG_CONFIG_HOME; it must yield threshold 95 and strategy consume-first,
# both from the file (source "global"), and leave every other key at its default. The
# source path carries private_ on the directory and the file, so chezmoi deploys them
# 0700/0600 as `tagteam doctor` requires; a rename away from that fails the existence check.
#
#   ./tests/tagteam-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$SRC/dot_config/private_tagteam/private_config.toml"
[ -f "$CFG" ] || { echo "missing file under test: $CFG" >&2; exit 2; }
command -v tagteam >/dev/null 2>&1 || { echo "tagteam is not installed (Brewfile)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/tagteam-config.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tagteam"
cp "$CFG" "$T/tagteam/config.toml"
chmod 700 "$T/tagteam"
chmod 600 "$T/tagteam/config.toml"
json=$(XDG_CONFIG_HOME="$T" tagteam config list --json 2>"$T/err") || { _fail "tagteam config list" "$json $(cat "$T/err")"; json='{}'; }
err=$(cat "$T/err")

if printf '%s' "$json" | jq -e '.keys[] | select(.key == "autoswitch.threshold") | .value == 95 and .source == "global"' >/dev/null; then
  _pass "autoswitch.threshold is 95, from the file"
else _fail "autoswitch.threshold" "$(printf '%s' "$json" | jq -c '.keys[]? | select(.key == "autoswitch.threshold")') stderr: $err"; fi

if printf '%s' "$json" | jq -e '.keys[] | select(.key == "autoswitch.strategy") | .value == "consume-first" and .source == "global"' >/dev/null; then
  _pass "autoswitch.strategy is consume-first, from the file"
else _fail "autoswitch.strategy" "$(printf '%s' "$json" | jq -c '.keys[]? | select(.key == "autoswitch.strategy")') stderr: $err"; fi

others=$(printf '%s' "$json" | jq -c '[.keys[]? | select(.source != "default") | .key] | sort')
if [ "$others" = '["autoswitch.strategy","autoswitch.threshold"]' ]; then
  _pass "no other key leaves its default"
else _fail "only the two autoswitch keys may be set" "$others stderr: $err"; fi

echo "tagteam-config: $pass passed, $fail failed"
exit "$fail"
